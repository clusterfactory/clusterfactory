"""Planner tests — `build_graph` from platform.yaml.

The planner is where most platform.yaml mistakes get caught at install time:
unknown components, unknown credential kinds, capability mismatches. These
tests pin those error paths so a typo in platform.yaml fails fast with a
useful message instead of a confusing traceback five layers in.
"""
import pytest

from clusterfactory_engine import credential as cred_module
from clusterfactory_engine.credential import ApiToken, UserPass
from clusterfactory_engine.planner import build_graph

from ._fakes import FakeGitea, FakeJenkins


def _gitea_jenkins():
    return {"gitea": FakeGitea(), "jenkins": FakeJenkins()}


def test_builds_one_edge_for_demo_wiring():
    """The v0.3 demo: gitea → jenkins via UserPass. One edge, validates clean."""
    components = _gitea_jenkins()
    wiring = [{"from": "gitea", "to": "jenkins", "credential": "UserPass"}]

    graph = build_graph(wiring, components, cred_module)

    assert len(graph.edges) == 1
    edge = graph.edges[0]
    assert edge.source is components["gitea"]
    assert edge.target is components["jenkins"]
    assert edge.credential_kind == "UserPass"
    assert edge.credential_type is UserPass


def test_unknown_source_raises_with_name():
    components = _gitea_jenkins()
    wiring = [{"from": "harbor", "to": "jenkins", "credential": "UserPass"}]

    with pytest.raises(ValueError, match="harbor"):
        build_graph(wiring, components, cred_module)


def test_unknown_target_raises_with_name():
    components = _gitea_jenkins()
    wiring = [{"from": "gitea", "to": "harbor", "credential": "UserPass"}]

    with pytest.raises(ValueError, match="harbor"):
        build_graph(wiring, components, cred_module)


def test_unknown_credential_kind_raises():
    """Catch typos like `userpass` (lowercase) or `RobotToken` (not a class)."""
    components = _gitea_jenkins()
    wiring = [{"from": "gitea", "to": "jenkins", "credential": "RobotToken"}]

    with pytest.raises(ValueError, match="RobotToken"):
        build_graph(wiring, components, cred_module)


def test_producer_must_actually_produce_the_kind():
    """If platform.yaml says jenkins → gitea via ApiToken, refuse: jenkins doesn't
    produce ApiToken. This is the contract the resolver enforces."""
    components = _gitea_jenkins()
    wiring = [{"from": "jenkins", "to": "gitea", "credential": "ApiToken"}]

    with pytest.raises(ValueError, match="does not produce"):
        build_graph(wiring, components, cred_module)


def test_consumer_must_actually_consume_the_kind():
    """If platform.yaml says gitea consumes ApiToken, refuse: gitea is a seed."""
    components = _gitea_jenkins()
    wiring = [{"from": "jenkins", "to": "gitea", "credential": "UserPass"}]
    # FakeJenkins doesn't produce UserPass, so this should fail at the produces
    # check first. Swap producer/consumer to hit the consumes check directly:
    wiring = [{"from": "gitea", "to": "gitea", "credential": "ApiToken"}]

    with pytest.raises(ValueError, match="does not consume"):
        build_graph(wiring, components, cred_module)


def test_multiple_edges_are_all_added():
    """Future flavors will add more edges. The planner must scale beyond one."""
    components = _gitea_jenkins()
    wiring = [
        {"from": "gitea", "to": "jenkins", "credential": "UserPass"},
        {"from": "gitea", "to": "jenkins", "credential": "ApiToken"},
    ]

    graph = build_graph(wiring, components, cred_module)
    assert len(graph.edges) == 2
    assert {e.credential_kind for e in graph.edges} == {"UserPass", "ApiToken"}
