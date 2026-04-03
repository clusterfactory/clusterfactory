# Changelog

All notable changes to clusterfactory are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## Unreleased

<!-- PRs add entries here. Released versions move them to a versioned section. -->

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
