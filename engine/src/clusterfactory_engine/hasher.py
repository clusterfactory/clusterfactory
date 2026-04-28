"""Structural SHA computation over wiring topology."""
import json
import hashlib
from .credential import Credential


def _sha256(s: str) -> str:
    """Compute SHA256 hash of a string."""
    return hashlib.sha256(s.encode()).hexdigest()


def structural_sha(credentials: list[Credential]) -> str:
    """Stable hash over the wiring result, independent of secret values.
    
    Two installs with the same platform.yaml produce the same SHA, even if
    admin passwords differ. The hash covers the topology (who wired what to whom),
    not the credential values.
    
    Args:
        credentials: List of credentials produced during wiring
        
    Returns:
        SHA256 hash string
    """
    if not credentials:
        return _sha256("")
    
    # Hash over (producer, consumer, kind) tuples, not credential values.
    # Two installs produce the same hash if they wired the same graph.
    topology = sorted(
        f"{c.producer}→{c.consumer}:{c.kind}" for c in credentials
    )
    return _sha256(json.dumps(topology))
