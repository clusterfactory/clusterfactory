"""Credential base class and common types."""
from dataclasses import dataclass, field
import hashlib
import json


def _sha256(s: str) -> str:
    """Compute SHA256 hash of a string."""
    return hashlib.sha256(s.encode()).hexdigest()


@dataclass(frozen=True)
class Credential:
    """Typed secret produced by one component for another.
    
    Attributes:
        producer: Component name that generated this credential
        consumer: Component name this credential is intended for
        value: The actual credential payload as a dictionary
        sha: Computed structural hash of this credential (auto-generated)
    """
    producer: str
    consumer: str
    value: dict
    sha: str = field(init=False)

    def __post_init__(self):
        """Compute credential SHA from sorted JSON representation of value."""
        object.__setattr__(
            self, "sha", _sha256(json.dumps(self.value, sort_keys=True))
        )

    @property
    def kind(self) -> str:
        """Return the credential type name (class name)."""
        return type(self).__name__


@dataclass(frozen=True)
class ApiToken(Credential):
    """API token credential (e.g., Gitea token for Jenkins)."""
    pass


@dataclass(frozen=True)
class UserPass(Credential):
    """Username/password credential."""
    pass


@dataclass(frozen=True)
class RunnerToken(Credential):
    """Runner registration token (e.g., Gitea Actions runner)."""
    pass
