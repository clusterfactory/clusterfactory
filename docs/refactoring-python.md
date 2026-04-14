# ClusterFactory — Python Refactoring Blueprint

> **Status:** Design document  
> **Scope:** Replace bash wire-job with a typed Python factory engine  
> **Goal:** A system that wires any component set, manages airgap bundles, plans upgrades, and tests itself at every layer

---

## Why

The bash wire-job in `wire-job.yaml` is a hand-compiled output of what an engine should generate. It works for gitea-jenkins because the wiring is a linear sequence of curl calls. It cannot scale to the factory vision because:

- It is not composable — no graph, no interface, no reusable structure
- It is not diffable — two bash scripts that do similar things look nothing alike structurally
- It has no type system — a credential is just a string, a readiness check is just a loop
- It breaks airgap discipline — `apk add curl jq` at runtime pulls from the internet
- It cannot plan upgrades — there is no model of current state versus desired state
- It cannot test itself — there is no seam between the wiring logic and a test harness

The Python engine is not a refactor of the bash. The bash was a hand-written instance of what the engine should produce automatically.

---

## The Mental Model

The factory takes two inputs and produces one output:

```
artifact_list  +  wiring_declaration  →  running, verified, signed platform
```

Everything else — airgap bundling, upgrade planning, testing — is a function over this triple.

---

## Input Format

A single `platform.yaml` file is the complete input to the factory:

```yaml
platform:
  name: gitea-jenkins
  version: "0.2.0"

artifacts:
  - name: gitea
    chart: gitea/gitea
    version: "11.0.1"
    image: gitea/gitea:1.23.6-rootless

  - name: jenkins
    chart: jenkins/jenkins
    version: "5.9.9"
    image: jenkins/jenkins:2.541.3-jdk21

  - name: act-runner
    image: gitea/act_runner:0.3.1

  - name: wire
    image: python:3.12-slim

wiring:
  - from: gitea
    to: jenkins
    credential: api-token

  - from: gitea
    to: act-runner
    credential: runner-token

airgap: true

compatibility:
  tested: true
  matrix:
    gitea: "1.23.6"
    jenkins: "2.541.3"
    actRunner: "0.3.1"
```

The artifact list is the bundle manifest. The wiring declaration is the topology. There is no other source of truth.

---

## Repository Layout

```
factory/
  __main__.py              # entrypoint — reads platform.yaml, runs engine

  model/
    artifact.py            # Artifact — name, chart, version, image, sha
    credential.py          # Credential — kind, producer, consumer, value, sha
    platform.py            # Platform — artifact list + wiring graph + platform sha
    graph.py               # WiringGraph — directed graph, topological sort
    result.py              # PlatformResult — structural sha, credentials, timestamp

  engine/
    resolver.py            # artifact name → component instance
    planner.py             # wiring declaration → execution plan
    executor.py            # executes plan, retries, ordering
    verifier.py            # verifies each wire holds post-execution
    hasher.py              # structural sha from credential set
    differ.py              # diff two PlatformResults for upgrade planning

  components/
    base.py                # Component interface — every component implements this
    gitea.py               # Gitea component
    jenkins.py             # Jenkins component
    harbor.py              # future
    vault.py               # future
    keycloak.py            # future
    registry.py            # auto-discovers component class from artifact name

  credentials/
    base.py                # Credential base class
    types.py               # ApiToken, UserPass, RegistryPush, OIDCConfig, RunnerToken
    store.py               # Kubernetes Secret read/write

  health/
    checker.py             # readiness primitives — parallel polling, timeout, backoff

  bundle/
    collector.py           # walks artifact list, collects images + charts
    packager.py            # produces airgap bundle — images.tar + manifest
    loader.py              # loads bundle on airgapped machine

  upgrade/
    planner.py             # diff two platform shas → ordered transition steps
    validator.py           # precondition checks before upgrade executes
    contract.py            # signed, hashable upgrade artifact

  testing/
    framework.py           # test runner — connected, airgap, upgrade modes
    fixtures.py            # shared fixtures — fake components, mock credentials
    layers/
      unit/                # pure logic — no network, no kubernetes
      integration/         # real components, real network, test namespace
      airgap/              # full airgap simulation — no external pulls allowed
      upgrade/             # N → N+1 transition verification
    assertions/
      wiring.py            # assert wires hold
      sha.py               # assert sha determinism
      airgap.py            # assert no external traffic
      upgrade.py           # assert state preserved across upgrade
```

