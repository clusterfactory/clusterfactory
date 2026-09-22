# Changelog

All notable changes to clusterfactory are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [0.4.0] - unreleased (rc.1 2026-09-20)

clusterfactory is no longer a Helm chart. It is a signed Zarf package
(`zarf-package-clusterfactory-amd64-0.4.0-upstream.tar.zst`) and an all-in-one
Zarf init package (`zarf-init-amd64-v0.75.0.tar.zst`) that takes a bare
Rocky/RHEL 9 host to RKE2 + a wired Gitea/Jenkins/Nexus forge with one
`zarf init`, with no internet at any point. Read `README.md` first; the
reasoning is in `adr/` (0001–0016), the rationale document in `docs/design.md`.

### Added
- Root `zarf.yaml` (variables, `upstream` flavor, pinned images) importing
  `common/zarf.yaml` (charts in deploy order, health checks, wire-Job gating).
- `charts/config` (namespaces, PSA labels, deny-all-egress NetworkPolicies
  with the API server resolved at deploy time, admin Secrets) before the apps;
  `charts/settings` (the wire-engine Job, RBAC, demo pipeline) after them.
- Nexus Repository CE 3.96 on embedded H2, own helper chart `charts/nexus`
  (ADR 0007); no Postgres (ADR 0008).
- Jenkins plugin closure resolved on the connected side (`jenkins/plugins.txt`
  → `plugins.lock`) into a data-only image (ADR 0006); update centre off.
- Wire engine: stdlib-only `wire-engine/wire.py` Job, 18 idempotent
  check-then-act steps across Gitea, Jenkins and Nexus; a redeploy on a
  converged cluster prints only `ok` (ADR 0002, 0004).
- In-cluster image builds with Kaniko pod agents in `cf-build` (PSA baseline,
  one declared exemption, ADR 0009); demo pipeline builds from the
  Nexus-hosted base image and pushes back to Nexus.
- `preflight` component: executable contract (NetworkPolicy enforcement,
  default StorageClass binds, PSA, DNS, Zarf registry, API endpoint) that
  refuses the deploy; `PREREQUISITES.md` generated from it (ADR 0014).
- `rke2/`: custom Zarf init package — RKE2 v1.36.4+rke2r1 from tarballs,
  SELinux policy RPMs, local-path StorageClass, Canal, host preflight — that
  also carries the forge components (ADR 0015, 0012). `make init-package`.
- Supply chain: cosign signing of both packages (`cosign.pub` in the repo and
  every release), per-image SBOMs, CVE gate (`.grype.yaml`: KEV blocks
  anywhere, critical-with-fix blocks on images built here),
  `oscal-component.yaml` validated in CI, Renovate.
- CI on a physically air-gapped Rocky 9 / SELinux host (no internet route;
  packages through a private bucket, control through an IAP tunnel): install
  from the all-in-one, gate with a real Kaniko build, upgrade N-1→N, idempotent
  redeploy, and a negative test the preflight must refuse. Gated on the repo
  variable `CF_RIG`; hosted lint/create jobs need nothing (`docs/ci.md`).
- Release workflow: tag `v*` → both packages built, signed, verified and
  attached with SBOMs and checksums; nightly gate installs the release as a
  customer would. Docs: `docs/install-bare-host.md`, `docs/lessons.md`,
  `docs/roadmap.md`.

### Changed
- Gitea 1.27.3 (chart 12.7.0, `strategy: Recreate`), Jenkins 2.568.3 (chart
  5.9.63), inbound-agent 3385, k8s-sidecar 2.9.0, Kaniko 1.24.0-debug,
  alpine 3.22.2 — all upstream, pinned by linux/amd64 manifest digest.
- Access is cluster-internal plain HTTP via port-forward for now (ADR 0010);
  Ingress and TLS are roadmap items.

### Removed
- The umbrella Helm chart, the Helm repository on GitHub Pages
  (`docs/*.tgz`, `index.yaml`), the custom Jenkins image, the bash and
  Python "factory engine" wiring, Gitea act_runner, the three deployment
  modes, Dependabot, all kind/laptop test paths, and `docs/archive/`.
  Every decision they embodied is either an ADR or gone on purpose.

### Breaking changes
- There is no Helm install path anymore. Migrate by deploying the Zarf
  package into a fresh cluster (or a fresh host with the all-in-one); no
  data migration from the 0.2.x chart is provided.

## [0.2.0] - 2026-04-05

### Added
- Kaniko-based container builds — eliminates Docker-in-Docker and privileged
  containers; runner now spawns ephemeral Kubernetes Jobs for image builds
- `runner-rbac.yaml` — ServiceAccount, Role, RoleBinding for runner with
  minimal pod/job permissions for Kaniko job spawning
- `templates/networkpolicy.yaml` — NetworkPolicy for Gitea and Jenkins ingress;
  prevents silent wire job failure on default-deny clusters (Calico, Cilium)
