# 0003 — Upstream flavor only; flavor = image provenance

**Status:** Accepted
**Date:** 2026-09-18

## Context

Consumers in regulated environments will eventually want hardened images
(Iron Bank / registry1, Chainguard). UDS packages express this with Zarf
**flavors**: one root component per flavor, each importing the same
`common/zarf.yaml`. Previous clusterfactory "deployment modes" conflated
image source with behaviour.

## Decision

- **Flavor = image provenance only.** Behaviour, charts, deploy order and
  wiring are identical across flavors. Only `values/<flavor>-values.yaml`
  and the root component's `images:` list change per flavor.
- Ship **`upstream` flavor only** now. The seam (`only.flavor`, per-flavor
  values file) exists so `registry1` / `chainguard` can be added without
  touching `common/`.
- Every image is pinned by digest (`repo:tag@sha256:...`) in both the
  flavor values file and the `images:` list; Renovate keeps them current.

## Consequences

- Adding a flavor is: one values file, one root component, one CI matrix
  entry. Documented in CONTRIBUTING.md.
- "Deployment modes" (Gitea Actions vs Jenkins, etc.) are **not** flavors;
  if they return they are deploy-time variables or bundle overrides
  (see ADR 0012).
- `zarf package create . -f upstream` is the only build until a second
  flavor is requested.