---

## The Model Layer

### Artifact

```python
# model/artifact.py

from dataclasses import dataclass, field
from factory.hasher import sha256_of

@dataclass
class Artifact:
    name: str
    chart: str | None
    version: str | None
    image: str

    sha: str = field(init=False)

    def __post_init__(self):
        self.sha = sha256_of(f"{self.chart}:{self.version}:{self.image}")
```

### Credential

```python
# model/credential.py

from dataclasses import dataclass, field
from factory.hasher import sha256_of
import json

@dataclass
class Credential:
    kind: str           # ApiToken | UserPass | RegistryPush | RunnerToken | OIDCConfig
    producer: str       # artifact name that generated this
    consumer: str       # artifact name this is intended for
    value: dict         # the actual credential payload

    sha: str = field(init=False)

    def __post_init__(self):
        self.sha = sha256_of(json.dumps(self.value, sort_keys=True))
```

### Platform

The platform SHA is the structural contract fingerprint. Same artifact list plus same wiring always produces the same SHA.

```python
# model/platform.py

from dataclasses import dataclass
from factory.hasher import sha256_of
from factory.model.artifact import Artifact
import json

@dataclass
class WiringEdge:
    source: str         # artifact name
    target: str         # artifact name
    credential: str     # credential kind

@dataclass
class Platform:
    name: str
    version: str
    artifacts: list[Artifact]
    wiring: list[WiringEdge]
    airgap: bool = False

    @property
    def sha(self) -> str:
        artifact_sha = sha256_of(
            json.dumps(sorted(a.sha for a in self.artifacts))
        )
        wiring_sha = sha256_of(
            json.dumps(sorted(
                f"{e.source}-{e.credential}-{e.target}"
                for e in self.wiring
            ))
        )
        return sha256_of(artifact_sha + wiring_sha)

    @classmethod
    def from_yaml(cls, path: str) -> "Platform":
        ...
```

### PlatformResult

```python
# model/result.py

from dataclasses import dataclass
from datetime import datetime

@dataclass
class PlatformResult:
    platform_sha: str           # sha of the platform declaration
    structural_sha: str         # sha of all credential shas — proves wiring executed
    credentials: list           # all credentials produced during wiring
    timestamp: datetime
    success: bool
    errors: list[str] = field(default_factory=list)
```

---

## The Component Interface

Every component implements this interface. The engine calls only these methods. Adding a new component means writing a new class — nothing in the engine changes.

```python
# components/base.py

from abc import ABC, abstractmethod
from factory.model.credential import Credential

class Component(ABC):

    def __init__(self, artifact, config: dict):
        self.artifact = artifact
        self.config = config

    @property
    def name(self) -> str:
        return self.artifact.name

    @property
    @abstractmethod
    def url(self) -> str:
        """Base URL of this component's API."""

    @abstractmethod
    def ready(self) -> bool:
        """
        Poll until the component is ready to accept API calls.
        Raises TimeoutError after max_wait seconds.
        Returns True when ready.
        """

    @abstractmethod
    def produces(self) -> list[type[Credential]]:
        """Credential types this component can generate."""

    @abstractmethod
    def consumes(self) -> list[type[Credential]]:
        """Credential types this component accepts."""

    @abstractmethod
    def extract(self, kind: type[Credential], for_consumer: str) -> Credential:
        """
        Generate and return a credential of the requested type.
        Called by the engine after this component is ready.
        Must be idempotent — re-calling produces the same logical credential.
        """

    @abstractmethod
    def inject(self, credential: Credential) -> None:
        """
        Accept and apply an inbound credential.
        Called by the engine after the producing component has run extract().
        Must be idempotent.
        """

    @abstractmethod
    def verify(self, credential: Credential) -> bool:
        """
        Prove that a specific wire holds.
        Called by the verifier after all inject() calls complete.
        Returns True if the wire is confirmed, False or raises if broken.
        """
```

---

## Gitea and Jenkins Components

