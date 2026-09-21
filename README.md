# clusterfactory

**A transparent way to package a software forge for disconnected environments.**

One signed [Zarf](https://zarf.dev) package that stands up **Gitea** (git), **Jenkins**
(CI), **Nexus Repository CE** (container registry) — and optionally **Argo CD** — on any
Kubernetes cluster with no internet access, and wires them together so that a
push to a repo builds an image in-cluster and lands it in the registry.
Nothing in the package phones home; CI proves it on every change by deploying
into a cluster with all egress denied.

The repo layout and conventions are borrowed from Defense Unicorns'
[UDS packages](https://uds.defenseunicorns.com/structure/packages/) — the
people who have shipped this kind of thing into air-gapped environments for
years — without taking on UDS Core, Istio or the UDS operator. Every decision
is an [ADR](adr/README.md).

## What "transparent" means here

| Claim | How you can check it |
|---|---|
| **Unmodified upstream** | The package contains the upstream Helm charts and images of Gitea, Jenkins and Nexus, pinned by digest in [`zarf.yaml`](zarf.yaml). clusterfactory adds only values files, two tiny helper charts and one Python file. |
| **No custom application images** | The only images built here are a data-only image carrying the resolved Jenkins plugin closure ([`jenkins/`](jenkins/)) and the wire-engine image (`python:slim` + one stdlib script, [`wire-engine/`](wire-engine/)). Both are built at package-create time with content-addressed tags and exist only in a throwaway registry on the build machine. |
| **Wiring you can read** | All cross-service setup is a post-deploy Kubernetes Job running [`wire-engine/wire.py`](wire-engine/wire.py): check-then-act, one `[ok\|created\|updated]` line per step, exit 0 only when converged. A redeploy on a converged cluster prints only `ok`. No Helm hooks, no operators, no CRDs. |
| **The contract is executable** | The `preflight` component ([`preflight/preflight.sh`](preflight/preflight.sh)) runs first and refuses the deploy if the cluster cannot honour the package's guarantees: NetworkPolicy actually enforced (positive control, then deny-all), a default StorageClass that binds, PSA active, DNS, the Zarf registry, an API-server endpoint the egress policy can express. [`PREREQUISITES.md`](PREREQUISITES.md) is generated from it; results land in a ConfigMap. |
| **Airgap is enforced, not assumed** | [`charts/config`](charts/config) ships deny-all-egress NetworkPolicies (DNS, in-namespace and the API server only), Pod Security `restricted` on every namespace but one, and every update-checker/telemetry switch off. |
| **One declared exception** | Kaniko builds run as uid 0 in the `cf-build` namespace at PSA `baseline`. It is written down in [`docs/exemptions/kaniko.md`](docs/exemptions/kaniko.md) with scope, justification and a review date, UDS-style. |
| **Auditable artifacts** | Zarf signs the package (cosign, [`cosign.pub`](cosign.pub) in the repo and in every release) and generates an SBOM per image; CI scans every SBOM under [`.grype.yaml`](.grype.yaml): known-exploited (KEV) findings block anywhere, critical-with-fix blocks in images built here, the rest is reported. [`oscal-component.yaml`](oscal-component.yaml) maps what is actually enforced to NIST 800-53 and is schema-validated in CI. |
| **Tested on a physically air-gapped RKE2 host** | [`ci.yaml`](.github/workflows/ci.yaml): lint → create → a **Rocky 9 / SELinux-enforcing VM with no route to the internet** (artifacts arrive through a private bucket, control through an IAP tunnel): RKE2 installed from tarballs only, deploy the previous package, upgrade to this one, the full gate ([`tests/deploy-check.sh`](tests/deploy-check.sh)) with a real Kaniko build pushed to Nexus, idempotent redeploy, and a second RKE2 with flannel + no StorageClass that the preflight must refuse. No kind, nothing runs on a laptop (ADR 0014). |

## What you get

```
                    ┌──────────────────── clusterfactory namespace (PSA restricted) ───────────────────┐
  push ──────────▶  │  Gitea ──token──▶ Jenkins ──credential──▶ Nexus (docker-hosted, :5000)          │
                    │     ▲                 │                       ▲          ▲                         │
                    │     │ clone           │ pod agent             │ push     │ pre-seeded base image   │
                    └─────┼─────────────────┼───────────────────────┼──────────┼─────────────────────────┘
                          │        ┌────────▼──────── cf-build (PSA baseline) ─┐  │
                          └────────┤  jnlp + Kaniko  (FROM nexus:5000/alpine)  ├──┘
                                   └───────────────────────────────────────────┘
                    wire engine Job (charts/settings) creates: org cf-demo, repo hello-world,
                    Jenkinsfile + Dockerfile, integration user + token, Jenkins credentials and
                    pipeline, Nexus repo/role/deploy user, Kaniko docker config, base image copy.
```

Deploy order: the `preflight` component, then the chart order in
[`common/zarf.yaml`](common/zarf.yaml): `cf-config` → `gitea` → `jenkins` →
`nexus` → (`argocd`, optional, planned) → `cf-settings`.

## Usage

### Build the package (connected machine)

Needs `zarf`, `helm`, `docker`, `make`, `python3`, `skopeo` (only for re-pinning digests).

```bash
make package            # = zarf package create . -f upstream (resolves Jenkins plugins,
                        #   builds the two local images, generates SBOMs)
# → zarf-package-clusterfactory-amd64-<version>-upstream.tar.zst
```

Always build through `make` — it passes the content-addressed tags of the locally
built images to Zarf.

### Deploy (disconnected cluster)

Prerequisites on the target are in [`PREREQUISITES.md`](PREREQUISITES.md) and
are checked by the package itself before anything is deployed. To check a
cluster before you have the forge: `zarf package create preflight -f upstream`
gives a preflight-only package.

```bash
zarf init --confirm
zarf package deploy zarf-package-clusterfactory-amd64-<version>-upstream.tar.zst \
  --key cosign.pub \
  --set NEXUS_ACCEPT_CE_EULA=true \                # you are accepting Sonatype's CE EULA
  --set GITEA_ADMIN_PASSWORD=... \                 # defaults are CHANGEME-*; see ADR 0005
  --set JENKINS_ADMIN_PASSWORD=... \
  --set NEXUS_ADMIN_PASSWORD=...
```

The deploy fails loudly if the wire engine does not converge and prints its
logs. Redeploying the same or a newer package over an existing install is the
upgrade path.

### Use it

Everything is cluster-internal over plain HTTP (ADR 0010); reach it with
port-forward:

```bash
kubectl port-forward -n clusterfactory svc/gitea-http 3000:3000   # http://localhost:3000  gitea-admin
kubectl port-forward -n clusterfactory svc/jenkins    8080:8080   # http://localhost:8080  admin
kubectl port-forward -n clusterfactory svc/nexus      8081:8081   # http://localhost:8081  admin
```

Push to `cf-demo/hello-world` (or trigger `cf-demo-hello-world` in Jenkins): a pod
agent in `cf-build` builds the `Dockerfile` with Kaniko from the Nexus-hosted
base image and pushes `cf-demo/hello-world:<build>` to Nexus `docker-hosted`.

Inspect the wiring: `kubectl logs -n clusterfactory -l app.kubernetes.io/name=cf-wire-engine`.

### Run the gate yourself

The gates run only on the RKE2 runner; there is no laptop path. On any RKE2
host with the package deployed, `hack/vm-demo.sh` triggers the demo pipeline
and checks Nexus, and `tests/deploy-check.sh` runs the full gate.

## Repo layout

```
zarf.yaml              root: variables, one component per flavor (upstream), pinned images
common/zarf.yaml       flavor-agnostic: charts in deploy order, health checks, wire-Job gating
charts/config          BEFORE the apps: namespaces + PSA, NetworkPolicies, admin Secrets
charts/nexus           Nexus CE on embedded H2 (the one chart we own, ADR 0007)
charts/settings        AFTER the apps: the wire-engine Job, RBAC, demo Jenkinsfile/Dockerfile
values/                <app>-common-values.yaml (behaviour) / <app>-upstream-values.yaml (images)
wire-engine/           wire.py + Dockerfile (stdlib only)
jenkins/               plugins.txt → plugins.lock → data-only plugins image
tests/                 the gate scripts (run on the RKE2 runner)
adr/                   why things are the way they are
docs/exemptions/       every deviation from PSA restricted
```

**Flavor = image provenance only** (ADR 0003). Behaviour, charts, ordering and
wiring are identical across flavors; only `values/*-<flavor>-values.yaml` and the
`images:` list change. `upstream` is the only flavor shipped today; a `registry1`
(Iron Bank) flavor is the intended next one.

## Fork it, customize it

This is meant to be forked. The seams are deliberate:

- **Different apps or versions** — change the chart block in `common/zarf.yaml`
  and its two values files; re-pin digests with `hack/pin-images.sh`. Nothing
  else knows the app exists except the wire engine.
- **Different wiring** — add a check-then-act step to `wire-engine/wire.py`.
  Keep it idempotent; the CI gate fails a redeploy that reports `created` or `updated`.
- **Hardened images** — add a flavor: one values file per app, one component in
  `zarf.yaml`, one CI matrix entry.
- **Your own policy** — `charts/config` is where namespaces, NetworkPolicies and
  Secrets live; extend it rather than the app charts.
- **Per-app packages / a UDS bundle** — each app block is self-contained so it
  can be lifted into its own package later (ADR 0012, still open).

If you build something on top, an ADR in your fork explaining what you changed
and why is the whole point.

## Status

Steps 0–9 of the migration plan ([`uds-way.md`](uds-way.md) §13) are done and
CI-green: the package is signed, every image's SBOM is CVE-gated, upgrades are
tested N-1→N. Remaining: Argo CD optional component
([ADR 0013](adr/0013-argocd-optional-component.md)), the `rke2/` platform bundle,
and a first tagged release.

## License

MIT — see [LICENSE](LICENSE).
