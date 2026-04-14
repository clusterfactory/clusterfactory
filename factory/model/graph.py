"""Wiring graph - directed graph with topological ordering."""

from dataclasses import dataclass
from typing import Any


@dataclass
class GraphEdge:
    """
    An edge in the wiring graph with resolved component instances.
    
    Attributes:
        source: Source component instance
        target: Target component instance
        credential_kind: Type of credential to wire
        credential_type: Credential class type
    """
    source: Any
    target: Any
    credential_kind: str
    credential_type: type


class WiringGraph:
    """
    Directed graph of component wiring with topological sort.
    
    Attributes:
        edges: List of graph edges
    """
    
    def __init__(self):
        self.edges: list[GraphEdge] = []

    def add_edge(self, source: Any, target: Any, credential_kind: str, credential_type: type):
        """
        Add an edge to the graph.
        
        Args:
            source: Source component
            target: Target component
            credential_kind: Credential type name
            credential_type: Credential class
        """
        self.edges.append(GraphEdge(
            source=source,
            target=target,
            credential_kind=credential_kind,
            credential_type=credential_type
        ))

    def topological_order(self) -> list[GraphEdge]:
        """
        Return edges in topological order (dependencies first).
        
        For now, returns edges in declaration order.
        Future: implement proper topological sort for complex dependency graphs.
        
        Returns:
            List of edges in execution order
        """
        return self.edges
