#!/usr/bin/env bash
# clusterfactory bootstrap
# Creates one pre-install secret then runs helm install.
# Works on any cluster — local or cloud.
#
# Usage:
#   bash bootstrap.sh [namespace]
#
# Override service type for cloud clusters:
#   bash bootstrap.sh clusterfactory
#   helm upgrade --install clusterfactory . --set serviceType=LoadBalancer

set -euo pipefail

NAMESPACE="${1:-clusterfactory}"
RELEASE="clusterfactory"

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in helm kubectl; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: no cluster reachable"; exit 1; }

# ── Namespace ──────────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── kubeconfig Secret ──────────────────────────────────────────────────────────
# This is the only thing that cannot be done from inside the cluster.
# The init job reads this Secret and patches the URL for its environment.
kubectl create secret generic "${RELEASE}-kubeconfig" \
  --namespace "$NAMESPACE" \
  --from-literal=kubeconfig="$(kubectl config view --minify --flatten)" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── cert-manager ───────────────────────────────────────────────────────────────
# If TLS_EMAIL is set, ensure cert-manager is installed before the main chart
# so ClusterIssuer CRDs are available when Helm renders them.
# If cert-manager is already in the cluster, skip installation entirely.
if [ -n "${TLS_EMAIL:-}" ]; then
  if kubectl get deployment cert-manager -n cert-manager --ignore-not-found 2>/dev/null | grep -q cert-manager; then
    echo "  Detected cert-manager — skipping installation"
  else
    echo "  Installing cert-manager (TLS_EMAIL set)..."
    helm repo add jetstack https://charts.jetstack.io --force-update > /dev/null
    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --set crds.enabled=true \
      --wait --timeout 5m
  fi
fi

# ── RKE2 detection ─────────────────────────────────────────────────────────────
# RKE2 ships rke2-ingress-nginx in kube-system. If it's already running we must
# skip deploying our own ingress-nginx to avoid an IngressClass "nginx" conflict.
# RKE2's controller binds hostPort 80/443, so accessPort=80 instead of 30080.
EXTRA_ARGS=""
if kubectl get daemonset rke2-ingress-nginx-controller -n kube-system \
     --ignore-not-found 2>/dev/null | grep -q rke2-ingress-nginx-controller; then
  echo "  Detected rke2-ingress-nginx — skipping bundled ingress-nginx controller (accessPort=80)"
  EXTRA_ARGS="--set ingress-nginx.enabled=false --set accessPort=80 --set runner.dockerSocket="
fi

# ── Helm install ───────────────────────────────────────────────────────────────
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${CHART_DIR}/charts" ] || [ -z "$(ls -A "${CHART_DIR}/charts" 2>/dev/null)" ]; then
  helm dependency update "$CHART_DIR"
fi

# TLS flags passed through to helm when TLS_EMAIL is set
if [ -n "${TLS_EMAIL:-}" ]; then
  TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
  EXTRA_ARGS="$EXTRA_ARGS --set tls.enabled=true --set tls.email=${TLS_EMAIL} --set tls.issuer=${TLS_ISSUER} --set accessPort=443"
fi

# shellcheck disable=SC2086
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --timeout 30m \
  --wait \
  $EXTRA_ARGS

echo ""
echo "  done — run: kubectl logs job/${RELEASE}-summary -n ${NAMESPACE}"
