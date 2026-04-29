# Changelog

## v0.4.0 — clean-room rewrite, bash wiring only

Breaking simplification. The v0.3 Python wire engine was an interesting experiment but added cost without earning it at the current scale (two components, one wire). v0.4.0 reverts to a single bash post-install Job for wiring and treats Zarf as a thin airgap wrapper rather than a primary architectural concern.

### Changed
- Wiring is now a single `files/wire.sh` script, mounted into a post-install Job via ConfigMap. POSIX sh, idempotent, no Python.
- One user-facing knob: `mode` (`gitea-actions` | `jenkins` | `both`). Subchart enablement and runner enablement are derived.
- `values.schema.json` validates `mode` and requires `giteaAdmin.password` to be set explicitly. No default password.
- The wiring receipt (structural sha of `producer:consumer:credential_kind` tuples) is preserved in bash and written to the `cf-wire-result` ConfigMap.
- CI: integration test now waits for Gitea as a Deployment and Jenkins as a StatefulSet (Gitea v11.x has no StatefulSet template — the v0.3 CI was structurally wrong).

### Removed
- Python wire engine and its container image.
- `wire.engine` value selector.
- `manifests/platform-configmap.yaml` and other templates that existed only to feed the Python engine.
- v0.3 design documents that no longer reflect the product (moved to `docs/archive/` if kept at all).

### Added
- `docs/composing-platforms.md` — the conventions used here, written as a discipline rather than a standard.
- `docs/airgap.md` — Zarf packaging and airgap deployment.
- helm tests that verify functional wiring (org/repo exist, Jenkins job exists, runner registered) rather than just pod readiness.

## v0.3.x

v0.3 introduced a Python wire engine with a typed Component abstraction, a structural-sha hasher, and a separate container image. The architecture was sound for a much larger graph; for two components it was overkill. v0.4 keeps the structural-sha idea, drops the rest.

## v0.2.x

Original architecture: Helm chart with bash post-install hook. v0.4.0 returns to this shape.
