#!/usr/bin/env bash
# clusterfactory bootstrap — RKE2, two-phase install
#
# Requires: RKE2 cluster with rke2-ingress-nginx already running.
#
# Phase 1: Installs Gitea + act_runner + Cockpit + Headlamp + Ingress rules
# Phase 2: Calls Gitea API to push install-platform.yaml workflow,
#          which installs ArgoCD, Harbor, OpenBao, and Crossplane
#          via Gitea Actions running on the act_runner inside the cluster.
#
# Usage:
#   bash bootstrap.sh [--airgap] [namespace]
#
# Modes:
#   (default)   online  — pulls charts and images from the internet
#   --airgap            — uses bundled charts and images, no internet required
#                         requires load.sh to have been run first
#                         requires CF_HARBOR_HOST to be set
#
# Environment variables (optional overrides):
#   CF_HOST                      — hostname for ingress rules (default: localhost)
#   CF_ACCESS_PORT               — local port for SSM port-forward (default: 8443)
#   CF_HARBOR_HOST               — internal Harbor host for airgap mode
#   GITEA_PASS                   — Gitea admin password (generated if not set)
#   HARBOR_PASS                  — Harbor admin password (generated if not set)

set -euo pipefail

# ── Parse args ────────────────────────────────────────────────────────────────
AIRGAP=false
NAMESPACE="clusterfactory"
for arg in "$@"; do
  case "$arg" in
    --airgap) AIRGAP=true ;;
    --*)      echo "Unknown flag: $arg"; exit 1 ;;
    *)        NAMESPACE="$arg" ;;
  esac
done

RELEASE="clusterfactory"

# ── Source versions ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="${SCRIPT_DIR}/../VERSIONS.env"
[ -f "${VERSIONS_FILE}" ] || { echo "ERROR: VERSIONS.env not found at ${VERSIONS_FILE}"; exit 1; }
source "${VERSIONS_FILE}"

# ── Airgap overrides ──────────────────────────────────────────────────────────
if [ "${AIRGAP}" = "true" ]; then
  : "${CF_HARBOR_HOST:?ERROR: CF_HARBOR_HOST must be set in airgap mode}"
  OVERRIDES_FILE="${SCRIPT_DIR}/../airgap-overrides.env"
  [ -f "${OVERRIDES_FILE}" ] || { echo "ERROR: airgap-overrides.env not found"; exit 1; }
  source "${OVERRIDES_FILE}"
  echo "  Mode: airgap (Harbor: ${CF_HARBOR_HOST})"
else
  echo "  Mode: online"
fi

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
AUTHENTIK_SECRET_KEY="${AUTHENTIK_SECRET_KEY:-$(openssl rand -hex 32)}"
AUTHENTIK_PG_PASSWORD="${AUTHENTIK_PG_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
# Deployment configuration
CF_HOST="${CF_HOST:-localhost}"
CF_ACCESS_PORT="${CF_ACCESS_PORT:-8443}"

echo "  Credentials (save these):"
echo "    GITEA_PASS=$GITEA_PASS"
echo "    HARBOR_PASS=$HARBOR_PASS"
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

# ── nginx ingress controller ──────────────────────────────────────────────────
# server-snippet and configuration-snippet are disabled by default in nginx ingress
# v1.9+. Required for the custom /_ak-auth auth location to be injected.
echo "  Enabling nginx ingress snippet annotations..."
# Wait for the nginx configmap to exist (RKE2 creates it asynchronously)
for i in $(seq 1 30); do
  kubectl get configmap rke2-ingress-nginx-controller -n kube-system > /dev/null 2>&1 && break
  echo "    Waiting for nginx configmap ($i/30)..."
  sleep 5
done
kubectl patch configmap rke2-ingress-nginx-controller -n kube-system \
  --type merge \
  -p '{"data":{"allow-snippet-annotations":"true","annotations-risk-level":"Critical"}}'

# ── cert-manager (required before main chart — provides TLS CRDs) ──────────────
echo "  Installing cert-manager..."
if [ "${AIRGAP}" = "false" ]; then
  helm repo add jetstack "${REPO_JETSTACK}" --force-update > /dev/null 2>&1