- `networkPolicy.enabled: true` in values.yaml — on by default, safe to disable
- Release workflow: SBOM generation via Syft (`anchore/sbom-action`), cosign
  SBOM attestation, SLSA Level 2 provenance via `slsa-github-generator`
- `on: release: types: [published]` trigger in release.yaml — fixes Scorecard
  Packaging check
- `administration: read` permission on Scorecard job — fixes Branch-Protection `?`
- `docs/kaniko-builds.md` — comprehensive guide for Kaniko usage with Gitea Actions
- `docs/kaniko-migration.md` — upgrade guide from DinD to Kaniko

### Changed
- Runner hardened: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL`
  capabilities, `seccompProfile: RuntimeDefault` — passes restricted PSA
- Runner label changed from `ubuntu-latest:host` / `ubuntu-latest:docker` to
  `ubuntu-latest:kubernetes` — Kaniko mode
- `runner.mode` and `runner.dindImage` values removed (breaking change)
- `runner.capacity` added (default: 2) — configures max concurrent workflow runs
- `.trivyignore` restructured — all suppressions documented with rationale;
  "temporary" framing removed; subchart findings separated from intentional accepts

### Removed
- Docker-in-Docker sidecar — no privileged containers in any default mode
- `runner.mode` value (host | dind) — replaced by Kaniko architecture
- `runner.dindImage` value — no longer needed
- `KANIKO_REFACTORING.md` from repo root — content moved to docs/

### Breaking changes
- Workflows using `runs-on: ubuntu-latest` with Docker commands must migrate
  to Kaniko. See `docs/kaniko-migration.md`.
- `runner.mode` and `runner.dindImage` values removed — remove from any
  overrides before upgrading.

## [0.1.8] - 2026-04-03

### Fixed
- Runner DaemonSet: use NODE_NAME from downward API instead of hostname to
  prevent ghost runner accumulation on pod restart
- load.sh: registry mode now retags only bundled images (images.txt) instead
  of all images in local Docker daemon
- load.sh: replace deprecated --atomic with --rollback-on-failure

### Removed
- Generated chart tarballs from repo root (clusterfactory-0.1.4.tgz through
  0.1.7.tgz) — build artifacts do not belong in source

## [0.1.6] - 2026-04-03

### Added
- Helm test jobs (`templates/tests/`) asserting Gitea and Jenkins wiring after install
- k3d CI pipeline (`.github/workflows/test.yaml`) — full install + helm test on every push/PR
- Branch protection: `Lint and dry-run` and `Install and test (k3d)` required to merge

### Fixed
- `.helmignore`: exclude packaged `.tgz` artifacts from chart load to prevent Helm release
  secret exceeding the 1MB Kubernetes limit

## [0.1.5] - 2026-04-03

### Added
- `runner.mode` value (`host` | `dind`) — opt-in Docker-in-Docker sidecar for full
  container support in CI jobs
- `runner.dindImage` value (`docker:27-dind`) for airgap override
- DinD sidecar: `docker:dind` with `privileged` scoped to that container only;
  readiness probe on port 2375 gates pod ready state

### Changed
- `runner.labels` removed — labels are now derived from `runner.mode` to prevent
  host/dind label mismatch
- `act_runner` image bumped to `nightly`
- `container.network` in runner config set to `host` when `runner.mode=dind`

## [0.1.4] - 2026-04-03

### Added
- `persistence` top-level block (`enabled`, `storageClassName`, `size`)
- Pre-install preflight Job: fails fast with human-readable error when
  `persistence.enabled=true` but no usable StorageClass is found; lists available
  classes in the error output
- Preflight RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding) with hook-weight -11

### Changed
- `gitea.persistence` and `jenkins.persistence` default to `enabled: false` (emptyDir);
  eliminates silent PVC-pending hang on clusters with no default StorageClass

### Fixed
- Preflight RBAC delete policy set to `before-hook-creation` only — `hook-succeeded`
  on non-Job hook resources fires on apply (not job completion) and deleted RBAC before
  the preflight pod could use it

## [0.1.3] - 2026-04-02

### Changed
- Runner state moved from `hostPath` to `emptyDir`
- Gitea subchart updated to 11.0.1
- Jenkins subchart updated to 5.9.9
- Wire job: idempotent token and credential upsert on upgrade

### Added
- Airgap bundle support via `hack/bundle.sh`
- Supply chain hardening: LICENSE, SECURITY.md, Dependabot, pinned actions
- Security scanning: Trivy, OSSF Scorecard, Helm lint

## [0.1.2] - 2026-04-02

### Added
- hello-world repo: Jenkinsfile and Gitea Actions workflow pushed by wire job
- GitHub Pages Helm repository

## [0.1.0] - 2026-04-02

### Added
- Initial release
- Gitea + Jenkins installed via a single `helm install`
- Wire job: Gitea org, repo, Jenkinsfile, Actions workflow, Jenkins job and
  credentials created automatically on install
- Gitea Actions runner DaemonSet with init container registration flow
- hello-world pipeline runnable in both Jenkins and Gitea Actions
