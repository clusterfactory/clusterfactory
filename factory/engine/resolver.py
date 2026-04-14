"""Resolver - maps artifact names to component instances."""

from factory.model.artifact import Artifact
from factory.components.base import Component


class Resolver:
    """
    Resolves artifact names to component instances.
    
    Maps artifact.name to the corresponding Component class implementation.
    """
    
    def __init__(self, config: dict | None = None):
        """
        Initialize resolver.
        
        Args:
            config: Global configuration (namespaces, service names, etc.)
        """
        self.config = config or {}

    def resolve(self, artifacts: list[Artifact]) -> dict[str, Component]:
        """
        Resolve artifacts to component instances.
        
        Args:
            artifacts: List of artifacts from platform declaration
            
        Returns:
            Dictionary mapping artifact name to component instance
            
        Raises:
            ValueError: If artifact name has no corresponding component
        """
        components = {}
        
        for artifact in artifacts:
            component_class = self._get_component_class(artifact.name)
            if component_class:
                component_config = self._get_component_config(artifact.name)
                components[artifact.name] = component_class(artifact, component_config)
        
        return components

    def _get_component_class(self, name: str) -> type[Component] | None:
        """
        Get component class for artifact name.
        
        Args:
            name: Artifact name
            
        Returns:
            Component class or None if not found
        """
        # Component registry - maps artifact names to component classes
        component_map = {
            'gitea': self._import_gitea,
            'jenkins': self._import_jenkins,
        }
        
        importer = component_map.get(name)
        if importer:
            return importer()
        return None

    def _import_gitea(self) -> type[Component]:
        """Import Gitea component class."""
        from factory.components.gitea import GiteaComponent
        return GiteaComponent

    def _import_jenkins(self) -> type[Component]:
        """Import Jenkins component class."""
        from factory.components.jenkins import JenkinsComponent
        return JenkinsComponent

    def _get_component_config(self, name: str) -> dict:
        """
        Get component-specific configuration.
        
        Args:
            name: Artifact name
            
        Returns:
            Configuration dictionary
        """
        import os
        
        # Build config from global config + component defaults + environment
        config = dict(self.config)
        config['namespace'] = self.config.get('namespace', 'default')
        
        # Service name mappings
        service_map = {
            'gitea': 'gitea-http',
            'jenkins': 'jenkins',
        }
        config['service'] = service_map.get(name, f"{name}-service")
        
        # Pull credentials from environment variables (for Kubernetes secrets)
        if name == 'gitea':
            config['admin_user'] = os.getenv('GITEA_USER', 'gitea')
            config['admin_pass'] = os.getenv('GITEA_PASS', 'giteapwd')
        elif name == 'jenkins':
            config['admin_user'] = os.getenv('JENKINS_USER', 'admin')
            config['admin_pass'] = os.getenv('JENKINS_PASS', 'adminpwd')
        
        return config
