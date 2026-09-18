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
- A Zarf component `jenkins-plugins` ships that directory as `files:`
  into a PVC via an initContainer (ConfigMaps are too small), mounted at
  `$JENKINS_HOME/plugins`.
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
