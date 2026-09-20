#!/usr/bin/env bash
# Run the demo pipeline on a deployed clusterfactory and check the result.
# Paste-safe: every line is short. Run as root on the RKE2 host:
#   curl -sLO https://raw.githubusercontent.com/clusterfactory/clusterfactory/refactor/uds-step-10a-preflight/hack/vm-demo.sh
#   bash vm-demo.sh            # trigger + wait + verify
#   bash vm-demo.sh status     # just show state
#   bash vm-demo.sh console    # last build's console tail
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export PATH="$PATH:/var/lib/rancher/rke2/bin"
NS=clusterfactory
JOB=cf-demo-hello-world

JPW=$(kubectl get secret cf-jenkins-admin -n "$NS" -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
NPW=$(kubectl get secret cf-nexus-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d)
J() { kubectl exec -n "$NS" jenkins-0 -c jenkins -- curl -sg -u "admin:${JPW}" "$@"; }
N() { kubectl exec -n "$NS" nexus-0 -c nexus -- curl -s -u "admin:${NPW}" "$@"; }

status() {
  echo "== pods"; kubectl get pods -n "$NS"; kubectl get pods -n cf-build 2>/dev/null
  echo "== wire engine"; kubectl logs -n "$NS" -l app.kubernetes.io/name=cf-wire-engine --tail=30 | grep -v '^\[     ok\]'
  echo "== last build"
  J "http://localhost:8080/job/${JOB}/lastBuild/api/json?tree=number,result,building"; echo
  echo "== nexus tags"
  N http://localhost:5000/v2/cf-demo/hello-world/tags/list; echo
}

console() { J "http://localhost:8080/job/${JOB}/lastBuild/consoleText" | grep -v '^\[Pipeline\]' | tail -40; }

trigger() {
  local crumb next result
  crumb=$(J -c /tmp/cf-cj http://localhost:8080/crumbIssuer/api/json | python3 -c 'import json,sys;print(json.load(sys.stdin)["crumb"])')
  next=$(J "http://localhost:8080/job/${JOB}/api/json?tree=nextBuildNumber" | python3 -c 'import json,sys;print(json.load(sys.stdin)["nextBuildNumber"])')
  J -b /tmp/cf-cj -H "Jenkins-Crumb: ${crumb}" -X POST -o /dev/null -w "triggered build #${next}: HTTP %{http_code}\n" "http://localhost:8080/job/${JOB}/build"
  echo "waiting for build #${next} (pod agent in cf-build, Kaniko build, push to Nexus)..."
  for _ in $(seq 1 120); do
    result=$(J "http://localhost:8080/job/${JOB}/${next}/api/json?tree=result" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("result") or "")' 2>/dev/null)
    [ -n "$result" ] && break
    sleep 5
  done
  echo "build #${next}: ${result:-still running after 10 min}"
  echo "== nexus tags"; N http://localhost:5000/v2/cf-demo/hello-world/tags/list; echo
  [ "$result" = "SUCCESS" ] || { echo "== console tail"; console; }
}

case "${1:-run}" in
  status) status ;;
  console) console ;;
  *) trigger ;;
esac
