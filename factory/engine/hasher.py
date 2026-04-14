"""Hasher - computes structural SHA from credentials."""

import json
from factory.hasher import sha256_of
from factory.model.credential import Credential


class Hasher:
    """
    Computes structural SHA from credential set.
    
    The structural SHA proves wiring executed correctly.
    Same credentials = same structural SHA.
    """

    def hash(self, credentials: list[Credential]) -> str:
        """
        Compute structural SHA from credentials.
        
        Args:
            credentials: List of credentials produced during wiring
            
        Returns:
            Hex-encoded SHA256 hash of sorted credential SHAs
        """
        if not credentials:
            return sha256_of("")
        
        credential_shas = sorted(c.sha for c in credentials)
        return sha256_of(json.dumps(credential_shas))
