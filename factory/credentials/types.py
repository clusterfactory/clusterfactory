"""Credential type definitions."""

from dataclasses import dataclass
from factory.model.credential import Credential


@dataclass
class ApiToken(Credential):
    """API token credential for REST API access."""
    
    def __init__(self, producer: str, consumer: str, value: dict):
        super().__init__(
            kind="ApiToken",
            producer=producer,
            consumer=consumer,
            value=value
        )


@dataclass
class UserPass(Credential):
    """Username/password credential."""
    
    def __init__(self, producer: str, consumer: str, value: dict):
        super().__init__(
            kind="UserPass",
            producer=producer,
            consumer=consumer,
            value=value
        )


@dataclass
class RunnerToken(Credential):
    """CI runner registration token."""
    
    def __init__(self, producer: str, consumer: str, value: dict):
        super().__init__(
            kind="RunnerToken",
            producer=producer,
            consumer=consumer,
            value=value
        )


@dataclass
class RegistryPush(Credential):
    """Container registry push credential."""
    
    def __init__(self, producer: str, consumer: str, value: dict):
        super().__init__(
            kind="RegistryPush",
            producer=producer,
            consumer=consumer,
            value=value
        )


@dataclass
class OIDCConfig(Credential):
    """OIDC/OAuth configuration."""
    
    def __init__(self, producer: str, consumer: str, value: dict):
        super().__init__(
            kind="OIDCConfig",
            producer=producer,
            consumer=consumer,
            value=value
        )
