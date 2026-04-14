"""Base component interface - all components implement this."""

from abc import ABC, abstractmethod
from factory.model.credential import Credential


class Component(ABC):
    """
    Base interface for all factory components.
    
    Every component implements this interface. The engine calls only these methods.
    Adding a new component means writing a new class - nothing in the engine changes.
    """

    def __init__(self, artifact, config: dict):
        """
        Initialize component.
        
        Args:
            artifact: Artifact model instance
            config: Component configuration (service names, namespaces, etc.)
        """
        self.artifact = artifact
        self.config = config

    @property
    def name(self) -> str:
        """Component name from artifact."""
        return self.artifact.name

    @property
    @abstractmethod
    def url(self) -> str:
        """Base URL of this component's API."""
        pass

    @abstractmethod
    def ready(self) -> bool:
        """
        Poll until the component is ready to accept API calls.
        
        Returns:
            True when ready
            
        Raises:
            TimeoutError: After max_wait seconds
        """
        pass

    @abstractmethod
    def produces(self) -> list[type[Credential]]:
        """
        Credential types this component can generate.
        
        Returns:
            List of credential classes this component produces
        """
        pass

    @abstractmethod
    def consumes(self) -> list[type[Credential]]:
        """
        Credential types this component accepts.
        
        Returns:
            List of credential classes this component consumes
        """
        pass

    @abstractmethod
    def extract(self, kind: type[Credential], for_consumer: str) -> Credential:
        """
        Generate and return a credential of the requested type.
        
        Called by the engine after this component is ready.
        Must be idempotent - re-calling produces the same logical credential.
        
        Args:
            kind: Credential class type to produce
            for_consumer: Target component name
            
        Returns:
            Credential instance
        """
        pass

    @abstractmethod
    def inject(self, credential: Credential) -> None:
        """
        Accept and apply an inbound credential.
        
        Called by the engine after the producing component has run extract().
        Must be idempotent.
        
        Args:
            credential: Credential to inject
        """
        pass

    @abstractmethod
    def verify(self, credential: Credential) -> bool:
        """
        Prove that a specific wire holds.
        
        Called by the verifier after all inject() calls complete.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if the wire is confirmed, False or raises if broken
        """
        pass
