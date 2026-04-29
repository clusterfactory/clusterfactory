"""platform.yaml parse-and-plan smoke test.

The actual platform.yaml at the repo root is the demo's source of truth.
This test loads it, swaps in fake components, and confirms the planner can
turn it into a graph. If someone breaks the schema, this fails before zarf
package create even runs.
"""
from pathlib import Path

import pytest
import yaml

from clusterfactory_engine import credential as cred_module
from clusterfactory_engine.planner import build_graph

from ._fakes import FakeGitea, FakeJenkins


REPO_ROOT = Path(__file__).resolve().parents[3]
PLATFORM_YAML = REPO_ROOT / "platform.yaml"


@pytest.fixture
def spec():
    if not PLATFORM_YAML.exists():
        pytest.skip(f"platform.yaml not found at {PLATFORM_YAML}")
    return yaml.safe_load(PLATFORM_YAML.read_text())


def test_platform_yaml_has_expected_shape(spec):
    """Lock in the schema the engine reads."""
    assert spec["apiVersion"] == "clusterfactory.io/v1"
    assert spec["kind"] == "Platform"
    assert "components" in spec["spec"]
    assert "wiring" in spec["spec"]


def test_platform_yaml_declares_gitea_and_jenkins(spec):
    kinds = {c["kind"] for c in spec["spec"]["components"]}
    assert {"gitea", "jenkins"}.issubset(kinds), \
        "demo platform must declare both gitea and jenkins"


def test_platform_yaml_wires_gitea_to_jenkins(spec):
    """Single edge: gitea → jenkins. Anything else is scope creep for v0.3."""
    wiring = spec["spec"]["wiring"]
    assert len(wiring) == 1
    edge = wiring[0]
    assert edge["from"] == "gitea"
    assert edge["to"] == "jenkins"
    assert edge["credential"] in {"UserPass", "ApiToken"}


def test_platform_yaml_planner_round_trip(spec):
    """Substitute fakes for the named components and build the graph."""
    fakes = {"gitea": FakeGitea(), "jenkins": FakeJenkins()}
    graph = build_graph(spec["spec"]["wiring"], fakes, cred_module)
    assert len(graph.edges) == 1
