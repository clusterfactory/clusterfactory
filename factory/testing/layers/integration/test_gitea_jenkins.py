"""Integration tests for full Gitea-Jenkins wiring."""

import pytest
from factory.model.platform import Platform
from factory.engine.executor import Executor
from factory.engine.resolver import Resolver
from factory.engine.planner import Planner
from factory.engine.verifier import Verifier
from factory.engine.hasher import Hasher
from factory.health.checker import HealthChecker
from factory.components.gitea import GiteaComponent
from factory.components.jenkins import JenkinsComponent


@pytest.mark.integration
def test_full_gitea_jenkins_wire(platform_gitea_jenkins, live_cluster):
    """
    Full integration test: Wire Gitea → Jenkins with live services.
    
    Prerequisites:
        - Gitea deployed and accessible
        - Jenkins deployed and accessible
        - Admin credentials available
    
    Verifies:
        - Platform loads correctly
        - Components resolve
        - Health checks pass
        - Wiring executes
        - Credentials are stored
        - Structural SHA is computed
        - All verifications pass
    """
    # Load platform
    platform = Platform.from_yaml(platform_gitea_jenkins)
    
    assert platform.name == "gitea-jenkins"
    assert len(platform.artifacts) == 2
    assert len(platform.wiring) == 1
    
    # Create executor with live config
    config = {
        'namespace': live_cluster['namespace'],
        'admin_user': live_cluster['gitea_user'],
        'admin_pass': live_cluster['gitea_pass'],
    }
    
    executor = Executor(
        resolver=Resolver(config),
        planner=Planner(),
        verifier=Verifier(),
        hasher=Hasher(),
        health=HealthChecker()
    )
    
    # Execute wiring
    result = executor.run(platform)
    
    # Verify results
    assert result.success, f"Wiring failed: {result.errors}"
    assert result.platform_sha == platform.sha
    assert result.structural_sha != ""
    assert len(result.credentials) == 1
    assert result.credentials[0].kind == "ApiToken"
    assert result.credentials[0].producer == "gitea"
    assert result.credentials[0].consumer == "jenkins"


@pytest.mark.integration
def test_gitea_component_health_check(live_cluster):
    """Test Gitea component health check against live service."""
    from factory.model.artifact import Artifact
    
    artifact = Artifact(
        name="gitea",
        chart="gitea/gitea",
        version="11.0.1",
        image="gitea/gitea:1.23.6-rootless"
    )
    
    config = {
        'service': live_cluster['gitea_service'],
        'namespace': live_cluster['namespace'],
        'port': 3000,
        'admin_user': live_cluster['gitea_user'],
        'admin_pass': live_cluster['gitea_pass'],
    }
    
    gitea = GiteaComponent(artifact, config)
    
    # Should complete within timeout
    assert gitea.ready()
    assert gitea.url == f"http://{live_cluster['gitea_service']}:3000"


@pytest.mark.integration
def test_jenkins_component_health_check(live_cluster):
    """Test Jenkins component health check against live service."""
    from factory.model.artifact import Artifact
    
    artifact = Artifact(
        name="jenkins",
        chart="jenkins/jenkins",
        version="5.9.9",
        image="jenkins/jenkins:2.541.3-jdk21"
    )
    
    config = {
        'service': live_cluster['jenkins_service'],
        'namespace': live_cluster['namespace'],
        'port': 8080,
        'admin_user': live_cluster['jenkins_user'],
        'admin_pass': live_cluster['jenkins_pass'],
    }
    
    jenkins = JenkinsComponent(artifact, config)
    
    # Should complete within timeout
    assert jenkins.ready()
    assert jenkins.url == f"http://{live_cluster['jenkins_service']}:8080"


@pytest.mark.integration
def test_gitea_mints_api_token(live_cluster):
    """Test Gitea can mint API token."""
    from factory.model.artifact import Artifact
    from factory.credentials.types import ApiToken
    
    artifact = Artifact("gitea", None, None, "gitea/gitea:1.23.6-rootless")
    config = {
        'service': live_cluster['gitea_service'],
        'admin_user': live_cluster['gitea_user'],
        'admin_pass': live_cluster['gitea_pass'],
    }
    
    gitea = GiteaComponent(artifact, config)
    gitea.ready()
    
    # Mint token
    credential = gitea.extract(ApiToken, "jenkins")
    
    assert credential.kind == "ApiToken"
    assert credential.producer == "gitea"
    assert credential.consumer == "jenkins"
    assert "token" in credential.value
    assert credential.value["token"] != ""
    assert credential.sha != ""


