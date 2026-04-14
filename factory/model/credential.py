"""Credential model - represents wiring secrets between components."""

from dataclasses import dataclass, field
import json
from factory.hasher import sha256_of


@dataclass
class Credential:
    """
    A credential is a typed secret produced by one component for another.
    
    Attributes:
        kind: Credential type (ApiToken, UserPass, RegistryPush, RunnerToken, OIDCConfig)
        producer: Artifact name that generated this credential
        consumer: Artifact name this credential is intended for
        value: The actual credential payload as a dictionary
        sha: Computed structural hash of this credential
    """
    kind: str
    producer: str
    consumer: str
    value: dict

    sha: str = field(init=False, repr=False)

    def __post_init__(self):
        """Compute credential SHA from sorted JSON representation of value."""
        self.sha = sha256_of(json.dumps(self.value, sort_keys=True))
