#!/usr/bin/env bash
# clusterfactory bootstrap — two-phase install
#
# Phase 1: Installs Gitea + act_runner + Cockpit + Headlamp + Ingress
# Phase 2: Calls Gitea API to push the install-platform.yaml workflow,
#          which installs ArgoCD, Harbor, OpenBao, and Crossplane via
#          Gitea Actions running on the act_runner inside the cluster.
#
# Usage:
#   bash bootstrap.sh [namespace]
#
# Environment variables (optional overrides):
#   GITEA_PASS      — Gitea admin password (generated if not set)
#   HARBOR_PASS     — Harbor admin password (generated if not set)
#   COCKPIT_TOKEN   — Cockpit WebSocket auth token (generated if not set)

set -euo pipefail

NAMESPACE="${1:-clusterfactory}"
RELEASE="clusterfactory"

# ── Kubeconfig ─────────────────────────────────────────────────────────────────
# When running in SSM RunShellScript, HOME may be unset. Fall back to the RKE2
# kubeconfig so kubectl/helm work regardless of how the script is invoked.
if [ -z "${KUBECONFIG:-}" ]; then
  if   [ -f /root/.kube/config ];           then export KUBECONFIG=/root/.kube/config
  elif [ -f /etc/rancher/rke2/rke2.yaml ];  then export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  elif [ -f /etc/rancher/k3s/k3s.yaml ];    then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
fi

# ── Credentials ────────────────────────────────────────────────────────────────
GITEA_PASS="${GITEA_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
HARBOR_PASS="${HARBOR_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
COCKPIT_TOKEN="${COCKPIT_TOKEN:-$(openssl rand -hex 32)}"

echo "  Credentials (save these):"
echo "    GITEA_PASS=$GITEA_PASS"
echo "    HARBOR_PASS=$HARBOR_PASS"
echo "    COCKPIT_TOKEN=$COCKPIT_TOKEN"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in helm kubectl curl jq; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: no cluster reachable"; exit 1; }

# ── Namespace ──────────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── cert-manager ───────────────────────────────────────────────────────────────
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
EXTRA_ARGS=""
if kubectl get daemonset rke2-ingress-nginx-controller -n kube-system \
     --ignore-not-found 2>/dev/null | grep -q rke2-ingress-nginx-controller; then
  echo "  Detected rke2-ingress-nginx — skipping bundled ingress-nginx (accessPort=80)"
  EXTRA_ARGS="--set ingress-nginx.enabled=false --set accessPort=80"
fi

# TLS flags
if [ -n "${TLS_EMAIL:-}" ]; then
  TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
  EXTRA_ARGS="$EXTRA_ARGS --set tls.enabled=true --set tls.email=${TLS_EMAIL} --set tls.issuer=${TLS_ISSUER} --set accessPort=443"
fi

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${CHART_DIR}/charts" ] || [ -z "$(ls -A "${CHART_DIR}/charts" 2>/dev/null)" ]; then
  helm dependency update "$CHART_DIR"
fi

# ── Phase 1a: Gitea ────────────────────────────────────────────────────────────
echo "  Installing Gitea..."
helm repo add gitea https://dl.gitea.com/charts/ --force-update > /dev/null 2>&1
helm upgrade --install "${RELEASE}-gitea" gitea/gitea \
  --version 12.5.0 \
  --namespace "$NAMESPACE" \
  --set gitea.admin.username=admin \
  --set "gitea.admin.password=${GITEA_PASS}" \
  --set gitea.admin.email=admin@example.com \
  --set "gitea.config.actions.ENABLED=true" \
  --set "gitea.config.actions.DEFAULT_ACTIONS_URL=github" \
  --set service.http.type=ClusterIP \
  --set persistence.size=5Gi \
  --set postgresql.enabled=true \
  --set "postgresql.primary.persistence.size=2Gi" \
  --set valkey.enabled=true \
  --set "valkey-cluster.enabled=false" \
  --set "postgresql-ha.enabled=false" \
  --timeout 15m \
  --wait

# ── Phase 1b: Main chart (cockpit + headlamp + runner + ingress) ───────────────
echo "  Installing clusterfactory chart (cockpit, headlamp, runner, ingress)..."
# shellcheck disable=SC2086
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set "gitea.adminPassword=${GITEA_PASS}" \
  --set "workflow.harborAdminPassword=${HARBOR_PASS}" \
  --set "cockpit.token=${COCKPIT_TOKEN}" \
  --timeout 10m \
  --wait \
  $EXTRA_ARGS

# ── Phase 2: Gitea API setup ───────────────────────────────────────────────────
echo "  Setting up Gitea via API..."

# Port-forward Gitea to localhost for API calls
kubectl port-forward svc/${RELEASE}-gitea-http -n "$NAMESPACE" 13000:3000 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

