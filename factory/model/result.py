"""Platform result - execution output with structural SHA."""

from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class PlatformResult:
    """
    Result of platform execution.
    
    Attributes:
        platform_sha: SHA of the platform declaration
        structural_sha: SHA of all credential SHAs (proves wiring executed)
        credentials: All credentials produced during wiring
        timestamp: When execution completed
        success: Whether execution succeeded
        errors: List of error messages if execution failed
    """
    platform_sha: str
    structural_sha: str
    credentials: list
    timestamp: datetime
    success: bool
    errors: list[str] = field(default_factory=list)
