"""Verifier - validates wiring after execution."""
from .planner import WiringGraph
from .credential import Credential


def verify_all(graph: WiringGraph, credentials: list[Credential]) -> list[str]:
    """Verify all wiring edges.
    
    Calls each target component's verify() method to prove credentials were applied.
    
    Args:
        graph: Wiring graph that was executed
        credentials: List of credentials that were wired
        
    Returns:
        List of error messages (empty if all verified)
    """
    errors = []
    
    for i, edge in enumerate(graph.edges):
        if i >= len(credentials):
            errors.append(
                f"Missing credential for edge {edge.source.name} → {edge.target.name}"
            )
            continue
        
        credential = credentials[i]
        
        try:
            if not edge.target.verify(credential):
                errors.append(
                    f"Verification failed: {edge.source.name} → {edge.target.name}"
                )
        except Exception as e:
            errors.append(
                f"Verification error {edge.source.name} → {edge.target.name}: {str(e)}"
            )
    
    return errors
