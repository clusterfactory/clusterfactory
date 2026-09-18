# 0006 — Jenkins plugins via pre-bundled volume, `installPlugins: []`

**Status:** Accepted
**Date:** 2026-09-18

## Context

The Jenkins chart's `installPlugins` downloads from the update centre at
startup, which is impossible airgapped. v0.3 worked around it by baking
plugins into a custom Jenkins image (`images/jenkins/Dockerfile.wire`),
violating the "unmodified upstream images" principle (ADR 0001).

## Decision

- `jenkins/plugins.txt` pins exact versions of the plugins the demo
  needs (`gitea`, `workflow-aggregator`, `kubernetes`,
  `credentials-binding`, `git`, ...).
- `make plugins` runs `jenkins-plugin-cli` in a throwaway container on
  the connected side to resolve the full transitive closure into
  `jenkins/plugins/`.
- The closure is shipped as a **data-only OCI image** (`jenkins/Dockerfile`:
  busybox + `/plugins`, tag = package version, built into the local Docker
  daemon at `zarf package create` time and never pushed). An init container
  from that image copies the `.jpi` files into an `emptyDir` mounted at
  `$JENKINS_HOME/plugins` on every pod start.
  *Amended 2026-09-18:* the original plan (`files:` + Zarf `dataInjections`
  into a PVC) was dropped because Zarf deprecates `dataInjections` and
  recommends exactly this image-based delivery. This is the one image the
  repo builds; it carries no application code and is derived
  deterministically from `plugins.txt` / `plugins.lock`.
- Upstream chart values: `controller.installPlugins: []`,
  `controller.initializeOnce: true`, update centre disabled.
- CI gate: Jenkins must reach Ready in an egress-blocked cluster with
  every plugin in `plugins.txt` reported loaded
  (`/pluginManager/api/json`).

## Consequences

- The Jenkins image is exactly `jenkins/jenkins:<tag>@sha256:...` from
  upstream.
- A missing transitive plugin only surfaces at boot in the airgapped
  cluster — the CI gate exists to catch exactly that.
- Plugin bumps are a Renovate PR against `plugins.txt` followed by a
  regenerated closure.
