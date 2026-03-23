#!/usr/bin/env bash
# clusterfactory bootstrap — interactive preflight + helm install
#
# Usage after helm pull:
#   helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory
#   helm pull clusterfactory/clusterfactory --untar
#   bash ./clusterfactory/bootstrap.sh
#
# Or from source:
#   bash ./clusterfactory/bootstrap.sh

set -euo pipefail

CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; BOLD="\033[1m"; NC="\033[0m"

# Self-locate — works whether run from inside the packaged chart or source tree
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_NAME="clusterfactory"

# Minimum allocatable resources required for the full stack (startup spike)
NEED_CPU_MILLI=4000   # 4 cores
NEED_MEM_MI=6144      # 6Gi

echo -e "\n${BOLD}${CYAN}  clusterfactory bootstrap${NC}\n"
echo -e "  Creates pre-install secrets and runs helm install."
echo -e "  Press Ctrl+C at any time to abort.\n"

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in helm kubectl; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
done
kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: no cluster reachable — check KUBECONFIG"; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
  echo -e "${BOLD}  Preflight check${NC}"

  # Detect environment
  local ctx server env_name fix
  ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

  if [[ "$ctx" == "docker-desktop" ]] || echo "$server" | grep -qE "docker\.internal"; then
    env_name="Docker Desktop"
    fix="Settings → Resources → Memory → set to 8Gi, CPUs → set to 4"
  elif echo "$ctx" | grep -qi "rancher"; then
    env_name="Rancher Desktop"
    fix="Preferences → Virtual Machine → Hardware → Memory: 8Gi, CPU: 4 → restart"
  elif echo "$ctx" | grep -qi "podman"; then
    env_name="Podman Desktop"
    fix="Settings → Resources → Memory → set to 8Gi, CPUs → set to 4"
  elif [[ "$ctx" == "minikube" ]]; then
    env_name="minikube"
    fix="minikube stop && minikube start --cpus=4 --memory=8192"
  elif echo "$ctx" | grep -qE "^kind-"; then
    env_name="kind"
    fix="kind delete cluster && kind create cluster (add resource config for 4 CPU / 8Gi)"
  elif echo "$server" | grep -q "eks\.amazonaws\.com"; then
    env_name="Amazon EKS"
    fix="use t3.xlarge nodes or larger (4 vCPU / 16Gi)"
  elif echo "$ctx" | grep -qE "^gke_" || echo "$server" | grep -q "googleapis\.com"; then
    env_name="Google GKE"
    fix="use n1-standard-4 nodes or larger (4 vCPU / 15Gi)"
  elif echo "$server" | grep -q "azmk8s\.io" || echo "$ctx" | grep -qi "aks"; then
    env_name="Azure AKS"
    fix="use Standard_D4s_v3 nodes or larger (4 vCPU / 16Gi)"
  else
    env_name="Kubernetes (${ctx})"
    fix="ensure nodes have at least 4 allocatable CPU cores and 6Gi allocatable RAM"
  fi

  # Measure allocatable resources across all nodes
  local total_cpu_milli=0 total_mem_mi=0
  while IFS=' ' read -r cpu mem; do
    [ -z "$cpu" ] && continue
    # CPU: "4" → 4000m, "3500m" → 3500
    if echo "$cpu" | grep -q 'm$'; then
      total_cpu_milli=$(( total_cpu_milli + ${cpu%m} ))
    else
      total_cpu_milli=$(( total_cpu_milli + ${cpu%.*} * 1000 ))
    fi
    # Memory: "16Gi" "8192Mi" "1048576Ki"
    if echo "$mem" | grep -q 'Gi$'; then
      total_mem_mi=$(( total_mem_mi + ${mem%Gi} * 1024 ))
    elif echo "$mem" | grep -q 'Mi$'; then
      total_mem_mi=$(( total_mem_mi + ${mem%Mi} ))
    elif echo "$mem" | grep -q 'Ki$'; then
      total_mem_mi=$(( total_mem_mi + ${mem%Ki} / 1024 ))
    fi
  done < <(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}' \
    2>/dev/null)

  local have_cpu have_mem
  have_cpu=$(awk "BEGIN {printf \"%.1f\", ${total_cpu_milli} / 1000}")
  have_mem=$(awk "BEGIN {printf \"%.1f\", ${total_mem_mi} / 1024}")
  local need_cpu="$(awk "BEGIN {printf \"%.1f\", ${NEED_CPU_MILLI} / 1000}")"
  local need_mem="$(awk "BEGIN {printf \"%.1f\", ${NEED_MEM_MI} / 1024}")"

  echo -e "  You are on   : ${CYAN}${env_name}${NC}"
  echo -e "  Allocatable  : ${CYAN}${have_cpu} CPU  /  ${have_mem}Gi RAM${NC}"

  local cpu_ok=true mem_ok=true
  [ "$total_cpu_milli" -lt "$NEED_CPU_MILLI" ] && cpu_ok=false
  [ "$total_mem_mi"    -lt "$NEED_MEM_MI"    ] && mem_ok=false

  if $cpu_ok && $mem_ok; then
    echo -e "  Required     : ${GREEN}${need_cpu} CPU  /  ${need_mem}Gi RAM  ✓  OK${NC}\n"
    return 0
  fi

  echo -e "  Required     : ${need_cpu} CPU  /  ${need_mem}Gi RAM"
  echo ""
  echo -e "  ${RED}${BOLD}✗  insufficient resources — cannot install${NC}"
  echo ""
  $cpu_ok || echo -e "  CPU : have ${have_cpu} cores,  need ${need_cpu} cores"
  $mem_ok || echo -e "  RAM : have ${have_mem}Gi,      need ${need_mem}Gi"
  echo ""
  echo -e "  ${BOLD}Fix (${env_name}):${NC}"
  echo -e "  ${YELLOW}${fix}${NC}"
  echo ""
  echo -e "  Then re-run:  bash bootstrap.sh"
  echo -e "  Details:      RESOURCES.md"
  echo ""
  exit 1
}

