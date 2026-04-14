"""Unit tests for platform SHA determinism."""

import pytest
from factory.model.platform import Platform, WiringEdge
from factory.model.artifact import Artifact


def make_gitea_jenkins_platform():
    """Helper to create a standard gitea-jenkins platform."""
    return Platform(
        name="gitea-jenkins",
        version="0.2.0",
        artifacts=[
            Artifact(
                name="gitea",
                chart="gitea/gitea",
                version="11.0.1",
                image="gitea/gitea:1.23.6-rootless"
            ),
            Artifact(
                name="jenkins",
                chart="jenkins/jenkins",
                version="5.9.9",
                image="jenkins/jenkins:2.541.3-jdk21"
            ),
        ],
        wiring=[
            WiringEdge("gitea", "jenkins", "api-token"),
        ]
    )


def test_platform_sha_is_deterministic():
    """Same declaration always produces same SHA."""
    platform_a = make_gitea_jenkins_platform()
    platform_b = make_gitea_jenkins_platform()
    assert platform_a.sha == platform_b.sha


def test_platform_sha_changes_on_artifact_version():
    """Bumping a version changes the SHA."""
    platform_a = Platform(
        name="test",
        version="1.0",
        artifacts=[
            Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
        ],
        wiring=[]
    )
    platform_b = Platform(
        name="test",
        version="1.0",
        artifacts=[
            Artifact("gitea", "gitea/gitea", "11.0.2", "gitea/gitea:1.23.6-rootless")
        ],
        wiring=[]
    )
    assert platform_a.sha != platform_b.sha


def test_platform_sha_changes_on_wiring_change():
    """Adding a wire changes the SHA."""
    artifacts = [
        Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless"),
        Artifact("jenkins", "jenkins/jenkins", "5.9.9", "jenkins/jenkins:2.541.3-jdk21"),
    ]
    
    platform_a = Platform(
        name="test",
        version="1.0",
        artifacts=artifacts,
        wiring=[]
    )
    platform_b = Platform(
        name="test",
        version="1.0",
        artifacts=artifacts,
        wiring=[WiringEdge("gitea", "jenkins", "api-token")]
    )
    assert platform_a.sha != platform_b.sha


def test_platform_sha_changes_on_image_change():
    """Changing an image changes the SHA."""
    platform_a = Platform(
        name="test",
        version="1.0",
        artifacts=[
            Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
        ],
        wiring=[]
    )
    platform_b = Platform(
        name="test",
        version="1.0",
        artifacts=[
            Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.7-rootless")
        ],
        wiring=[]
    )
    assert platform_a.sha != platform_b.sha


def test_artifact_sha_is_deterministic():
    """Same artifact always produces same SHA."""
    artifact_a = Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
    artifact_b = Artifact("gitea", "gitea/gitea", "11.0.1", "gitea/gitea:1.23.6-rootless")
    assert artifact_a.sha == artifact_b.sha


def test_artifact_find_by_name():
    """Can find artifact by name."""
    platform = make_gitea_jenkins_platform()
    gitea = platform.artifact("gitea")
    assert gitea is not None
    assert gitea.name == "gitea"
    
    missing = platform.artifact("harbor")
    assert missing is None
