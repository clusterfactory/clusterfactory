"""Credential-level SHA tests.

Each Credential carries its own .sha (over the value dict). This is separate
from the structural SHA (which is over topology only). It's used internally
for logging — `wired | sha=abc123…` lines — and for any future drift checks
that want to know "did the credential value change between runs?".
"""
import json

import pytest

from clusterfactory_engine.credential import ApiToken, Credential, UserPass


def test_credential_sha_is_set_post_init():
    c = ApiToken(producer="gitea", consumer="jenkins",
                 value={"token": "abc"})
    assert c.sha
    assert len(c.sha) == 64


def test_credential_sha_is_deterministic_across_key_order():
    """JSON key order in the value dict must not change the SHA."""
    a = ApiToken(producer="g", consumer="j", value={"a": 1, "b": 2})
    b = ApiToken(producer="g", consumer="j", value={"b": 2, "a": 1})
    assert a.sha == b.sha


def test_credential_sha_changes_when_value_changes():
    a = ApiToken(producer="g", consumer="j", value={"token": "AAA"})
    b = ApiToken(producer="g", consumer="j", value={"token": "BBB"})
    assert a.sha != b.sha


def test_kind_returns_class_name():
    """`Credential.kind` is what the verifier uses to dispatch.

    Kind comes from the class name, so `ApiToken().kind == "ApiToken"`. If a
    subclass renames itself, that has to be intentional.
    """
    assert ApiToken(producer="g", consumer="j", value={}).kind == "ApiToken"
    assert UserPass(producer="g", consumer="j", value={}).kind == "UserPass"


def test_credential_is_frozen():
    """Frozen dataclass — no mutation after construction."""
    c = ApiToken(producer="g", consumer="j", value={"x": 1})
    with pytest.raises(Exception):  # FrozenInstanceError
        c.producer = "tampered"  # type: ignore[misc]
