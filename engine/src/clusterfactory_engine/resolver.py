"""Component resolver - maps kind strings to component classes.

For v0.3: Simple dictionary. Entry-point discovery comes in v0.4.
"""
from .component import Component


# Component registry - populated after components are imported
COMPONENT_REGISTRY: dict[str, type[Component]] = {}


def register(kind: str):
    """Decorator to register a component class."""
    def decorator(cls: type[Component]):
        COMPONENT_REGISTRY[kind] = cls
        return cls
    return decorator


def resolve(kind: str) -> type[Component]:
    """Resolve a component kind to its implementation class.
    
    Args:
        kind: Component kind string (e.g., "gitea", "jenkins")
        
    Returns:
        Component class
        
    Raises:
        ValueError: If kind is not registered
    """
    if kind not in COMPONENT_REGISTRY:
        raise ValueError(
            f"Unknown component kind: {kind}. "
            f"Available: {list(COMPONENT_REGISTRY.keys())}"
        )
    return COMPONENT_REGISTRY[kind]
