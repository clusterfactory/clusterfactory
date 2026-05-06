# Composing platforms with Helm

How ClusterFactory glues two upstream charts (Gitea, Jenkins) into a working CI/CD platform — and why each convention is the way it is. If you're building a similar meta-chart for a different stack (Gitea + Argo + Vault, Postgres + Redis + your-app, whatever), these conventions transfer.

This document is descriptive, not prescriptive. It's a worked pattern, not a standard.

## The problem

Helm installs charts. Charts install applications. But a *platform* is N charts that have to know about each other — Gitea has a webhook that points at Jenkins, Jenkins has a credential that talks to Gitea, the runner has a registration token minted by Gitea. None of that is in any of the upstream charts because none of them know about the others.

Most teams handle this with runbooks: "after `helm install`, do these 12 manual steps." The runbook works until the person who wrote it leaves, the cluster gets recreated, or someone runs the steps in the wrong order. The common failure mode is "all pods are running, none of the wiring works."

ClusterFactory's claim is that the wiring should be part of the chart and should run automatically. The conventions below are how.

## The six conventions

### 1. Preflight Job validates the contract

Runs as a `pre-install,pre-upgrade` hook with weight `-5`. Asserts what the rest of the chart relies on: Kubernetes version, mode validity, anything else that's cheap to check and expensive to discover late.

The preflight does not install anything. It exits 0 or 1. If it exits 1, the install fails before any subchart resources are created — which means no half-installed mess to clean up.

See `templates/preflight-job.yaml`. Keep it short. The temptation to put more checks here is real and worth resisting; preflight is for things that, if wrong, mean the rest of the chart cannot possibly work.

### 2. Subchart deps via standard `Chart.yaml`, conditionally enabled

Don't fork upstream charts. Don't vendor them. Pin them by version in `Chart.yaml`'s `dependencies:` and let upstream maintain upstream:

```yaml
dependencies:
  - name: gitea
    version: "11.0.1"
    repository: "https://dl.gitea.com/charts/"
    condition: gitea.enabled
  - name: jenkins
    version: "5.9.9"
    repository: "https://charts.jenkins.io"
    condition: jenkins.enabled
```

The `condition` field is what makes mode-driven enablement possible — set `gitea.enabled: false` and the entire Gitea subchart vanishes from the install.

When upstream releases a new version with breaking changes, you bump in lockstep, run the test matrix, and decide. This is more work than vendoring, but vendoring is a tax you pay forever.

### 3. One user-facing knob, derived booleans for the subcharts

The user sets `mode: gitea-actions | jenkins | both`. The chart derives everything else:

```
| mode           | gitea | jenkins | runner | gitea actions |
| gitea-actions  |   ✓   |    ✗    |   ✓    |     true      |
| jenkins        |   ✓   |    ✓    |   ✗    |     false     |
| both           |   ✓   |    ✓    |   ✓    |     true      |
```

See `templates/_mode-helpers.tpl` for the derivation logic and `_mode-helpers.tpl`'s `validate` for the consistency check that fails the install fast if the user passed contradictory flags.

The reason for the consistency check, rather than just deriving everything: subchart `condition` flags can't be set from a parent template — they're evaluated by Helm before templates render. So `jenkins.enabled` must be set by the user (or by a values file), and the chart's job is to refuse to install if `mode` and `jenkins.enabled` disagree. The error message tells the user exactly what to do.

### 4. Wiring is a post-install Job, not a sidecar, not an Operator

Runs as `post-install,post-upgrade` hook with weight `0`. Single Job. Idempotent. The wiring script is a real file (`files/wire.sh`) mounted via ConfigMap, not a heredoc inside a Helm template — so it can be `shellcheck`-ed, run locally for development, and read without squinting through `{{- }}` syntax.

Why not a sidecar? Sidecars run continuously. Wiring is a one-shot operation. Continuous reconciliation against runtime drift is a different (harder) problem and not what the chart is solving.

Why not an Operator? Operators are appropriate when the wiring needs to react to ongoing events. ClusterFactory's wiring needs to happen once, at install/upgrade. An Operator would be a permanent ongoing cost paid for a one-time benefit.

The script's contract:
- Reads all input from environment variables.
- Idempotent — re-running it on an already-wired cluster produces the same result. Existing tokens are revoked and reissued, existing webhooks are removed and recreated, existing repos are reused.
- Branches on `MODE`. The same script handles all three modes; mode-specific steps are guarded by `case "$MODE" in ... esac` rather than separate scripts.
- Exits non-zero on any failure with a clear log line.
- Emits a structural hash to a ConfigMap as the wiring receipt.

