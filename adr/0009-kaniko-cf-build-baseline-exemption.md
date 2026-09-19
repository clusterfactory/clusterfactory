# 0009 — Kaniko + `cf-build` namespace at PSA `baseline` (declared exemption)

**Status:** Accepted
**Date:** 2026-09-18

## Context

The demo pipeline must build a container image in-cluster with no Docker
daemon and no egress. Kaniko (`gcr.io/kaniko-project/executor`) does this
but runs as uid 0 and writes to `/`, which violates PSA `restricted`
(`RequireNonRootUser`, `readOnlyRootFilesystem` conflicts).

## Decision

- Kaniko executor pinned by digest in the flavor `images:` list.
- Jenkins Kubernetes plugin runs builds as pod agents in namespace
  `cf-build`, labelled PSA **`baseline`** (not `privileged`). The Nexus
  credential is mounted as `/kaniko/.docker/config.json`.
- Kaniko pods: uid 0 with the runtime-default capability set (nothing
  added; `drop: ALL` leaves root unable to write the workspace or extract
  layers). No privileged, no hostPath, no ServiceAccount token, seccomp
  `RuntimeDefault`, root fs writable (Kaniko needs `/` and `/kaniko`).
- `NetworkPolicy` on `cf-build` allows egress only to Gitea and Nexus.
- Demo Dockerfile pulls `FROM nexus-docker.clusterfactory.svc:<port>/alpine`
  — never Docker Hub. Nexus is the only registry the pipeline knows.
- The exemption is recorded in `docs/exemptions/kaniko.md` (title, scope,
  justification, review date), modelled on UDS Core's `Exemption` pattern.

## Consequences

- One namespace in the cluster is `baseline` instead of `restricted`, and
  that fact is written down where an assessor will find it.
- **Supply risk:** the executor is published only on `gcr.io`, which Google is
  retiring in favour of Artifact Registry; package *creation* pulls it from
  there (deployment never does). If the pull starts failing, mirror the pinned
  digest into a registry we control or move to the alternative below.
- **Recorded alternative:** `ko` / Jib / `apko` need no root and would
  remove the exemption at the cost of a language-specific demo. Revisit if
  the exemption becomes a blocker for an assessor.
