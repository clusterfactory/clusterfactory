# v0.3 Greenfield: Zarf + Gitea + Jenkins Demo

**Status:** Implementation plan, greenfield on branch `v0.3`
**Target:** A working demo that packages Gitea (git server) + Jenkins (workflow engine) as a Zarf package, deploys it airgapped, and auto-wires them via a Python wire engine.
**Scope:** Demo only. One mode: Gitea-as-git, Jenkins-as-workflow-engine. No Gitea Actions. No multiple flavors. No Harbor. No OpenBao. Those come later.
**Effort:** One focused week to a working demo, one more week to polish.

---

## Why this scope, why this shape

The v0.3 greenfield is a deliberate reset. The previous repo had three modes, two wire engines, a homegrown bundle pipeline, and seven historical refactor docs. We're replacing all of it with one mode, one engine, one packaging tool (Zarf), and one plan.

The demo answers exactly one question: *can we install Gitea + Jenkins on an airgapped cluster with one command, have them be automatically wired so a push to Gitea triggers a Jenkins build, and produce a structural hash proving the wiring happened as declared?*

If yes, we have a working foundation and the SDK/Harbor/v1.0 story has a real reference implementation to grow from. If no, the plan was wrong and we stop before spending a month on something that doesn't compose.

Everything in this document is in service of that one question.

---

## What we're building, in plain terms

One command on a connected machine:
```
zarf package create .
```
produces a signed `tar.zst` with everything needed.

Transfer the tarball to an airgapped cluster. One command there:
```
zarf package deploy clusterfactory-ci-0.3.0.tar.zst \
  --key cosign.pub \
  --set GITEA_ADMIN_PASSWORD=<secret>
```
does:

