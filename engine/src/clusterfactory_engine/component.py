"""Component ABC — the contract every component implements."""
from abc import ABC, abstractmethod
from typing import Type
from .credential import Credential


class Component(ABC):
    """A wirable service: produces and/or consumes typed credentials.
    
    Every component implements this interface. The engine calls only these methods.
    Adding a new component means writing a new class - nothing in the engine changes.
    """

    def __init__(self, name: str, config: dict):
        """Initialize component.
        
        Args:
            name: Component name (from platform.yaml)
            config: Component configuration dict
        """
        self.name = name
        self.config = config

    @property
    @abstractmethod
    def url(self) -> str:
        """Base URL of this component's API."""
        pass

    @abstractmethod
    def ready(self) -> bool:
        """Poll until the component is ready to accept API calls.
        
        Returns:
            True when ready
            
        Raises:
            TimeoutError: After max_wait seconds
        """
        pass

    @abstractmethod
    def produces(self) -> list[Type[Credential]]:
        """Credential types this component can generate.
        
        Returns:
            List of credential classes this component produces
        """
        pass

    @abstractmethod
    def consumes(self) -> list[Type[Credential]]:
        """Credential types this component accepts.
        
        Returns:
            List of credential classes this component consumes
        """
        pass

    @abstractmethod
    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential:
        """Generate and return a credential of the requested type.
        
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
        """Accept and apply an inbound credential.
        
        Called by the engine after the producing component has run extract().
        Must be idempotent.
        
        Args:
            credential: Credential to inject
        """
        pass

    @abstractmethod
    def verify(self, credential: Credential) -> bool:
        """Prove that a specific wire holds.
        
        Called by the verifier after all inject() calls complete.
        
        Args:
            credential: Credential to verify
            
        Returns:
            True if the wire is confirmed, False or raises if broken
        """
        pass