@pytest.mark.integration
def test_jenkins_accepts_api_token(live_cluster):
    """Test Jenkins can accept and store API token."""
    from factory.model.artifact import Artifact
    from factory.credentials.types import ApiToken
    
    # Create fake token credential
    credential = ApiToken(
        producer="gitea",
        consumer="jenkins",
        value={
            "token": "test-token-12345",
            "user": "gitea",
            "name": "jenkins-wiring"
        }
    )
    
    artifact = Artifact("jenkins", None, None, "jenkins/jenkins:2.541.3-jdk21")
    config = {
        'service': live_cluster['jenkins_service'],
        'admin_user': live_cluster['jenkins_user'],
        'admin_pass': live_cluster['jenkins_pass'],
    }
    
    jenkins = JenkinsComponent(artifact, config)
    jenkins.ready()
    
    # Inject credential
    jenkins.inject(credential)
    
    # Verify it was stored
    assert jenkins.verify(credential)


@pytest.mark.integration
def test_wire_is_idempotent(platform_gitea_jenkins, live_cluster):
    """Test that running wire twice produces same structural SHA."""
    platform = Platform.from_yaml(platform_gitea_jenkins)
    
    config = {
        'namespace': live_cluster['namespace'],
    }
    
    def run_wiring():
        executor = Executor(
            resolver=Resolver(config),
            planner=Planner(),
            verifier=Verifier(),
            hasher=Hasher(),
            health=HealthChecker()
        )
        return executor.run(platform)
    
    # Run twice
    result_1 = run_wiring()
    result_2 = run_wiring()
    
    assert result_1.success
    assert result_2.success
    
    # Should produce same structural SHA (idempotent)
    assert result_1.structural_sha == result_2.structural_sha


@pytest.mark.integration
def test_gitea_creates_org(live_cluster):
    """Test Gitea can create organization."""
    from factory.model.artifact import Artifact
    
    artifact = Artifact("gitea", None, None, "gitea/gitea:1.23.6-rootless")
    config = {
        'service': live_cluster['gitea_service'],
        'admin_user': live_cluster['gitea_user'],
        'admin_pass': live_cluster['gitea_pass'],
    }
    
    gitea = GiteaComponent(artifact, config)
    gitea.ready()
    
    # Create org (should be idempotent)
    assert gitea.create_org("test-integration-org")


@pytest.mark.integration  
def test_gitea_creates_repo(live_cluster):
    """Test Gitea can create repository."""
    from factory.model.artifact import Artifact
    
    artifact = Artifact("gitea", None, None, "gitea/gitea:1.23.6-rootless")
    config = {
        'service': live_cluster['gitea_service'],
        'admin_user': live_cluster['gitea_user'],
        'admin_pass': live_cluster['gitea_pass'],
    }
    
    gitea = GiteaComponent(artifact, config)
    gitea.ready()
    
    # Ensure org exists
    gitea.create_org("test-integration-org")
    
    # Create repo (should be idempotent)
    assert gitea.create_repo("test-integration-org", "test-repo")


@pytest.mark.integration
def test_jenkins_creates_pipeline(live_cluster):
    """Test Jenkins can create pipeline job."""
    from factory.model.artifact import Artifact
    
    artifact = Artifact("jenkins", None, None, "jenkins/jenkins:2.541.3-jdk21")
    config = {
        'service': live_cluster['jenkins_service'],
        'admin_user': live_cluster['jenkins_user'],
        'admin_pass': live_cluster['jenkins_pass'],
    }
    
    jenkins = JenkinsComponent(artifact, config)
    jenkins.ready()
    
    # Create pipeline pointing to Gitea repo
    repo_url = f"http://{live_cluster['gitea_service']}:3000/test-org/test-repo.git"
    assert jenkins.create_pipeline("test-pipeline", repo_url)
