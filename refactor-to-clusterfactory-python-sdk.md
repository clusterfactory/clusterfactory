# Refactoring ClusterFactory to an SDK: Verifiable Immutable Platform Wiring

**Status:** Design proposal
**Target:** `clusterfactory` v0.3.x → v1.0
**Audience:** Core maintainers, prospective third-party component authors, security reviewers

---

## Why this document exists

ClusterFactory today is a Helm chart that installs Gitea + Jenkins and wires them together through a post-install `wire` Job. The wire logic exists in two forms: a bash script embedded in a Helm template, and a Python engine under `factory/` that is structurally correct but only wires the same two components.

The second form is the interesting one. Under `factory/engine/` there is a small, well-shaped wiring runtime: a resolver that maps names to components, a planner that builds a credential-dependency DAG, an executor that runs edges in topological order, a verifier that confirms wires hold, and a hasher that produces a structural SHA of the resulting platform. That is not a bootstrap script. It is the kernel of a platform-wiring engine.

This document proposes the refactor that turns the kernel into a real SDK: one where **a third party can implement `Component`, publish it as a pip package, drop it into a platform YAML, and have `clusterfactory` wire it into an airgap-complete, structurally-hashed platform bundle** — without ever touching the core repository.

The deliverable from that refactor is a single claim the project can make honestly: *given the same platform spec and the same component set, clusterfactory produces a bundle that installs into a reproducible, verifiable, structurally-identical platform in any cluster, connected or airgapped.*

That claim is what "immutable infrastructure, programmatically delivered, including into airgap" actually means. It is also what makes the project defensible as a pattern rather than as a Helm chart.

---

## Current state: what's there, what's missing

### What's there

The Python engine under `factory/` defines five pieces that correspond to the real shape of the wiring problem:

- `factory/components/base.py` defines the `Component` ABC with the right five methods: `ready`, `produces`, `consumes`, `extract`, `inject`, `verify`.
- `factory/model/credential.py` defines `Credential` as a dataclass with an auto-computed SHA over its value payload.
- `factory/engine/planner.py` builds a `WiringGraph` from declared edges, validates that producers produce and consumers consume, and refuses to build a graph with a mismatch.
- `factory/engine/executor.py` runs edges in topological order, catches failures per edge, and returns a `PlatformResult` with success/error state.
- `factory/engine/hasher.py` produces a structural SHA by sorting credential SHAs and hashing the JSON of the sorted list. Stable, order-independent, reproducible.

That is a real architecture. The shape is right.

### What's missing

Six things stand between this shape and a third-party-onboardable SDK. They are all mechanical rather than conceptual — the design doesn't need to change, the glue does.

**1. The resolver hardcodes components.** `factory/engine/resolver.py` lines 57–60 contain a dict `{'gitea': ..., 'jenkins': ...}` and per-component `if/elif` blocks for config. Adding Harbor requires editing this file. That is fork-and-patch, not plugin loading.

**2. The credential type registry is a closed enum.** `factory/engine/planner.py` lines 75–81 map strings like `"api-token"` to classes imported from a closed list in `factory/credentials/types.py`. A third party cannot introduce `VaultAppRole` or `HarborRobotAccount` without editing this map.

**3. The SDK is not a separate package.** Third parties who want to depend on `Component` must depend on the whole clusterfactory monorepo. Their version pins couple to your internal refactoring, which is a guaranteed path to breakage.

**4. The wire container image bakes components in at build time.** `Dockerfile.wire` copies the entire `factory/` directory at image build. A Harbor component cannot be loaded at runtime; it must be baked in, which means every component adds a new build variant.

**5. There is no conformance test suite.** A component author has no executable way to confirm their implementation satisfies the contract. The contract exists only in prose docstrings, which rot.

**6. The structural SHA covers credentials but not the full platform.** Today, `PlatformResult.structural_sha` hashes the set of produced credentials. That proves wiring *happened*. It does not prove that the *inputs* to the wiring — component versions, image digests, platform spec, SDK version — were what you expected. A full immutability claim needs to cover the inputs, not just the output.

Until those six are fixed, "the `Component` abstraction enables third-party onboarding" is aspirational prose. After they are fixed, it is demonstrable in a README tutorial under fifty lines.

