"""Unit tests for credential SHA determinism."""

import pytest
from factory.model.credential import Credential


def test_credential_sha_is_deterministic():
    """Same credential value always produces same SHA."""
    cred_a = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"token": "abc123", "user": "admin"}
    )
    cred_b = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"token": "abc123", "user": "admin"}
    )
    assert cred_a.sha == cred_b.sha


def test_credential_sha_changes_on_value_change():
    """Different credential values produce different SHAs."""
    cred_a = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"token": "abc123"}
    )
    cred_b = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"token": "xyz789"}
    )
    assert cred_a.sha != cred_b.sha


def test_credential_sha_independent_of_dict_order():
    """Credential SHA is same regardless of dict key order."""
    cred_a = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"user": "admin", "token": "abc123"}
    )
    cred_b = Credential(
        kind="ApiToken",
        producer="gitea",
        consumer="jenkins",
        value={"token": "abc123", "user": "admin"}
    )
    assert cred_a.sha == cred_b.sha
