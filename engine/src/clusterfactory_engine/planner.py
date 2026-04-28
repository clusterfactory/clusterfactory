"""Planner - builds wiring graph from platform declaration."""
from dataclasses import dataclass
from typing import Any, Type
from .component import Component
from .credential import Credential


@dataclass
class GraphEdge:
    """An edge in the wiring graph with resolved component instances.
    
    Attributes:
        source: Source component instance
        target: Target component instance
        credential_kind: Credential type name
        credential_type: Credential class type
    """
    source: Component
    target: Component
    credential_kind: str
    credential_type: Type[Credential]


class WiringGraph:
    """Directed graph of component wiring with topological sort."""
    
    def __init__(self):
        self.edges: list[GraphEdge] = []

    def add_edge(self, source: Component, target: Component, 
                 credential_kind: str, credential_type: Type[Credential]):
        """Add an edge to the graph."""
        self.edges.append(GraphEdge(
            source=source,
            target=target,
            credential_kind=credential_kind,
            credential_type=credential_type
        ))

    def topological_order(self) -> list[GraphEdge]:
        """Return edges in topological order (dependencies first).
        
        For v0.3: Simple declaration order is fine (one edge: gitea→jenkins).
        Future: implement proper topological sort for complex graphs.
        """
        return self.edges


def build_graph(wiring: list[dict], components: dict[str, Component], 
                cred_module: Any) -> WiringGraph:
    """Build wiring graph from platform declaration.
    
    Args:
        wiring: List of wiring edge dicts from platform.yaml
        components: Dict of resolved component instances
        cred_module: Module containing credential types
        
    Returns:
        WiringGraph with resolved edges
        
    Raises:
        ValueError: If wiring references unknown components or credentials
    """
    graph = WiringGraph()

    for edge in wiring:
        src_name = edge["from"]
        tgt_name = edge["to"]
        cred_kind = edge["credential"]
        
        if src_name not in components:
            raise ValueError(f"Unknown source component: {src_name}")
        if tgt_name not in components:
            raise ValueError(f"Unknown target component: {tgt_name}")

        source_comp = components[src_name]
        target_comp = components[tgt_name]
        
        # Resolve credential type from module
        if not hasattr(cred_module, cred_kind):
            raise ValueError(f"Unknown credential type: {cred_kind}")
        cred_type = getattr(cred_module, cred_kind)
        
        # Validate component capabilities
        if cred_type not in source_comp.produces():
            raise ValueError(
                f"Component {src_name} does not produce {cred_kind}"
            )
        if cred_type not in target_comp.consumes():
            raise ValueError(
                f"Component {tgt_name} does not consume {cred_kind}"
            )

        graph.add_edge(
            source=source_comp,
            target=target_comp,
            credential_kind=cred_kind,
            credential_type=cred_type
        )

    return graph
