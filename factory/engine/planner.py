"""Planner - builds wiring graph from declaration."""

from factory.model.platform import WiringEdge
from factory.model.graph import WiringGraph
from factory.components.base import Component


class Planner:
    """
    Builds directed wiring graph from platform declaration.
    
    Resolves wiring edges to component instances and credential types.
    """

    def build(self, wiring: list[WiringEdge], components: dict[str, Component]) -> WiringGraph:
        """
        Build wiring graph from declaration.
        
        Args:
            wiring: List of wiring edges from platform
            components: Dictionary of resolved components
            
        Returns:
            WiringGraph with resolved edges
            
        Raises:
            ValueError: If wiring references unknown components or credentials
        """
        graph = WiringGraph()

        for edge in wiring:
            if edge.source not in components:
                raise ValueError(f"Unknown source component: {edge.source}")
            if edge.target not in components:
                raise ValueError(f"Unknown target component: {edge.target}")

            source_component = components[edge.source]
            target_component = components[edge.target]
            
            credential_type = self._resolve_credential_type(edge.credential)
            
            if not self._component_produces(source_component, credential_type):
                raise ValueError(
                    f"Component {edge.source} does not produce {edge.credential}"
                )
            
            if not self._component_consumes(target_component, credential_type):
                raise ValueError(
                    f"Component {edge.target} does not consume {edge.credential}"
                )

            graph.add_edge(
                source=source_component,
                target=target_component,
                credential_kind=edge.credential,
                credential_type=credential_type
            )

        return graph

    def _resolve_credential_type(self, kind: str) -> type:
        """
        Resolve credential kind string to type.
        
        Args:
            kind: Credential kind string (e.g. "api-token")
            
        Returns:
            Credential type class
        """
        from factory.credentials.types import (
            ApiToken, UserPass, RunnerToken, RegistryPush, OIDCConfig
        )
        
        credential_map = {
            "api-token": ApiToken,
            "user-pass": UserPass,
            "runner-token": RunnerToken,
            "registry-push": RegistryPush,
            "oidc-config": OIDCConfig,
        }
        
        if kind not in credential_map:
            raise ValueError(f"Unknown credential type: {kind}")
        
        return credential_map[kind]

    def _component_produces(self, component: Component, credential_type: type) -> bool:
        """Check if component produces credential type."""
        return credential_type in component.produces()

    def _component_consumes(self, component: Component, credential_type: type) -> bool:
        """Check if component consumes credential type."""
        return credential_type in component.consumes()
