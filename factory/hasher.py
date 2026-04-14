"""SHA256 hashing utilities for structural fingerprinting."""

import hashlib


def sha256_of(content: str) -> str:
    """
    Compute SHA256 hash of string content.
    
    Args:
        content: String to hash
        
    Returns:
        Hex-encoded SHA256 hash
    """
    return hashlib.sha256(content.encode('utf-8')).hexdigest()
