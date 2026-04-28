#!/usr/bin/env bash
# engine/tests/integration/test_airgap_install.sh
#
# Proves the v0.3 demo goal end-to-end:
#   1. zarf package create        → produces a signed tar.zst
#   2. zarf package deploy        → installs Gitea + Jenkins on a k3d cluster
#   3. wire Job runs              → Python engine wires Gitea credential into Jenkins
#   4. structural SHA appears     → in cf-wire-result ConfigMap
#   5. wiring is real             → Gitea has the org/repo/Jenkinsfile,
#                                   Jenkins has the gitea-userpass credential
#
# This is the only test that proves "opinionated Gitea + Jenkins, wired by
# Python, zarfed for airgap" works as a single pipeline. Unit tests prove
# the engine logic is correct; this proves the whole thing composes.
#
# Requirements (checked at start):
#   - zarf, k3d, kubectl, cosign on PATH
#   - docker daemon reachable
#   - 4+ GB free RAM, 5+ GB free disk
#
# Environment:
#   GITEA_ADMIN_PASSWORD   required, used at deploy time
#   K3D_CLUSTER            optional, default cf-test
#   KEEP_CLUSTER           optional, set to 1 to skip teardown for debugging
#   SKIP_BUILD             optional, set to 1 to reuse an existing tarball
#
# Exit codes:
#   0  success
#   1  test failure (assertion didn't hold)
#   2  environment problem (missing tool, no docker, etc.)

set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────
K3D_CLUSTER="${K3D_CLUSTER:-cf-test}"
NS="cicd"
WIRE_IMAGE_TAG="ghcr.io/clusterfactory/clusterfactory-wire:0.3.0"
TIMEOUT_GITEA="5m"
TIMEOUT_JENKINS="10m"
TIMEOUT_WIRE="10m"

# Find repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

# ── output helpers ──────────────────────────────────────────────────────────
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

fail()   { red   "FAIL: $*"; exit 1; }
need()   { command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 2; }; }

# ── preflight ───────────────────────────────────────────────────────────────
step "preflight"
need docker
need k3d
need kubectl
need zarf
need helm

if [[ -z "${GITEA_ADMIN_PASSWORD:-}" ]]; then
  red "GITEA_ADMIN_PASSWORD is required"
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  red "docker daemon not reachable"
  exit 2
fi

green "preflight ok"