1. Verify the cosign signature over the bundle.
2. Bootstrap an in-cluster container registry (Zarf's init package, idempotent).
3. Push the bundled images into the registry.
4. `helm install` Gitea.
5. `helm install` Jenkins.
6. Apply clusterfactory's own manifests (wire Job, RBAC, NetworkPolicies).
7. Wait for the wire Job to complete.
8. Surface the structural SHA in Zarf's deploy output.

After it completes:
- Gitea is running, admin password set, a `cf-demo/hello-world` repo exists with a `Jenkinsfile` committed to it.
- Jenkins is running, admin password known, a pipeline job `cf-demo-hello-world` points at the Gitea repo, a `gitea-userpass` credential is stored so the job can clone.
- Pushing to `cf-demo/hello-world` triggers the Jenkins job. It clones, runs, passes.
- `kubectl get cm -n cicd cf-wire-result -o yaml` shows a structural SHA.

That's the demo. Everything else is plumbing.

---

## Repository layout

On a new branch `v0.3` off the current main. The old tree stays intact until we tag v0.3.0 and move it to `legacy/`.

```
clusterfactory/                             # root of the v0.3 branch
├── README.md                               # short, honest, four paragraphs
├── LICENSE                                 # copy from main
├── SECURITY.md                             # updated from main
├── zarf.yaml                               # the Zarf package definition
├── cosign.pub                              # for verify on deploy (pub key committed)
│
├── platform.yaml                           # the wiring graph, read by the engine
│
├── manifests/                              # standalone K8s manifests, no Helm templating
│   ├── wire-rbac.yaml
│   ├── wire-job.yaml
│   ├── platform-configmap.yaml
│   ├── gitea-admin-secret.yaml
│   └── networkpolicy.yaml
│
├── values/                                 # upstream Helm chart values
│   ├── gitea.yaml
│   └── jenkins.yaml
│
├── files/                                  # bootstrap artifacts pushed into Gitea
│   └── Jenkinsfile
│
├── engine/                                 # the Python wire runtime
│   ├── pyproject.toml
│   ├── Dockerfile
│   ├── requirements.txt
│   └── src/
│       └── clusterfactory_engine/
│           ├── __init__.py
│           ├── __main__.py                 # CLI entry: `python -m clusterfactory_engine`
│           ├── component.py                # Component ABC (will become SDK in v0.4)
│           ├── credential.py               # Credential dataclass + common types
│           ├── resolver.py                 # entry-point discovery stub (single map for v0.3)
│           ├── planner.py                  # build DAG from platform.yaml wiring
│           ├── executor.py                 # topological run of edges
│           ├── verifier.py                 # confirm wires hold post-inject
│           ├── hasher.py                   # structural SHA
│           └── components/
│               ├── gitea.py                # first-party Gitea component
│               └── jenkins.py              # first-party Jenkins component
│
├── tests/                                  # pytest, runs against live services
│   ├── unit/
│   │   ├── test_planner.py
│   │   ├── test_hasher.py
│   │   └── test_credential.py
│   └── e2e/
│       └── test_airgap_install.sh          # bash, runs full Zarf + verify + assert
│
├── Makefile                                # targets listed below
│
└── .github/workflows/
    ├── test.yaml                           # pytest + helm lint
    ├── build-wire-image.yaml               # build + cosign-sign the wire image
    └── release.yaml                        # zarf package create on tag, attach to release
```

The things conspicuously absent from this tree compared to the old one: no `Chart.yaml`, no `charts/`, no `templates/` (Helm templating is gone; we use Zarf flavors + upstream subchart values), no `hack/` (Zarf does what those scripts did), no `docs/` with seven nested refactor essays. Four top-level docs in the root, max: README, SECURITY, LICENSE, and this plan.

---

## The `zarf.yaml`

The central file. Written for the demo scope — one flavor, two services, one wire component.

```yaml
kind: ZarfPackageConfig
metadata:
  name: clusterfactory-ci
  version: "0.3.0"
  description: "Airgap CI demo: Gitea (git) + Jenkins (workflow), auto-wired."
  url: https://github.com/clusterfactory/clusterfactory
  architecture: amd64

variables:
  - name: GITEA_ADMIN_PASSWORD
    description: "Gitea admin password (required, prompted if not set)."
    prompt: true
    sensitive: true

components:
  # ─────────────────────────────────────────────────────────────
  # NetworkPolicies — apply first so nothing talks before we allow it
  # ─────────────────────────────────────────────────────────────
  - name: netpol
    required: true
    description: "Default-deny ingress except wire→{gitea,jenkins} and runners."
    manifests:
      - name: networkpolicy
        namespace: cicd
        files:
          - manifests/networkpolicy.yaml

  # ─────────────────────────────────────────────────────────────
  # Gitea admin Secret — applied before Gitea's chart reads it
  # ─────────────────────────────────────────────────────────────
  - name: gitea-secret
    required: true
    description: "Pre-create the admin Secret Gitea will use."
    manifests:
      - name: gitea-admin
        namespace: cicd
        files:
          - manifests/gitea-admin-secret.yaml

  # ─────────────────────────────────────────────────────────────
  # Gitea — upstream chart, vanilla, SQLite-backed, single replica
  # ─────────────────────────────────────────────────────────────
  - name: gitea
    required: true
    description: "Gitea 1.23.6 as a git server (Actions disabled for the demo)."
    charts:
      - name: gitea
        url: https://dl.gitea.com/charts/
        version: 11.0.1
        namespace: cicd
        releaseName: cf-gitea
        valuesFiles:
          - values/gitea.yaml
    images:
      - gitea/gitea:1.23.6

  # ─────────────────────────────────────────────────────────────
  # Jenkins — upstream chart, vanilla, minimal plugin set
  # ─────────────────────────────────────────────────────────────
  - name: jenkins
    required: true
    description: "Jenkins 2.541.3 LTS as workflow engine."
    charts:
      - name: jenkins
        url: https://charts.jenkins.io
        version: 5.9.9
        namespace: cicd
        releaseName: cf-jenkins
        valuesFiles:
          - values/jenkins.yaml
    images:
      - jenkins/jenkins:2.541.3-jdk21
      - kiwigrid/k8s-sidecar:2.5.0

  # ─────────────────────────────────────────────────────────────
  # Platform spec ConfigMap — what the wire engine reads
  # ─────────────────────────────────────────────────────────────
  - name: platform-spec
    required: true
    description: "Platform spec: components + wiring graph for the engine."
    manifests:
      - name: platform-configmap
        namespace: cicd
        files:
          - manifests/platform-configmap.yaml

  # ─────────────────────────────────────────────────────────────
  # Wire engine — our custom code, the only non-upstream image
  # ─────────────────────────────────────────────────────────────
  - name: wire
    required: true
    description: "Credential wiring: Gitea → Jenkins."
    manifests:
      - name: wire-rbac
        namespace: cicd
        files:
          - manifests/wire-rbac.yaml
      - name: wire-job
        namespace: cicd
        files:
          - manifests/wire-job.yaml
    images:
      - ghcr.io/clusterfactory/clusterfactory-wire:0.3.0
    actions:
      onDeploy:
        after:
          - description: "Wait for wire Job to complete."
            cmd: |
              kubectl wait --for=condition=complete \
                --timeout=10m -n cicd job/cf-wire
            maxRetries: 0
          - description: "Read and report the structural SHA."
            cmd: |
              kubectl get cm -n cicd cf-wire-result \
                -o jsonpath='{.data.structural_sha}'
            setVariables:
              - name: STRUCTURAL_SHA
          - description: "Print post-install access instructions."
            cmd: |
              echo ""
              echo "────────────────────────────────────────────────"
              echo "  clusterfactory-ci is up."
              echo "  Structural SHA: $STRUCTURAL_SHA"
              echo ""
              echo "  Port-forward:"
              echo "    kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000"
              echo "    kubectl port-forward -n cicd svc/cf-jenkins 8080:8080"
              echo ""
              echo "  Credentials:"
              echo "    Gitea:   gitea-admin / <the password you set>"
              echo "    Jenkins: admin / \$(kubectl get secret cf-jenkins -n cicd \\"
              echo "              -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
              echo "────────────────────────────────────────────────"
```

Notes on specific choices:

**NetworkPolicies applied first, before any workload.** In most clusters without a default-deny this is inert; in clusters with it, this is what allows wire → Gitea and wire → Jenkins later. Ordering is via Zarf's component declaration order.

**Pre-create the Gitea admin Secret.** Gitea's chart reads an existing Secret rather than accepting a cleartext password via values. The old repo embedded the password in values via a Helm hook; we pre-apply the Secret with Zarf's manifests before the chart install runs.

**Platform spec as a ConfigMap.** The wire engine reads `platform.yaml` from a ConfigMap mounted at `/config/platform.yaml`. Same pattern as before, but the ConfigMap is a Zarf-managed manifest, not a Helm-templated one. Simpler, fewer moving parts.

**Wire image is the only custom image.** Everything else is an upstream vanilla image that Zarf pulls from its original registry at `zarf package create` time, bundles by digest, and pushes into the in-cluster registry on deploy. Only `ghcr.io/clusterfactory/clusterfactory-wire:0.3.0` is ours.

**`onDeploy.after` orchestrates post-install.** Three actions: wait for the Job, read the SHA, print access instructions. Everything a user needs to see after `zarf package deploy` returns.

---

## The `platform.yaml`

The file the wire engine consumes. Declarative, versioned, schema-validated, hashed.

```yaml
apiVersion: clusterfactory.io/v1
kind: Platform
metadata:
  name: cf-ci
  version: "0.3.0"

spec:
  components:
    - name: gitea
      kind: gitea
      config:
        service: cf-gitea-http.cicd.svc.cluster.local
        port: 3000
        admin_user: gitea-admin
        admin_pass_env: GITEA_PASS         # env var populated from Secret
        org: cf-demo
        repo: hello-world
        bootstrap_files:
          - path: Jenkinsfile
            source: /files/Jenkinsfile     # mounted from ConfigMap

    - name: jenkins
      kind: jenkins
      config:
        service: cf-jenkins.cicd.svc.cluster.local
        port: 8080
        admin_user: admin
        admin_pass_env: JENKINS_PASS
        pipeline_name: cf-demo-hello-world

  wiring:
    # Gitea mints an API token; Jenkins stores it as a credential for git clone.
    - from: gitea
      to: jenkins
      credential: UserPass
```

For the demo, one wiring edge is enough. The token Gitea mints goes into Jenkins as a `UserPass` credential (`gitea-userpass`) used for git clone. Later components add more edges; the engine's job stays the same.

This file is deliberately separate from `zarf.yaml`. Zarf doesn't read it; the engine does. The separation reflects the architectural seam — Zarf handles packaging and install; the engine handles wiring. Keeping the files apart prevents the temptation to cram wiring logic into Zarf actions (where it doesn't belong) or packaging logic into the engine (ditto).

