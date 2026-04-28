"""Executor - orchestrates wiring execution."""
import logging
from .planner import WiringGraph
from .credential import Credential


class Executor:
    """Orchestrates platform wiring execution.
    
    Executes the wiring graph in topological order, collecting credentials.
    """

    def __init__(self, log: logging.Logger):
        """Initialize executor.
        
        Args:
            log: Logger instance
        """
        self.log = log

    def run(self, graph: WiringGraph) -> list[Credential]:
        """Execute wiring graph and return credentials.
        
        Args:
            graph: Resolved wiring graph
            
        Returns:
            List of credentials produced
            
        Raises:
            Exception: If any wire operation fails
        """
        credentials = []
        
        for edge in graph.topological_order():
            self.log.info(
                f"wiring | {edge.source.name} → {edge.target.name} | {edge.credential_kind}"
            )
            
            # Extract credential from source
            credential = edge.source.extract(edge.credential_type, edge.target.name)
            
            # Inject into target
            edge.target.inject(credential)
            
            credentials.append(credential)
            self.log.info(f"wired  | sha={credential.sha[:12]}")

        return credentials
