# Refactor: Package Upstream-Only, Wire Once In-Airgap

## Context

clusterfactory currently delivers Gitea + Jenkins as a Zarf package, but the
Jenkins image is a custom build (`images/jenkins/Dockerfile.wire`) baked with
wiring logic, so the "unmodified upstream Gitea + Jenkins" claim in the
README isn't quite true. This refactor removes the custom image build and moves all
cross-service wiring to a one-shot job that runs *after* Zarf has deployed
unmodified upstream charts.

**Principle:** the Zarf package contains only unmodified upstream charts
and images, plus our values. Tuning/wiring is a separate step that runs
once, inside the cluster, after deploy.

## Current State (as-is)

- `zarf.yaml` at repo root packages a Helm chart (root `Chart.yaml` +
  `values.yaml`) that installs Gitea + Jenkins.
- `images/jenkins/Dockerfile.wire` — custom Jenkins image with wiring logic
  baked in.
- A Python "wire engine" (see `refactor-to-zarf.md`,
  `DEPLOYMENT_MODES_IMPLEMENTATION.md`) runs externally after
  `zarf package deploy` completes:
  1. Mints an API token from Gitea
  2. Stores the token as a Jenkins credential
  3. Creates `cf-demo/hello-world` repo in Gitea
  4. Commits a Jenkinsfile
  5. Creates a matching Jenkins pipeline job
  6. Emits a structural SHA proving the wiring graph executed as declared
- Credentials (e.g. `GITEA_ADMIN_PASSWORD`) are passed via `--set` at deploy
  time. Security hardening here (cosign key, structural SHA framing) is
  currently over-scoped relative to the actual threat model: this deploys to
  a trusted operator's airgapped cluster where `kubectl` access already means
  full control. `CHANGEME`-style defaults are fine.

## Target State (to-be)

### 1. Upstream-only package

- Remove `images/jenkins/Dockerfile.wire` and the root `Dockerfile.wire`.
- Jenkins, Gitea, and (new) Nexus are installed from their unmodified
  upstream Helm charts/images only. No custom image builds, no forked
  Dockerfiles.
- `zarf.yaml` components list Gitea, Jenkins, Nexus, and PostgreSQL (for
  Nexus) as sibling components (each with its own chart + explicit
  `images:` list, per Zarf convention — auto-detection from templated Helm
  values is unreliable).
- Drop the cosign signing and the structural SHA entirely from code and
  `SECURITY.md`. The wire Job's exit code is the success signal.

### 1a. Jenkins plugins without a custom image

Upstream `jenkins/jenkins` ships no Gitea/pipeline/kubernetes plugins, and in
a full airgap it cannot download them at boot (`installPlugins` must be
`[]`). Plugins are delivered as a **pre-bundled plugin volume**:

- A Zarf component ships the pinned `.hpi` set (gitea, workflow-aggregator,
  kubernetes, credentials-binding, plus transitive deps) into the cluster
  (ConfigMap/PVC populated at deploy, or an initContainer copying from a
  plugin-only volume — *not* a rebuilt Jenkins image).
- The upstream Jenkins chart mounts that volume at
  `$JENKINS_HOME/plugins` via `persistence.volumes` / `extraVolumeMounts`.
- Plugin versions are pinned in-repo so the airgapped set is reproducible.

### 2. Wiring as a post-deploy Job, not a baked image

- New Zarf component, e.g. `wire-engine`, containing:
  - A small, purpose-built image (Python + whatever Gitea/Jenkins API
    clients are needed) — *not* merged into the Jenkins image.
  - A Kubernetes `Job` manifest that runs the wire engine's five API calls
    against the now-live Gitea/Jenkins/Nexus services.
- **Decided: in-cluster `Job`.** The environment is fully airgapped at
  wiring time, so nothing may depend on the operator's machine. The wire
  engine runs entirely in-cluster; the wire-engine image is pushed to the
  Zarf registry like every other image in the package.
- Component ordering / readiness:
  - Use Zarf's `actions.onDeploy.before` on the `wire-engine` component with
    `wait: cluster: kind: pod ... condition: Ready` for Gitea, Jenkins,
    Nexus, and Postgres so the Job is only created once all services are up.
  - Follow with an `onDeploy.after` wait on the Job's `condition: Complete`
    so `zarf package deploy` fails loudly if wiring did not converge.
- **Lifecycle: run once per deploy, idempotent.** Zarf (re)creates the Job
  on each deploy; it converges and exits. Operator re-runs by deleting the
  Job and re-applying. No Helm hooks, no long-lived controller.
- **Credentials:** the Job mounts the Secrets the upstream charts already
  create (Gitea admin secret, Jenkins admin secret, Nexus admin password
  secret, Postgres credentials). No `--set` plumbing for creds; one source
  of truth. `CHANGEME`-style defaults in `values.yaml` are acceptable under
  the trusted-operator threat model.