fi
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "${CERTMANAGER_CHART_VERSION}" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --timeout 10m \
  --wait

# ── Phase 1a: Gitea ────────────────────────────────────────────────────────────
echo "  Installing Gitea..."
if [ "${AIRGAP}" = "false" ]; then
  helm repo add gitea "${REPO_GITEA}" --force-update > /dev/null 2>&1
fi
helm upgrade --install "${RELEASE}-gitea" gitea/gitea \
  --version "${GITEA_CHART_VERSION}" \
  --namespace "$NAMESPACE" \
  --set gitea.admin.username=admin \
  --set "gitea.admin.password=${GITEA_PASS}" \
  --set gitea.admin.email=admin@example.com \
  --set "gitea.config.actions.ENABLED=true" \
  --set "gitea.config.actions.DEFAULT_ACTIONS_URL=github" \
  --set "gitea.config.server.ROOT_URL=http://${RELEASE}-gitea-http.${NAMESPACE}.svc.cluster.local:3000" \
  --set service.http.type=ClusterIP \
  --set persistence.size=5Gi \
  --set postgresql.enabled=true \
  --set "postgresql.primary.persistence.size=2Gi" \
  --set valkey.enabled=true \
  --set "valkey-cluster.enabled=false" \
  --set "postgresql-ha.enabled=false" \
  --timeout 15m \
  --wait

# ── Phase 1b: Main chart (cockpit + headlamp + runner + ingress rules) ─────────
echo "  Installing clusterfactory chart..."
# Use local chart if Chart.yaml present (dev mode), otherwise use published Helm repo
if [ -f "${CHART_DIR}/Chart.yaml" ]; then
  CHART_REF="$CHART_DIR"
else
  if [ "${AIRGAP}" = "false" ]; then
    helm repo add clusterfactory "${REPO_CLUSTERFACTORY}" --force-update > /dev/null 2>&1
    helm repo update > /dev/null 2>&1
  fi
  CHART_REF="clusterfactory/clusterfactory"
fi
helm upgrade --install "$RELEASE" "$CHART_REF" \
  --namespace "$NAMESPACE" \
  --set "gitea.adminPassword=${GITEA_PASS}" \
  --set "host=${CF_HOST}" \
  --set "accessPort=${CF_ACCESS_PORT}" \
  --timeout 10m \
  --wait

# ── Phase 2: Gitea API setup (via kubectl exec — no port-forward needed) ───────
#
# All Gitea API calls are made from inside the Gitea pod itself using kubectl exec.
# This avoids port-forward fragility entirely — no background process, no timing
# race between helm --wait and the service being reachable from the host.
#
# Pattern:
#   _gitea_api METHOD /path [body]
#   → runs: kubectl exec gitea-pod -- curl http://localhost:3000/api/v1/...
#
echo "  Setting up Gitea via API (kubectl exec)..."

