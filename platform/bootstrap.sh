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

# ── Kubeconfig ─────────────────────────────────────────────────────────────────
# When running in SSM RunShellScript, HOME may be unset. Fall back to the RKE2
# kubeconfig so kubectl/helm work regardless of how the script is invoked.
if [ -z "${KUBECONFIG:-}" ]; then
  if   [ -f /root/.kube/config ];              then export KUBECONFIG=/root/.kube/config
  elif [ -f /etc/rancher/rke2/rke2.yaml ];     then export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  elif [ -f /etc/rancher/k3s/k3s.yaml ];       then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
fi

# ── Credentials ────────────────────────────────────────────────────────────────
# Generate secure credentials if not already provided via environment variables.
GITEA_PASS="${GITEA_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
HARBOR_PASS="${HARBOR_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
COCKPIT_TOKEN="${COCKPIT_TOKEN:-$(openssl rand -hex 32)}"

echo "  Credentials (save these):"
echo "    GITEA_PASS=$GITEA_PASS"
echo "    HARBOR_PASS=$HARBOR_PASS"
echo "    COCKPIT_TOKEN=$COCKPIT_TOKEN"
echo ""

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

# ── ArgoCD CRDs ────────────────────────────────────────────────────────────────
# ArgoCD's CRD YAMLs (applicationset alone is 1MB+) push the Helm release
# secret over K8s's 1MB limit. We install them via kubectl before the main
# chart and set crds.install=false inside the chart to skip re-rendering them.
ARGOCD_VERSION="$(helm show chart "${CHART_DIR}/charts/argo-cd-"*.tgz 2>/dev/null | awk '/^appVersion:/{print $2}' | head -1)"
if [ -n "$ARGOCD_VERSION" ]; then
  echo "  Installing ArgoCD CRDs (v${ARGOCD_VERSION})..."
  ARGOCD_CRD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/crds"
  for crd in application applicationset appproject; do
    kubectl apply -f "${ARGOCD_CRD_URL}/${crd}-crd.yaml" --server-side 2>/dev/null || \
    kubectl apply -f "${ARGOCD_CRD_URL}/${crd}-crd.yaml" 2>/dev/null || true
  done
fi

# TLS flags passed through to helm when TLS_EMAIL is set
if [ -n "${TLS_EMAIL:-}" ]; then
  TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
  EXTRA_ARGS="$EXTRA_ARGS --set tls.enabled=true --set tls.email=${TLS_EMAIL} --set tls.issuer=${TLS_ISSUER} --set accessPort=443"
fi

EXTRA_ARGS="$EXTRA_ARGS --set gitea.gitea.admin.password=${GITEA_PASS} --set harbor.harborAdminPassword=${HARBOR_PASS} --set cockpit.token=${COCKPIT_TOKEN}"

# shellcheck disable=SC2086
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --timeout 30m \
  --wait \
  $EXTRA_ARGS

echo ""
echo "  done — run: kubectl logs job/${RELEASE}-summary -n ${NAMESPACE}"
