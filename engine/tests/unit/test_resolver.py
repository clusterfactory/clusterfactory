"""Resolver tests — registry plumbing for component kinds.

Importing `clusterfactory_engine.components.gitea` must auto-register `gitea`
in the resolver. If that wiring breaks, every install fails at the platform
parse step. These tests catch that regression.
"""
import pytest

from clusterfactory_engine.resolver import (
    COMPONENT_REGISTRY, register, resolve,
)


def test_known_kinds_register_themselves_on_import():
    """Importing a component module must side-effect the registry."""
    # Side-effect import — registers via @register.
    from clusterfactory_engine.components import gitea, jenkins  # noqa: F401

    assert "gitea" in COMPONENT_REGISTRY
    assert "jenkins" in COMPONENT_REGISTRY


def test_resolve_returns_class_for_known_kind():
    from clusterfactory_engine.components import gitea  # noqa: F401
    cls = resolve("gitea")
    assert cls.__name__ == "GiteaComponent"


def test_resolve_raises_with_helpful_message_for_unknown_kind():
    """Operators see this message when platform.yaml has a typo."""
    with pytest.raises(ValueError, match="Unknown component kind: harbor"):
        resolve("harbor")


def test_register_decorator_adds_to_registry():
    """Defining a new component via @register exposes it for resolve()."""
    from clusterfactory_engine.component import Component
    from clusterfactory_engine.credential import Credential

    @register("test-only-do-not-keep")
    class _T(Component):
        @property
        def url(self): return "http://x"
        def ready(self): return True
        def produces(self): return []
        def consumes(self): return []
        def extract(self, kind, for_consumer): raise NotImplementedError
        def inject(self, credential): pass
        def verify(self, credential): return True

    try:
        assert resolve("test-only-do-not-keep") is _T
    finally:
        COMPONENT_REGISTRY.pop("test-only-do-not-keep", None)
