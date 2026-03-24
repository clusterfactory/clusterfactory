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

# ── Helm install ───────────────────────────────────────────────────────────────
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${CHART_DIR}/charts" ] || [ -z "$(ls -A "${CHART_DIR}/charts" 2>/dev/null)" ]; then
  helm dependency update "$CHART_DIR"
fi

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --timeout 30m \
  --wait

echo ""
echo "  done — run: kubectl logs job/${RELEASE}-summary -n ${NAMESPACE}"
