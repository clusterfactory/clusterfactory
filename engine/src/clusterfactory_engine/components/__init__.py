"""Component implementations."""

from .gitea import GiteaComponent
from .jenkins import JenkinsComponent

# Convenience aliases
Gitea = GiteaComponent
Jenkins = JenkinsComponent

__all__ = ["GiteaComponent", "JenkinsComponent", "Gitea", "Jenkins"]