---

## Target architecture

### Package split

Today: one repo, one package, one image.

Target: three pip packages with clear dependency direction, plus N component packages published independently.

```
clusterfactory-sdk           ← small, stable, changes rarely
  ├─ Component (ABC)
  ├─ Credential (base class)
  ├─ Common credential types: ApiToken, UserPass, OIDCClientCredential,
  │                           DockerRegistryCredential, VaultAppRole, ...
  └─ Testing: ComponentContractTests (pytest base class)

clusterfactory-engine        ← the runtime, depends on SDK
  ├─ Resolver (entry-point driven)
  ├─ Planner, Executor, Verifier, Hasher
  ├─ Platform spec parser
  └─ Bundle manifest writer

clusterfactory-cli           ← thin wrapper over engine, what users invoke
  └─ `clusterfactory wire`, `clusterfactory bundle`, `clusterfactory verify`

clusterfactory-component-gitea      ← first-party reference component
clusterfactory-component-jenkins    ← first-party reference component
clusterfactory-component-harbor     ← first proof-of-generalization
clusterfactory-component-openbao    ← second proof-of-generalization

third-party-clusterfactory-*        ← community components, never touch core
```

Dependency rules:
- `clusterfactory-sdk` depends on nothing beyond stdlib + `requests` + `pyyaml`.
- `clusterfactory-engine` depends on `clusterfactory-sdk`.
- Components depend on `clusterfactory-sdk` only — never on `clusterfactory-engine`.

This is the same shape as pytest (core + plugins), Django (core + apps), and Kubernetes CSI (kubelet + drivers). It is boring on purpose. Boring plugin systems are the ones that last.

### Entry-point discovery

The resolver stops knowing component names. Components advertise themselves via Python entry points. A component's `pyproject.toml`:

```toml
[project]
name = "clusterfactory-component-harbor"
version = "0.1.0"
dependencies = [
    "clusterfactory-sdk>=1.0,<2.0",
    "requests>=2.31",
]

[project.entry-points."clusterfactory.components"]
harbor = "clusterfactory_component_harbor:HarborComponent"

[project.entry-points."clusterfactory.credentials"]
harbor-robot = "clusterfactory_component_harbor.credentials:HarborRobotAccount"
docker-registry = "clusterfactory_sdk.credentials:DockerRegistryCredential"
```

The engine's resolver becomes dumb:

```python
# clusterfactory_engine/resolver.py
from importlib.metadata import entry_points
from clusterfactory_sdk import Component

class Resolver:
    def __init__(self):
        self._registry: dict[str, type[Component]] = {}
        for ep in entry_points(group="clusterfactory.components"):
            self._registry[ep.name] = ep.load()

    def get(self, kind: str) -> type[Component]:
        if kind not in self._registry:
            raise UnknownComponentError(
                f"No component registered for '{kind}'. "
                f"Known: {sorted(self._registry)}"
            )
        return self._registry[kind]
```

`pip install clusterfactory-component-harbor` is now the only step needed to make `kind: harbor` valid in a platform spec. No core code changes. No fork.

### Credential types as first-class extensible objects

Credential types move from enum-matching to nominal class identity. The SDK ships common types:

```python
# clusterfactory_sdk/credentials.py
@dataclass(frozen=True)
class Credential:
    producer: str
    consumer: str
    value: dict
    kind: str = field(init=False)
    sha: str = field(init=False)

    def __post_init__(self):
        object.__setattr__(self, "kind", self.__class__.__name__)
        object.__setattr__(self, "sha", sha256_of(json.dumps(self.value, sort_keys=True)))

@dataclass(frozen=True)
class ApiToken(Credential): ...

@dataclass(frozen=True)
class UserPass(Credential): ...

@dataclass(frozen=True)
class DockerRegistryCredential(Credential): ...

@dataclass(frozen=True)
class OIDCClientCredential(Credential): ...

@dataclass(frozen=True)
class VaultAppRole(Credential): ...

@dataclass(frozen=True)
class SSHKeypair(Credential): ...

@dataclass(frozen=True)
class MTLSCertificate(Credential): ...
```

Third parties subclass `Credential` in their own package and register via entry point. The planner matches on class identity. A component declares it produces `DockerRegistryCredential` and the planner validates that — not a string match.