```python
# components/gitea.py

from factory.components.base import Component
from factory.credentials.types import ApiToken, RunnerToken
import requests

class GiteaComponent(Component):

    @property
    def url(self):
        return f"http://{self.config['service']}:3000"

    def ready(self) -> bool:
        # GET / → 200
        ...

    def produces(self):
        return [ApiToken, RunnerToken]

    def consumes(self):
        return []  # seed stack — consumes nothing
                   # future: OIDCConfig from Keycloak

    def extract(self, kind, for_consumer) -> Credential:
        if kind == ApiToken:
            return self._mint_api_token(for_consumer)
        if kind == RunnerToken:
            return self._fetch_runner_token(for_consumer)

    def inject(self, credential):
        pass  # gitea consumes nothing in seed stack

    def verify(self, credential) -> bool:
        if credential.kind == "ApiToken":
            # GET /api/v1/users/{user}/tokens → token name exists
            ...
        if credential.kind == "RunnerToken":
            # check secret exists in kubernetes
            ...

    # internal methods
    def _mint_api_token(self, consumer: str) -> Credential: ...
    def _fetch_runner_token(self, consumer: str) -> Credential: ...
    def create_org(self, name: str): ...
    def create_repo(self, org: str, name: str): ...
    def push_file(self, org: str, repo: str, path: str, content: bytes): ...
```

```python
# components/jenkins.py

from factory.components.base import Component
from factory.credentials.types import ApiToken, UserPass

class JenkinsComponent(Component):

    @property
    def url(self):
        return f"http://{self.config['service']}:8080"

    def ready(self) -> bool:
        # GET / → 200
        ...

    def produces(self):
        return []  # Jenkins produces nothing in seed stack
                   # future: BuildArtifact, DeployToken

    def consumes(self):
        return [ApiToken, UserPass]

    def extract(self, kind, for_consumer):
        pass

    def inject(self, credential: Credential) -> None:
        if credential.kind == "ApiToken":
            self._store_api_token(credential)
        if credential.kind == "UserPass":
            self._store_userpass(credential)

    def verify(self, credential: Credential) -> bool:
        # GET /credentials/store/system/domain/_/credential/{id}/api/json
        # confirm credential id exists
        ...

    # internal methods
    def _store_api_token(self, credential: Credential): ...
    def _store_userpass(self, credential: Credential): ...
    def create_pipeline(self, name: str, repo_url: str): ...
```

---

## The Engine

```python
# engine/executor.py

from factory.model.platform import Platform
from factory.model.result import PlatformResult
from factory.engine.resolver import Resolver
from factory.engine.planner import Planner
from factory.engine.verifier import Verifier
from factory.engine.hasher import Hasher
from factory.health.checker import HealthChecker
from datetime import datetime, timezone
import logging

log = logging.getLogger("factory.engine")

class Executor:

    def __init__(self, resolver, planner, verifier, hasher, health):
        self.resolver = resolver
        self.planner = planner
        self.verifier = verifier
        self.hasher = hasher
        self.health = health

    def run(self, platform: Platform) -> PlatformResult:
        log.info(f"factory starting | platform_sha={platform.sha}")

        # 1. resolve artifact names → component instances
        components = self.resolver.resolve(platform.artifacts)
        log.info(f"resolved {len(components)} components")

        # 2. build directed wiring graph from declaration
        graph = self.planner.build(platform.wiring, components)
        log.info(f"wiring graph | {len(graph.edges)} edges")

        # 3. wait for all components ready — parallel with timeout
        self.health.wait_all(components, timeout=300)
        log.info("all components ready")

        # 4. execute wiring in dependency order
        credentials = []
        for edge in graph.topological_order():
            log.info(f"wiring | {edge.source.name} → {edge.target.name} | {edge.credential_kind}")
            credential = edge.source.extract(edge.credential_type, edge.target.name)
            edge.target.inject(credential)
            credentials.append(credential)
            log.info(f"wired  | sha={credential.sha[:12]}")

        # 5. verify all wires hold
        errors = self.verifier.verify_all(graph.edges, credentials)
        if errors:
            return PlatformResult(
                platform_sha=platform.sha,
                structural_sha="",
                credentials=credentials,
                timestamp=datetime.now(timezone.utc),
                success=False,
                errors=errors
            )

        # 6. produce structural sha
        structural_sha = self.hasher.hash(credentials)
        log.info(f"factory complete | structural_sha={structural_sha}")

        return PlatformResult(
            platform_sha=platform.sha,
            structural_sha=structural_sha,
            credentials=credentials,
            timestamp=datetime.now(timezone.utc),
            success=True
        )
```

