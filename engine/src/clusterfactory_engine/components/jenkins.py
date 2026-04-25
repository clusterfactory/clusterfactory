"""Jenkins component - manages Jenkins credential storage and job creation."""
import logging
import os
import time
from typing import Type
import requests
from requests.auth import HTTPBasicAuth
from xml.sax.saxutils import escape as xml_escape

from ..component import Component
from ..credential import Credential, ApiToken, UserPass
from ..resolver import register

log = logging.getLogger("jenkins")


@register("jenkins")
class JenkinsComponent(Component):
    """Jenkins component implementation.
    
    Produces:
        - Nothing (sink component)
    
    Consumes:
        - ApiToken: Stores as Jenkins credential
        - UserPass: Stores as Jenkins credential
    """

    def __init__(self, name: str, config: dict):
        super().__init__(name, config)
        self.service = config.get('service', 'jenkins.default.svc.cluster.local')
        self.port = config.get('port', 8080)
        self.admin_user = config.get('admin_user', 'admin')
        self.admin_pass = os.getenv(config.get('admin_pass_env', 'JENKINS_PASS'), '')
        self.pipeline_name = config.get('pipeline_name', 'demo-pipeline')
        self.timeout = 30  # All requests use explicit timeout
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
        """Check if Jenkins is ready to accept requests.
        
        Returns:
            True when Jenkins responds with 200
            
        Raises:
            TimeoutError: If Jenkins doesn't become ready
        """
        max_attempts = 60
        backoff = 5
        
        for attempt in range(max_attempts):
            try:
                resp = requests.get(f"{self.url}/login", timeout=5)
                if resp.status_code == 200:
                    log.info(f"ready at {self.url}")
                    return True
            except requests.RequestException:
                pass
            
            if attempt < max_attempts - 1:
                time.sleep(backoff)
        
        raise TimeoutError(f"Jenkins not ready after {max_attempts * backoff}s")

    def produces(self) -> list[Type[Credential]]:
        """Jenkins produces nothing (sink component)."""
        return []

    def consumes(self) -> list[Type[Credential]]:
        """Jenkins consumes API tokens and username/password credentials."""
        return [ApiToken, UserPass]

    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential:
        """Jenkins doesn't produce credentials."""
        raise ValueError(f"Jenkins does not produce {kind}")

    def inject(self, credential: Credential) -> None:
        """Store credential in Jenkins.
        
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
        """Verify that a credential is stored in Jenkins.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if credential exists in Jenkins
        """
        if credential.kind == "ApiToken":
            cred_id = f"{credential.producer}-api-token"
        elif credential.kind == "UserPass":
            cred_id = f"{credential.producer}-userpass"
        else:
            return False
        
        return self._credential_exists(cred_id)

    def _get_crumb(self) -> tuple[str, str]:
        """Get Jenkins CSRF crumb.
        
        Returns:
            Tuple of (crumb_field, crumb_value)
            
        Raises:
            ValueError: If crumb cannot be fetched
        """
        if self._crumb is None:
            try:
                resp = self.session.get(
                    f"{self.url}/crumbIssuer/api/json",
                    timeout=self.timeout
                )
                resp.raise_for_status()
                data = resp.json()
                
                self._crumb_field = data.get('crumbRequestField')
                self._crumb = data.get('crumb')
                
                if not self._crumb or not self._crumb_field:
                    raise ValueError(f"Invalid crumb response")
                
                log.debug(f"got crumb: {self._crumb_field}")
                
            except Exception as e:
                raise ValueError(f"Failed to get Jenkins crumb: {e}")
        
        return self._crumb_field, self._crumb

    def _inject_api_token(self, credential: Credential) -> None:
        """Store API token as Jenkins StringCredentials.
        
        Args:
            credential: ApiToken credential
        """
        cred_id = f"{credential.producer}-api-token"
        token_value = credential.value.get('token')
        
        log.info(f"injecting API token: {cred_id}")
        
        # XML with proper escaping (security fix)
        xml = f"""<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl plugin="plain-credentials">
  <scope>GLOBAL</scope>
  <id>{xml_escape(cred_id)}</id>
  <description>{xml_escape(credential.producer)} API token</description>
  <secret>{xml_escape(token_value)}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>"""
        
        self._upsert_credential(cred_id, xml)

    def _inject_userpass(self, credential: Credential) -> None:
        """Store username/password as Jenkins UsernamePasswordCredentials.
        
        After storing, create the pipeline job that uses this credential.
        
        Args:
            credential: UserPass credential
        """
        cred_id = f"{credential.producer}-userpass"
        username = credential.value.get('username')
        password = credential.value.get('password')
        
        log.info(f"injecting userpass: {cred_id}")
        
        # XML with proper escaping (security fix)
        xml = f"""<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>{xml_escape(cred_id)}</id>
  <description>{xml_escape(credential.producer)} username + password</description>
  <username>{xml_escape(username)}</username>
  <password>{xml_escape(password)}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"""
        
        self._upsert_credential(cred_id, xml)
        
        # After credential is stored, create the pipeline job
        self._create_pipeline(cred_id, credential.producer)

    def _upsert_credential(self, cred_id: str, xml: str) -> None:
        """Upsert (delete + create) credential in Jenkins.
        
        Args:
            cred_id: Credential ID
            xml: Credential XML definition
        """
        crumb_field, crumb = self._get_crumb()
        
        # Try to delete existing credential (idempotency)
        try:
            self.session.post(
                f"{self.url}/credentials/store/system/domain/_/credential/{cred_id}/doDelete",
                headers={crumb_field: crumb},
                timeout=self.timeout
            )
            log.debug(f"deleted existing credential: {cred_id}")
        except Exception:
            pass  # Credential might not exist
        
        # Create credential
        resp = self.session.post(
            f"{self.url}/credentials/store/system/domain/_/createCredentials",
            headers={
                crumb_field: crumb,
                'Content-Type': 'application/xml'
            },
            data=xml.encode('utf-8'),
            timeout=self.timeout
        )
        
        if resp.status_code in [200, 302]:
            log.info(f"credential created: {cred_id}")
        else:
            log.warning(f"credential creation returned {resp.status_code}")
            raise ValueError(f"Failed to create credential: {resp.status_code}")

    def _create_pipeline(self, credential_id: str, git_source: str) -> None:
        """Create Jenkins pipeline job pointing to Gitea repo.
        
        Args:
            credential_id: Jenkins credential ID for git clone
            git_source: Source component name (e.g., "gitea")
        """
        job_name = self.pipeline_name
        log.info(f"creating pipeline job: {job_name}")
        
        # Construct repo URL from config
        # Assumes gitea component config has org and repo
        repo_url = f"http://cf-gitea-http:3000/cf-demo/hello-world.git"
        
        crumb_field, crumb = self._get_crumb()
        
        # Build job XML with proper escaping (security fix)
        job_xml = f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>{xml_escape(job_name)}</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>{xml_escape(repo_url)}</url>
          <credentialsId>{xml_escape(credential_id)}</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
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
        
        # Delete existing job if present (idempotency)
        try:
            self.session.post(
                f"{self.url}/job/{job_name}/doDelete",
                headers={crumb_field: crumb},
                timeout=self.timeout
            )
            log.debug(f"deleted existing job: {job_name}")
        except Exception:
            pass
        
        # Create job
        resp = self.session.post(
            f"{self.url}/createItem",
            params={'name': job_name},
            headers={
                crumb_field: crumb,
                'Content-Type': 'application/xml'
            },
            data=job_xml.encode('utf-8'),
            timeout=self.timeout
        )
        
        if resp.status_code in [200, 302]:
            log.info(f"pipeline job created: {job_name}")
        else:
            log.warning(f"job creation returned {resp.status_code}")

    def _credential_exists(self, cred_id: str) -> bool:
        """Check if credential exists in Jenkins.
        
        Args:
            cred_id: Credential ID to check
            
        Returns:
            True if credential exists
        """
        try:
            resp = self.session.get(
                f"{self.url}/credentials/store/system/domain/_/credential/{cred_id}/api/json",
                timeout=self.timeout
            )
            
            if resp.status_code == 200:
                log.debug(f"credential verified: {cred_id}")
                return True
            else:
                return False
                
        except Exception:
            return False