---

## The wire engine, demo-scoped

Fresh Python, ported cleanly from the old `factory/` tree but without the dual-engine scaffolding or the hardcoded resolver. For v0.3, we stop short of full entry-point discovery — components are registered in a single module-level dict. That's a v0.4 deliberate step; don't pre-optimize.

### `engine/src/clusterfactory_engine/component.py`

```python
"""Component ABC — the contract every component implements."""
from abc import ABC, abstractmethod
from typing import Type
from .credential import Credential


class Component(ABC):
    """A wirable service: produces and/or consumes typed credentials."""

    def __init__(self, name: str, config: dict):
        self.name = name
        self.config = config

    @property
    @abstractmethod
    def url(self) -> str: ...

    @abstractmethod
    def ready(self) -> bool: ...

    @abstractmethod
    def produces(self) -> list[Type[Credential]]: ...

    @abstractmethod
    def consumes(self) -> list[Type[Credential]]: ...

    @abstractmethod
    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential: ...

    @abstractmethod
    def inject(self, credential: Credential) -> None: ...

    @abstractmethod
    def verify(self, credential: Credential) -> bool: ...
```

### `engine/src/clusterfactory_engine/credential.py`

```python
"""Credential base class and common types."""
from dataclasses import dataclass, field
import hashlib
import json


def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


@dataclass(frozen=True)
class Credential:
    """Typed secret produced by one component for another."""
    producer: str
    consumer: str
    value: dict
    sha: str = field(init=False)

    def __post_init__(self):
        object.__setattr__(
            self, "sha", _sha256(json.dumps(self.value, sort_keys=True))
        )

    @property
    def kind(self) -> str:
        return type(self).__name__


@dataclass(frozen=True)
class ApiToken(Credential): pass

@dataclass(frozen=True)
class UserPass(Credential): pass
```