### 3. Idempotency

Since wiring no longer happens at image-build time, re-running
`zarf package deploy` (or manually re-running the wire Job) must not error
on "repo already exists" / "credential already exists." The wire engine
needs a check-first-then-act guard for each of its five steps:

- Does `cf-demo/hello-world` already exist in Gitea? Skip create, or just
  ensure Jenkinsfile content matches.
- Does the Jenkins credential already exist? Update in place rather than
  erroring.
- Does the Jenkins pipeline job already exist? Update in place.

- Nexus: does the `docker-hosted` repo exist? Does the Jenkins credential
  for Nexus exist? Update in place.

### 4. Nexus addition

- **Required component** (`required: true`), sibling to Gitea/Jenkins.
- **Chart: Sonatype official `nxrm-ha`** (the community
  `nexus-repository-manager` chart is archived). Run it single-replica with
  Nexus Repository **Community Edition** — HA itself needs Pro, but the
  chart works with one replica. Verify the CE image + chart combination
  during step 4 before committing further.
- `nxrm-ha` requires an external PostgreSQL. **Decided: ship an unmodified
  upstream Postgres chart as its own Zarf component** (Bitnami `postgresql`
  or CloudNativePG operator — pick during implementation based on image
  count and airgap friendliness). Nexus points at it via chart values.
  Do not reuse Gitea's bundled Postgres; keep the services decoupled.
- **Wiring scope for this refactor: Docker registry only.** The wire
  engine:
  1. Creates a `docker-hosted` repository in Nexus (HTTP connector on a
     fixed port, anonymous pull off, service exposed in-cluster).
  2. Stores Nexus deploy credentials as a Jenkins credential.
  3. Updates the demo Jenkinsfile so the pipeline builds and pushes an image
     to that repo.
- No Maven/npm/PyPI proxies — proxies are useless in airgap without
  pre-seeding, which is out of scope.

### 5. In-cluster image builds: Kaniko

Pushing to Nexus means the demo pipeline builds an image in-cluster.
**Decided: Kaniko.**

- The `gcr.io/kaniko-project/executor` image is listed under the
  `jenkins` (or `wire-engine`) component's `images:` so Zarf mirrors it.
- The Jenkins Kubernetes plugin (from the plugin volume, §1a) runs the
  build as a pod agent; the Jenkinsfile uses a `kaniko` container with the
  Nexus credential mounted as a docker `config.json`.
- Kaniko pushes to the in-cluster Nexus service DNS name; the Nexus
  registry needs to be reachable over plain HTTP or with a cluster-trusted
  cert (`--insecure` / `--skip-tls-verify` acceptable under the current
  threat model).

## Airgap Principles

The refactor is not just "upstream charts"; every design choice must survive
a cluster with **zero egress**. Rules that follow from that:

1. **Nothing downloads at runtime.** Every byte the cluster needs — images,
   Helm charts, Jenkins plugins, Kaniko base images — is inside the Zarf
   package. If a component works only because CI had internet, it is a bug.
2. **Prove it in CI, not on-site.** The GitHub Actions test creates the
   package on a connected runner, then deploys it into a kind cluster with
   a default-deny egress `NetworkPolicy` (and a CNI that enforces it, e.g.
   Calico or Cilium — kindnet does not). Any hidden phone-home fails the
   build.
3. **Ship the guard.** The package itself installs a deny-all-egress
   `NetworkPolicy` (allowing DNS and in-cluster traffic) in every
   clusterfactory namespace. Airgap is enforced, not assumed. Pair this with
   disabling update checks in each app via chart values (Jenkins update
   center, Gitea `[cron.update_checker]`, Nexus outreach/telemetry) so
   startup doesn't stall on timeouts.
4. **The build pipeline stays inside the fence.** Kaniko's `FROM` base
   image is pre-seeded into Nexus by the wire Job (copied from the Zarf
   registry with a Docker Registry API v2 mount/push — no `docker` daemon).
   The demo Dockerfile references `nexus-docker.<ns>.svc:<port>/alpine`,
   never Docker Hub. Nexus is the only registry the pipeline knows about.
5. **Plain HTTP, port-forward access — for now.** No cert-manager, no
   ingress, no public DNS. Kaniko uses `--insecure`; the operator reaches
   UIs via `kubectl port-forward`. Documented as a known limitation under
   the trusted-operator threat model; cert-manager with a cluster CA is the
   upgrade path when needed.
6. **Reproducible connected-side build.** `jenkins/plugins.txt` pins exact
   plugin versions; `make plugins` runs `jenkins-plugin-cli` in a
   throwaway container to resolve the full closure into `jenkins/plugins/`,
   which Zarf packages. Same for the wire-engine image: `python:3.x-slim`
   with stdlib `urllib`/`json` only — no `pip install`, no wheel mirroring.
