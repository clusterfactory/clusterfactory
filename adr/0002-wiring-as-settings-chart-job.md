# 0002 — Wiring as a settings-chart Job; logic in Python, never in Helm

**Status:** Accepted
**Date:** 2026-09-18

## Context

Cross-service wiring (Gitea org/repo/token → Jenkins credential/job →
Nexus repo/user → base-image pre-seed) previously lived partly in a custom
Jenkins image and partly in a Python engine run from the operator's
workstation. Neither is acceptable in a package that must be deployable
from a single `.tar.zst` in an airgapped cluster by an operator with only
`zarf` and `kubectl`.

## Decision

Wiring is a **post-deploy, in-cluster, idempotent Kubernetes `Job`**,
delivered as the `charts/settings` Helm chart whose only responsibility is
to template the Job manifest and its RBAC. All wiring **logic** lives in
Python (`wire-engine/wire.py`) inside the Job's image:

- Image is `python:3.x-slim`, stdlib only (`urllib`, `json`, `base64`),
  **no pip** — nothing to mirror.
- Every step is check-then-act; re-runs log only `ok`/`skipped`.
- Gitea API tokens are not re-readable, so the Job persists the token it
  creates in a Kubernetes Secret it owns and reuses it.
- `common/zarf.yaml` gates on the Job with `wait: condition: complete` and
  dumps its logs `onFailure`; `zarf package deploy` fails loudly if wiring
  does not converge.
- Re-deploy runs `helm upgrade` per chart and recreates the Job (a
  release-revision annotation forces a spec change if Helm would not).

Never put wiring logic in Helm templates or Helm hooks.

## Consequences

- "Vanilla upstream Jenkins/Gitea/Nexus" is literally true; the only
  clusterfactory-authored runtime code is one Python file.
- Debugging is `kubectl logs job/cf-wire-engine`.
- No long-lived controller, no operator, no CRDs.
- Idempotency is a hard requirement and is CI-gated (second deploy must
  yield only `ok`/`skipped`).
