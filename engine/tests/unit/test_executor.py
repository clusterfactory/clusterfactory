"""Executor + verifier tests.

Once the graph is built, the executor runs each edge in topological order
(extract from source, inject into target), and the verifier confirms each
target accepted its credential. These tests pin the call sequence and the
end-to-end happy path through the engine, all without network.
"""
import logging
import pytest

from clusterfactory_engine import credential as cred_module
from clusterfactory_engine.credential import UserPass
from clusterfactory_engine.executor import Executor
from clusterfactory_engine.hasher import structural_sha
from clusterfactory_engine.planner import build_graph
from clusterfactory_engine.verifier import verify_all

from ._fakes import FakeGitea, FakeJenkins


@pytest.fixture
def log():
    return logging.getLogger("test")


@pytest.fixture
def demo_graph():
    """The v0.3 demo wiring: gitea → jenkins via UserPass."""
    components = {"gitea": FakeGitea(), "jenkins": FakeJenkins()}
    wiring = [{"from": "gitea", "to": "jenkins", "credential": "UserPass"}]
    graph = build_graph(wiring, components, cred_module)
    return components, graph


def test_executor_runs_extract_then_inject(demo_graph, log):
    components, graph = demo_graph
    gitea, jenkins = components["gitea"], components["jenkins"]

    Executor(log).run(graph)

    # Source got extract, target got inject — exactly once each.
    assert len(gitea.extract_calls) == 1
    assert len(jenkins.inject_calls) == 1

    # And it was the right credential type for the right consumer.
    kind, consumer = gitea.extract_calls[0]
    assert kind is UserPass
    assert consumer == "jenkins"


def test_executor_returns_credentials_in_edge_order(demo_graph, log):
    components, graph = demo_graph

    creds = Executor(log).run(graph)

    assert len(creds) == 1
    assert creds[0].producer == "gitea"
    assert creds[0].consumer == "jenkins"
    assert creds[0].kind == "UserPass"


def test_full_pipeline_produces_stable_sha(log):
    """Run the full pipeline twice with different secret values — SHAs match."""
    def run(token):
        components = {
            "gitea": FakeGitea(token=token),
            "jenkins": FakeJenkins(),
        }
        wiring = [{"from": "gitea", "to": "jenkins", "credential": "UserPass"}]
        graph = build_graph(wiring, components, cred_module)
        creds = Executor(log).run(graph)
        errors = verify_all(graph, creds)
        assert not errors
        return structural_sha(creds)

    sha_a = run("password-from-airgap-a")
    sha_b = run("password-from-airgap-b")
    assert sha_a == sha_b, "structural SHA must not depend on secret values"


def test_verifier_reports_failure_when_target_rejects(log):
    """If a component's verify() returns False, surface a useful error."""
    components = {
        "gitea": FakeGitea(),
        "jenkins": FakeJenkins(verify_result=False),
    }
    wiring = [{"from": "gitea", "to": "jenkins", "credential": "UserPass"}]
    graph = build_graph(wiring, components, cred_module)
    creds = Executor(log).run(graph)

    errors = verify_all(graph, creds)
    assert len(errors) == 1
    assert "gitea" in errors[0]
    assert "jenkins" in errors[0]


def test_executor_propagates_extract_failure(log):
    """If extract raises (e.g., Gitea API 5xx), executor surfaces the error.

    The Job restarts under backoffLimit; this just pins that we don't swallow.
    """
    class BrokenGitea(FakeGitea):
        def extract(self, kind, for_consumer):
            raise RuntimeError("boom: gitea API down")

    components = {"gitea": BrokenGitea(), "jenkins": FakeJenkins()}
    wiring = [{"from": "gitea", "to": "jenkins", "credential": "UserPass"}]
    graph = build_graph(wiring, components, cred_module)

    with pytest.raises(RuntimeError, match="boom"):
        Executor(log).run(graph)
