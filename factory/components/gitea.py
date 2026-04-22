"""Gitea component - manages Gitea API operations."""

import logging
import time
import requests
from requests.auth import HTTPBasicAuth

from factory.components.base import Component
from factory.credentials.types import ApiToken, RunnerToken
from factory.model.credential import Credential

log = logging.getLogger("factory.components.gitea")


class GiteaComponent(Component):
    """
    Gitea component implementation.
    
    Produces:
        - ApiToken: API token for accessing Gitea API
        - RunnerToken: Registration token for Gitea Actions runners
    
    Consumes:
        - Nothing (seed component)
    """

    def __init__(self, artifact, config: dict):
        super().__init__(artifact, config)
        self.service = config.get('service', 'gitea-http')
        self.namespace = config.get('namespace', 'default')
        self.port = config.get('port', 3000)
        self.admin_user = config.get('admin_user', 'gitea')
        self.admin_pass = config.get('admin_pass', 'giteapwd')
        self.timeout = config.get('timeout', 30)  # Default 30s timeout
        self._session = None

    @property
    def url(self) -> str:
        """Base URL of Gitea API."""
        return f"http://{self.service}:{self.port}"

    @property
    def session(self) -> requests.Session:
        """Reusable HTTP session."""
        if self._session is None:
            self._session = requests.Session()
            self._session.auth = HTTPBasicAuth(self.admin_user, self.admin_pass)
        return self._session

    def ready(self) -> bool:
        """
        Check if Gitea is ready to accept requests.
        
        Returns:
            True when Gitea responds with 200
            
        Raises:
            TimeoutError: If Gitea doesn't become ready
        """
        max_attempts = 60
        backoff = 5
        
        for attempt in range(max_attempts):
            try:
                resp = requests.get(self.url, timeout=3)
                if resp.status_code == 200:
                    log.info(f"Gitea ready at {self.url}")
                    return True
            except requests.RequestException as e:
                log.debug(f"Gitea not ready (attempt {attempt + 1}/{max_attempts}): {e}")
            
            time.sleep(backoff)
        
        raise TimeoutError(f"Gitea not ready after {max_attempts * backoff}s")

    def produces(self) -> list[type[Credential]]:
        """Gitea produces API tokens and runner tokens."""
        return [ApiToken, RunnerToken]

    def consumes(self) -> list[type[Credential]]:
        """Gitea consumes nothing (seed component)."""
        return []

    def extract(self, kind: type[Credential], for_consumer: str) -> Credential:
        """
        Generate and return a credential.
        
        Args:
            kind: ApiToken or RunnerToken
            for_consumer: Target component name
            
        Returns:
            Credential instance
            
        Raises:
            ValueError: If credential type is not supported
        """
        if kind == ApiToken:
            return self._mint_api_token(for_consumer)
        elif kind == RunnerToken:
            return self._fetch_runner_token(for_consumer)
        else:
            raise ValueError(f"Gitea cannot produce {kind}")

    def inject(self, credential: Credential) -> None:
        """
        Gitea consumes nothing (seed component).
        
        Args:
            credential: Credential to inject (ignored)
        """
        pass

    def verify(self, credential: Credential) -> bool:
        """
        Verify that a credential exists and is valid.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if credential is valid
        """
        if credential.kind == "ApiToken":
            return self._verify_api_token(credential)
        elif credential.kind == "RunnerToken":
            return self._verify_runner_token(credential)
        return False

    def _mint_api_token(self, for_consumer: str) -> ApiToken:
        """
        Mint a new API token for the target consumer.
        
        Idempotent: Deletes existing token with same name before creating.
        
        Args:
            for_consumer: Target component name
            
        Returns:
            ApiToken credential
        """
        token_name = f"{for_consumer}-wiring"
        log.info(f"Minting API token: {token_name}")
        
        # Delete existing token if present
        try:
            existing_tokens = self.session.get(
                f"{self.url}/api/v1/users/{self.admin_user}/tokens",
                timeout=self.timeout
            ).json()
            
            for token_data in existing_tokens:
                if token_data.get('name') == token_name:
                    token_id = token_data.get('id')
                    self.session.delete(
                        f"{self.url}/api/v1/users/{self.admin_user}/tokens/{token_id}",
                        timeout=self.timeout
                    )
                    log.debug(f"Deleted existing token: {token_name}")
                    break
        except Exception as e:
            log.warning(f"Could not check existing tokens: {e}")
        
        # Create new token
        token_request = {
            "name": token_name,
            "scopes": [
                "write:repository",
                "write:user",
                "write:organization",
                "write:issue"
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
            safe_data = {k: v for k, v in token_data.items() if k not in ['sha1', 'token']}
            raise ValueError(f"Token mint failed: {safe_data}")
        
        log.info(f"API token minted: {token_name}")
        
        return ApiToken(
            producer=self.name,
            consumer=for_consumer,
            value={
                "token": token_value,
                "user": self.admin_user,
                "name": token_name
            }
        )

    def _fetch_runner_token(self, for_consumer: str) -> RunnerToken:
        """
        Fetch runner registration token from Gitea.
        
        Args:
            for_consumer: Target component name
            
        Returns:
            RunnerToken credential
        """
        log.info(f"Fetching runner token for: {for_consumer}")
        
        # Get runner registration token
        # Note: This requires Gitea Actions to be enabled
        # For now, return a placeholder - proper implementation needs
        # Gitea Actions API endpoint
        
        return RunnerToken(
            producer=self.name,
            consumer=for_consumer,
            value={
                "token": "runner-registration-token-placeholder",
                "url": self.url
            }
        )

    def _verify_api_token(self, credential: Credential) -> bool:
        """
        Verify API token exists in Gitea.
        
        Args:
            credential: ApiToken to verify
            
        Returns:
            True if token is valid
        """
        token_name = credential.value.get('name')
        
        try:
            tokens = self.session.get(
                f"{self.url}/api/v1/users/{self.admin_user}/tokens",
                timeout=self.timeout
            ).json()
            
            for token_data in tokens:
                if token_data.get('name') == token_name:
                    log.debug(f"Token verified: {token_name}")
                    return True
            
            log.warning(f"Token not found: {token_name}")
            return False
            
        except Exception as e:
            log.error(f"Token verification failed: {e}")
            return False

    def _verify_runner_token(self, credential: Credential) -> bool:
        """
        Verify runner token is valid.
        
        Args:
            credential: RunnerToken to verify
            
        Returns:
            True (placeholder)
        """
        return True

    def create_org(self, name: str, visibility: str = "private") -> bool:
        """
        Create organization in Gitea.
        
        Args:
            name: Organization name
            visibility: Organization visibility (public/private)
            
        Returns:
            True if created or already exists
        """
        log.info(f"Creating org: {name}")
        
        org_data = {
            "username": name,
            "visibility": visibility
        }
        
        try:
            resp = self.session.post(
                f"{self.url}/api/v1/orgs",
                json=org_data,
                timeout=self.timeout
            )
            
            if resp.status_code in [201, 422]:  # 422 = already exists
                log.info(f"Org ready: {name}")
                return True
            else:
                log.warning(f"Org creation returned: {resp.status_code}")
                return False
                
        except Exception as e:
            log.error(f"Org creation failed: {e}")
            return False

    def create_repo(self, org: str, name: str, private: bool = False) -> bool:
        """
        Create repository in organization.
        
        Args:
            org: Organization name
            name: Repository name
            private: Whether repository is private
            
        Returns:
            True if created or already exists
        """
        log.info(f"Creating repo: {org}/{name}")
        
        repo_data = {
            "name": name,
            "private": private,
            "auto_init": False,
            "default_branch": "main"
        }
        
        try:
            resp = self.session.post(
                f"{self.url}/api/v1/orgs/{org}/repos",
                json=repo_data,
                timeout=self.timeout
            )
            
            if resp.status_code in [201, 409]:  # 409 = already exists
                log.info(f"Repo ready: {org}/{name}")
                return True
            else:
                log.warning(f"Repo creation returned: {resp.status_code}")
                return False
                
        except Exception as e:
            log.error(f"Repo creation failed: {e}")
            return False

    def push_file(self, org: str, repo: str, path: str, 
                  content: bytes, message: str = "update") -> bool:
        """
        Push file to repository using Gitea Contents API.
        
        Args:
            org: Organization name
            repo: Repository name
            path: File path in repo
            content: File content as bytes
            message: Commit message
            
        Returns:
            True if pushed successfully
        """
        import base64
        
        log.info(f"Pushing file: {org}/{repo}/{path}")
        
        b64_content = base64.b64encode(content).decode('utf-8')
        
        # Check if file exists (to get SHA for update)
        try:
            resp = self.session.get(
                f"{self.url}/api/v1/repos/{org}/{repo}/contents/{path}",
                timeout=self.timeout
            )
            
            if resp.status_code == 200:
                # File exists, update it
                existing_sha = resp.json().get('sha')
                update_data = {
                    "message": f"update {path}",
                    "content": b64_content,
                    "sha": existing_sha
                }
                
                resp = self.session.put(
                    f"{self.url}/api/v1/repos/{org}/{repo}/contents/{path}",
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
                    f"{self.url}/api/v1/repos/{org}/{repo}/contents/{path}",
                    json=create_data,
                    timeout=self.timeout
                )
            
            if resp.status_code in [200, 201]:
                log.info(f"File pushed: {path}")
                return True
            else:
                log.warning(f"File push returned: {resp.status_code}")
                return False
                
        except Exception as e:
            log.error(f"File push failed: {e}")
            return False