Only two credential types in v0.3: `ApiToken` and `UserPass`. The Gitea component mints an `ApiToken`; the wiring converts it into a `UserPass` for Jenkins (so git clone works with `<user>:<token>`). Adding `DockerRegistryCredential`, `VaultAppRole`, `OIDCClientCredential` is a v0.4 task, right before Harbor.

### The resolver

A single dict for v0.3. Entry-point discovery is v0.4.

```python
# engine/src/clusterfactory_engine/resolver.py
from .components.gitea import GiteaComponent
from .components.jenkins import JenkinsComponent

COMPONENT_REGISTRY = {
    "gitea": GiteaComponent,
    "jenkins": JenkinsComponent,
}

def resolve(kind: str):
    if kind not in COMPONENT_REGISTRY:
        raise ValueError(f"Unknown component kind: {kind}")
    return COMPONENT_REGISTRY[kind]
```

Deliberately simple. Don't build entry-point discovery until we have a third component to discover. Build it in v0.4 when Harbor forces the issue.

### The planner, executor, verifier, hasher

Port cleanly from the old repo. Same algorithms, fresh Python. ~200 lines total.

The executor runs edges in topological order. For the demo, there's one edge (Gitea → Jenkins, UserPass), so topology is trivial, but the code handles arbitrary DAGs so adding Harbor is just a matter of declaring new edges.

The hasher stays scoped to credential SHAs:

```python
# engine/src/clusterfactory_engine/hasher.py
import json
from .credential import Credential
from .credential import _sha256


def structural_sha(credentials: list[Credential]) -> str:
    """Stable hash over the wiring result, independent of secret values."""
    if not credentials:
        return _sha256("")
    # Hash over (producer, consumer, kind) tuples, not credential values.
    # Two installs produce the same hash if they wired the same graph.
    topology = sorted(
        f"{c.producer}→{c.consumer}:{c.kind}" for c in credentials
    )
    return _sha256(json.dumps(topology))
```

