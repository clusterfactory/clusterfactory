# 0016 — Policy profiles as separate, forkable packages

**Status:** Accepted
**Date:** 2026-09-20

## Context

ADR 0014 separates what is *permitted* (customer policy) from what the
platform *is* and what the forge *needs*. Policy must be replaceable
without touching the forge or the init package.

## Decision

- `policy/<profile>/zarf.yaml` builds `clusterfactory-policy-<profile>`.
  Shipped examples: **`baseline`** (PSA `restricted` cluster-wide with
  `cf-build` at `baseline`, deny-all egress in application namespaces with
  the API server allowed, internet reachable is a warning) and **`cis`**
  (`profile: cis` drop-in for RKE2, `etcd` user + sysctls, audit policy,
  SELinux enforcing expected, internet reachable is a failure).
- A profile contains: the RKE2 `50-policy.yaml` drop-in (applied by the init
  package from `POLICY_PROFILE`), in-cluster manifests (NetworkPolicy
  denies, PSA labels/exemptions beyond the forge's own namespaces, audit
  policy), and a `profile.yaml` that preflight reads to classify checks.
- **The forge ships only allow rules**; every deny lives in the profile. The
  forge's own namespaces are labelled by `cf-config`; the profile may
  tighten but not loosen them.
- Customers fork a profile; the examples are documentation as much as code.

## Consequences

- CI deploys the `baseline` profile before the forge so the egress test
  remains meaningful; a matrix entry runs `cis` on the RKE2 gate.
- `charts/config` loses its deny policies (moved to `policy/baseline`),
  keeps namespaces, PSA labels, Secrets and allow rules.
- A deployment without any profile is valid and unhardened - by the
  customer's choice, visibly.
