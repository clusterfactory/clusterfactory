# 0001 — Adopt UDS package anatomy without UDS Core

**Status:** Accepted
**Date:** 2026-09-18

## Context

clusterfactory was one monolithic `zarf.yaml` wrapping a root umbrella Helm
chart (Gitea + Jenkins as dependencies), with cross-service wiring baked
into a custom Jenkins image and a Python engine run from the operator's
machine after deploy. Three structural problems followed:

1. No separation between unmodified upstream and clusterfactory glue —
   every customization was a diff against upstream charts.
2. No seam for alternate image sources (hardened / Iron Bank / Chainguard)
   without editing values in place.
3. Wiring lived in an image build, so "vanilla upstream Jenkins" was not
   actually true.

Defense Unicorns' UDS packages have solved exactly this shape of problem
over years of airgapped deployments: a root `zarf.yaml` with one component
per flavor importing a flavor-agnostic `common/zarf.yaml`; per-flavor
values files; `config` and `settings` helper charts around unmodified
upstream charts.

## Decision

Adopt the UDS package **repo anatomy and conventions** only:

```
zarf.yaml            root: variables + one component per flavor importing common/
common/zarf.yaml     flavor-agnostic: charts in order, healthChecks, actions
charts/config        helper chart deployed BEFORE the apps
charts/settings      helper chart deployed AFTER the apps
values/common-values.yaml, values/<flavor>-values.yaml
```

UDS Core, Istio, the UDS Operator, `Package` CRs and `Exemption` CRs are
**not** dependencies. Where the UDS pattern is a poor fit for a lightweight
Gitea + Jenkins + Nexus forge, the design doc (`uds-way.md`) says so and
what we do instead.

## Consequences

- The package contains only unmodified upstream charts and images plus our
  values and helper charts. No custom application image builds. If a
  component works only because CI had internet, it is a bug.
- Contributors familiar with UDS packages can navigate the repo without
  a tour; the reference material is public.
- The umbrella chart (`Chart.yaml`, `values.yaml`, `templates/`), both
  `Dockerfile.wire` files and the structural-SHA code paths are deleted
  during migration.
- We carry the UDS conventions ourselves; there is no shared tooling
  (`uds-common` tasks) to lean on unless ADR 0012 chooses the bundle route.
