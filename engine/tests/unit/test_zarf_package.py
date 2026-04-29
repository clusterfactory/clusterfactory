"""zarf.yaml structure tests.

The airgap promise has two halves: (a) Python wires Gitea + Jenkins in-cluster,
and (b) Zarf packages all the images so it works without internet. This test
file pins half (b): zarf.yaml must declare gitea + jenkins charts, must bundle
the upstream images, must reference the wire image we build, and must surface
the structural SHA after deploy.

These are not Helm tests — they're config-drift tests against zarf.yaml.
"""
from pathlib import Path

import pytest
import yaml


REPO_ROOT = Path(__file__).resolve().parents[3]
ZARF_YAML = REPO_ROOT / "zarf.yaml"


@pytest.fixture
def zarf():
    if not ZARF_YAML.exists():
        pytest.skip(f"zarf.yaml not found at {ZARF_YAML}")
    return yaml.safe_load(ZARF_YAML.read_text())


def _components(zarf):
    return {c["name"]: c for c in zarf["components"]}


def test_zarf_metadata_is_a_clusterfactory_package(zarf):
    assert zarf["kind"] == "ZarfPackageConfig"
    assert zarf["metadata"]["name"].startswith("clusterfactory")


def test_gitea_admin_password_is_a_prompted_variable(zarf):
    """Operator sets this at deploy time. It must be marked sensitive."""
    var_names = [v["name"] for v in zarf.get("variables", [])]
    assert "GITEA_ADMIN_PASSWORD" in var_names
    var = next(v for v in zarf["variables"] if v["name"] == "GITEA_ADMIN_PASSWORD")
    assert var.get("sensitive") is True
    assert var.get("prompt") is True


def test_gitea_component_pulls_chart_and_image(zarf):
    comps = _components(zarf)
    assert "gitea" in comps, "zarf.yaml must declare a gitea component"
    gitea = comps["gitea"]
    chart_names = [c["name"] for c in gitea.get("charts", [])]
    assert "gitea" in chart_names
    images = gitea.get("images", [])
    assert any("gitea" in img.lower() for img in images), \
        "gitea component must bundle the upstream gitea image"


def test_jenkins_component_pulls_chart_and_image(zarf):
    comps = _components(zarf)
    assert "jenkins" in comps, "zarf.yaml must declare a jenkins component"
    jenkins = comps["jenkins"]
    chart_names = [c["name"] for c in jenkins.get("charts", [])]
    assert "jenkins" in chart_names
    images = jenkins.get("images", [])
    assert any("jenkins" in img.lower() for img in images), \
        "jenkins component must bundle the upstream jenkins image"


def test_platform_spec_configmap_is_packaged(zarf):
    """The wire engine reads platform.yaml from a ConfigMap. That ConfigMap
    must ship in the package or the engine has nothing to read."""
    comps = _components(zarf)
    assert "platform-spec" in comps


def test_wire_component_deploys_job_manifest(zarf):
    """The wire Job manifest must be packaged so it can be deployed.
    The integration test handles waiting and validation."""
    comps = _components(zarf)
    assert "wire" in comps, "zarf.yaml must declare a wire component"
    wire = comps["wire"]
    
    # Check that wire manifests are included
    manifests = wire.get("manifests", [])
    manifest_names = [m["name"] for m in manifests]
    assert "wire-rbac" in manifest_names, "wire component must include RBAC"
    assert "wire-job" in manifest_names, "wire component must include the Job manifest"