See `files/wire.sh` and `templates/wire-job.yaml`.

### 5. The parent chart owns cross-subchart secrets

The Gitea admin password is created once by the parent chart in `templates/gitea-admin-secret.yaml`. Gitea is told to read it via `gitea.gitea.admin.existingSecret`. The wire Job reads it via `secretKeyRef`. The user never sees a secret-passing dance.

Why this matters: if Gitea generated its own admin password (the subchart's default behavior), the wire Job would have no way to retrieve it without scraping Gitea's logs or polling its secrets — both fragile. Centralizing secret ownership in the parent chart makes wiring straightforward.

The Jenkins admin password is the inverse case: Jenkins generates it (we don't override), and the wire Job reads `<release>-jenkins / jenkins-admin-password`. Same principle, different direction. The point is that *somebody* owns each shared secret unambiguously.

### 6. Helm tests verify functional wiring, not pod readiness

`kubectl get pod` already tells you pods are running. Helm tests should tell you the platform *works*. ClusterFactory's tests:

- Hit Gitea's API with the admin credential. Confirm the bootstrap org and repo exist.
- Hit Jenkins's API. Confirm the bootstrap job exists.
- Query Gitea's runner registration list. Confirm a runner registered.

A passing `helm test cf` means the wiring script did its job, not just that the Helm install command exited 0.

See `templates/tests/`. The tests use the same minimal `alpine/curl` image as the wire Job — no test-specific image to maintain.

## The wiring receipt

The wire Job emits a `cf-wire-result` ConfigMap containing a `structural_sha`: a sha256 of the sorted list of `producer:consumer:kind` tuples for every wire performed.

Two installs of the same mode produce the same `structural_sha`, regardless of admin password or generated tokens — because the hash is over the *topology* of the wiring, not the secret values. Same graph, same hash.

This is not a signed attestation and is not an audit artifact in any formal sense. It's a small, cheap diagnostic: a way to ask "did this install wire what I expected?" and get a yes/no without reading 200 lines of log.

If the receipt becomes useful enough to your environment to want signing, in-toto attestation, or a richer schema, the place to extend is the `upsert_result_configmap` function in `wire.sh` and the script's `record_wire` calls.

## Airgap as wrapper, not architecture

Zarf packages this chart and its image dependencies into a signed tarball. `zarf package deploy` stands up an in-cluster registry, mirrors the images, and runs the install with `--values values-airgap.yaml` to set `pullPolicy: IfNotPresent`.

Nothing in the chart itself knows about airgap. The chart works connected; Zarf adds airgap delivery as a layer on top. This is the right separation of concerns — `helm install` should not care whether the cluster has internet, only whether the images it asks for are present.

See `zarf.yaml` and `docs/airgap.md`.

## When to extend, when to rewrite

If you reach 5+ components with non-trivial credential graphs (e.g., Gitea → Vault → Jenkins, where Vault both produces and consumes credentials), the bash wire script becomes painful. At that point a typed-component abstraction earns its keep.

The shape that abstraction should take is in the parked v0.3 code under `engine/` — `Component`, `Credential`, `Planner`, `Executor`, `Verifier`, `Hasher`. The primitives are right; what made v0.3 wrong was shipping them when the graph was two nodes and one edge. Don't rebuild that engine if you outgrow bash; resurrect it.

The criterion for "outgrew bash" is concrete: you can't write the wire script idempotently in under 500 lines of POSIX sh, or you have credential dependencies that need real topological sorting (a credential's production depends on another credential being injected first). Until then, bash is honest.

## What this pattern is not

- **Not a standard.** No spec, no registry, no governance. A documented working example.
- **Not a framework.** No abstractions to import. Copy the conventions you find useful.
- **Not airgap-specific.** Works connected. Zarf wraps it for airgap; the conventions don't change.
- **Not specific to CI/CD.** The same shape applies to any composition where N upstream charts need to be wired together to be functional.

## See also

- `Chart.yaml` — subchart deps with conditions
- `values.yaml` — single mode knob plus pass-through subchart values
- `values.schema.json` — fail-fast validation
- `templates/_mode-helpers.tpl` — derivation and consistency checking
- `templates/preflight-job.yaml` — contract validation
- `templates/gitea-admin-secret.yaml` — parent-owned shared secret
- `templates/wire-job.yaml`, `templates/wire-rbac.yaml`, `templates/wire-script-cm.yaml` — the post-install wiring trio
- `files/wire.sh` — the actual wiring logic, lintable as a script
- `templates/tests/` — functional wiring tests
- `zarf.yaml` — airgap wrapper
