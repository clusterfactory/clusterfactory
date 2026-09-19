# 0010 — Plain HTTP in-cluster + `kubectl port-forward`; cert-manager as upgrade path

**Status:** Accepted
**Date:** 2026-09-18

## Context

Gitea, Jenkins and Nexus talk to each other over cluster-internal Service
DNS; the operator reaches them via port-forward. Adding TLS means a CA,
cert-manager, trust distribution into Jenkins agents and Kaniko, and an
ingress controller — none of which the demo needs and all of which must
also work airgapped.

## Decision

- All in-cluster traffic is plain HTTP on ClusterIP Services; no Ingress
  is shipped (`rke2-ingress-nginx` is disabled in the platform layer).
- Operator access is `kubectl port-forward`, documented in the README.
- Kaniko pushes with `--insecure --skip-tls-verify` to the Nexus Docker
  connector.
- This is accepted under the trusted-operator threat model (ADR 0005):
  the attacker who can sniff pod-to-pod traffic already has node access.

## Consequences

- Documented upgrade path: cert-manager with a cluster-internal CA, its
  images added to the flavor `images:` list, and the CA injected into
  Jenkins/Kaniko trust stores. Not scheduled.
- SECURITY.md lists "no TLS in-cluster" as a known, accepted gap.