The SDK ships the common types because they are what the majority of components will use. That keeps the type space from exploding: a Harbor component produces `DockerRegistryCredential`, and so does a Docker Hub component, and so does a GCR component. They are interchangeable at the type level, which is the point.

### Component config as declared schema

Today: the resolver knows each component's env vars.
Target: each component declares its own config schema, the engine validates the spec against the schema, and the component receives a validated config object.

```python
# clusterfactory_component_harbor/__init__.py
from pydantic import BaseModel
from clusterfactory_sdk import Component, DockerRegistryCredential, RobotAccount

class HarborConfig(BaseModel):
    service: str
    port: int = 80
    admin_user: str
    admin_pass_secret_ref: str   # Kubernetes secret name
    project: str = "library"
    robot_lifetime_days: int = 90

class HarborComponent(Component):
    ConfigModel = HarborConfig

    def produces(self):
        return [DockerRegistryCredential, RobotAccount]

    def consumes(self):
        return []   # Harbor is a source

    def ready(self) -> bool:
        ...

    def extract(self, kind, for_consumer):
        if kind is DockerRegistryCredential:
            return self._mint_robot(for_consumer)
        raise UnsupportedCredential(kind)
```

The engine reads the platform spec, finds `kind: harbor`, loads the `HarborComponent` class via entry point, reads `ConfigModel`, validates the relevant block of the spec against it, and constructs the component with the validated config. Input validation and documentation become the same artifact. Security findings about injection in untyped config disappear.

### Platform spec as the declarative artifact

Today: wiring is implicit in bash templates or in `platform.yaml` with a schema that's mostly undocumented.

Target: a versioned, validated platform spec that is the input to the engine and the thing stored in git:

```yaml
apiVersion: clusterfactory.io/v1
kind: Platform
metadata:
  name: regulated-ci
  version: "2.4.1"        # platform author's own versioning

spec:
  components:
    - name: gitea
      kind: gitea            # resolved via entry point
      version: "1.23.6"
      config:
        service: cf-gitea-http
        admin_user: gitea-admin
        admin_pass_secret_ref: clusterfactory-gitea-admin

    - name: harbor
      kind: harbor
      version: "2.11.0"
      config:
        service: cf-harbor-core
        admin_pass_secret_ref: clusterfactory-harbor-admin

    - name: vault
      kind: openbao
      version: "2.0.0"
      config:
        service: cf-openbao

    - name: jenkins
      kind: jenkins
      version: "2.541.3"
      config:
        service: cf-jenkins
        admin_pass_secret_ref: cf-jenkins

  wiring:
    - from: gitea
      to: jenkins
      credential: ApiToken

    - from: harbor
      to: jenkins
      credential: DockerRegistryCredential

    - from: harbor
      to: gitea
      credential: DockerRegistryCredential

    - from: vault
      to: jenkins
      credential: VaultAppRole
```

This file is hashed into the structural SHA (see next section). It is the unit of reproducibility. Two clusters fed the same spec + the same SDK + engine + component versions must produce identical platform behavior.

### Structural SHA: covering the whole platform, not just credentials

Today's `hasher.py` hashes the set of produced credentials. That proves wiring *executed*. It does not prove wiring was reproducible — two different Gitea admin passwords would produce two different credential values and two different SHAs, even though the platform shape is identical.

Target: a three-level hash that models what immutability actually means.

```
PlatformHash = sha256 of:
  ├─ SpecHash      (the platform YAML, canonicalized)
  ├─ InputsHash    (SDK version, engine version, component pkg versions, image digests)
  └─ TopologyHash  (the credential graph: edges only, not credential values)
```

Why three levels:

- **SpecHash** answers "was the declared platform the same?" Stable across runs. Changes when someone edits the YAML.
- **InputsHash** answers "was the tooling the same?" Stable across runs. Changes when you bump the SDK, upgrade a component package, or re-pin an image digest.
- **TopologyHash** answers "did the wiring produce the same graph?" Stable across runs even with different credential *values* (because it hashes only which edges produced which credential types, not the secret material). This is the one that proves two airgapped installs converged on the same structure.