---

## The Upgrade Engine

```python
# upgrade/planner.py

from dataclasses import dataclass
from factory.model.platform import Platform
from factory.model.result import PlatformResult

@dataclass
class ArtifactDelta:
    name: str
    from_sha: str
    to_sha: str
    image_changed: bool
    chart_changed: bool

@dataclass
class WiringDelta:
    kind: str           # added | removed | changed
    edge: object

@dataclass
class UpgradePlan:
    from_sha: str               # sha of running platform
    to_sha: str                 # sha of target platform
    artifact_deltas: list[ArtifactDelta]
    wiring_deltas: list[WiringDelta]
    steps: list                 # ordered execution steps — only what changed
    preconditions: list         # must be true before upgrade starts
    rollback_sha: str           # re-apply this sha to roll back
    plan_sha: str               # sha of this plan — signable artifact

class UpgradePlanner:

    def plan(self,
             current: PlatformResult,
             target: Platform) -> UpgradePlan:

        artifact_deltas = self._diff_artifacts(
            current.platform, target
        )
        wiring_deltas = self._diff_wiring(
            current.platform, target
        )

        steps = self._order_steps(artifact_deltas, wiring_deltas)
        preconditions = self._preconditions(artifact_deltas, wiring_deltas)

        plan = UpgradePlan(
            from_sha=current.platform_sha,
            to_sha=target.sha,
            artifact_deltas=artifact_deltas,
            wiring_deltas=wiring_deltas,
            steps=steps,
            preconditions=preconditions,
            rollback_sha=current.platform_sha,
            plan_sha=""  # set below
        )
        plan.plan_sha = self._hash_plan(plan)
        return plan

    def _diff_artifacts(self, current, target) -> list[ArtifactDelta]: ...
    def _diff_wiring(self, current, target) -> list[WiringDelta]: ...
    def _order_steps(self, artifact_deltas, wiring_deltas) -> list: ...
    def _preconditions(self, artifact_deltas, wiring_deltas) -> list: ...
    def _hash_plan(self, plan: UpgradePlan) -> str: ...
```

The upgrade plan is itself a hashable, signable artifact. Produce it on a connected machine, sign it, ship it into the airgap with the delta bundle. On the airgapped machine verify the plan SHA before executing a single step.

---

## The Bundle Collector

```python
# bundle/collector.py

from dataclasses import dataclass
from factory.model.platform import Platform

@dataclass
class Bundle:
    platform_sha: str
    images: list[str]       # all image references
    charts: list[str]       # all chart references
    manifest_sha: str       # sha of (images + charts) — verifiable on arrival

class BundleCollector:

    def collect(self, platform: Platform) -> Bundle:
        images = [a.image for a in platform.artifacts if a.image]
        charts = [f"{a.chart}:{a.version}" for a in platform.artifacts if a.chart]

        return Bundle(
            platform_sha=platform.sha,
            images=images,
            charts=charts,
            manifest_sha=sha256_of(
                json.dumps(sorted(images) + sorted(charts))
            )
        )
```

The artifact list in `platform.yaml` is the bundle manifest. There is no separate `images.txt`. The platform SHA is the manifest SHA root.

---

## The Testing System

Testing is not an afterthought. The factory tests itself at four layers. Every layer is required — no component joins the factory without passing all four.

### The Four Layers

```
unit         →  pure logic, no network, no kubernetes, runs in milliseconds
integration  →  real components, real network, test namespace, runs in minutes
airgap       →  full simulation, no external pulls allowed, runs in CI
upgrade      →  N → N+1 transition, state preserved, wiring re-verified
```

### Layer 1 — Unit Tests

Test the model and engine logic in isolation. No network. No Kubernetes. Fake components and fake credentials.