7. **Upgrades are the same command.** `zarf package deploy` over an
   existing install runs `helm upgrade` per component and re-runs the
   idempotent wire Job. All state (Gitea, Jenkins home, Nexus blobstore,
   Postgres) is PVC-backed so it survives. CI tests N-1 → N.
8. **Single artifact, size is not a constraint yet.** One `.tar.zst` on
   removable media. Revisit (`--max-package-size`, base+app split) only if
   a real limit appears.

## Platform Layer: RKE2

clusterfactory owns the cluster, not just the app. The full airgapped
install order is:

```
OS (customer)  →  RKE2 airgap install  →  zarf init  →  zarf package deploy
```

There is no `helm install` and **no manual image preloading for
clusterfactory**: `zarf init` stands up an in-cluster registry + mutating
webhook, and `zarf package deploy` pushes the package's images into it and
rewrites every pod's `image:` to point there. The only images that must
exist *before* Zarf are RKE2's own (CNI, CoreDNS, metrics-server,
ingress-nginx), which come from the RKE2 airgap tarball dropped into
`/var/lib/rancher/rke2/agent/images/`.

### What the repo ships

- `rke2/` directory: pinned RKE2 version, `rke2-images.linux-amd64.tar.zst`,
  `rke2.linux-amd64.tar.gz`, `install.sh`, and a hardened `config.yaml`.
- `rke2/config.yaml`:
  - `profile: cis` — enables PSA `restricted` by default, audit logging,
    kernel sysctls, and requires the `etcd` user/group (install script
    creates it and applies `/etc/sysctl.d/60-rke2-cis.conf`).
  - `secrets-encryption: true` — Secrets encrypted at rest in etcd (all
    admin passwords live in Secrets).
  - `cni: canal` — default, bundled in the airgap tarball, enforces
    `NetworkPolicy`, no extra images. Cilium deliberately not chosen.
  - `disable: rke2-ingress-nginx` — no ingress in this refactor (plain
    HTTP + port-forward per Airgap Principles §5); saves images and attack
    surface.
- `rke2/manifests/local-path-storage.yaml` → placed in
  `/var/lib/rancher/rke2/server/manifests/` so RKE2 auto-applies it. Its
  single image is added to the airgap images dir. Set as default
  `StorageClass`; all stateful pods (Gitea, Jenkins, Nexus, Postgres, Zarf
  registry) get a `nodeSelector` pinning them to the storage node.
- The Zarf init package (pinned version matching the `zarf` CLI).

### Security posture under `profile: cis`

- **Cluster-wide PSA `restricted`.** Every clusterfactory workload runs
  non-root with `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`: Jenkins
  (1000), Gitea rootless (1000), Nexus (200 + `fsGroup`), Postgres (1001),
  wire-engine (non-root uid). Chart values must set these explicitly.
- **One declared exemption: Kaniko.** Modeled on the UDS Core `Exemption`
  pattern (narrow scope, named policy, written justification) rather than
  a privileged namespace:
  - namespace `cf-build` labeled `pod-security.kubernetes.io/enforce=baseline`
    (**not** `privileged`);
  - Kaniko runs as uid 0 — the only rule it violates is
    `RequireNonRootUser`; it gets **no** `privileged`, no capabilities, no
    hostPath, no ServiceAccount token, seccomp `RuntimeDefault`;
  - `NetworkPolicy` on `cf-build` allows egress only to Gitea and Nexus;
  - `docs/exemptions/kaniko.md` records title, scope, justification, and
    review date.
  - Recorded alternative: `ko`/Jib/`apko` builders need no root and would
    remove the exemption entirely, at the cost of a language-specific demo.
- **Zarf registry:** plain HTTP NodePort with hostPath storage. Accepted
  under the trusted-operator model; pinned to the storage node via
  `nodeSelector` so a reschedule doesn't lose every image. Documented.
- **Audit logging** comes with `profile: cis`; logs stay on the node
  (`/var/lib/rancher/rke2/server/logs/audit.log`) with RKE2's default
  rotation — no SIEM to ship to.
- **Out of scope, stated in PREREQUISITES:** host OS STIG/hardening, etcd
  snapshot off-node copy cadence, multi-node HA.

## Migration Steps

0. Add the `rke2/` bundle: pinned version, airgap tarballs, `install.sh`,
   hardened `config.yaml`, local-path-provisioner manifest. Add a CI job
   that boots RKE2 in a VM with no egress, runs `zarf init`, and asserts
   the cluster passes `kube-bench` for the RKE2 CIS profile.
