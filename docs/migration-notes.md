# Migration notes: clusterfactory → UDS-style Zarf package (steps 0–9)

What was built, what was decided, and what bit us. Written 2026-09-20 after
`uds-way.md` §13 steps 0–9 merged into `main` (PRs #54, #55). This is the
narrative; the decisions themselves are in [`adr/`](../adr/README.md).

## Where things stand

| Area | State |
|---|---|
| Package | `zarf package create . -f upstream` via `make package`; signed with cosign; ~370 MB |
| Components | `cf-config` → Gitea 1.27.3 (chart 12.7.0) → Jenkins 2.568.3 (chart 5.9.63) → Nexus CE 3.96.2 (own chart, H2) → `cf-settings` (wire engine) |
| Wiring | 18 idempotent steps in `wire-engine/wire.py`; second run prints only `ok` |
| Demo | push → Jenkins pod agent in `cf-build` → Kaniko builds from Nexus-hosted `alpine` → pushes `cf-demo/hello-world:<n>` to Nexus |
| Airgap | deny-all-egress NetworkPolicies shipped; CI deploys with egress denied and asserts every image comes from the Zarf registry and `example.com` is unreachable |
| PSA | `restricted` everywhere except `cf-build` (`baseline`, one documented exemption) |
| CI | lint → create (SBOM, CVE gate, signing) → airgapped deploy + functional gate ∥ N-1→N upgrade gate; ~10 min each on `ubuntu-latest` |
| Audit | cosign signature, per-image SBOMs, `.grype.yaml` policy, `oscal-component.yaml`, ADRs 0001–0013 |
| Not yet | Argo CD (ADR 0013), `rke2/` platform bundle, `PREREQUISITES.md`, first tagged release |

## Decisions that changed on contact with reality

- **No Postgres, Nexus on H2** (ADR 0007/0008). `nxrm-ha` only exists in an
  external-database shape; nothing else needed Postgres. An operator, CRDs and
  five images for one demo database was the wrong trade.
- **Jenkins plugins as a data-only OCI image, not `dataInjections`** (ADR 0006
  amended). Zarf deprecates `dataInjections` and recommends exactly this.
- **Wire Job named per Helm revision.** Job templates are immutable; an
  upgrade must create a new Job. Helm removes the previous one.
- **`cf-config` lives in its own `cf-system` namespace.** Helm cannot adopt a
  Namespace that Zarf pre-created, and the chart must own the application
  namespaces to label them.
- **CVE policy: KEV blocks anywhere; critical-with-fix blocks only on images
  built here.** Scanning the *newest* upstream tags showed a blanket
  critical-with-fix rule is unachievable on unmodified images (openssl in
  `alpine:3.22.2`, perl/glibc in the Debian-based Jenkins images, bundled
  jars). The gate still earned its keep: Gitea 1.27.0 carried CVE-2026-60004,
  on CISA's exploited list.
- **Kaniko runs as uid 0 with the runtime-default capability set.** `drop: ALL`
  leaves root unable to write the uid-1000 workspace or extract layers, and
  PSA `baseline` forbids adding capabilities back. Written down precisely in
  `docs/exemptions/kaniko.md`.

## Things that will bite the next person (all handled, all worth knowing)

**Zarf**
- Rejects multi-arch *index* digests; pin the linux/amd64 *manifest* digest
  (`hack/pin-images.sh`). Renovate must not pin docker digests.
- Namespaces that exist before `zarf init` get `zarf.dev/agent=ignore`: the
  agent never rewrites their images and the node quietly pulls from the
  internet. CI creates namespaces after init and asserts every image is
  served by the Zarf registry.
- Package templates (`###ZARF_PKG_TMPL_*###`) are substituted only in
  `zarf.yaml`, not in values files; route them through `constants:`.
  `setVariables` is not allowed in `onCreate`.
- The "pull from the Docker daemon" fallback tags/untags images by id while
  pulling, races itself with several images in flight ("reference does not
  exist") and deletes the images afterwards. Locally built images go through
  a throwaway registry (`make local-registry`, `localhost:5001`).
- The API server is not a pod: deny-all-egress must allow it by `ipBlock`,
  resolved from the `kubernetes` EndpointSlice at deploy time (a Zarf
  `onDeploy.before` action). If the node IP changes, every such rule goes
  stale until the next deploy.

**Jenkins**
- `agent.restrictedPssSecurityContext: true` merges `capabilities.drop: ALL`
  into *every* container of a pod template. Off; contexts are explicit.
- The Kubernetes plugin injects its own default `inbound-agent` tag unless
  the pod YAML names a `jnlp` container. Pinned.
- `container()` needs a shell: use the `-debug` Kaniko image.
- CSRF crumbs are bound to the session cookie (the wire engine keeps a jar).
- `jenkins-plugin-cli` resolves transitive dependencies against the live
  update centre; a lock re-resolved from `plugins.txt` drifts within hours.
  `plugins.lock` is the source of truth; `make plugins-update` refreshes it.

**Gitea**
- Chart 12 renamed redis to valkey in values.
- Single instance on one RWO volume with the LevelDB queue must use
  `strategy: Recreate`; `RollingUpdate` with 100% surge crash-loops on the
  queue lock and every in-place upgrade fails.
- API tokens are not re-readable; the wire engine persists the one it mints.

**Nexus CE**
- The Docker connector answers 403 until the `DockerToken` realm is active
  **and** the CE EULA is accepted via REST. EULA acceptance is an operator
  variable (`NEXUS_ACCEPT_CE_EULA`), never a default.

**Kubelet / images**
- A kubelet caches by tag with `IfNotPresent`; rebuilding a locally built
  image under the same tag silently runs old bits. Tags are content hashes
  of the payload.

**Runners / registries**
- On Linux, bind-mounted directories must be writable by the container's uid
  (jenkins-plugin-cli runs as 1000); macOS hid this.
- `umask 077` set for writing a signing key leaks into the rest of the shell
  step. Use a subshell.
- `gcr.io` is retired ("requires billing"): `scorecard-action` v2.4.0 broke,
  and the Kaniko executor is published only there (ADR 0009 risk).

**Rocky 9 / SELinux**
- local-path-provisioner's directory must be `container_file_t`, or its helper
  pod cannot `mkdir` and every PVC (the Zarf registry's first) stays Pending.
- systemd will not exec the GitHub runner from `user_home_t`; label it `bin_t`.

## What the gates verify (so you can trust green)

`tests/deploy-check.sh`: workload pods Ready; every container image from
the Zarf registry; Gitea/Jenkins/Nexus answer; anonymous docker pull 401;
cf-config credentials accepted by both APIs; all top-level plugins active;
wire Job converged (and, with `EXPECT_IDEMPOTENT=1`, only `ok`); the demo
pipeline build with its own number succeeds and its tag exists in Nexus;
`example.com` returns `000`. The upgrade job wraps this with
`tests/snapshot-state.sh` / `tests/compare-state.py` around an N-1→N deploy.

## CI runs only on RKE2, and the RKE2 host is physically air-gapped (2026-09-21)

kind and every laptop path were removed. The test host `cf-runner-1` (GCP,
Rocky 9, SELinux enforcing, 16 vCPU / 32 GB) has **no route to the internet
at all** - no external IP, no Cloud NAT, only Private Google Access to one
private GCS bucket, and SSH reachable solely through Google's IAP tunnel.
Everything online happens on GitHub-hosted runners:

- `airgap-stage.yaml` fetches the platform artifacts (RKE2 core + canal +
  flannel tarballs, `install.sh`, checksums, `rke2-selinux` +
  `container-selinux` RPMs resolved in a Rocky container, local-path
  manifest + image tar, zarf + init package) with `hack/airgap-fetch.sh` and
  stages them under `gs://cf-artifacts-<project>/platform/<rke2 version>/`.
- `ci.yaml` `rke2` job (hosted): stages this run's package and the gate
  scripts under `runs/<run id>/`, then over IAP the VM pulls them and runs
  `hack/airgap-install.sh up` (tarball-only RKE2 install, local-path from the
  manifests dir with the `container_file_t` label, `zarf init`), deploys the
  previous main package, upgrades to this one, runs the full gate incl. the
  demo Kaniko build, checks data survived, redeploys idempotently, uninstalls,
  and deletes the run prefix. `rke2-negative` does the same with
  `cni: flannel` and the default-class annotation removed; the preflight must
  refuse. GitHub → VM only ever flows through WIF-authenticated `gcloud`
  (service account limited to that instance + that bucket); the VM's own
  identity can only read the bucket.
- `hack/airgap-install.sh` is the manual form of the `rke2` init component
  (ADR 0015): same files, same order, same waits - and the runbook.

Measured earlier the same day (still with NAT): deploy to wire-engine
Complete in 2m38s on this VM.

## Revised plan after ADRs 0014–0016 (replaces uds-way.md §13 steps 10–12)

| # | Work | Gate |
|---|---|---|
| 10a | **Preflight component** in `common/zarf.yaml` (contract + advisory checks, `PREFLIGHT_STRICT`), `PREREQUISITES.md` generated from the check table | RKE2: preflight passes; RKE2 with flannel + no StorageClass is refused |
| 10b | **Policy profiles** `policy/baseline`, `policy/cis`: denies move out of `charts/config`; `profile.yaml` read by preflight | CI deploys `baseline` before the forge; egress test unchanged |
| 10c | **Custom init package** `rke2/zarf.yaml` (`rke2` component + upstream init components; RPM/deb flavors; registry on a local-path PVC); Traefik `Ingress` by hostname in the forge | nightly tier-1 gate: RKE2 on the runner, iptables egress block, init → policy → forge → `deploy-check.sh` |
| 10d | Tier-2 self-hosted Rocky VM gate (SELinux enforcing, snapshot-revert), weekly + pre-release | needs a runner from you |
| 11 | Docs pass: README usage for the three-package flow, SECURITY (policy layer), CONTRIBUTING, runbook | — |
| 12 | **Deliverable tar** (Zarf binary, init package, forge, profiles, `cosign.pub`, signed `SHA256SUMS`, install script, runbook) built by the release workflow; tag `v0.4.0` | release workflow green; nightly gate installs from the tar |
| 8b | Argo CD optional component (ADR 0013) - after 10a–10c, it is independent | functional gate extended |
| v0.5 | TLS via policy profile; etcd snapshot + PV backup procedure; system-upgrade-controller for factory-built clusters | |

## Self-hosted RKE2 gate (2026-09-21)

`cf-runner-1`: GCP `sportpilot-dev-001`, `europe-west1-b`, `n2-custom-16-32768`,
Rocky 9 GCP image, shielded VM, **no external IP, no service account, own VPC
`cf-runner` with zero ingress rules, Cloud NAT for egress**. It is a GitHub
self-hosted runner (labels `self-hosted, rke2, rocky9, gcp`): only outbound
connections to GitHub, nothing ever connects in. Registered with a one-hour
token passed as instance metadata and purged afterwards; the startup script
(re-run on every boot) installs deps, disables `nm-cloud-setup`/`firewalld`,
labels the runner tree `bin_t` (SELinux refuses to exec `user_home_t` from
systemd) and starts the service.

`rke2-gate.yaml` runs the forge on it from a clean RKE2 install
(`workflow_dispatch` with a release tag or the latest CI artifact; nightly),
and uninstalls RKE2 afterwards. `vm-ops.yaml` resets/stops/starts the VM via
Workload Identity Federation - service account `cf-runner-ops` with a custom
role limited to that one instance, no key file. Stop the VM when not in use.