The full `PlatformHash` changes if and only if the declared platform, the tooling, or the produced topology changes. Credential values — which are inherently secret and per-install — don't pollute it.

Pseudocode:

```python
def compute_platform_hash(spec, inputs, topology):
    spec_hash = sha256(canonical_yaml(spec))
    inputs_hash = sha256(canonical_json({
        "sdk_version": inputs.sdk_version,
        "engine_version": inputs.engine_version,
        "components": sorted(
            {"name": c.name, "version": c.version, "digest": c.image_digest}
            for c in inputs.components
        ),
    }))
    topology_hash = sha256(canonical_json(sorted(
        {"from": e.source, "to": e.target, "credential": e.credential_type.__name__}
        for e in topology.edges
    )))
    return sha256(spec_hash + inputs_hash + topology_hash)
```

The bundle manifest records all three component hashes alongside the full `PlatformHash`. A security reviewer can check each independently.

### The bundle as signed, verifiable distribution unit

The current `hack/bundle.sh` produces a tarball with a chart, images, and a load script. That's most of the way to what's needed. The upgrade:

```
clusterfactory-bundle-<platform-name>-<version>.tar.gz
├── MANIFEST.yaml              # platform hash + component hashes + provenance
├── MANIFEST.yaml.sig          # cosign signature over MANIFEST
├── spec/
│   └── platform.yaml          # the declarative spec
├── charts/
│   └── clusterfactory-*.tgz   # the Helm chart
├── components/
│   ├── clusterfactory-sdk-*.whl
│   ├── clusterfactory-engine-*.whl
│   └── clusterfactory-component-*.whl  # one per enabled component
├── images/
│   ├── images.tar             # docker save of all images
│   └── images.txt             # image:tag@sha256:... list
├── sbom/
│   ├── bundle.spdx.json       # SBOM for the whole bundle
│   └── <image>.spdx.json      # SBOM per image
├── scans/
│   └── <image>.trivy.json     # Trivy scan per image at bundle time
└── load.sh                    # the same loader, plus verify step
```

`MANIFEST.yaml` contains:

```yaml
apiVersion: clusterfactory.io/v1
kind: BundleManifest
platform:
  name: regulated-ci
  version: "2.4.1"
hashes:
  platform: "sha256:..."
  spec: "sha256:..."
  inputs: "sha256:..."
  topology: "sha256:..."
builtAt: "2026-04-24T10:30:00Z"
builtBy: "github.com/yourorg/clusterfactory-bundles@abc123"
sdk: { version: "1.2.0", digest: "sha256:..." }
engine: { version: "1.2.0", digest: "sha256:..." }
components:
  - name: gitea
    package: "clusterfactory-component-gitea"
    version: "0.4.1"
    digest: "sha256:..."
    image: "gitea/gitea"
    imageDigest: "sha256:..."
  - name: harbor
    ...
signatures:
  cosign: "MANIFEST.yaml.sig"
  publicKey: "https://.../cosign.pub"
```

The airgapped install side runs, before anything else:

```bash
./load.sh verify     # verifies cosign sig, recomputes hashes, checks match
./load.sh install    # only runs if verify passed
```

Now the immutability claim is mechanically checkable. The security team on the receiving side does not trust your promises; they verify the manifest.

### Component conformance test suite

The SDK ships a pytest base class every component author inherits:

```python
# clusterfactory_sdk/testing.py
class ComponentContractTests:
    component_class: type[Component]
    test_config: dict

    def test_implements_required_methods(self):
        assert issubclass(self.component_class, Component)

    def test_produces_and_consumes_are_credential_subclasses(self):
        c = self._instantiate()
        for t in c.produces() + c.consumes():
            assert issubclass(t, Credential)

    def test_extract_returns_declared_type(self):
        c = self._instantiate()
        for kind in c.produces():
            result = c.extract(kind, for_consumer="test")
            assert isinstance(result, kind)

    def test_extract_is_idempotent(self):
        c = self._instantiate()
        for kind in c.produces():
            a = c.extract(kind, for_consumer="test")
            b = c.extract(kind, for_consumer="test")
            assert a.sha == b.sha, "extract must be idempotent"

    def test_inject_accepts_declared_types(self):
        ...

    def test_inject_is_idempotent(self):
        ...

    def test_verify_returns_true_after_inject(self):
        ...

    def test_ready_eventually_returns_or_raises_timeout(self):
        ...
```

