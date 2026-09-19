# 0005 — Trusted-operator threat model; CHANGEME defaults acceptable

**Status:** Accepted
**Date:** 2026-09-18

## Context

The package is deployed by an operator who already holds cluster-admin
`kubectl` on an airgapped cluster. Anyone with that access can read every
Secret, exec into every pod and rewrite every NetworkPolicy. Building
credential-secrecy machinery (sealed secrets, external secret stores,
prompt-only passwords) adds moving parts without changing who can read
what.

## Decision

- The threat model is **trusted operator, untrusted network**. We defend
  the cluster boundary (deny-all egress, PSA, CIS profile), not the
  operator.
- Admin passwords for Gitea / Jenkins / Nexus / Postgres are created by
  `charts/config` from values; `CHANGEME`-style defaults are acceptable and
  documented. Operators override them with `--set` / a values file.
- No credential-secrecy machinery: no vault integration, no sealed
  secrets, no interactive prompts required for deploy.

## Consequences

- SECURITY.md states this plainly, including what is and is not enforced.
- Anything that *does* need secrecy from a less-privileged party (e.g. a
  future multi-tenant mode) is out of scope and would need a new ADR.
- The `GITEA_ADMIN_PASSWORD` `prompt: true` variable from v0.3 is retired
  in favour of values-driven Secrets with overridable defaults.