```python
# testing/layers/unit/test_platform_sha.py

from factory.model.platform import Platform, WiringEdge
from factory.model.artifact import Artifact

def test_platform_sha_is_deterministic():
    """Same declaration always produces same SHA."""
    platform_a = make_gitea_jenkins_platform()
    platform_b = make_gitea_jenkins_platform()
    assert platform_a.sha == platform_b.sha

def test_platform_sha_changes_on_artifact_version():
    """Bumping a version changes the SHA."""
    platform_a = make_platform(gitea_version="11.0.1")
    platform_b = make_platform(gitea_version="11.0.2")
    assert platform_a.sha != platform_b.sha

def test_platform_sha_changes_on_wiring_change():
    """Adding a wire changes the SHA."""
    platform_a = make_platform(wiring=[])
    platform_b = make_platform(wiring=[WiringEdge("gitea", "jenkins", "api-token")])
    assert platform_a.sha != platform_b.sha

def test_wiring_graph_topological_order():
    """Engine executes edges in dependency order."""
    ...

def test_credential_sha_is_deterministic():
    """Same credential value always produces same SHA."""
    ...
```

```python
# testing/layers/unit/test_engine.py

from factory.testing.fixtures import FakeGiteaComponent, FakeJenkinsComponent, FakeCredential

def test_engine_calls_extract_before_inject():
    """Engine calls extract on producer before inject on consumer."""
    gitea = FakeGiteaComponent()
    jenkins = FakeJenkinsComponent()
    engine = make_engine([gitea, jenkins])
    platform = make_platform()

    result = engine.run(platform)

    assert gitea.extract_called_before(jenkins.inject_called_at)

def test_engine_calls_verify_after_all_injects():
    """Engine verifies all wires after execution completes."""
    ...

def test_engine_returns_failure_on_verify_error():
    """Engine result is failure if any verify() returns False."""
    ...

def test_structural_sha_changes_if_credential_changes():
    """Different credential values produce different structural SHA."""
    ...
```

### Layer 2 — Integration Tests

Real components. Real network calls. Runs against a live cluster in a dedicated test namespace. These are the existing helm tests, promoted to the Python testing framework.

```python
# testing/layers/integration/test_gitea_jenkins.py

import pytest
from factory.model.platform import Platform
from factory.engine.executor import make_executor

@pytest.fixture
def platform():
    return Platform.from_yaml("tests/fixtures/platform-gitea-jenkins.yaml")

def test_full_wire_produces_result(platform, live_cluster):
    executor = make_executor()
    result = executor.run(platform)

    assert result.success
    assert result.structural_sha != ""
    assert len(result.credentials) == 2  # api-token + runner-token

def test_gitea_ready(platform, live_cluster):
    from factory.components.gitea import GiteaComponent
    gitea = GiteaComponent(platform.artifact("gitea"), config=live_cluster.config)
    assert gitea.ready()

def test_gitea_produces_api_token(platform, live_cluster):
    gitea = make_gitea(platform, live_cluster)
    gitea.ready()
    token = gitea.extract(ApiToken, for_consumer="jenkins")
    assert token.kind == "ApiToken"
    assert token.sha != ""

def test_jenkins_accepts_api_token(platform, live_cluster):
    ...

def test_jenkins_pipeline_points_at_gitea_repo(platform, live_cluster):
    # this is the existing test-jenkins.yaml helm test, in Python
    ...

def test_wire_is_idempotent(platform, live_cluster):
    """Running the engine twice produces the same structural SHA."""
    executor = make_executor()
    result_a = executor.run(platform)
    result_b = executor.run(platform)
    assert result_a.structural_sha == result_b.structural_sha
```

### Layer 3 — Airgap Tests

Full airgap simulation. No external network pulls allowed. The factory must complete using only the images in the bundle. This is the existing airgap CI job, promoted to a first-class test layer.

```python
# testing/layers/airgap/test_airgap.py

from factory.testing.assertions.airgap import assert_no_external_traffic

def test_bundle_contains_all_images(platform):
    """Every image referenced in platform.yaml is in the bundle."""
    from factory.bundle.collector import BundleCollector
    bundle = BundleCollector().collect(platform)
    for image in bundle.images:
        assert image_exists_locally(image), f"missing: {image}"

def test_wire_completes_without_external_traffic(platform, airgap_cluster):
    """
    Full wire-job execution with network policy blocking external traffic.
    Uses the same k3d + containerd setup as the existing CI airgap job.
    Assert no DNS lookups or TCP connections left the cluster boundary.
    """
    with assert_no_external_traffic(airgap_cluster):
        executor = make_executor()
        result = executor.run(platform)
        assert result.success

def test_bundle_sha_matches_platform_sha(platform):
    """Bundle manifest SHA is derived from platform SHA."""
    bundle = BundleCollector().collect(platform)
    assert bundle.platform_sha == platform.sha

def test_wire_image_is_in_bundle(platform):
    """The factory engine image itself is bundled."""
    bundle = BundleCollector().collect(platform)
    assert any("python" in img for img in bundle.images)
```

