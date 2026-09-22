# 0013 — Argo CD as an optional component

**Status:** Proposed (implementation scheduled after Nexus, docs/roadmap.md)
**Date:** 2026-09-18

## Context

Nexus and Jenkins cover build and artifact storage; the forge has no
deployment leg. Argo CD is the de-facto GitOps deployer, has an upstream
chart (`https://argoproj.github.io/argo-helm`, chart `argo-cd`) and freely
pullable images, and works fully airgapped once its repo sources are
in-cluster (Gitea).

## Decision

- Ship Argo CD as a **separate, optional Zarf component** `argocd`
  (`required: false`) in `common/zarf.yaml`, deploying the upstream
  `argo-cd` chart into namespace `argocd`. Same flavor rules as everything
  else: images pinned by digest in the flavor `images:` list; no custom
  images.
- Wire-engine steps (idempotent, only run when the component is present):
  ensure Gitea is registered as a repository credential in Argo CD, ensure
  a demo `Application` pointing at `cf-demo/hello-world` (a `deploy/`
  directory the Jenkins pipeline updates with the image it pushed to
  Nexus).
- Values: `dex` and `notifications` disabled; `server.insecure: true`
  (plain HTTP + port-forward, ADR 0010); update checks off; PSA
  `restricted`-compatible securityContexts.
- Gitea → Argo CD: Argo CD polls Gitea (default 3 min) — no webhook needed;
  `NetworkPolicy` allows `argocd` → Gitea only.

## Consequences

- Deploy order becomes: cf-config, postgresql, gitea, jenkins, nexus,
  argocd (optional), cf-settings.
- Adds roughly 3 images (argocd, redis, dex is disabled) to the package.
- The demo becomes end-to-end: push → Jenkins/Kaniko build → Nexus →
  Argo CD sync. A separate `argocd` demo namespace is created by
  `cf-config` at PSA `restricted`.
- Optional means the wire engine must tolerate Argo CD being absent
  (feature flag in `values/common-values.yaml`).
