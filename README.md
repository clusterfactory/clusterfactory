# clusterfactory

**A transparent way to package a software forge for disconnected environments.**

One signed [Zarf](https://zarf.dev) file and one command turn a bare Rocky/RHEL 9
host with no internet into a working forge: **RKE2**, then **Gitea** (git),
**Jenkins** (CI), **Nexus Repository CE** (container registry) — optionally
**Argo CD** — wired together so that a push to a repo builds an image in-cluster
and lands it in the registry. Already have a cluster? The forge is also a
package of its own. Nothing in either phones home; CI proves it on every change
on a VM with no route to the internet.

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
| **Tested on a physically air-gapped bare host** | [`ci.yaml`](.github/workflows/ci.yaml): lint → create both packages → a **Rocky 9 / SELinux-enforcing VM with no route to the internet** (packages arrive through a private bucket, control through an IAP tunnel): the customer command on the all-in-one of the previous `main` build, the full gate ([`tests/deploy-check.sh`](tests/deploy-check.sh)) with a real Kaniko build pushed to Nexus, upgrade with this build's forge package, gate, idempotent redeploy, and a second RKE2 with flannel + no StorageClass that the preflight must refuse. No kind, nothing runs on a laptop (ADR 0014). |

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

Every [release](https://github.com/clusterfactory/clusterfactory/releases) carries
two signed packages, `cosign.pub` and checksums:

| File | What it is | Use it when |
|---|---|---|
| `zarf-init-amd64-<zarf>.tar.zst` (~2 GB) | **All-in-one**: RKE2 (air-gapped, from tarballs), the Zarf registry and agent, then the forge. A custom Zarf init package ([`rke2/zarf.yaml`](rke2/zarf.yaml), [ADR 0015](adr/0015-custom-init-package-rke2.md)). | You have a bare host. |
| `zarf-package-clusterfactory-amd64-<version>-upstream.tar.zst` (~1.2 GB) | **The forge only** ([`zarf.yaml`](zarf.yaml)). | You bring the cluster, or you upgrade an existing install. |

### Bare host → forge, step by step

Target host: Rocky/RHEL 9, x86_64, 16 GB+ RAM, 4+ CPUs, 20 GB+ free under
`/var/lib`, SELinux enforcing is fine, **no internet needed**. You need root
and nothing installed.

**1. On a connected machine, download the release** (≈2.3 GB; pick the tag on
the [releases page](https://github.com/clusterfactory/clusterfactory/releases),
the Zarf version is in the init file name):

```bash
V=0.4.0                 # clusterfactory release
Z=v0.75.0               # zarf CLI version the init package is built for
R=https://github.com/clusterfactory/clusterfactory/releases/download/v$V
mkdir clusterfactory-$V && cd clusterfactory-$V
curl -sSfLO "$R/zarf-init-amd64-$Z.tar.zst"
curl -sSfLO "$R/cosign.pub"
curl -sSfLO "$R/clusterfactory-$V-SHA256SUMS"
curl -sSfL "https://github.com/zarf-dev/zarf/releases/download/$Z/zarf_${Z}_Linux_amd64" -o zarf
sha256sum -c "clusterfactory-$V-SHA256SUMS" --ignore-missing     # init package + cosign.pub OK
```

**2. Carry the directory across** (USB, scp, whatever the gap allows) to the
target host, e.g. `/root/clusterfactory-0.4.0/`.

**3. On the target host, as root:**

```bash
cd /root/clusterfactory-0.4.0
install -m 755 zarf /usr/local/bin/zarf
sha256sum -c "clusterfactory-0.4.0-SHA256SUMS" --ignore-missing  # again, after the transfer
zarf init --confirm --key cosign.pub \
  --set NEXUS_ACCEPT_CE_EULA=true \                # you are accepting Sonatype's CE EULA
  --set GITEA_ADMIN_PASSWORD=... \                 # defaults are CHANGEME-*; see ADR 0005
  --set JENKINS_ADMIN_PASSWORD=... \
  --set NEXUS_ADMIN_PASSWORD=...
```

`--key cosign.pub` refuses a package that is not signed by this project. The
host preflight then refuses a host that already runs RKE2, and the cluster
preflight refuses a cluster that cannot honour the package's guarantees — it
never "fixes" either. About eight minutes later:

```
preflight ok: Rocky Linux 9.8 (Blue Onyx), selinux=Enforcing
== rke2 ready
wire engine: cf-wire-engine-r1=Complete:True
init complete.
```

**4. Use it** — see [Use it](#use-it) below; `kubectl` is at
`/var/lib/rancher/rke2/bin/kubectl` with `KUBECONFIG=/etc/rancher/rke2/rke2.yaml`.

To take everything down again: `zarf package remove init --confirm` (removes
the forge, then RKE2 and its state).

### Your own cluster, or an upgrade

Prerequisites are in [`PREREQUISITES.md`](PREREQUISITES.md) and are checked by
the package itself before anything is deployed (`zarf package create preflight
-f upstream` gives a preflight-only package to check a cluster ahead of time).

```bash
zarf init --confirm      # your cluster, once (skip after the all-in-one)
zarf package deploy zarf-package-clusterfactory-amd64-<version>-upstream.tar.zst \
  --key cosign.pub --set NEXUS_ACCEPT_CE_EULA=true   # + the passwords as above
```

Redeploying the same or a newer forge package over an existing install — from
the all-in-one or not — is the upgrade path: Helm release names do not depend
on which package deployed them. The deploy fails loudly if the wire engine does
not converge and prints its logs.

### Build the packages (connected machine)

Needs `zarf`, `helm`, `docker`, `make`, `python3`, `skopeo`.

```bash
make package            # the forge: zarf package create . -f upstream (resolves Jenkins
                        #   plugins, builds the two local images, generates SBOMs)
make init-package       # the all-in-one: rke2/ + the forge components, renamed to the
                        #   name `zarf init` looks for
```

Always build through `make` — it passes the content-addressed tags of the locally
built images to Zarf.

### Use it

Everything is cluster-internal over plain HTTP (ADR 0010); reach it with
port-forward (on the all-in-one host: `export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
PATH=$PATH:/var/lib/rancher/rke2/bin`):

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
