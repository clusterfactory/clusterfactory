"""Unit tests for component implementations."""

import pytest
from factory.model.artifact import Artifact
from factory.components.gitea import GiteaComponent
from factory.components.jenkins import JenkinsComponent
from factory.credentials.types import ApiToken, UserPass


def test_gitea_produces_api_token():
    """Gitea declares it can produce ApiToken."""
    artifact = Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
    gitea = GiteaComponent(artifact, {})
    
    assert ApiToken in gitea.produces()


def test_gitea_consumes_nothing():
    """Gitea is a seed component, consumes nothing."""
    artifact = Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
    gitea = GiteaComponent(artifact, {})
    
    assert gitea.consumes() == []


def test_jenkins_produces_nothing():
    """Jenkins is a sink component, produces nothing."""
    artifact = Artifact("jenkins", "jenkins/jenkins", "5.9.9", "jenkins/jenkins:2.541.3-jdk21")
    jenkins = JenkinsComponent(artifact, {})
    
    assert jenkins.produces() == []


def test_jenkins_consumes_api_token():
    """Jenkins declares it can consume ApiToken."""
    artifact = Artifact("jenkins", "jenkins/jenkins", "5.9.9", "jenkins/jenkins:2.541.3-jdk21")
    jenkins = JenkinsComponent(artifact, {})
    
    assert ApiToken in jenkins.consumes()
    assert UserPass in jenkins.consumes()


def test_gitea_url_construction():
    """Gitea URL is built from config."""
    artifact = Artifact("gitea", None, None, "gitea/gitea:1.23.6-rootless")
    config = {'service': 'gitea-http', 'port': 3000}
    gitea = GiteaComponent(artifact, config)
    
    assert gitea.url == "http://gitea-http:3000"


def test_jenkins_url_construction():
    """Jenkins URL is built from config."""
    artifact = Artifact("jenkins", None, None, "jenkins/jenkins:2.541.3-jdk21")
    config = {'service': 'jenkins', 'port': 8080}
    jenkins = JenkinsComponent(artifact, config)
    
    assert jenkins.url == "http://jenkins:8080"


def test_component_name_from_artifact():
    """Component name comes from artifact."""
    artifact = Artifact("gitea", None, None, "gitea:latest")
    gitea = GiteaComponent(artifact, {})
    
    assert gitea.name == "gitea"
