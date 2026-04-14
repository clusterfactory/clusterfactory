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
        # Dynamic import based on name
        # For now, return None for unimplemented components
        # TODO: Implement component registry with auto-discovery
        component_map = {}
        
        return component_map.get(name)

    def _get_component_config(self, name: str) -> dict:
        """
        Get component-specific configuration.
        
        Args:
            name: Artifact name
            
        Returns:
            Configuration dictionary
        """
        # Build config from global config + component defaults
        config = dict(self.config)
        config['service'] = f"{name}-service"
        config['namespace'] = self.config.get('namespace', 'default')
        return config