GITEA_API="http://localhost:13000/api/v1"

# Wait for Gitea API to be reachable
for i in $(seq 1 30); do
  curl -sf "${GITEA_API}/version" > /dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { echo "ERROR: Gitea API not reachable"; exit 1; }
  sleep 3
done

# Create a long-lived admin token (idempotent)
curl -sf -X DELETE "${GITEA_API}/users/admin/tokens/bootstrap" \
  -u "admin:${GITEA_PASS}" > /dev/null 2>&1 || true

ADMIN_TOKEN=$(curl -sf -X POST "${GITEA_API}/users/admin/tokens" \
  -u "admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"name":"bootstrap","scopes":["write:admin","write:repository","write:organization","write:user","write:actionsVariables"]}' \
  | jq -r '.sha1')

[ -z "$ADMIN_TOKEN" ] && { echo "ERROR: could not create Gitea admin token"; exit 1; }

AUTH="-H \"Authorization: token ${ADMIN_TOKEN}\""

# Create org and repo (idempotent — 422 if already exists)
curl -sf -X POST "${GITEA_API}/orgs" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"clusterfactory","visibility":"private"}' > /dev/null 2>&1 || true

curl -sf -X POST "${GITEA_API}/orgs/clusterfactory/repos" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"platform","description":"Platform installation workflow","auto_init":true,"default_branch":"main","private":false}' \
  > /dev/null 2>&1 || true

# Store credentials as org-level Actions secrets
_org_secret() {
  curl -sf -X PUT "${GITEA_API}/orgs/clusterfactory/actions/secrets/${1}" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\":\"${2}\"}" > /dev/null
}
_org_secret "HARBOR_ADMIN_PASSWORD"     "${HARBOR_PASS}"
_org_secret "ARGOCD_CHART_VERSION"      "7.8.28"
_org_secret "HARBOR_CHART_VERSION"      "1.16.2"
_org_secret "OPENBAO_CHART_VERSION"     "0.5.0"
_org_secret "CROSSPLANE_CHART_VERSION"  "1.18.5"
_org_secret "CF_NAMESPACE"              "${NAMESPACE}"
_org_secret "CF_RELEASE"                "${RELEASE}"

echo "  Org secrets stored."

# Create runner registration token and store as Kubernetes Secret
RUNNER_TOKEN=$(curl -sf "${GITEA_API}/admin/runners/registration-token" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  | jq -r '.token')

kubectl create secret generic "${RELEASE}-runner-token" \
  --namespace "$NAMESPACE" \
  --from-literal=token="${RUNNER_TOKEN}" \
  --from-literal=gitea_url="http://${RELEASE}-gitea-http.${NAMESPACE}.svc.cluster.local:3000" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  Runner token stored — waiting for runner to register..."

# Wait for the runner to come online
for i in $(seq 1 60); do
  COUNT=$(curl -sf "${GITEA_API}/admin/runners" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    2>/dev/null | jq '[.[] | select(.status == "online")] | length' 2>/dev/null || echo "0")
  [ "${COUNT:-0}" -gt 0 ] && { echo "  Runner online."; break; }
  [ "$i" -eq 60 ] && { echo "ERROR: runner never came online after 5 minutes"; exit 1; }
  sleep 5
done

# Push install-platform.yaml workflow to trigger it
WORKFLOW_FILE="${CHART_DIR}/files/workflows/install-platform.yaml"
CONTENT=$(base64 < "${WORKFLOW_FILE}" | tr -d '\n')

SHA=$(curl -sf "${GITEA_API}/repos/clusterfactory/platform/contents/.gitea/workflows/install-platform.yaml" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  | jq -r '.sha // empty' 2>/dev/null || true)

if [ -n "$SHA" ]; then
  PAYLOAD="{\"message\":\"chore: trigger platform installation\",\"content\":\"${CONTENT}\",\"sha\":\"${SHA}\"}"
  METHOD="PUT"
else
  PAYLOAD="{\"message\":\"chore: trigger platform installation\",\"content\":\"${CONTENT}\"}"
  METHOD="POST"
fi

curl -sf -X "${METHOD}" \
  "${GITEA_API}/repos/clusterfactory/platform/contents/.gitea/workflows/install-platform.yaml" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" > /dev/null

echo ""
echo "  ✓ Phase 1 complete. Platform installation running via Gitea Actions."
echo ""
echo "  Monitor progress:"
ACCESS_PORT="${accessPort:-30080}"
HOST="${host:-localhost}"
echo "    Gitea:   http://gitea.${HOST}:${ACCESS_PORT}"
echo "    Actions: http://gitea.${HOST}:${ACCESS_PORT}/clusterfactory/platform/actions"
echo "    Cockpit: http://cockpit.${HOST}:${ACCESS_PORT}"
echo ""
echo "  Or watch: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=${RELEASE}-runner -f"
