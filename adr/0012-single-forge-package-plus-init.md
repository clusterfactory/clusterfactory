# 0012 — One forge package; the platform is the init package

**Status:** Accepted — 2026-09-21

## Context

§12 of the design doc left open whether to ship one package for the whole forge
or one package per app plus a bundle. Meanwhile the platform question (RKE2)
was answered by a custom Zarf init package (ADR 0015).

## Decision

- **One forge package** (`zarf.yaml`, components `preflight` + `clusterfactory`).
  The apps are wired together by design; shipping them apart would only move
  the ordering problem into a bundle file. Each app's chart block in
  `common/zarf.yaml` stays self-contained so a fork can still lift one out.
- **The platform is the init package**, and the init package also carries the
  forge (imports the root components after `zarf-agent`), so a bare host needs
  one file and one command. The forge-only package remains the artifact for
  clusters the customer brings and the upgrade path for everyone.
- **Policy is a third kind of package** (ADR 0016), deployed after the init
  and before/independently of the forge.

## Consequences

Two release artifacts (init all-in-one, forge-only) plus policy profiles; no
UDS bundle, no per-app packages. Versions are coupled inside the all-in-one;
every forge change ships a new ~2 GB file — accepted, it is the single-file
story's price.
