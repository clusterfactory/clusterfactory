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
# Long-running workloads only; the wire-engine Job's pods finish (checked below).
$KUBECTL wait --for=condition=Ready pod -l 'app.kubernetes.io/name!=cf-wire-engine' -n "$NS" --timeout=600s >/dev/null \
  || fail "not all pods Ready in ${NS}"
ok "all workload pods Ready"

# Curl from inside the cluster using an image the package already ships -
# the exact (agent-rewritten) reference the running Gitea pod uses, so the
# probe pod pulls from the Zarf registry too. (Read the Pod, not the
# Deployment: after a helm upgrade the Deployment template carries the
# upstream reference again and only the Pod has the rewritten one.)
PROBE_IMAGE=$($KUBECTL get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].spec.containers[0].image}')
probe() {
  local name="$1" url="$2" expect="$3" curlargs="${4:-}"
  local pod="probe-${name}-$RANDOM" out
  # Create, wait, read logs, delete: `kubectl run -i --rm` attaches over a
  # websocket that intermittently drops output, which made this flaky.
  $KUBECTL run "$pod" -n "$NS" --restart=Never --quiet \
      --image="$PROBE_IMAGE" --image-pull-policy=IfNotPresent \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"p","image":"'"$PROBE_IMAGE"'","command":["sh","-c","curl -s -o /dev/null -m 10 '"$curlargs"' -w \"%{http_code}\n\" '"$url"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  for _ in $(seq 1 60); do
    phase=$($KUBECTL get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}')
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 2
  done
  out=$($KUBECTL logs "$pod" -n "$NS" 2>/dev/null | tr -d '\r' | tail -1 || true)
  $KUBECTL delete pod "$pod" -n "$NS" --wait=false >/dev/null 2>&1 || true
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

echo "== every plugin in jenkins/plugins.txt is loaded and active"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON=$($KUBECTL exec -n "$NS" jenkins-0 -c jenkins -- \
  curl -sg -u "admin:${JENKINS_PW}" "http://localhost:8080/pluginManager/api/json?depth=1&tree=plugins[shortName,active,version]")
missing=$(python3 - "$HERE/jenkins/plugins.txt" <<'PY'
import json, sys
want = [l.split(':')[0] for l in open(sys.argv[1]) if l.strip() and not l.startswith('#')]
have = {p['shortName']: p for p in json.loads(sys.stdin.readline())['plugins']}
bad = [w for w in want if w not in have or not have[w]['active']]
print(' '.join(bad))
PY
<<<"$PLUGIN_JSON")
[[ -z "$missing" ]] || fail "plugins not active: ${missing}"
ok "$(grep -cv '^#' "$HERE/jenkins/plugins.txt") top-level plugins active"

echo "== wire engine converged (latest Job Complete, no failed steps)"
WIRE_POD=$($KUBECTL get pod -n "$NS" -l app.kubernetes.io/name=cf-wire-engine --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
WIRE_LOG=$($KUBECTL logs -n "$NS" "$WIRE_POD")
grep -q '^converged:' <<<"$WIRE_LOG" || fail "wire engine did not converge:\n${WIRE_LOG}"
grep -q 'failed' <<<"$WIRE_LOG" && fail "wire engine reported failed steps:\n${WIRE_LOG}"
ok "$(grep '^converged:' <<<"$WIRE_LOG")"
if [[ "${EXPECT_IDEMPOTENT:-}" == "1" ]]; then
  # Gate: a redeploy over a converged cluster changes nothing.
  grep -Eq '^\[ *(created|updated)\]' <<<"$WIRE_LOG" && fail "redeploy was not idempotent:\n${WIRE_LOG}"
  ok "redeploy idempotent (only ok/skipped)"
fi

echo "== demo pipeline builds from Gitea"
JCURL() { $KUBECTL exec -n "$NS" jenkins-0 -c jenkins -- curl -sg -u "admin:${JENKINS_PW}" "$@"; }
CRUMB=$(JCURL -c /tmp/cf-cj http://localhost:8080/crumbIssuer/api/json | python3 -c 'import json,sys;print(json.load(sys.stdin)["crumb"])')
JCURL -b /tmp/cf-cj -H "Jenkins-Crumb: ${CRUMB}" -X POST -o /dev/null http://localhost:8080/job/cf-demo-hello-world/build
result=""
for _ in $(seq 1 60); do
  result=$(JCURL "http://localhost:8080/job/cf-demo-hello-world/lastBuild/api/json?tree=result" 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("result") or "")' 2>/dev/null || true)
  [[ -n "$result" ]] && break
  sleep 5
done
[[ "$result" == "SUCCESS" ]] || fail "demo pipeline result: '${result}'"
ok "cf-demo-hello-world build SUCCESS"

echo "== egress is blocked"
probe egress "http://example.com/" 000  # curl reports 000 when it cannot connect