A Harbor author writes:

```python
class TestHarborContract(ComponentContractTests):
    component_class = HarborComponent
    test_config = {...}
```

And gets thirty+ contract tests for free. If those pass against a real Harbor instance (in the author's own CI), the component is compliant. "Compliant" is now executable, not prose.

---

## The refactor, stepwise

Each step is independently mergeable, independently testable, and leaves the project in a working state. No big-bang rewrite.

### Step 1: Extract the SDK (week 1)

- Create a new Python package `clusterfactory-sdk` under `/sdk/` in the monorepo (or as a sibling repo; see decision below).
- Move `factory/components/base.py` → `clusterfactory_sdk/component.py`.
- Move `factory/model/credential.py` → `clusterfactory_sdk/credential.py`.
- Move `factory/credentials/types.py` → `clusterfactory_sdk/credentials/__init__.py`.
- Add common credential types that should have been there: `DockerRegistryCredential`, `OIDCClientCredential`, `VaultAppRole`, `SSHKeypair`, `MTLSCertificate`.
- Write the conformance test base class.
- Write an SDK README with a "implement your first component in 50 lines" tutorial.
- Publish `clusterfactory-sdk==1.0.0a1` to TestPyPI.

**Exit criterion:** the existing `factory/components/gitea.py` and `factory/components/jenkins.py`, with only import-path changes, pass the new conformance test suite.

**Monorepo vs split-repo decision:** keep the SDK in the main repo under `/sdk/` for now. Publish from the same repo with a separate PyPI package name. Splitting into its own repo adds coordination cost and isn't necessary until there are external contributors. Revisit at v1.0 GA.

### Step 2: Entry-point discovery in the resolver (week 1)

- Rewrite `factory/engine/resolver.py` to discover components via `importlib.metadata.entry_points(group="clusterfactory.components")`.
- Add first-party components as entry points in the monorepo's `pyproject.toml` so nothing changes for users.
- Delete the hardcoded `component_map` and `_import_*` methods.
- Delete the per-component config `if/elif` — config comes from the platform spec now.

**Exit criterion:** `pip install clusterfactory-component-gitea` (even if that package is just a wheel built from the same repo) is a no-op in terms of functionality, but verifies the entry-point mechanism works.

### Step 3: Credential type extensibility (week 1)

- Rewrite `factory/engine/planner.py` to match credential types by class identity, not by string map.
- Change the platform spec's `credential:` field from a string like `"api-token"` to a class name like `"ApiToken"`, resolved via entry point if not in the SDK built-ins.
- Deprecate the old string mapping with a warning for one release, then remove.

**Exit criterion:** a third-party component that defines its own `Credential` subclass can produce and consume it without any core code change.

### Step 4: Platform spec v1 with schema validation (week 2)

- Formalize the platform spec as shown above (`apiVersion: clusterfactory.io/v1`, `kind: Platform`).
- Publish a JSON Schema for the spec.
- Validate incoming specs against the schema before the engine starts.
- Each component's `ConfigModel` (pydantic) validates its own config block.
- Move input-sanitization-heavy fields (org names, repo names) into the schema; this closes several of the bash-injection findings from the earlier security review without changing runtime code.

**Exit criterion:** invalid platform spec fails with a precise, line-numbered error before any API call is made. Existing `platform.yaml` files migrate with a small converter.

### Step 5: Three-level platform hash (week 2)

- Extend `factory/engine/hasher.py` to compute `SpecHash`, `InputsHash`, `TopologyHash`, and combined `PlatformHash`.
- `PlatformResult` gains all four fields.
- The hash is emitted in logs at wire-job completion and written to a Kubernetes ConfigMap or Secret as the canonical record.
- Document the three-level model in a new `docs/reproducibility.md`.

**Exit criterion:** two runs of the same spec against two fresh clusters produce identical `SpecHash`, `InputsHash`, `TopologyHash`. Credential values differ; PlatformHash matches.

### Step 6: Bundle manifest and signing (week 3)

- Rewrite `hack/bundle.sh` to produce the structured bundle layout shown above.
- Generate `MANIFEST.yaml` with all hashes, component inventory, image digests, SBOMs, scan reports.
- Sign `MANIFEST.yaml` with `cosign sign-blob`; publish the public key.
- Generate SBOMs with Syft, vuln scans with Trivy, per image.
- Extend `load.sh` with a `verify` subcommand that: checks cosign signature, recomputes hashes from the bundle contents, refuses to install on mismatch.

**Exit criterion:** an airgapped install can be blocked mid-flight by tampering with any single file in the bundle.

### Step 7: Add Harbor as the third component (week 3–4)

This is the load-bearing step. It is what proves the pattern generalizes. It is the one that, if it fails, tells you the SDK has a design flaw and needs rework before v1.0.

- Create `clusterfactory-component-harbor` as a separate pip package (but still in the monorepo initially).
- Implement `HarborComponent` against the SDK.
- Produces `DockerRegistryCredential` (robot account).
- Wire it into the reference platform spec: Harbor → Jenkins (for image push from CI), Harbor → Gitea (for image push from Actions workflows).
- Pass the conformance test suite.
- Add a Harbor section to the airgap bundle build.

**Exit criterion:** a platform spec with `gitea + jenkins + harbor` installs end-to-end, airgapped, and produces a stable `PlatformHash` across two clean installs.

**Failure criterion (what you want to discover here):** if implementing Harbor requires editing SDK internals — e.g. the `Component` ABC needs a new method, or the `Credential` base class needs a new field — that is a design flaw in the SDK that is much cheaper to fix now than after external authors start writing components. Treat any SDK change forced by the Harbor integration as a blocker for v1.0 GA.

### Step 8: Add OpenBao to stress-test the pattern (week 4)

- `clusterfactory-component-openbao`, producing `VaultAppRole`, consuming nothing.
- Wire to Jenkins (Vault plugin) and to Gitea Actions (environment injection via a runner sidecar).
- Confirms the pattern covers secret-management components, not just source-code and CI components.

**Exit criterion:** `gitea + jenkins + harbor + openbao` spec installs and produces a stable `PlatformHash`. No SDK changes required.

### Step 9: Externalize components from the wire image (week 5)

Today the wire image bakes components in at build time. Target: the wire image is a thin runtime that loads components from pip wheels bundled into the airgap tarball.

Two viable approaches, pick one:

**9a. Composite image per platform.** At bundle time, `hack/bundle.sh` builds a custom wire image `FROM clusterfactory-wire-base:X.Y.Z` with `pip install` of the component wheels baked in. The airgap bundle includes the composite image in `images.tar`. Simpler, less flexible.

**9b. Sidecar wheels + runtime install.** The wire image ships as a base runtime. Component wheels are mounted via a ConfigMap or emptyDir init-container that copies them from the bundle. The wire container `pip install`s from the local directory at startup. More flexible, slower startup, more moving parts.

I recommend 9a for v1.0 — simplicity wins — with 9b as a v1.1 option for environments that need per-platform customization without a rebuild.

**Exit criterion:** adding a component to a platform is a values.yaml/spec change plus a rebundle, not a core rebuild.

### Step 10: v1.0 release (week 6)

- Pin the SDK API. Semver commitment: breaking changes require a major bump.
- Publish `clusterfactory-sdk 1.0.0` to real PyPI.
- Publish `clusterfactory-engine 1.0.0`, `clusterfactory-cli 1.0.0`.
- Publish first-party components at 1.0.0.
- README rewrite (see next section).
- Blog post / announcement with the "three new components in a weekend" demo.

---

## What the new README says

The current README leads with "a Helm chart that bootstraps Gitea + Jenkins." That's a fair description of v0.x. It's the wrong description of v1.0.

Target lede:

> **clusterfactory is an SDK and runtime for wiring multi-service platforms into Kubernetes clusters — connected or airgapped — with cryptographically verifiable reproducibility.**
>
> You declare a platform (Gitea + Harbor + Vault + Jenkins, or your own combination) in YAML. Components are pip-installable plugins implementing a small contract. The engine resolves a credential-dependency graph, wires services in topological order, and emits a structural hash that proves the installed platform matches the declared one.
>
> The airgap bundle is a signed tarball containing the chart, images, SBOMs, vulnerability scans, component wheels, and a manifest covering all hashes. An airgapped cluster verifies the bundle offline before installing — if any byte of the bundle has changed, install refuses.
>
> Use it to: ship regulated labs, build platform products, stand up reproducible CI/CD in sovereign clouds, or steal the pattern for your own internal platform.

Reference implementations shipped in the main repo: Gitea, Jenkins, Harbor, OpenBao, Gitea Actions Runner. The SDK is documented as the primary interface.

---

## What this refactor buys

**For the project's positioning:** it becomes defensible. "A helm chart that wires two apps together" is forkable in an afternoon. "A versioned SDK for pluggable platform components with a signed-bundle airgap distribution model and verifiable reproducibility hashes" is a multi-quarter commitment that has a community around it. The second one is the thing to own.

**For security teams:** everything they want is mechanical. SBOMs in the bundle. Cosign signatures over the manifest. Structural hashes that prove what was delivered. Entry-point-based plugin discovery means they can audit exactly which components are installed and pin them. Per-component pydantic config schemas close input-validation gaps that today require prose review.

**For third parties:** onboarding is `pip install clusterfactory-sdk`, implement five methods, write a pyproject entry point, run the conformance suite. The current bar is "fork the repo and hope the maintainers merge your PR." The new bar is "publish your own package on your own schedule." These are not comparable.

**For the core team:** the maintenance surface shrinks. Instead of owning every component, you own the SDK contract and the engine. Components become a distributed problem. This is the same shift Kubernetes made with CRDs and operators, Pytest made with plugins, and Django made with apps. Every one of those ecosystems grew faster after the shift than before.

**For the airgap claim specifically:** this is the thing that makes "immutable infrastructure into airgap" a precise technical claim rather than a marketing line. The three-level hash plus the signed manifest plus the conformance suite means you can say: *given this bundle and this public key, any cluster that successfully installs will produce this PlatformHash, and if it doesn't, it refused to install.* That is a sentence a compliance auditor can act on.

---

## Risks and what to watch for

**The Component ABC might not survive Harbor.** The test of whether this design is right is Step 7. If Harbor's robot-account minting needs a method the ABC doesn't have — say, a `rotate()` hook, or a `describe_expiry()` method — that's fine, add it, but it has to land *before* v1.0 pins the contract. Do not ship v1.0 until at least three components (Gitea, Jenkins, Harbor) are stable on the contract, because two-component abstractions are the most dangerous kind.

**The "three-level hash" might be over-engineered for v1.0.** If the distinction between SpecHash and InputsHash feels like noise to users, collapse them into a single `PlatformHash` for v1.0 and reintroduce the breakdown in v1.1. What matters for the immutability claim is that *some* deterministic hash exists and is signed. The three-level breakdown is a nice-to-have for auditors, not a requirement.

**Runtime plugin loading introduces supply chain surface.** The entry-point mechanism means the wire job `pip install`s component packages. That's a new supply chain dependency. Mitigation: in the airgap bundle, components are wheels from the bundle directory (not PyPI), and the bundle manifest records their digests. In the non-airgap install, components are pre-installed in the wire image at build time (approach 9a), so PyPI is not hit at runtime. Document this clearly.

**Third-party component quality is unmanaged.** Once anyone can publish `clusterfactory-component-*`, some of them will be low quality, broken, or malicious. This is true of every plugin ecosystem. Mitigation: a formal "verified components" list maintained by the core team, with a small review process; pass/fail status from the public conformance suite is a prerequisite. Badge verified components. Don't gate community components behind review — gate the "verified" badge.

**The bundle size grows.** Adding Harbor (~500MB image), OpenBao (~300MB), SBOMs, scan reports, component wheels — a full platform bundle starts looking like 2-3GB. That's fine for disk but unpleasant for transfer. Mitigation: support per-component bundle slices so users who want only Gitea+Jenkins get a smaller bundle; treat the full-platform bundle as one build target among many.

**Scope creep on "what is a Component."** Someone will want to make a Postgres Component, a Kafka Component, an S3 Component. Those services don't have the same "admin-bootstrapped credential minting" shape. The SDK should be clear that Component is for services that mint and consume credentials over their own APIs. For databases and object stores, the right integration is usually through Vault or a similar secret-minting middleware, with the database as a downstream consumer. Don't contort the ABC to cover data plane services.

---

## Open questions for the team

1. **Monorepo vs multi-repo split.** I recommend monorepo for now, split at v1.0 GA if external contribution volume warrants it. Alternative view: split immediately, because the SDK's stability guarantees differ from the engine's.

2. **Python as the only SDK language.** Every component today is Python. Is that a permanent choice, or does the plugin contract eventually need to support components written in Go (reached via a subprocess or gRPC)? This matters because Go is the native language of the Kubernetes ecosystem and component authors will ask.

3. **The bash wire engine.** Keep it, retire it, or maintain as a minimal-dependency fallback? It's ~200 lines and works without the Python runtime. Argument for keeping: it's the path of least resistance for very small deployments. Argument against: maintaining two engines drifts. I lean toward retiring it in v1.0 but the team should decide explicitly.

4. **Who signs the bundles.** `cosign` needs a key or keyless OIDC. Project key (one key, maintainers rotate)? GitHub OIDC keyless (ties signatures to the build workflow)? Both? This decision affects how the airgap receiver validates — keyless requires embedding a trust policy.

5. **Whether to treat v1.0 as a marketing moment.** If the pattern framing is right, v1.0 warrants a blog post, a talk proposal to KubeCon or PlatformCon, and a conscious outreach to the platform-engineering community. Or it can ship quietly and accrete users over time. The former is higher variance; the latter is lower risk.

---

## Appendix: a complete minimal third-party component

For concreteness, here is what a community member would write end to end to ship a component for, say, a toy "EchoService" that mints API tokens for anyone who asks. In a separate repo:

**`pyproject.toml`**

```toml
[project]
name = "clusterfactory-component-echo"
version = "0.1.0"
description = "Echo service component for clusterfactory"
dependencies = ["clusterfactory-sdk>=1.0,<2.0"]

[project.entry-points."clusterfactory.components"]
echo = "cf_echo:EchoComponent"
```

**`cf_echo/__init__.py`**

```python
from pydantic import BaseModel
from clusterfactory_sdk import Component, ApiToken, Credential
import requests

class EchoConfig(BaseModel):
    service: str
    port: int = 8080

class EchoComponent(Component):
    ConfigModel = EchoConfig

    def __init__(self, artifact, config: EchoConfig):
        super().__init__(artifact, config)

    @property
    def url(self) -> str:
        return f"http://{self.config.service}:{self.config.port}"

    def ready(self) -> bool:
        for _ in range(60):
            try:
                if requests.get(self.url, timeout=3).status_code == 200:
                    return True
            except requests.RequestException:
                pass
            time.sleep(5)
        raise TimeoutError(f"Echo not ready at {self.url}")

    def produces(self): return [ApiToken]
    def consumes(self): return []

    def extract(self, kind, for_consumer: str) -> Credential:
        assert kind is ApiToken
        resp = requests.post(
            f"{self.url}/mint",
            json={"consumer": for_consumer},
            timeout=10,
        )
        resp.raise_for_status()
        return ApiToken(
            producer=self.name,
            consumer=for_consumer,
            value={"token": resp.json()["token"]},
        )

    def inject(self, credential: Credential) -> None:
        raise NotImplementedError("Echo is source-only")

    def verify(self, credential: Credential) -> bool:
        return True
```

**`tests/test_contract.py`**

```python
from clusterfactory_sdk.testing import ComponentContractTests
from cf_echo import EchoComponent

class TestEchoContract(ComponentContractTests):
    component_class = EchoComponent
    test_config = {"service": "echo", "port": 8080}
```

**Publish:**

```bash
python -m build
twine upload dist/*
```

**Use:**

```yaml
spec:
  components:
    - name: echo
      kind: echo
      config:
        service: my-echo-svc
        port: 8080
  wiring:
    - from: echo
      to: jenkins
      credential: ApiToken
```

That is the end-to-end onboarding story. Fewer than a hundred lines. No fork of clusterfactory. That is what the refactor delivers, and it is what makes every other claim in this document — immutable infra, airgap reproducibility, growing pattern value — mechanically true instead of aspirational.