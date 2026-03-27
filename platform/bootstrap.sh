#!/usr/bin/env bash
# clusterfactory bootstrap — RKE2, two-phase install
#
# Requires: RKE2 cluster with rke2-ingress-nginx already running.
#
# Phase 1: Installs Gitea + act_runner + Cockpit + Headlamp + Ingress rules
# Phase 2: Calls Gitea API to push install-platform.yaml workflow,
#          which installs ArgoCD, Harbor, OpenBao, and Crossplane via
#          Gitea Actions running on the act_runner inside the cluster.
#
# Usage:
#   bash bootstrap.sh [namespace]
#
# Environment variables (optional overrides):
#   GITEA_PASS                  — Gitea admin password (generated if not set)
#   HARBOR_PASS                 — Harbor admin password (generated if not set)
#   AUTHENTIK_SECRET_KEY        — Authentik signing key (generated if not set)
#   AUTHENTIK_BOOTSTRAP_TOKEN   — Authentik API token (generated if not set)
#   AUTHENTIK_BOOTSTRAP_PASSWORD — Authentik admin UI password (generated if not set)

set -euo pipefail

NAMESPACE="${1:-clusterfactory}"
RELEASE="clusterfactory"

# ── Kubeconfig ─────────────────────────────────────────────────────────────────
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"

# ── Auto-install jq if missing ─────────────────────────────────────────────────
command -v jq > /dev/null 2>&1 || apt-get install -yq jq

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in helm kubectl curl jq; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: no cluster reachable"; exit 1; }

# ── Credentials ────────────────────────────────────────────────────────────────
GITEA_PASS="${GITEA_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
HARBOR_PASS="${HARBOR_PASS:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
AUTHENTIK_SECRET_KEY="${AUTHENTIK_SECRET_KEY:-$(openssl rand -base64 36 | tr -dc 'a-zA-Z0-9' | head -c 50)}"
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-$(openssl rand -hex 32)}"
AUTHENTIK_BOOTSTRAP_PASSWORD="${AUTHENTIK_BOOTSTRAP_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
AUTHENTIK_PG_PASSWORD="${AUTHENTIK_PG_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"

# Deployment configuration
CF_HOST="${CF_HOST:-localhost}"
CF_ACCESS_PORT="${CF_ACCESS_PORT:-8443}"

echo "  Credentials (save these):"
echo "    GITEA_PASS=$GITEA_PASS"
echo "    HARBOR_PASS=$HARBOR_PASS"
echo "    AUTHENTIK_BOOTSTRAP_PASSWORD=$AUTHENTIK_BOOTSTRAP_PASSWORD"
echo ""

# ── Namespace ──────────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── local-path-provisioner (default StorageClass for RKE2) ────────────────────
if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  echo "  Installing local-path-provisioner (no default StorageClass found)..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cert-manager (required before main chart — provides TLS CRDs) ──────────────
echo "  Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update > /dev/null 2>&1
helm upgrade --install cert-manager jetstack/cert-manager \
  --version 1.17.1 \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --timeout 10m \
  --wait

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
  --set "gitea.config.server.ROOT_URL=http://${RELEASE}-gitea-clusterip.${NAMESPACE}.svc.cluster.local:3000" \
  --set service.http.type=ClusterIP \
  --set persistence.size=5Gi \
  --set postgresql.enabled=true \
  --set "postgresql.primary.persistence.size=2Gi" \
  --set valkey.enabled=true \
  --set "valkey-cluster.enabled=false" \
  --set "postgresql-ha.enabled=false" \
  --timeout 15m \
  --wait

# ── Create stable (non-headless) ClusterIP service for Gitea ──────────────────
# The default gitea-http service is headless (ClusterIP:None) which breaks
# act_runner streaming; this stable service gives the runner a real ClusterIP.
kubectl apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE}-gitea-clusterip
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: gitea
  ports:
    - port: 3000
      targetPort: 3000
EOF

# ── Phase 1b: Main chart (cockpit + headlamp + runner + ingress rules) ─────────
echo "  Installing clusterfactory chart..."
# Use local chart if Chart.yaml present (dev mode), otherwise use published Helm repo
if [ -f "${CHART_DIR}/Chart.yaml" ]; then
  CHART_REF="$CHART_DIR"
else
  helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory --force-update > /dev/null 2>&1
  helm repo update > /dev/null 2>&1
  CHART_REF="clusterfactory/clusterfactory"