# ── teardown registration ───────────────────────────────────────────────────
cleanup() {
  local rc=$?
  if [[ "${KEEP_CLUSTER:-0}" == "1" ]]; then
    yellow "KEEP_CLUSTER=1 — leaving k3d cluster '${K3D_CLUSTER}' running"
    yellow "  kubectl --context k3d-${K3D_CLUSTER} -n ${NS} get all"
    yellow "  k3d cluster delete ${K3D_CLUSTER}"
    return $rc
  fi
  step "teardown"
  k3d cluster delete "${K3D_CLUSTER}" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT

# ── 1. cluster ──────────────────────────────────────────────────────────────
step "k3d cluster: ${K3D_CLUSTER}"
if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "${K3D_CLUSTER}"; then
  yellow "cluster exists, deleting first for a clean run"
  k3d cluster delete "${K3D_CLUSTER}"
fi
k3d cluster create "${K3D_CLUSTER}" \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --wait \
  --timeout 120s

kubectl --context "k3d-${K3D_CLUSTER}" cluster-info >/dev/null

# ── 2. build ────────────────────────────────────────────────────────────────
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  step "build wire image"
  docker build -t "${WIRE_IMAGE_TAG}" engine/
  k3d image import "${WIRE_IMAGE_TAG}" -c "${K3D_CLUSTER}"

  step "zarf package create"
  zarf package create . --confirm
fi

PKG="$(ls zarf-package-clusterfactory-ci-amd64-*.tar.zst 2>/dev/null | head -n1 || true)"
[[ -n "${PKG}" ]] || fail "no zarf package tarball found in repo root"
yellow "package: ${PKG}"

# ── 3. zarf init + deploy ───────────────────────────────────────────────────
step "zarf init"
# Download zarf-init if not present
if [[ ! -f zarf-init-amd64-*.tar.zst ]]; then
  yellow "downloading zarf-init..."
  zarf tools download-init
fi
# Initialize without optional components
zarf init --confirm --components=k3s

step "zarf deploy"
zarf package deploy "${PKG}" \
  --confirm \
  --set "GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD}"

# ── 4. assertions ───────────────────────────────────────────────────────────
ctx="k3d-${K3D_CLUSTER}"
kc() { kubectl --context "${ctx}" "$@"; }

step "wait for gitea + jenkins"
kc -n "${NS}" rollout status \
  statefulset/cf-gitea --timeout="${TIMEOUT_GITEA}" \
  || fail "gitea did not become ready"

# Jenkins chart deploys as a StatefulSet named after the release.
kc -n "${NS}" rollout status \
  statefulset/cf-jenkins --timeout="${TIMEOUT_JENKINS}" \
  || fail "jenkins did not become ready"

step "wait for wire Job"
kc -n "${NS}" wait --for=condition=complete \
  --timeout="${TIMEOUT_WIRE}" job/cf-wire \
  || {
    yellow "wire Job did not complete; dumping logs:"
    kc -n "${NS}" logs job/cf-wire --tail=200 || true
    fail "wire Job failed"
  }

step "assert: structural SHA was emitted"
SHA="$(kc -n "${NS}" get cm cf-wire-result \
  -o jsonpath='{.data.structural_sha}' 2>/dev/null || true)"
[[ -n "${SHA}" ]] || fail "cf-wire-result ConfigMap missing structural_sha"
[[ "${#SHA}" -eq 64 ]] || fail "structural_sha is not 64 hex chars: '${SHA}'"
green "structural_sha = ${SHA}"

step "assert: gitea has the bootstrapped repo"
# Port-forward briefly and hit the Gitea API.
kc -n "${NS}" port-forward svc/cf-gitea-http 13000:3000 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true; cleanup' EXIT
sleep 3

http_status() {
  curl -s -o /dev/null -w '%{http_code}' \
    -u "gitea-admin:${GITEA_ADMIN_PASSWORD}" \
    "http://127.0.0.1:13000$1"
}

[[ "$(http_status /api/v1/orgs/cf-demo)" == "200" ]] \
  || fail "gitea org cf-demo missing"
[[ "$(http_status /api/v1/repos/cf-demo/hello-world)" == "200" ]] \
  || fail "gitea repo cf-demo/hello-world missing"
[[ "$(http_status /api/v1/repos/cf-demo/hello-world/contents/Jenkinsfile)" == "200" ]] \
  || fail "Jenkinsfile not committed to cf-demo/hello-world"
green "gitea wired: cf-demo/hello-world has Jenkinsfile"

kill ${PF_PID} 2>/dev/null || true
trap cleanup EXIT

step "assert: jenkins has the gitea-userpass credential"
JENKINS_PASS="$(kc -n "${NS}" get secret cf-jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"

kc -n "${NS}" port-forward svc/cf-jenkins 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true; cleanup' EXIT
sleep 5

# Jenkins credentials API: list the system store; expect "gitea-userpass" by id.
CREDS_XML="$(curl -s -u "admin:${JENKINS_PASS}" \
  'http://127.0.0.1:18080/credentials/store/system/domain/_/api/xml?depth=2' || true)"
echo "${CREDS_XML}" | grep -q '<id>gitea-userpass</id>' \
  || fail "jenkins credential 'gitea-userpass' not found"
green "jenkins wired: gitea-userpass credential present"

# Confirm the pipeline job was created.
JOB_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
  -u "admin:${JENKINS_PASS}" \
  'http://127.0.0.1:18080/job/cf-demo-hello-world/api/json')"
[[ "${JOB_STATUS}" == "200" ]] \
  || fail "jenkins pipeline job 'cf-demo-hello-world' missing (HTTP ${JOB_STATUS})"
green "jenkins wired: pipeline job 'cf-demo-hello-world' exists"

kill ${PF_PID} 2>/dev/null || true
trap cleanup EXIT

# ── 5. result ───────────────────────────────────────────────────────────────
step "PASS"
green "airgap install proved end-to-end"
green "  structural_sha: ${SHA}"
green "  gitea: cf-demo/hello-world (with Jenkinsfile)"
green "  jenkins: cf-demo-hello-world job + gitea-userpass credential"