# ── Wait for Gitea pod to be ready ────────────────────────────────────────────
GITEA_POD=""
echo "  Waiting for Gitea pod..."
for i in $(seq 1 60); do
  GITEA_POD=$(kubectl get pod -n "${NAMESPACE}" \
    -l "app.kubernetes.io/name=gitea" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${GITEA_POD}" ]; then
    kubectl wait pod "${GITEA_POD}" -n "${NAMESPACE}" \
      --for=condition=Ready --timeout=5s > /dev/null 2>&1 && break
  fi
  [ "$i" -eq 60 ] && { echo "ERROR: Gitea pod never became Ready"; exit 1; }
  sleep 5
done
echo "  Gitea pod: ${GITEA_POD}"

# ── Wait for Gitea HTTP to respond inside the pod ────────────────────────────
echo "  Waiting for Gitea API inside pod..."
for i in $(seq 1 30); do
  kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -sf http://localhost:3000/api/v1/version > /dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { echo "ERROR: Gitea API not responding inside pod"; exit 1; }
  sleep 5
done

# ── Helper: run a Gitea API call from inside the pod ─────────────────────────
# Usage: _gitea METHOD /path [-d 'body']
# Returns response body. Exits on HTTP error only if --fail is appropriate.
_gitea() {
  local method="$1" path="$2"
  shift 2
  kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -sf -X "${method}" \
    "http://localhost:3000/api/v1${path}" \
    -H "Content-Type: application/json" \
    "$@"
}

_gitea_auth() {
  local method="$1" path="$2"
  shift 2
  kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -sf -X "${method}" \
    "http://localhost:3000/api/v1${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    "$@"
}

# ── Create admin token (idempotent) ───────────────────────────────────────────
# Delete any stale bootstrap token first, then create fresh
kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
  curl -sf -X DELETE \
  "http://localhost:3000/api/v1/users/admin/tokens/bootstrap" \
  -u "admin:${GITEA_PASS}" > /dev/null 2>&1 || true

ADMIN_TOKEN=$(kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
  curl -sf -X POST \
  "http://localhost:3000/api/v1/users/admin/tokens" \
  -u "admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"name":"bootstrap","scopes":["write:admin","write:repository","write:organization","write:user"]}' \
  | jq -r '.sha1')

[ -z "${ADMIN_TOKEN}" ] || [ "${ADMIN_TOKEN}" = "null" ] && \
  { echo "ERROR: could not create Gitea admin token"; exit 1; }
echo "  Admin token created."

# ── Create org and repo (idempotent — ignore 422 already exists) ──────────────
_gitea_auth POST /orgs \
  -d '{"username":"clusterfactory","visibility":"public"}' > /dev/null 2>&1 || true

_gitea_auth POST /orgs/clusterfactory/repos \
  -d '{"name":"platform","description":"Platform installation workflow","auto_init":true,"default_branch":"main","private":false}' \
  > /dev/null 2>&1 || true
echo "  Org and repo ready."

# ── Store all credentials as org-level Actions secrets ───────────────────────
_org_secret() {
  local name="$1" value="$2"
  kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -sf -X PUT \
    "http://localhost:3000/api/v1/orgs/clusterfactory/actions/secrets/${name}" \
    -H "Content-Type: application/json" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    -d "{\"data\":\"${value}\"}" > /dev/null
}

_org_secret "HARBOR_ADMIN_PASSWORD"          "${HARBOR_PASS}"
_org_secret "AUTHENTIK_SECRET_KEY"           "${AUTHENTIK_SECRET_KEY}"
_org_secret "AUTHENTIK_PG_PASSWORD"          "${AUTHENTIK_PG_PASSWORD}"
_org_secret "AUTHENTIK_CHART_VERSION"        "${AUTHENTIK_CHART_VERSION}"
_org_secret "REPO_AUTHENTIK"                 "${REPO_AUTHENTIK}"
_org_secret "ARGOCD_CHART_VERSION"           "${ARGOCD_CHART_VERSION}"
_org_secret "HARBOR_CHART_VERSION"           "${HARBOR_CHART_VERSION}"
_org_secret "OPENBAO_CHART_VERSION"          "${OPENBAO_CHART_VERSION}"
_org_secret "CROSSPLANE_CHART_VERSION"       "${CROSSPLANE_CHART_VERSION}"
_org_secret "CERTMANAGER_CHART_VERSION"      "${CERTMANAGER_CHART_VERSION}"
_org_secret "CF_NAMESPACE"                   "${NAMESPACE}"
_org_secret "CF_RELEASE"                     "${RELEASE}"
_org_secret "CF_HOST"                        "${CF_HOST}"
_org_secret "CF_ACCESS_PORT"                 "${CF_ACCESS_PORT}"
_org_secret "REPO_ARGO"                      "${REPO_ARGO}"
_org_secret "REPO_HARBOR"                    "${REPO_HARBOR}"
_org_secret "REPO_OPENBAO"                   "${REPO_OPENBAO}"
_org_secret "REPO_CROSSPLANE"                "${REPO_CROSSPLANE}"
_org_secret "REPO_JETSTACK"                  "${REPO_JETSTACK}"
_org_secret "REPO_CLUSTERFACTORY"            "${REPO_CLUSTERFACTORY}"
_org_secret "KUBECTL_VERSION"                "${KUBECTL_VERSION}"
_org_secret "HELM_VERSION"                   "${HELM_VERSION}"
echo "  Org secrets stored."

# ── Fetch runner token and write to k8s Secret ───────────────────────────────
# The runner Deployment mounts this Secret and uses it to self-register.
RUNNER_TOKEN=$(kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
  curl -sf \
  "http://localhost:3000/api/v1/admin/runners/registration-token" \
  -H "Authorization: token ${ADMIN_TOKEN}" \
  | jq -r '.token')

[ -z "${RUNNER_TOKEN}" ] || [ "${RUNNER_TOKEN}" = "null" ] && \
  { echo "ERROR: could not fetch runner registration token"; exit 1; }

kubectl create secret generic "${RELEASE}-runner-token" \
  --namespace "${NAMESPACE}" \
  --from-literal=token="${RUNNER_TOKEN}" \
  --from-literal=gitea_url="http://${RELEASE}-gitea-http.${NAMESPACE}.svc.cluster.local:3000" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  Runner token written to k8s Secret."

# ── Wait for runner to come online ────────────────────────────────────────────
# The runner pod was already created by helm install but was waiting for the
# Secret to appear. Now that the Secret exists it will register automatically.
# Check pod logs directly — avoids dependency on Gitea API endpoint which
# varies across Gitea versions.
echo "  Waiting for runner to register (up to 5 min)..."
for i in $(seq 1 60); do
  RUNNER_POD=$(kubectl get pod -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '/runner/{print $1}' | head -1)
  if [ -n "${RUNNER_POD}" ]; then
    if kubectl logs -n "${NAMESPACE}" "${RUNNER_POD}" 2>/dev/null \
        | grep -q "Runner registered successfully\|declare successfully"; then
      echo "  Runner online."
      break
    fi
  fi
  [ "$i" -eq 60 ] && { echo "ERROR: runner never came online after 5 minutes"; exit 1; }
  [ $((i % 6)) -eq 0 ] && echo "    ...still waiting (${i}/60)"
  sleep 5
done

# ── Helper: push a workflow file to Gitea repo ───────────────────────────────
# Usage: _push_workflow <local-file> <commit-message>
# Copies the file into the pod then pushes it via the Gitea contents API.
# Using kubectl cp avoids base64/shell escaping issues with large YAML files.
_push_workflow() {
  local src="$1" msg="$2"
  local name dest repo_path
  name="$(basename "${src}")"
  dest="/tmp/${name}"
  repo_path=".gitea/workflows/${name}"

  kubectl cp "${src}" "${NAMESPACE}/${GITEA_POD}:${dest}"

  local sha content method body status
  sha=$(kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -sf \
    "http://localhost:3000/api/v1/repos/clusterfactory/platform/contents/${repo_path}" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    2>/dev/null | jq -r '.sha // empty' || true)

  content=$(kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    base64 -w 0 "${dest}")

  if [ -n "${sha}" ]; then
    method="PUT"
    body="{\"message\":\"${msg}\",\"content\":\"${content}\",\"sha\":\"${sha}\"}"
  else
    method="POST"
    body="{\"message\":\"${msg}\",\"content\":\"${content}\"}"
  fi

  status=$(kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- \
    curl -s -o /dev/null -w "%{http_code}" \
    -X "${method}" \
    "http://localhost:3000/api/v1/repos/clusterfactory/platform/contents/${repo_path}" \
    -H "Authorization: token ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${body}")

  case "${status}" in
    200|201) echo "  Pushed ${name} (HTTP ${status})" ;;
    *)       echo "ERROR: push failed for ${name} (HTTP ${status})"; exit 1 ;;
  esac

  kubectl exec "${GITEA_POD}" -n "${NAMESPACE}" -- rm -f "${dest}"
}

# ── Push workflows ────────────────────────────────────────────────────────────
_push_workflow "${CHART_DIR}/files/workflows/install-platform.yaml" \
  "chore: trigger platform installation"
echo "  Phase 2 triggered via Gitea Actions."

_push_workflow "${CHART_DIR}/files/workflows/install-authentik.yaml" \
  "chore: add install-authentik workflow"
echo "  install-authentik workflow available in Gitea Actions."

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
echo ""
echo "  Or watch workflow: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=${RELEASE}-runner -f"