fi
helm upgrade --install "$RELEASE" "$CHART_REF" \
  --namespace "$NAMESPACE" \
  --set "gitea.adminPassword=${GITEA_PASS}" \
  --set "workflow.harborAdminPassword=${HARBOR_PASS}" \
  --set "host=${CF_HOST}" \
  --set "accessPort=${CF_ACCESS_PORT}" \
  --timeout 10m \
  --wait

# ── Phase 2: Gitea API setup ───────────────────────────────────────────────────
echo "  Setting up Gitea via API..."

kubectl port-forward svc/${RELEASE}-gitea-clusterip -n "$NAMESPACE" 13000:3000 &
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
  -d '{"name":"bootstrap","scopes":["write:admin","write:repository","write:organization","write:user"]}' \
  | jq -r '.sha1')

[ -z "$ADMIN_TOKEN" ] && { echo "ERROR: could not create Gitea admin token"; exit 1; }

# Create org and repo (idempotent — 422 if already exists)
curl -sf -X POST "${GITEA_API}/orgs" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"clusterfactory","visibility":"public"}' > /dev/null 2>&1 || true

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
_org_secret "HARBOR_ADMIN_PASSWORD"          "${HARBOR_PASS}"
_org_secret "AUTHENTIK_SECRET_KEY"           "${AUTHENTIK_SECRET_KEY}"
_org_secret "AUTHENTIK_BOOTSTRAP_TOKEN"      "${AUTHENTIK_BOOTSTRAP_TOKEN}"
_org_secret "AUTHENTIK_BOOTSTRAP_PASSWORD"   "${AUTHENTIK_BOOTSTRAP_PASSWORD}"
_org_secret "AUTHENTIK_PG_PASSWORD"          "${AUTHENTIK_PG_PASSWORD}"
_org_secret "ARGOCD_CHART_VERSION"           "7.8.28"
_org_secret "HARBOR_CHART_VERSION"           "1.16.2"
_org_secret "OPENBAO_CHART_VERSION"          "0.5.0"
_org_secret "CROSSPLANE_CHART_VERSION"       "1.18.5"
_org_secret "CERTMANAGER_CHART_VERSION"      "1.17.1"
_org_secret "AUTHENTIK_CHART_VERSION"        "2026.2.1"
_org_secret "CF_NAMESPACE"                   "${NAMESPACE}"
_org_secret "CF_RELEASE"                     "${RELEASE}"
_org_secret "CF_HOST"                        "${CF_HOST}"
_org_secret "CF_ACCESS_PORT"                 "${CF_ACCESS_PORT}"

echo "  Org secrets stored."

# Create runner registration token and store as Kubernetes Secret
RUNNER_TOKEN=$(curl -sf "${GITEA_API}/admin/runners/registration-token" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  | jq -r '.token')

kubectl create secret generic "${RELEASE}-runner-token" \
  --namespace "$NAMESPACE" \
  --from-literal=token="${RUNNER_TOKEN}" \
  --from-literal=gitea_url="http://${RELEASE}-gitea-clusterip.${NAMESPACE}.svc.cluster.local:3000" \
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
echo "  SSM port-forward (run on your laptop):"
echo "    aws ssm start-session --target <instance-id> \\"
echo "      --document-name AWS-StartPortForwardingSession \\"
echo "      --parameters '{\"portNumber\":[\"443\"],\"localPortNumber\":[\"${CF_ACCESS_PORT}\"]}'"
echo ""
echo "  Access (after port-forward to :${CF_ACCESS_PORT}, trust the self-signed cert):"
echo "    Gitea:    https://gitea.${CF_HOST}:${CF_ACCESS_PORT}"
echo "    Actions:  https://gitea.${CF_HOST}:${CF_ACCESS_PORT}/clusterfactory/platform/actions"
echo "    Cockpit:  https://cockpit.${CF_HOST}:${CF_ACCESS_PORT}"
echo "    Headlamp: https://headlamp.${CF_HOST}:${CF_ACCESS_PORT}"
echo "    Auth:     https://auth.${CF_HOST}:${CF_ACCESS_PORT}  (Authentik SSO)"
echo ""
echo "  Authentik admin UI: https://auth.${CF_HOST}:${CF_ACCESS_PORT}"
echo "    Username: akadmin"
echo "    Password: ${AUTHENTIK_BOOTSTRAP_PASSWORD}"
echo ""
echo "  Or watch workflow: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=${RELEASE}-runner -f"