Important change from the old hasher: we hash the *topology* (who produced what kind for whom), not the credential values. This is what makes the SHA stable across installs with different admin passwords. Two clusters fed the same `platform.yaml` produce the same structural SHA. That's the reproducibility claim.

### The Gitea and Jenkins components

Ported from `factory/components/gitea.py` and `factory/components/jenkins.py`. Read the old files for the edge cases — the 422/409 handling, the crumb + cookie pattern, the upsert-by-delete-then-create idempotency — and carry those over, but cleaner. Specifically:

**Fixed from the old repo:**
- All `requests` calls get an explicit timeout (security finding #6 from the old review).
- Error paths that previously logged the full API response now redact `sha1`/`token` fields.
- XML credential payloads for Jenkins are built with `xml.sax.saxutils.escape` rather than f-string interpolation (closes the XML-injection path).
- JSON payloads for Gitea are built with `json.dumps(...)` rather than f-string interpolation (closes the JSON-injection path).
- Config arrives as a validated pydantic model, not a raw dict.

The components' job in the demo:

**GiteaComponent:**
1. `ready()`: poll `GET /` until HTTP 200 or timeout.
2. `extract(ApiToken)`: delete any existing `jenkins-wiring` token, mint a new one with scopes `write:repository,write:user,write:organization`, return as `ApiToken`.
3. After extract, create the `cf-demo` org (idempotent) and the `cf-demo/hello-world` repo (idempotent).
4. Push the `Jenkinsfile` from the mounted `/files/` directory via the Contents API.

**JenkinsComponent:**
1. `ready()`: poll `GET /login` until HTTP 200.
2. `inject(UserPass)`: fetch CSRF crumb + session cookie, upsert a `UsernamePasswordCredentialsImpl` with id `gitea-userpass`.
3. After inject, create a pipeline job `cf-demo-hello-world` pointing at `http://cf-gitea-http:3000/cf-demo/hello-world.git`, using `gitea-userpass` for clone.

The wiring converts the `ApiToken` Gitea produces into a `UserPass` Jenkins consumes: user = `gitea-admin`, password = the token value. One line of logic in the executor.

### The `__main__.py`

```python
# engine/src/clusterfactory_engine/__main__.py
import argparse
import logging
import os
import sys
import yaml
from pathlib import Path

from .resolver import resolve
from .planner import build_graph
from .executor import Executor
from .verifier import verify_all
from .hasher import structural_sha
from . import credential as cred_module


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", default="/config/platform.yaml")
    ap.add_argument("--log-level", default="INFO")
    args = ap.parse_args()

    logging.basicConfig(
        level=args.log_level,
        format="[%(name)s] %(levelname)s %(message)s",
    )
    log = logging.getLogger("engine")

    spec = yaml.safe_load(Path(args.platform).read_text())

    # 1. Resolve components
    components = {}
    for c in spec["spec"]["components"]:
        cls = resolve(c["kind"])
        components[c["name"]] = cls(name=c["name"], config=c["config"])
    log.info(f"resolved {len(components)} components")

    # 2. Wait for all components to be ready
    for comp in components.values():
        comp.ready()

    # 3. Build wiring graph
    graph = build_graph(spec["spec"]["wiring"], components, cred_module)

    # 4. Execute in topological order
    executor = Executor(log)
    credentials = executor.run(graph)

    # 5. Verify all wires hold
    errors = verify_all(graph, credentials)
    if errors:
        log.error(f"verification failed: {errors}")
        sys.exit(1)

    # 6. Emit structural SHA
    sha = structural_sha(credentials)
    log.info(f"structural_sha: {sha}")

    # 7. Write result to ConfigMap via stdout convention
    # (The Job reads this log line and the wire-result ConfigMap is updated
    # via a kubectl sidecar, or we write directly via in-cluster API.)
    result_path = Path("/tmp/wire-result")
    result_path.write_text(f"structural_sha={sha}\n")


if __name__ == "__main__":
    main()
```

One simplification worth noting: the ConfigMap-writing step is a small in-cluster API call via the `kubernetes` Python client. The demo wire-job.yaml includes the RBAC permission to write this one ConfigMap (`cf-wire-result`), and the engine writes to it directly at the end. No sidecar needed.

### Dockerfile for the wire image

```dockerfile
# engine/Dockerfile
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/clusterfactory_engine/ ./clusterfactory_engine/

USER 10001
ENTRYPOINT ["tini", "--", "python", "-m", "clusterfactory_engine"]
```

Runs as non-root UID, uses `tini` for PID 1 signal handling, no shell entrypoint. The image is built once per release and signed:

```yaml
# .github/workflows/build-wire-image.yaml (excerpt)
- uses: docker/build-push-action@v5
  with:
    context: ./engine
    tags: ghcr.io/clusterfactory/clusterfactory-wire:0.3.0
    push: true
- uses: sigstore/cosign-installer@v3
- run: cosign sign --yes ghcr.io/clusterfactory/clusterfactory-wire:0.3.0
```

Keyless cosign via GitHub OIDC. No long-lived private keys. The signature is verifiable against the GitHub workflow identity, which is what Zarf's `--key cosign.pub` flow consumes in the airgap receiver.

---

## The manifests

Six short Kubernetes manifests, standalone, no Helm templating. Each is under 50 lines.

### `manifests/wire-rbac.yaml`

Service account + minimal Role. The engine needs `secrets` (read admin passwords, write runner token) and `configmaps` (write the wire-result). Namespace-scoped.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cf-wire
  namespace: cicd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cf-wire
  namespace: cicd
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["cf-wire-result"]
    verbs: ["get", "create", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create"]   # needed for initial creation; resourceNames doesn't cover create
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cf-wire
  namespace: cicd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cf-wire
subjects:
  - kind: ServiceAccount
    name: cf-wire
    namespace: cicd
```

Tighter than the old repo's runner RBAC, which had cluster-wide pod/job create permissions for Kaniko. We don't need those for the demo (no Actions runner, no Kaniko).

### `manifests/wire-job.yaml`

The Job that runs the engine. Mounts `/config/platform.yaml` from the platform-spec ConfigMap and `/files/Jenkinsfile` from a files ConfigMap.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cf-wire-files
  namespace: cicd
data:
  Jenkinsfile: |
    pipeline {
      agent any
      stages {
        stage('hello') {
          steps {
            sh 'echo hello from clusterfactory'
          }
        }
      }
    }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: cf-wire
  namespace: cicd
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wire
    spec:
      serviceAccountName: cf-wire
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: wire
          image: ghcr.io/clusterfactory/clusterfactory-wire:0.3.0
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: GITEA_PASS
              valueFrom:
                secretKeyRef:
                  name: clusterfactory-gitea-admin
                  key: password
            - name: JENKINS_PASS
              valueFrom:
                secretKeyRef:
                  name: cf-jenkins
                  key: jenkins-admin-password
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          volumeMounts:
            - { name: platform-spec, mountPath: /config, readOnly: true }
            - { name: files,         mountPath: /files,  readOnly: true }
            - { name: tmp,           mountPath: /tmp }
      volumes:
        - name: platform-spec
          configMap: { name: cf-platform-spec }
        - name: files
          configMap: { name: cf-wire-files }
        - name: tmp
          emptyDir: {}
```

### `manifests/platform-configmap.yaml`

The ConfigMap holding `platform.yaml`. The content is the file shown earlier.

### `manifests/gitea-admin-secret.yaml`

Pre-created Secret. The password is provided via Zarf variable substitution at `zarf package deploy` time:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: clusterfactory-gitea-admin
  namespace: cicd
type: Opaque
stringData:
  username: gitea-admin
  password: "###ZARF_VAR_GITEA_ADMIN_PASSWORD###"
```

Zarf substitutes `###ZARF_VAR_GITEA_ADMIN_PASSWORD###` from the `GITEA_ADMIN_PASSWORD` variable prompted at deploy time. The cleartext never appears in source; the rendered manifest lives only in memory and in the Kubernetes API at runtime.

### `manifests/networkpolicy.yaml`

Ingress-only NetworkPolicies for Gitea and Jenkins, allowing wire → each service. Same shape as the old repo's, ported without change.

### `values/gitea.yaml` and `values/jenkins.yaml`

Upstream chart values tuned for the demo. Critical settings:

**Gitea:**
- Actions disabled (`actions.ENABLED: "false"`) — we're doing Jenkins only.
- SQLite backend, memory cache, level queue, memory session — the "lean bootstrap" configuration from the old repo.
- `persistence.enabled: false` — emptyDir is fine for the demo.
- `ingress.enabled: false` — access via port-forward.
- `service.http.type: ClusterIP`.
- Admin credentials sourced from `clusterfactory-gitea-admin` Secret (which we pre-applied).

**Jenkins:**
- Minimal plugin set: `kubernetes`, `workflow-aggregator`, `git`, `configuration-as-code`, `plain-credentials`.
- `persistence.enabled: false`.
- `controller.ingress.enabled: false`.
- `controller.serviceType: ClusterIP`.
- `agent.enabled: false` — the demo pipeline runs on the controller.

Both files stay short (~30 lines each). Copy from the old repo's `values.yaml` subchart blocks, simplify.

---

## What ships vs. what stays hidden

For the demo, the user sees:
- `zarf.yaml` if they want to know what's in the bundle.
- `platform.yaml` if they want to know how the wiring works.
- The README.

What the user does not touch:
- The engine code.
- The manifests.
- The values files.

If they need to customize, they override via Zarf variables. If a variable doesn't exist for what they need, it's a feature gap and a future addition. The default install should work with `zarf package deploy` + `GITEA_ADMIN_PASSWORD`.

---

## Timeline

One focused week, five engineering days, to a working demo.

**Day 1: scaffolding.** New branch `v0.3`. Create the layout. Write `zarf.yaml` and `platform.yaml`. Stub manifests. Copy LICENSE, create a placeholder README. Get `zarf package create .` to succeed (even if the wire image doesn't exist yet — Zarf will fail at pull-time, which is the expected intermediate state).

**Day 2: wire engine, minimum viable.** Port Component, Credential, resolver (dict), planner, executor, verifier, hasher. Port GiteaComponent and JenkinsComponent, carrying over edge-case handling from the old `_wire-helpers.tpl` and `factory/components/*.py`. Fix the known security issues inline (explicit timeouts, XML escaping, JSON builders). Dockerfile. Local `make wire-image` target that builds and imports into k3d.

**Day 3: end-to-end on k3d, connected.** Stand up k3d. `zarf package create .`. `zarf package deploy <pkg>.tar.zst --set GITEA_ADMIN_PASSWORD=demo123`. Watch it fail the first time, fix whatever broke. Iterate until Gitea and Jenkins are up, wire Job runs green, the `cf-demo/hello-world` repo exists with the Jenkinsfile, the Jenkins job exists with the credential, and the structural SHA shows up in Zarf's output.

**Day 4: end-to-end on k3d, airgapped.** Disable k3d's outbound network (or use a second VM with firewall rules). Transfer the tarball via `scp` or USB emulation. `zarf package deploy` on the airgapped side with `--key cosign.pub` to exercise the verify path. Fix whatever issues surface — usually around image pull (Zarf's mutating webhook should handle this) or DNS (in-cluster services should work regardless).

**Day 5: GitHub Actions + polish.** Set up `build-wire-image.yaml` to publish + cosign-sign on tag. Set up `release.yaml` to `zarf package create` on tag and attach the tarball to the GitHub release. Write the README (four paragraphs; use the lede from the Zarf integration plan as a starting point). Tag `v0.3.0-rc1`.

**Exit criterion for the week:** someone with clone access, a k3d cluster, and Zarf installed can follow four README commands and end up with a working, wired, verified Gitea + Jenkins install. The structural SHA appears in the output. A push to `cf-demo/hello-world` triggers a Jenkins build.

**Second week (if needed):** Polish. Conformance test skeleton (not the full suite — that's v0.4). Documentation of the structural SHA claim with worked example. A short "how to write a component" doc aimed at v0.4 contributors, even though third-party components aren't formally supported yet. Tag `v0.3.0`.

---

## What the README says

Short. Four paragraphs, maybe five.

```markdown
# clusterfactory

**Airgap CI platform: Gitea (git) + Jenkins (workflow engine), auto-wired,
delivered as a Zarf package.**

Zarf handles supply chain: signed bundle, SBOMs, image transport, Helm
installs. clusterfactory handles what Zarf doesn't — cross-service credential
wiring. After Zarf installs Gitea and Jenkins, a small Python wire engine
mints an API token from Gitea, stores it in Jenkins as a credential, creates
a `cf-demo/hello-world` repo, commits a Jenkinsfile, and creates a matching
Jenkins pipeline. It emits a structural SHA proving the wiring graph
executed as declared.

## Demo

On a connected machine:
    zarf package create .

Transfer `clusterfactory-ci-0.3.0-amd64.tar.zst` to the airgapped cluster.
Then:
    zarf package deploy clusterfactory-ci-0.3.0-amd64.tar.zst \
        --key cosign.pub \
        --set GITEA_ADMIN_PASSWORD=<yourpassword>

At the end, Zarf prints the structural SHA and the port-forward commands.
Push to `cf-demo/hello-world` to trigger a build.

## Status

v0.3 is a demo. One deployment mode (Gitea as git, Jenkins as CI). Additional
components (Harbor, OpenBao) and third-party extensibility are planned for
v0.4+. See `zarf-integration-plan.md` and `v0.3-greenfield-demo.md` for the
roadmap.
```

Nothing more. The README is not the roadmap; the plan docs are. The README's job is to get someone to their first successful `zarf package deploy` as fast as possible.

---

## What v0.3 deliberately does not ship

Worth naming so we don't drift into scope creep mid-week.

**No Gitea Actions.** The old repo supported Gitea Actions as a separate mode with a DaemonSet runner. Skip it. Jenkins-only for the demo. If we need Actions later, it's a v0.4 addition.

**No mode selector.** The old `mode: gitea-actions | jenkins | both` selector is gone. One install does one thing.

**No Harbor, no OpenBao, no Keycloak.** Those are v0.4. They exist on the roadmap to prove the SDK generalizes, not to pad v0.3.

**No entry-point-based component discovery.** The resolver is a dict. Entry points come in v0.4 when Harbor forces the issue.

**No conformance test suite.** A single `test_gitea_and_jenkins_wire.py` e2e test is enough for v0.3. The formal `ComponentContractTests` pytest base class comes in v0.4.

**No migration helper from the old repo's installs.** v0.3 is a greenfield; anyone running the old chart stays on it or does a clean install of v0.3. Don't burn time writing a migration script that three users will ever run.

**No pydantic config validation.** The engine reads `platform.yaml` as a plain dict in v0.3. Config validation per component is v0.4 — cheap to add, but not on the demo's critical path.

**No multi-architecture builds.** amd64 only. arm64 is a follow-up.

Every one of these omissions is intentional. Each is also a trivial future addition — the architecture doesn't need to change to accommodate them.

---

## The v0.3 → v0.4 handoff

When v0.3 ships and the demo works, v0.4 is clear:

1. Extract `engine/src/clusterfactory_engine/component.py` + `credential.py` into a standalone `clusterfactory-sdk` pip package.
2. Rewrite the resolver to use `importlib.metadata.entry_points`.
3. Add per-component pydantic config validation.
4. Write the `ComponentContractTests` pytest base class.
5. Add `HarborComponent` as a separate pip package, prove it wires cleanly.

Five steps, each worth a couple of days. v0.4 lands four to six weeks after v0.3. That's the realistic path to something a third party could extend.

But v0.3 has to ship first, because v0.4 only makes sense if the demo works. And the demo only works if we keep v0.3's scope as ruthlessly narrow as the plan above suggests.

---

## The one-sentence summary

*Start a new branch, write a 120-line zarf.yaml, a 30-line platform.yaml, six short manifests, and port the Python engine cleanly from the old tree — run it end-to-end on airgapped k3d, and v0.3 is done.*

Everything else — SDK, Harbor, community, conformance — follows from that working demo. Without it, none of the rest lands. With it, the path forward is obvious.