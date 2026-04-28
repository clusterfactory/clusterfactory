"""Gitea component - manages Gitea API operations."""
import base64
import logging
import os
import time
from typing import Type
import requests
from requests.auth import HTTPBasicAuth

from ..component import Component
from ..credential import Credential, ApiToken, UserPass
from ..resolver import register

log = logging.getLogger("gitea")


@register("gitea")
class GiteaComponent(Component):
    """Gitea component implementation.
    
    Produces:
        - ApiToken: API token for accessing Gitea API
        - UserPass: Converted from ApiToken for git operations
    
    Consumes:
        - Nothing (seed component)
    """

    def __init__(self, name: str, config: dict):
        super().__init__(name, config)
        self.service = config.get('service', 'gitea-http.default.svc.cluster.local')
        self.port = config.get('port', 3000)
        self.admin_user = config.get('admin_user', 'gitea-admin')
        self.admin_pass = os.getenv(config.get('admin_pass_env', 'GITEA_PASS'), '')
        self.org = config.get('org', 'cf-demo')
        self.repo = config.get('repo', 'hello-world')
        self.bootstrap_files = config.get('bootstrap_files', [])
        self.timeout = 30  # All requests use explicit timeout
        self._session = None

    @property
    def url(self) -> str:
        """Base URL of Gitea API."""
        return f"http://{self.service}:{self.port}"

    @property
    def session(self) -> requests.Session:
        """Reusable HTTP session with auth."""
        if self._session is None:
            self._session = requests.Session()
            self._session.auth = HTTPBasicAuth(self.admin_user, self.admin_pass)
        return self._session

    def ready(self) -> bool:
        """Check if Gitea is ready to accept requests.
        
        Returns:
            True when Gitea responds with 200
            
        Raises:
            TimeoutError: If Gitea doesn't become ready
        """
        max_attempts = 60
        backoff = 5
        
        for attempt in range(max_attempts):
            try:
                resp = requests.get(self.url, timeout=5)
                if resp.status_code == 200:
                    log.info(f"ready at {self.url}")
                    return True
            except requests.RequestException:
                pass
            
            if attempt < max_attempts - 1:
                time.sleep(backoff)
        
        raise TimeoutError(f"Gitea not ready after {max_attempts * backoff}s")

    def produces(self) -> list[Type[Credential]]:
        """Gitea produces API tokens and UserPass credentials."""
        return [ApiToken, UserPass]

    def consumes(self) -> list[Type[Credential]]:
        """Gitea consumes nothing (seed component)."""
        return []

    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential:
        """Generate and return a credential.
        
        Args:
            kind: ApiToken or UserPass
            for_consumer: Target component name
            
        Returns:
            Credential instance
            
        Raises:
            ValueError: If credential type is not supported
        """
        if kind == ApiToken:
            return self._mint_api_token(for_consumer)
        elif kind == UserPass:
            # UserPass is ApiToken converted for git clone
            token_cred = self._mint_api_token(for_consumer)
            return UserPass(
                producer=self.name,
                consumer=for_consumer,
                value={
                    "username": self.admin_user,
                    "password": token_cred.value["token"]
                }
            )
        else:
            raise ValueError(f"Gitea cannot produce {kind}")

    def inject(self, credential: Credential) -> None:
        """Gitea consumes nothing (seed component)."""
        pass

    def verify(self, credential: Credential) -> bool:
        """Verify that a credential exists and is valid.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if credential is valid
        """
        if credential.kind == "ApiToken":
            return self._verify_api_token(credential)
        elif credential.kind == "UserPass":
            # For UserPass, verify the underlying token exists
            token_name = f"{credential.consumer}-wiring"
            return self._token_exists(token_name)
        return False

    def _mint_api_token(self, for_consumer: str) -> ApiToken:
        """Mint a new API token for the target consumer.
        
        Idempotent: Deletes existing token with same name before creating.
        
        Args:
            for_consumer: Target component name
            
        Returns:
            ApiToken credential
        """
        token_name = f"{for_consumer}-wiring"
        log.info(f"minting API token: {token_name}")
        
        # Delete existing token if present (idempotency)
        self._delete_token_if_exists(token_name)
        
        # Create new token
        token_request = {
            "name": token_name,
            "scopes": [
                "write:repository",
                "write:user",
                "write:organization"
            ]
        }
        
        resp = self.session.post(
            f"{self.url}/api/v1/users/{self.admin_user}/tokens",
            json=token_request,
            timeout=self.timeout
        )
        resp.raise_for_status()
        
        token_data = resp.json()
        token_value = token_data.get('sha1')
        
        if not token_value:
            # Redact sensitive fields before logging
            safe_data = {k: v for k, v in token_data.items() 
                        if k not in ['sha1', 'token']}
            raise ValueError(f"Token mint failed: {safe_data}")
        
        log.info(f"token minted: {token_name}")
        
        # After minting token, bootstrap org + repo + files
        self._bootstrap()
        
        return ApiToken(
            producer=self.name,
            consumer=for_consumer,
            value={
                "token": token_value,
                "user": self.admin_user,
                "name": token_name
            }
        )

    def _bootstrap(self):
        """Bootstrap org, repo, and files after token is minted."""
        # Create org
        log.info(f"creating org: {self.org}")
        org_data = {"username": self.org, "visibility": "public"}
        
        resp = self.session.post(
            f"{self.url}/api/v1/orgs",
            json=org_data,
            timeout=self.timeout
        )
        
        if resp.status_code in [201, 422]:  # 422 = already exists
            log.info(f"org ready: {self.org}")
        else:
            log.warning(f"org creation returned {resp.status_code}")
        
        # Create repo
        log.info(f"creating repo: {self.org}/{self.repo}")
        repo_data = {
            "name": self.repo,
            "private": False,
            "auto_init": True,  # Create with README so we have a default branch
            "default_branch": "main"
        }
        
        resp = self.session.post(
            f"{self.url}/api/v1/orgs/{self.org}/repos",
            json=repo_data,
            timeout=self.timeout
        )
        
        if resp.status_code in [201, 409]:  # 409 = already exists
            log.info(f"repo ready: {self.org}/{self.repo}")
        else:
            log.warning(f"repo creation returned {resp.status_code}")
        
        # Wait a bit for repo to be ready
        time.sleep(2)
        
        # Push bootstrap files
        for file_spec in self.bootstrap_files:
            file_path = file_spec.get('path')
            source_path = file_spec.get('source')
            
            if not file_path or not source_path:
                log.warning(f"invalid file spec: {file_spec}")
                continue
            
            try:
                with open(source_path, 'rb') as f:
                    content = f.read()
                self._push_file(file_path, content, f"Add {file_path}")
            except Exception as e:
                log.error(f"failed to push {file_path}: {e}")

    def _push_file(self, path: str, content: bytes, message: str):
        """Push file to repository using Contents API.
        
        Args:
            path: File path in repo
            content: File content as bytes
            message: Commit message
        """
        log.info(f"pushing file: {path}")
        
        b64_content = base64.b64encode(content).decode('utf-8')
        
        # Check if file exists
        resp = self.session.get(
            f"{self.url}/api/v1/repos/{self.org}/{self.repo}/contents/{path}",
            timeout=self.timeout
        )
        
        if resp.status_code == 200:
            # File exists, update it
            existing_sha = resp.json().get('sha')
            update_data = {
                "message": message,
                "content": b64_content,
                "sha": existing_sha
            }
            
            resp = self.session.put(
                f"{self.url}/api/v1/repos/{self.org}/{self.repo}/contents/{path}",
                json=update_data,
                timeout=self.timeout
            )
        else:
            # File doesn't exist, create it
            create_data = {
                "message": message,
                "content": b64_content
            }
            
            resp = self.session.post(
                f"{self.url}/api/v1/repos/{self.org}/{self.repo}/contents/{path}",
                json=create_data,
                timeout=self.timeout
            )
        
        if resp.status_code in [200, 201]:
            log.info(f"file pushed: {path}")
        else:
            log.warning(f"file push returned {resp.status_code}")

    def _delete_token_if_exists(self, token_name: str):
        """Delete token if it exists (for idempotency)."""
        try:
            tokens = self.session.get(
                f"{self.url}/api/v1/users/{self.admin_user}/tokens",
                timeout=self.timeout
            ).json()
            
            for token_data in tokens:
                if token_data.get('name') == token_name:
                    token_id = token_data.get('id')
                    self.session.delete(
                        f"{self.url}/api/v1/users/{self.admin_user}/tokens/{token_id}",
                        timeout=self.timeout
                    )
                    log.debug(f"deleted existing token: {token_name}")
                    break
        except Exception as e:
            log.warning(f"could not check existing tokens: {e}")

    def _token_exists(self, token_name: str) -> bool:
        """Check if token exists."""
        try:
            tokens = self.session.get(
                f"{self.url}/api/v1/users/{self.admin_user}/tokens",
                timeout=self.timeout
            ).json()
            
            for token_data in tokens:
                if token_data.get('name') == token_name:
                    return True
            return False
        except Exception:
            return False

    def _verify_api_token(self, credential: Credential) -> bool:
        """Verify API token exists in Gitea."""
        token_name = credential.value.get('name')
        return self._token_exists(token_name)
