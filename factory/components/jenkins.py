"""Jenkins component - manages Jenkins credential storage and job creation."""

import logging
import time
import requests
from requests.auth import HTTPBasicAuth
import xml.etree.ElementTree as ET

from factory.components.base import Component
from factory.credentials.types import ApiToken, UserPass
from factory.model.credential import Credential

log = logging.getLogger("factory.components.jenkins")


class JenkinsComponent(Component):
    """
    Jenkins component implementation.
    
    Produces:
        - Nothing (sink component)
    
    Consumes:
        - ApiToken: Stores as Jenkins credential
        - UserPass: Stores as Jenkins credential
    """

    def __init__(self, artifact, config: dict):
        super().__init__(artifact, config)
        self.service = config.get('service', 'jenkins')
        self.namespace = config.get('namespace', 'default')
        self.port = config.get('port', 8080)
        self.admin_user = config.get('admin_user', 'admin')
        self.admin_pass = config.get('admin_pass', 'adminpwd')
        self._session = None
        self._crumb = None
        self._crumb_field = None

    @property
    def url(self) -> str:
        """Base URL of Jenkins API."""
        return f"http://{self.service}:{self.port}"

    @property
    def session(self) -> requests.Session:
        """Reusable HTTP session with authentication."""
        if self._session is None:
            self._session = requests.Session()
            self._session.auth = HTTPBasicAuth(self.admin_user, self.admin_pass)
        return self._session

    def ready(self) -> bool:
        """
        Check if Jenkins is ready to accept requests.
        
        Returns:
            True when Jenkins responds with 200
            
        Raises:
            TimeoutError: If Jenkins doesn't become ready
        """
        max_attempts = 60
        backoff = 5
        
        for attempt in range(max_attempts):
            try:
                resp = requests.get(f"{self.url}/login", timeout=3)
                if resp.status_code == 200:
                    log.info(f"Jenkins ready at {self.url}")
                    return True
            except requests.RequestException as e:
                log.debug(f"Jenkins not ready (attempt {attempt + 1}/{max_attempts}): {e}")
            
            time.sleep(backoff)
        
        raise TimeoutError(f"Jenkins not ready after {max_attempts * backoff}s")

    def produces(self) -> list[type[Credential]]:
        """Jenkins produces nothing (sink component)."""
        return []

    def consumes(self) -> list[type[Credential]]:
        """Jenkins consumes API tokens and username/password credentials."""
        return [ApiToken, UserPass]

    def extract(self, kind: type[Credential], for_consumer: str) -> Credential:
        """
        Jenkins doesn't produce credentials.
        
        Args:
            kind: Credential type
            for_consumer: Target component
            
        Raises:
            ValueError: Always, Jenkins is a sink
        """
        raise ValueError(f"Jenkins does not produce {kind}")

    def inject(self, credential: Credential) -> None:
        """
        Store credential in Jenkins.
        
        Args:
            credential: Credential to store
            
        Raises:
            ValueError: If credential type is not supported
        """
        if credential.kind == "ApiToken":
            self._inject_api_token(credential)
        elif credential.kind == "UserPass":
            self._inject_userpass(credential)
        else:
            raise ValueError(f"Jenkins cannot consume {credential.kind}")

    def verify(self, credential: Credential) -> bool:
        """
        Verify that a credential is stored in Jenkins.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if credential exists in Jenkins
        """
        if credential.kind == "ApiToken":
            return self._verify_api_token(credential)
        elif credential.kind == "UserPass":
            return self._verify_userpass(credential)
        return False

    def _get_crumb(self) -> tuple[str, str]:
        """
        Get Jenkins CSRF crumb.
        
        Returns:
            Tuple of (crumb_field, crumb_value)
            
        Raises:
            ValueError: If crumb cannot be fetched
        """
        if self._crumb is None:
            try:
                resp = self.session.get(
                    f"{self.url}/crumbIssuer/api/json",
                    timeout=10
                )
                resp.raise_for_status()
                data = resp.json()
                
                self._crumb_field = data.get('crumbRequestField')
                self._crumb = data.get('crumb')
                
                if not self._crumb or not self._crumb_field:
                    raise ValueError(f"Invalid crumb response: {data}")
                
                log.debug(f"Got Jenkins crumb: {self._crumb_field}")
                
            except Exception as e:
                raise ValueError(f"Failed to get Jenkins crumb: {e}")
        
        return self._crumb_field, self._crumb

    def _inject_api_token(self, credential: Credential) -> None:
        """
        Store API token as Jenkins StringCredentials.
        
        Args:
            credential: ApiToken credential
        """
        cred_id = f"{credential.producer}-api-token"
        token_value = credential.value.get('token')
        user = credential.value.get('user', 'unknown')
        
        log.info(f"Injecting API token: {cred_id}")
        
        # XML for StringCredentials
        xml = f"""<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl plugin="plain-credentials">
  <scope>GLOBAL</scope>
  <id>{cred_id}</id>
  <description>{credential.producer} API token</description>
  <secret>{token_value}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>"""
        
        self._upsert_credential(cred_id, xml)

    def _inject_userpass(self, credential: Credential) -> None:
        """
        Store username/password as Jenkins UsernamePasswordCredentials.
        
        Args:
            credential: UserPass credential
        """
        cred_id = f"{credential.producer}-userpass"
        username = credential.value.get('username')
        password = credential.value.get('password')
        
        log.info(f"Injecting userpass: {cred_id}")
        
        # XML for UsernamePasswordCredentials
        xml = f"""<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>{cred_id}</id>
  <description>{credential.producer} username + password</description>
  <username>{username}</username>
  <password>{password}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"""
        
        self._upsert_credential(cred_id, xml)

    def _upsert_credential(self, cred_id: str, xml: str) -> None:
        """
        Upsert (delete + create) credential in Jenkins.
        
        Args:
            cred_id: Credential ID
            xml: Credential XML definition
        """
        crumb_field, crumb = self._get_crumb()
        
        # Try to delete existing credential
        try:
            self.session.post(
                f"{self.url}/credentials/store/system/domain/_/credential/{cred_id}/doDelete",
                headers={crumb_field: crumb},
                timeout=10
            )
            log.debug(f"Deleted existing credential: {cred_id}")
        except Exception:
            pass  # Credential might not exist
        
        # Create credential
        try:
            resp = self.session.post(
                f"{self.url}/credentials/store/system/domain/_/createCredentials",
                headers={
                    crumb_field: crumb,
                    'Content-Type': 'application/xml'
                },
                data=xml.encode('utf-8'),
                timeout=10
            )
            
            if resp.status_code in [200, 302]:
                log.info(f"Credential created: {cred_id}")
            else:
                log.warning(f"Credential creation returned: {resp.status_code}")
                
        except Exception as e:
            log.error(f"Credential creation failed: {e}")
            raise

    def _verify_api_token(self, credential: Credential) -> bool:
        """
        Verify API token credential exists in Jenkins.
        
        Args:
            credential: ApiToken to verify
            
        Returns:
            True if credential exists
        """
        cred_id = f"{credential.producer}-api-token"
        return self._credential_exists(cred_id)

    def _verify_userpass(self, credential: Credential) -> bool:
        """
        Verify userpass credential exists in Jenkins.
        
        Args:
            credential: UserPass to verify
            
        Returns:
            True if credential exists
        """
        cred_id = f"{credential.producer}-userpass"
        return self._credential_exists(cred_id)

    def _credential_exists(self, cred_id: str) -> bool:
        """
        Check if credential exists in Jenkins.
        
        Args:
            cred_id: Credential ID to check
            
        Returns:
            True if credential exists
        """
        try:
            resp = self.session.get(
                f"{self.url}/credentials/store/system/domain/_/credential/{cred_id}/api/json",
                timeout=10
            )
            
            if resp.status_code == 200:
                log.debug(f"Credential verified: {cred_id}")
                return True
            else:
                log.warning(f"Credential not found: {cred_id}")
                return False
                
        except Exception as e:
            log.error(f"Credential verification failed: {e}")
            return False

    def create_pipeline(self, name: str, repo_url: str, 
                       credential_id: str = "gitea-userpass",
                       branch: str = "*/main") -> bool:
        """
        Create Jenkins pipeline job pointing to Gitea repo.
        
        Args:
            name: Job name
            repo_url: Git repository URL
            credential_id: Jenkins credential ID for git clone
            branch: Branch specification
            
        Returns:
            True if job created successfully
        """
        log.info(f"Creating pipeline job: {name}")
        
        crumb_field, crumb = self._get_crumb()
        
        # Build job XML
        job_xml = f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>{name}</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>{repo_url}</url>
          <credentialsId>{credential_id}</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>{branch}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>"""
        
        # Delete existing job if present
        try:
            self.session.post(
                f"{self.url}/job/{name}/doDelete",
                headers={crumb_field: crumb},
                timeout=10
            )
            log.debug(f"Deleted existing job: {name}")
        except Exception:
            pass
        
        # Create job
        try:
            resp = self.session.post(
                f"{self.url}/createItem",
                params={'name': name},
                headers={
                    crumb_field: crumb,
                    'Content-Type': 'application/xml'
                },
                data=job_xml.encode('utf-8'),
                timeout=10
            )
            
            if resp.status_code in [200, 302]:
                log.info(f"Pipeline job created: {name}")
                return True
            else:
                log.warning(f"Job creation returned: {resp.status_code}")
                return False
                
        except Exception as e:
            log.error(f"Job creation failed: {e}")
            return False
