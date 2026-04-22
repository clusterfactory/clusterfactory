"""Integration test configuration and fixtures."""

import pytest
import os


@pytest.fixture(scope="session")
def live_cluster():
    """
    Live cluster configuration.
    
    Requires:
        - Kubernetes cluster accessible
        - Gitea and Jenkins deployed
        - Environment variables set
    """
    return {
        'namespace': os.getenv('TEST_NAMESPACE', 'default'),
        'gitea_service': os.getenv('GITEA_SERVICE', 'gitea-http'),
        'jenkins_service': os.getenv('JENKINS_SERVICE', 'jenkins'),
        'gitea_user': os.getenv('GITEA_USER', 'gitea'),
        'gitea_pass': os.getenv('GITEA_PASS'),  # Must be provided via env var or Secret
        'jenkins_user': os.getenv('JENKINS_USER', 'admin'),
        'jenkins_pass': os.getenv('JENKINS_PASS', 'adminpwd'),
    }


@pytest.fixture(scope="session")
def platform_gitea_jenkins(tmp_path_factory):
    """Platform YAML for gitea-jenkins integration test."""
    import yaml
    
    platform = {
        'platform': {
            'name': 'gitea-jenkins',
            'version': '0.2.0',
        },
        'artifacts': [
            {
                'name': 'gitea',
                'chart': 'gitea/gitea',
                'version': '11.0.1',
                'image': 'gitea/gitea:1.23.6-rootless',
            },
            {
                'name': 'jenkins',
                'chart': 'jenkins/jenkins',
                'version': '5.9.9',
                'image': 'jenkins/jenkins:2.541.3-jdk21',
            },
        ],
        'wiring': [
            {
                'from': 'gitea',
                'to': 'jenkins',
                'credential': 'api-token',
            },
        ],
        'airgap': False,
    }
    
    platform_file = tmp_path_factory.mktemp("data") / "platform.yaml"
    with open(platform_file, 'w') as f:
        yaml.dump(platform, f)
    
    return str(platform_file)


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "integration: mark test as integration test (requires live cluster)"
    )
    config.addinivalue_line(
        "markers", "airgap: mark test as airgap test (requires airgap cluster)"
    )
    config.addinivalue_line(
        "markers", "upgrade: mark test as upgrade test"
    )