### Layer 4 — Upgrade Tests

These tests are the most important and the most underserved by existing tooling. They prove that moving from SHA-A to SHA-B preserves state and produces a valid new structural SHA.

```python
# testing/layers/upgrade/test_upgrade.py

def test_upgrade_plan_sha_is_deterministic(platform_v1, platform_v2):
    """Same source + target always produces same plan SHA."""
    planner = UpgradePlanner()
    result_v1 = run_and_get_result(platform_v1)

    plan_a = planner.plan(result_v1, platform_v2)
    plan_b = planner.plan(result_v1, platform_v2)
    assert plan_a.plan_sha == plan_b.plan_sha

def test_upgrade_only_rewires_changed_edges(platform_v1, platform_v2, live_cluster):
    """Upgrade does not re-run wires that did not change."""
    result_v1 = run_platform(platform_v1, live_cluster)
    plan = UpgradePlanner().plan(result_v1, platform_v2)

    # gitea version bumped, jenkins unchanged
    # only the gitea → jenkins wire should re-run
    assert len(plan.steps) == 1
    assert plan.steps[0].edge.source.name == "gitea"

def test_upgrade_preserves_existing_state(platform_v1, platform_v2, live_cluster):
    """
    State that existed before upgrade (repos, jobs, credentials)
    survives the upgrade unchanged.
    """
    result_v1 = run_platform(platform_v1, live_cluster)
    # create some state
    create_test_repo(live_cluster)
    create_test_job(live_cluster)

    # upgrade
    plan = UpgradePlanner().plan(result_v1, platform_v2)
    result_v2 = UpgradeExecutor().run(plan, live_cluster)

    assert result_v2.success
    assert test_repo_still_exists(live_cluster)
    assert test_job_still_exists(live_cluster)

def test_rollback_restores_previous_sha(platform_v1, platform_v2, live_cluster):
    """Rolling back after upgrade restores the v1 structural SHA."""
    result_v1 = run_platform(platform_v1, live_cluster)
    v1_structural_sha = result_v1.structural_sha

    plan = UpgradePlanner().plan(result_v1, platform_v2)
    result_v2 = UpgradeExecutor().run(plan, live_cluster)

    # rollback
    result_rolled_back = UpgradeExecutor().rollback(plan, live_cluster)
    assert result_rolled_back.structural_sha == v1_structural_sha

def test_upgrade_airgap(platform_v1, platform_v2, airgap_cluster):
    """Upgrade completes without external traffic using delta bundle."""
    result_v1 = run_platform(platform_v1, airgap_cluster)
    plan = UpgradePlanner().plan(result_v1, platform_v2)
    delta_bundle = DeltaBundleCollector().collect(plan)

    with assert_no_external_traffic(airgap_cluster):
        result_v2 = UpgradeExecutor().run(plan, airgap_cluster)
        assert result_v2.success
```

### Test Fixtures

```python
# testing/fixtures.py

from factory.components.base import Component
from factory.credentials.types import ApiToken

class FakeGiteaComponent(Component):
    """In-memory Gitea. No network. Deterministic credentials."""

    def __init__(self):
        self.extract_calls = []
        self.inject_calls = []

    def ready(self) -> bool:
        return True

    def produces(self):
        return [ApiToken]

    def consumes(self):
        return []

    def extract(self, kind, for_consumer):
        credential = ApiToken(
            producer=self.name,
            consumer=for_consumer,
            value={"token": "fake-token-deterministic"}
        )
        self.extract_calls.append((kind, for_consumer, credential))
        return credential

    def inject(self, credential):
        self.inject_calls.append(credential)

    def verify(self, credential) -> bool:
        return True

    def extract_called_before(self, timestamp) -> bool:
        return any(c[2].timestamp < timestamp for c in self.extract_calls)


class FakeJenkinsComponent(Component):
    """In-memory Jenkins. Records inject calls for assertion."""
    ...
```

