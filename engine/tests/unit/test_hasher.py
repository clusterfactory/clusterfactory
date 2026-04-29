"""Structural SHA tests.

The structural SHA is the demo's single proof artifact: deploy two clusters from
the same platform.yaml and the SHA should match, even when secrets differ. These
tests pin that contract.
"""
import pytest

from clusterfactory_engine.credential import ApiToken, UserPass
from clusterfactory_engine.hasher import structural_sha


def _api(producer, consumer, value=None):
    return ApiToken(producer=producer, consumer=consumer,
                    value=value or {"token": "x", "user": "u"})


def _up(producer, consumer, value=None):
    return UserPass(producer=producer, consumer=consumer,
                    value=value or {"username": "u", "password": "p"})


def test_empty_credentials_have_a_stable_sha():
    """Empty wiring should not crash — it should hash the empty topology."""
    sha = structural_sha([])
    assert isinstance(sha, str)
    assert len(sha) == 64  # SHA-256 hex


def test_same_topology_same_sha():
    """Same (producer, consumer, kind) tuples → same SHA."""
    a = structural_sha([_api("gitea", "jenkins")])
    b = structural_sha([_api("gitea", "jenkins")])
    assert a == b


def test_secret_value_does_not_change_sha():
    """The whole point: SHA is structural, not over secret bytes.

    Two installs with different admin passwords must produce the same SHA when
    they wire the same graph — that's how an operator proves the airgap deploy
    matches the connected build without leaking the secret.
    """
    a = structural_sha([_api("gitea", "jenkins", {"token": "AAA", "user": "u"})])
    b = structural_sha([_api("gitea", "jenkins", {"token": "BBB", "user": "u"})])
    assert a == b


def test_changing_producer_changes_sha():
    a = structural_sha([_api("gitea", "jenkins")])
    b = structural_sha([_api("gitea-2", "jenkins")])
    assert a != b


def test_changing_consumer_changes_sha():
    a = structural_sha([_api("gitea", "jenkins")])
    b = structural_sha([_api("gitea", "tekton")])
    assert a != b


def test_changing_credential_kind_changes_sha():
    """ApiToken vs UserPass on the same edge are different topologies."""
    a = structural_sha([_api("gitea", "jenkins")])
    b = structural_sha([_up("gitea", "jenkins")])
    assert a != b


def test_sha_is_order_independent():
    """Edge declaration order in platform.yaml must not affect the SHA.

    The hasher sorts the topology tuples, so a YAML reformatting that swaps
    two edges shouldn't churn the structural hash.
    """
    edges_a = [_api("gitea", "jenkins"), _up("gitea", "harbor")]
    edges_b = [_up("gitea", "harbor"), _api("gitea", "jenkins")]
    assert structural_sha(edges_a) == structural_sha(edges_b)
