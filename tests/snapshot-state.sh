#!/usr/bin/env bash
# Snapshot the user-visible state that must survive an upgrade (gate 5):
# Gitea repo commits, Jenkins build numbers, Nexus docker tags. Prints JSON.
set -euo pipefail
NS="${1:-clusterfactory}"
K="${KUBECTL:-kubectl}"
GPW=$($K get secret cf-gitea-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d)
JPW=$($K get secret cf-jenkins-admin -n "$NS" -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
NPW=$($K get secret cf-nexus-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d)
GP=$($K get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')
commits=$($K exec -n "$NS" "$GP" -c gitea -- curl -s -u "gitea-admin:${GPW}" "http://localhost:3000/api/v1/repos/cf-demo/hello-world/commits?limit=50" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
builds=$($K exec -n "$NS" jenkins-0 -c jenkins -- curl -sg -u "admin:${JPW}" "http://localhost:8080/job/cf-demo-hello-world/api/json?tree=builds[number]" | python3 -c 'import json,sys;print(sorted(b["number"] for b in json.load(sys.stdin)["builds"]))')
tags=$($K exec -n "$NS" nexus-0 -c nexus -- curl -s -u "admin:${NPW}" http://localhost:5000/v2/cf-demo/hello-world/tags/list | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin).get("tags") or []))')
python3 - "$commits" "$builds" "$tags" <<'PY'
import json, sys, ast
print(json.dumps({"gitea_commits": int(sys.argv[1]), "jenkins_builds": ast.literal_eval(sys.argv[2]), "nexus_tags": ast.literal_eval(sys.argv[3])}))
PY
