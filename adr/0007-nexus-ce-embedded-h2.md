# 0007 — Nexus Repository CE on the embedded H2 store, own helper chart

**Status:** Accepted (spike 2026-09-19)
**Date:** 2026-09-19

## Context

The demo needs an in-cluster Docker registry that Jenkins/Kaniko can push
to and that the pipeline pulls base images from. uds-way.md §6 proposed
Sonatype's `nxrm-ha` chart, single replica, Community Edition, backed by
an external Postgres, with "raw manifests + embedded H2" as the fallback.

`nxrm-ha` has no embedded-database mode; choosing it forces a Postgres
component (an operator, CRDs, 3–5 more images to mirror and audit) into
the package purely to satisfy the chart. Nothing else in the forge needs
Postgres - Gitea runs on SQLite by design.

## Spike result (kind + Calico, PSA `restricted`, egress denied)

`docker.io/sonatype/nexus3:3.96.2` (CE, H2):

- Boots and reports healthy in ~3 min with `runAsUser/fsGroup 200`,
  `runAsNonRoot`, seccomp `RuntimeDefault`, all capabilities dropped,
  no privilege escalation. Root filesystem must stay writable.
- `NEXUS_SECURITY_RANDOMPASSWORD=false` gives a known initial admin
  password; the wire engine rotates it to the cf-config Secret.
- REST API creates a `docker-hosted` repository (HTTP connector on 5000),
  a scoped role (`nx-repository-view-docker-docker-hosted-*`) and a deploy
  user; anonymous access can be disabled.
- The Docker connector answers 403 until **two** things are done via REST:
  the `DockerToken` realm is activated, and the **CE EULA is accepted**
  (`POST /service/rest/v1/system/eula`, `accepted: true`). After that:
  deploy user 200, anonymous/wrong password 401.

## Decision

- Ship **Nexus 3 Community Edition with the embedded H2 store**, single
  replica, as a small clusterfactory helper chart (`charts/nexus`:
  StatefulSet + Service + PVC, ~80 lines, PSA-restricted). The upstream
  *image* is unmodified; we own the chart because `nxrm-ha` does not fit
  and the archived community chart is unmaintained.
- No Postgres component (ADR 0008).
- The wire engine performs all Nexus setup (password rotation, realm,
  repo, role, user, anonymous off) idempotently.
- **EULA acceptance is an operator act, never a package default**: the
  Zarf variable `NEXUS_ACCEPT_CE_EULA` defaults to `false`; the wire
  engine fails with an explicit message until it is set to `true`. CI
  sets it. The EULA text URL is printed in that message.

## Consequences

- One image for the registry instead of five or six; no operator lifecycle.
- H2 is single-node and Sonatype recommends Postgres for production loads
  and for the CE component/request caps (3.77+). Documented in SECURITY.md
  and PREREQUISITES.md as a demo/small-team limitation. Moving to Postgres
  later is additive: a Postgres component plus a values change on the
  Nexus chart; cf-config and the wire engine are unaffected.
- Nexus needs ~1.5 GiB RAM; the CI kind node and the RKE2 sizing in
  PREREQUISITES.md account for it.
- Docker connector is plain HTTP on 5000 (ADR 0010); Kaniko pushes with
  `--insecure`.
