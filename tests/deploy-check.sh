#!/usr/bin/env bash
# Gate 3 (uds-way.md §11): assert the package is healthy in an egress-blocked cluster.
#   - every pod in the package namespace is Ready
#   - Gitea and Jenkins answer over their ClusterIP Services
#   - egress to the internet from the package namespace is blocked
# Usage: tests/deploy-check.sh [namespace]   (default: clusterfactory)
set -euo pipefail
NS="${1:-clusterfactory}"
KUBECTL="${KUBECTL:-kubectl}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

echo "== pods in ${NS}"
$KUBECTL get pods -n "$NS" -o wide
$KUBECTL wait --for=condition=Ready pod --all -n "$NS" --timeout=600s >/dev/null || fail "not all pods Ready in ${NS}"
ok "all pods Ready"

# Curl from inside the cluster using an image the package already ships -
# the exact (agent-rewritten) reference the Gitea Deployment runs, so the
# probe pod pulls from the Zarf registry too.
PROBE_IMAGE=$($KUBECTL get deploy gitea -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
probe() {
  local name="$1" url="$2" expect="$3" curlargs="${4:-}"
  local out
  out=$($KUBECTL run "probe-${name}-$RANDOM" -n "$NS" --rm -i --restart=Never --quiet \
      --image="$PROBE_IMAGE" --image-pull-policy=IfNotPresent \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"p","image":"'"$PROBE_IMAGE"'","command":["sh","-c","curl -s -o /dev/null -m 10 '"$curlargs"' -w \"%{http_code}\n\" '"$url"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
      2>/dev/null | tr -d '\r' | tail -1 || true)  # kubectl run exits non-zero when curl does
  [[ "$out" == "$expect" ]] || fail "${name}: expected ${expect}, got '${out}' (${url})"
  ok "${name}: ${out}"
}

echo "== every image is served by the Zarf registry (agent rewrote it)"
REGISTRY=$($KUBECTL get secret -n zarf zarf-state -o jsonpath='{.data.state}' | base64 -d | python3 -c 'import json,sys; print(json.load(sys.stdin)["registryInfo"]["address"])')
bad=$($KUBECTL get pods -n "$NS" -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -v "^${REGISTRY}/" || true)
[[ -z "$bad" ]] || fail "images not from the Zarf registry (${REGISTRY}) - namespace pre-dates zarf init?:\n${bad}"
ok "all images from ${REGISTRY}"

echo "== service reachability"
probe gitea   "http://gitea-http.${NS}.svc.cluster.local:3000/api/healthz" 200
probe jenkins "http://jenkins.${NS}.svc.cluster.local:8080/login" 200

echo "== admin credentials from the cf-config Secrets work"
GITEA_PW=$($KUBECTL get secret cf-gitea-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d)
JENKINS_PW=$($KUBECTL get secret cf-jenkins-admin -n "$NS" -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
probe gitea-auth   "http://gitea-http.${NS}.svc.cluster.local:3000/api/v1/user" 200 "-u gitea-admin:${GITEA_PW}"
probe jenkins-auth "http://jenkins.${NS}.svc.cluster.local:8080/api/json" 200 "-u admin:${JENKINS_PW}"

echo "== egress is blocked"
probe egress "http://example.com/" 000  # curl reports 000 when it cannot connect
