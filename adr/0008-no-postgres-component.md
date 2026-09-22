# 0008 — No Postgres component (deferred until a real need)

**Status:** Accepted
**Date:** 2026-09-19

## Context

docs/design.md §6 asked for a Postgres chart choice (CloudNativePG, Zalando
operator or Bitnami) because the `nxrm-ha` chart requires an external
database. ADR 0007 replaces `nxrm-ha` with Nexus CE on its embedded H2
store, and Gitea runs on SQLite. No component in the package needs
Postgres.

## Decision

Do not ship a Postgres component. Do not pre-select an operator.

When a real need appears (Nexus outgrowing H2, Gitea needing Postgres for
scale, or a new component that requires it), evaluate in this order,
recording the result in a superseding ADR:

1. **CloudNativePG** - actively maintained, freely pullable images, a
   single-instance `Cluster` CR is tiny; most images to mirror.
2. **Zalando postgres-operator** - what the UDS ecosystem packages
   (`ghcr.io/uds-packages/postgres-operator`); proven in airgap.
3. **Bitnami `postgresql`** - only if its images are still freely
   pullable; Bitnami changed distribution in 2025.

## Consequences

- Smaller package, smaller SBOM and OSCAL surface, one fewer thing to
  wire and upgrade.
- The seam stays open: `common/zarf.yaml` reserves slot 2 (after
  `cf-config`) for a database component, and the Nexus chart takes its
  datastore settings from values.
