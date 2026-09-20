# 0010 — Plain HTTP in-cluster + `kubectl port-forward`; cert-manager as upgrade path

**Status:** Accepted (amended 2026-09-20)
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

## Amendment 2026-09-20 (ADR 0014, Q6)

On RKE2 the bundled ingress controller costs no extra images: RKE2 ≥ v1.36
defaults to Traefik (ingress-nginx is removed in v1.37), bound to hostPort
80/443 on the single node. v0.4 ships **plain HTTP `Ingress` by hostname**
for Gitea, Jenkins and Nexus (and the Nexus Docker connector) in addition
to port-forward, which stays the fallback and the only path on clusters
without an ingress controller. TLS is a v0.5 item and belongs to the policy
profile (customer CA or self-signed, injected into Jenkins and Kaniko
trust). `disable: rke2-ingress-nginx` in the platform config is replaced by
keeping Traefik enabled.

## Consequences

- Documented upgrade path: cert-manager with a cluster-internal CA, its
  images added to the flavor `images:` list, and the CA injected into
  Jenkins/Kaniko trust stores. Not scheduled.
- SECURITY.md lists "no TLS in-cluster" as a known, accepted gap.
