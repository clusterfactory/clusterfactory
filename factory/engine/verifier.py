"""Verifier - validates wiring after execution."""

import logging
from factory.model.graph import GraphEdge
from factory.model.credential import Credential

log = logging.getLogger("factory.verifier")


class Verifier:
    """
    Verifies that all wires hold after execution.
    
    Calls each component's verify() method to prove credentials were applied.
    """

    def verify_all(self, edges: list[GraphEdge], credentials: list[Credential]) -> list[str]:
        """
        Verify all wiring edges.
        
        Args:
            edges: List of graph edges to verify
            credentials: List of credentials that were wired
            
        Returns:
            List of error messages (empty if all verified)
        """
        errors = []
        
        for i, edge in enumerate(edges):
            if i >= len(credentials):
                errors.append(f"Missing credential for edge {edge.source.name} → {edge.target.name}")
                continue
            
            credential = credentials[i]
            
            try:
                log.info(f"verifying | {edge.source.name} → {edge.target.name}")
                
                if not edge.target.verify(credential):
                    errors.append(
                        f"Verification failed: {edge.source.name} → {edge.target.name}"
                    )
                    log.error(f"verify failed | {edge.source.name} → {edge.target.name}")
                else:
                    log.info(f"verified | {edge.source.name} → {edge.target.name}")
                    
            except Exception as e:
                errors.append(
                    f"Verification error {edge.source.name} → {edge.target.name}: {str(e)}"
                )
                log.error(f"verify error | {edge.source.name} → {edge.target.name} | {e}")
        
        return errors