### Test Runner

```python
# testing/framework.py

import argparse
import subprocess
import sys

LAYERS = ["unit", "integration", "airgap", "upgrade"]

def run(layers: list[str], platform_yaml: str):
    """
    Run the requested test layers in order.
    Fail fast — airgap and upgrade tests do not run if unit or integration fail.
    """
    results = {}

    for layer in layers:
        print(f"\n── {layer} tests ──────────────────────")
        result = subprocess.run(
            ["pytest", f"factory/testing/layers/{layer}/",
             "--platform", platform_yaml,
             "-v", "--tb=short"],
            capture_output=False
        )
        results[layer] = result.returncode == 0
        if not results[layer]:
            print(f"FAILED: {layer} tests failed. Stopping.")
            sys.exit(1)

    print("\n── all layers passed ──────────────────")
    return results

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--layers", nargs="+", default=LAYERS)
    parser.add_argument("--platform", default="platform.yaml")
    args = parser.parse_args()
    run(args.layers, args.platform)
```

---

## Container Change

Replace `alpine:3.19` with a Python image. All dependencies are installed at image build time — nothing is pulled at runtime.

```dockerfile
# Dockerfile.wire
FROM python:3.12-slim

WORKDIR /factory
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY factory/ factory/
ENTRYPOINT ["python", "-m", "factory"]
```

```
# requirements.txt
requests==2.32.3
kubernetes==30.1.0
pyyaml==6.0.2
```

This image is added to `bundle.sh` image collection and to `values-airgap.yaml`:

```yaml
# values-airgap.yaml
wire:
  image: REGISTRY/clusterfactory/wire:0.2.0
```

---

## Helm Integration

The wire-job stays a Kubernetes Job with the same hook annotations. Only the container changes.

```yaml
# templates/wire-job.yaml (simplified)
containers:
  - name: wire
    image: {{ .Values.wire.image }}
    command: ["python", "-m", "factory"]
    args:
      - "--platform"
      - "/config/platform.yaml"
      - "--mode"
      - "{{ .Values.wire.mode | default "wire" }}"
    volumeMounts:
      - name: platform-config
        mountPath: /config
volumes:
  - name: platform-config
    configMap:
      name: {{ .Release.Name }}-platform
```

`platform.yaml` is mounted from a ConfigMap generated from `values.yaml` at render time. The engine reads it at runtime.

---

## Acceptance Criteria

A component is ready to join the factory when:

1. `unit` tests pass — model is correct, engine logic is verified with fake components
2. `integration` tests pass — real component wires correctly in a live namespace
3. `airgap` tests pass — no external traffic during full wire execution
4. `upgrade` tests pass — state is preserved across N → N+1 transition
5. `helm test` passes — existing test-gitea.yaml and test-jenkins.yaml still green
6. `structural_sha` is logged at the end of a successful wire run
7. The component image appears in `bundle.sh` output and `values-airgap.yaml`
8. The compatibility matrix in `platform.yaml` is updated and CI enforces it

No exceptions. The moment a component joins without passing all layers the coherence guarantee that makes the SHA meaningful is broken.

---

## Migration Path from Bash

The bash wire-job and the Python engine can run side by side during the transition. The Helm chart supports both via a feature flag:

```yaml
wire:
  engine: bash    # current default
  # engine: python  # opt-in during transition
```

The transition is complete when:

- Python engine passes all four test layers
- Structural SHA produced by Python matches expected output
- CI airgap job passes with Python image in bundle
- `engine: python` becomes the default
- Bash script is deleted

---

## What This Enables

Every component added after this refactor gets the full factory treatment automatically:

- Add `harbor.py` implementing the Component interface
- Add Harbor to `platform.yaml`
- Write unit tests with `FakeHarborComponent`
- Run integration tests against a real Harbor instance
- Airgap test passes because `bundle.sh` walks the artifact list
- Upgrade tests verify Harbor state survives gitea or jenkins upgrades
- Compatibility matrix is updated and CI enforces it

The factory wires Harbor into every stack that declares it. No bash script changes. No engine changes. Just a new component class and a declaration in `platform.yaml`.

That is the factory pattern working as designed.