0a. Add `securityContext` blocks to every chart's values so all pods admit
   under PSA `restricted`; create `cf-build` at `baseline` with its
   `NetworkPolicy` and the Kaniko exemption doc.

1. Strip Dockerfile.wire logic out into a standalone `wire-engine/` image +
   script directory. Remove the structural SHA and cosign code paths.
   Confirm Jenkins/Gitea images in `zarf.yaml` now point at unmodified
   upstream tags.
2. Build the Jenkins plugin volume: commit `jenkins/plugins.txt`, add
   `make plugins` (jenkins-plugin-cli in a container), ship the resolved
   directory as a Zarf component, mount it via the upstream chart with
   `installPlugins: []`. Verify Jenkins boots with all plugins loaded in an
   airgapped kind cluster.
2a. Add the egress-blocked CI job: Calico/Cilium kind cluster, default-deny
   egress `NetworkPolicy`, deploy the package, assert all pods Ready and
   wire Job Complete. Every later step must pass this gate.
2b. Add the shipped deny-all-egress `NetworkPolicy` component and disable
   update checkers/telemetry in Gitea, Jenkins, and Nexus values.
3. Write the wire-engine `Job` manifest and add it as a new Zarf component
   with `onDeploy.before` readiness waits and an `onDeploy.after` wait on
   Job completion. Mount chart-created Secrets for credentials.
4. Add idempotency guards to each wire-engine step.
5. Add PostgreSQL and Nexus (`nxrm-ha`, single replica, CE) as required
   components. Validate CE + `nxrm-ha` + Postgres actually starts before
   proceeding.
6. Extend the wire engine: create `docker-hosted` repo, store Nexus cred in
   Jenkins, pre-seed the demo base image from the Zarf registry into Nexus,
   update the demo Jenkinsfile to build with Kaniko (`FROM` Nexus) and push
   to Nexus. Add the Kaniko executor and base images to `zarf.yaml`.
6a. Add an upgrade test to CI: deploy the previous release tag, then deploy
   the current package over it; assert PVC data (demo repo, Jenkins job,
   Nexus image) survives and the wire Job converges without errors.
7. Update README, SECURITY.md, `refactor-to-zarf.md`, and
   `DEPLOYMENT_MODES_IMPLEMENTATION.md` to reflect: (a) upstream-only
   package contents, (b) wiring-as-convenience framing, (c) new component
   list (Gitea, Jenkins, Jenkins plugins, Postgres, Nexus, wire-engine),
   (d) removal of structural SHA / cosign.
8. Re-run the demo flow end-to-end in an airgapped cluster:
   `zarf package create .` → transfer → `zarf package deploy` → confirm
   wire Job completes → push to `cf-demo/hello-world` → pipeline builds
   with Kaniko → image lands in Nexus.

## Decisions

The decision table that used to live here has been migrated to
Architecture Decision Records under [`adr/`](adr/README.md) (uds-way.md §10).
Superseding design: [`uds-way.md`](uds-way.md).

## Remaining Risks

- `nxrm-ha` + Community Edition + single replica is an assumption that
  needs a spike (step 5) — if it doesn't work, fall back to raw manifests
  with the upstream `sonatype/nexus3` image.
- The Jenkins plugin dependency closure must be resolved offline and pinned;
  a missing transitive plugin only shows up at boot in the airgapped
  cluster.
- Bitnami's image/chart distribution model changed in 2025; confirm the
  chosen Postgres chart's images are still freely pullable before pinning.
- kind's default CNI (kindnet) does not enforce `NetworkPolicy`; the
  airgap CI job must install Calico or Cilium or the deny-egress test is a
  no-op that passes silently.
- Copying the base image from the Zarf registry into Nexus needs the
  Zarf-internal registry to be reachable from the wire Job pod (it is a
  NodePort on `127.0.0.1:31999` by default — the Job must use the in-cluster
  `zarf-docker-registry.zarf.svc` Service instead).
- Nexus CE has a component/request cap (introduced in 3.77+); a demo won't
  hit it, but document it so nobody is surprised at scale.
- `profile: cis` refuses to start if the `etcd` user is missing or the
  sysctls aren't applied — the install script must do both before
  `systemctl start rke2-server`, or the first on-site install fails.
- Zarf's agent webhook and registry themselves must admit under PSA
  `restricted` on a CIS cluster; verify the pinned Zarf init version does
  (recent versions do), otherwise `zarf init` is the first thing to break.
- Kaniko + `readOnlyRootFilesystem` conflicts (it writes to `/kaniko` and
  `/`); expect to keep the root fs writable and lock down everything else.
- RKE2 CI needs a VM, not kind — kind can't run RKE2. Budget for a
  Lima/Vagrant/GitHub-hosted-VM job; it will be the slowest gate.