preflight

# ── kubectl context ───────────────────────────────────────────────────────────
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
echo -e "  Current kubectl context: ${CYAN}${CURRENT_CTX}${NC}"
read -rp "  Use this context? [Y/n] " USE_CTX
USE_CTX="${USE_CTX:-Y}"
if [[ "$(echo "$USE_CTX" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
  echo ""
  kubectl config get-contexts --no-headers | awk '{print "    " $2}'
  echo ""
  read -rp "  Enter context name: " CURRENT_CTX
  kubectl config use-context "$CURRENT_CTX"
fi

# ── Namespace ─────────────────────────────────────────────────────────────────
echo ""
read -rp "  Target namespace [clusterfactory]: " NAMESPACE
NAMESPACE="${NAMESPACE:-clusterfactory}"

# ── Host ──────────────────────────────────────────────────────────────────────
read -rp "  Host for browser access [localhost]: " HOST
HOST="${HOST:-localhost}"

# ── Docker Desktop detection ──────────────────────────────────────────────────
DETECTED_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
if echo "$DETECTED_API" | grep -qE "127\.0\.0\.1|localhost"; then
  PORT="${DETECTED_API##*:}"
  echo -e "\n  ${YELLOW}docker-desktop detected — kubeconfig will use kubernetes.docker.internal:${PORT}${NC}"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
echo -e "\n  ──────────────────────────────────────────"
echo -e "  Namespace : ${GREEN}${NAMESPACE}${NC}"
echo -e "  Host      : ${GREEN}${HOST}${NC}"
echo -e "  ──────────────────────────────────────────"
echo ""
read -rp "  Proceed? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" == "n" ]] && echo "Aborted." && exit 0

# ── Namespace ─────────────────────────────────────────────────────────────────
echo -e "\n  Creating namespace ${CYAN}${NAMESPACE}${NC}..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── kubeconfig Secret ─────────────────────────────────────────────────────────
echo "  Writing ${RELEASE_NAME}-kubeconfig Secret..."
kubectl create secret generic "${RELEASE_NAME}-kubeconfig" \
  --namespace "$NAMESPACE" \
  --from-literal=kubeconfig="$(
    kubectl config view --minify --flatten \
      | sed 's|127.0.0.1|kubernetes.docker.internal|g' \
      | sed 's|https://localhost:|https://kubernetes.docker.internal:|g'
  )" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

# ── Helm install (background) ─────────────────────────────────────────────────
echo -e "\n${BOLD}  Running helm install...${NC}\n"

# Update dependencies only if charts/ is missing (local dev).
if [ ! -d "${CHART_DIR}/charts" ] || [ -z "$(ls -A "${CHART_DIR}/charts" 2>/dev/null)" ]; then
  helm dependency update "$CHART_DIR"
fi

helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set "host=${HOST}" \
  --set "namespace=${NAMESPACE}" \
  --timeout 20m &
HELM_PID=$!

# ── Live log streaming ────────────────────────────────────────────────────────
# Streams each job's logs as they run so you see exactly what's happening.
_stream_job() {
  local job_name="$1"
  local label="$2"
  local pod=""

  echo -e "\n${CYAN}  ┌─ ${job_name} ────────────────────────────────────────────────${NC}"

  # Wait up to 5 min for the job pod to appear
  for i in $(seq 1 100); do
    pod=$(kubectl get pods -n "${NAMESPACE}" -l "${label}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${pod}" ] && break
    sleep 3
  done

  if [ -z "${pod}" ]; then
    echo -e "${CYAN}  │  (pod not found)${NC}"
  else
    # Follow logs; --pod-running-timeout waits for the container to start
    kubectl logs -n "${NAMESPACE}" "${pod}" -f --pod-running-timeout=120s 2>/dev/null \
      | sed "s/^/${CYAN}  │  ${NC}/" || true
  fi

  echo -e "${CYAN}  └──────────────────────────────────────────────────────────${NC}"
}

_stream_job "${RELEASE_NAME}-init"    "app.kubernetes.io/name=${RELEASE_NAME}-init"
_stream_job "${RELEASE_NAME}-wiring"  "app.kubernetes.io/name=${RELEASE_NAME}-wiring"
_stream_job "${RELEASE_NAME}-summary" "app.kubernetes.io/name=${RELEASE_NAME}-summary"

# ── Wait for helm to finish ───────────────────────────────────────────────────
if ! wait "$HELM_PID"; then
  echo -e "\n  ${YELLOW}helm install reported an error — check above for details${NC}"
  echo -e "  kubectl get jobs -n ${NAMESPACE}"
  exit 1
fi

echo -e "\n  ${GREEN}${BOLD}done.${NC}\n"
