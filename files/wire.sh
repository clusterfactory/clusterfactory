#!/bin/sh
# clusterfactory wiring script.
#
# Runs as a post-install Helm hook. Idempotent — safe to re-run.
#
# Inputs (env):
#   MODE              gitea-actions | jenkins | both
#   GITEA_SVC         Gitea service DNS name (e.g. cf-gitea-http.cicd.svc.cluster.local)
#   GITEA_PORT        Gitea HTTP port (default 3000)
#   GITEA_USER        Gitea admin username
#   GITEA_PASS        Gitea admin password
#   JENKINS_SVC       Jenkins service DNS (only used when jenkins enabled)
#   JENKINS_PORT      Jenkins HTTP port (default 8080)
#   JENKINS_USER      Jenkins admin username (typically "admin")
#   JENKINS_PASS      Jenkins admin password (read from <release>-jenkins secret)
#   ORG               Gitea org to create
#   REPO              Gitea repo name to bootstrap
#   REPO_DESCRIPTION  Gitea repo description
#   JENKINS_JOB       Jenkins job name (only used when jenkins enabled)
#   JENKINSFILE_B64   base64 of the Jenkinsfile (mounted via ConfigMap)
#   WORKFLOW_B64      base64 of the Gitea Actions workflow (mounted via ConfigMap)
#   RUNNER_SECRET     Name of the secret to write the runner registration token into
#   NAMESPACE         Release namespace (used for kubectl-style API calls)
#   RESULT_CONFIGMAP  Name of the ConfigMap to write the structural hash into
#
# Outputs:
#   - Gitea: org, repo, bootstrap files, optional API token for Jenkins, optional runner token
#   - Jenkins: job configured to poll/webhook the Gitea repo
#   - Webhook on Gitea repo pointing at Jenkins (jenkins/both modes)
#   - Runner registration token in a secret (gitea-actions/both modes)
#   - <RESULT_CONFIGMAP> with structural_sha = sha256 of sorted producer:consumer:kind tuples

set -eu

: "${MODE:?MODE must be set}"
: "${GITEA_SVC:?GITEA_SVC must be set}"
: "${GITEA_USER:?GITEA_USER must be set}"
: "${GITEA_PASS:?GITEA_PASS must be set}"
: "${ORG:?ORG must be set}"
: "${REPO:?REPO must be set}"
: "${NAMESPACE:?NAMESPACE must be set}"
: "${RESULT_CONFIGMAP:?RESULT_CONFIGMAP must be set}"

GITEA_PORT="${GITEA_PORT:-3000}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
GITEA_URL="http://${GITEA_SVC}:${GITEA_PORT}"
JENKINS_URL="http://${JENKINS_SVC:-unset}:${JENKINS_PORT}"

# Track wires performed for the structural hash.
# Format: producer:consumer:kind  (one per line)
WIRES=""

log() { printf 'wire | %s\n' "$*"; }
fail() { printf 'wire | FAIL: %s\n' "$*" >&2; exit 1; }

record_wire() {
  # $1=producer $2=consumer $3=kind
  WIRES="${WIRES}${1}:${2}:${3}
"
}

# ── readiness ─────────────────────────────────────────────────────────────

wait_for_url() {
  url="$1"; name="$2"; max=60
  i=0
  while [ "$i" -lt "$max" ]; do
    if curl -fsS -o /dev/null --max-time 5 "$url"; then
      log "${name} ready at ${url}"
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done
  fail "${name} not ready after $((max * 5))s at ${url}"
}

# ── gitea helpers ─────────────────────────────────────────────────────────

gitea_curl() {
  # $1=method $2=path $3=body(optional)
  method="$1"; path="$2"; body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      -H "Content-Type: application/json" \
      -X "$method" "${GITEA_URL}${path}" \
      --data "$body"
  else
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      -X "$method" "${GITEA_URL}${path}"
  fi
}

# Soft variants — return body, don't fail on non-2xx (used to check existence).
gitea_curl_soft() {
  method="$1"; path="$2"
  curl -sS -u "${GITEA_USER}:${GITEA_PASS}" \
    -o /tmp/resp -w '%{http_code}' \
    -X "$method" "${GITEA_URL}${path}"
}

gitea_ensure_org() {
  log "ensuring org: ${ORG}"
  code=$(gitea_curl_soft GET "/api/v1/orgs/${ORG}")
  if [ "$code" = "200" ]; then
    log "org exists: ${ORG}"
    return 0
  fi
  gitea_curl POST "/api/v1/orgs" \
    "{\"username\":\"${ORG}\",\"visibility\":\"public\"}" >/dev/null
  log "org created: ${ORG}"
}

gitea_ensure_repo() {
  log "ensuring repo: ${ORG}/${REPO}"
  code=$(gitea_curl_soft GET "/api/v1/repos/${ORG}/${REPO}")
  if [ "$code" = "200" ]; then
    log "repo exists: ${ORG}/${REPO}"
    return 0
  fi
  gitea_curl POST "/api/v1/orgs/${ORG}/repos" \
    "{\"name\":\"${REPO}\",\"description\":\"${REPO_DESCRIPTION:-}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null
  log "repo created: ${ORG}/${REPO}"
  # Brief pause for git backend to settle.
  sleep 2
}

gitea_push_file() {
  # $1=path $2=base64-content $3=commit-message
  path="$1"; b64="$2"; msg="$3"
  log "pushing ${path}"
  # Check existing.
  code=$(gitea_curl_soft GET "/api/v1/repos/${ORG}/${REPO}/contents/${path}")
  if [ "$code" = "200" ]; then
    sha=$(grep -o '"sha":"[^"]*"' /tmp/resp | head -1 | cut -d'"' -f4)
    gitea_curl PUT "/api/v1/repos/${ORG}/${REPO}/contents/${path}" \
      "{\"message\":\"${msg}\",\"content\":\"${b64}\",\"sha\":\"${sha}\"}" >/dev/null
    log "${path} updated"
  else
    gitea_curl POST "/api/v1/repos/${ORG}/${REPO}/contents/${path}" \
      "{\"message\":\"${msg}\",\"content\":\"${b64}\"}" >/dev/null
    log "${path} created"
  fi
}

gitea_mint_token() {
  # $1=token-name (consumer-scoped, e.g. "jenkins-wiring")
  # Idempotent: revoke existing token of same name first, then create.
  name="$1"
  log "minting token: ${name}"
  # List tokens, find by name, delete if present.
  tokens_json=$(gitea_curl GET "/api/v1/users/${GITEA_USER}/tokens" || echo '[]')
  existing_id=$(echo "$tokens_json" \
    | tr ',' '\n' \
    | awk -v n="$name" '
        /"name"[[:space:]]*:/ { gsub(/.*"name"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); cur=$0 }
        /"id"[[:space:]]*:/   { gsub(/.*"id"[[:space:]]*:[[:space:]]*/, ""); gsub(/[^0-9].*/, ""); if (cur==n) print $0 }
      ' | head -1)
  if [ -n "$existing_id" ]; then
    log "revoking prior token id=${existing_id}"
    gitea_curl_soft DELETE "/api/v1/users/${GITEA_USER}/tokens/${existing_id}" >/dev/null
  fi
  resp=$(gitea_curl POST "/api/v1/users/${GITEA_USER}/tokens" \
    "{\"name\":\"${name}\",\"scopes\":[\"write:repository\",\"write:user\",\"write:organization\"]}")
  token=$(echo "$resp" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$token" ]; then
    fail "token mint did not return sha1"
  fi
  printf '%s' "$token"
}

gitea_mint_runner_token() {
  # Mint Gitea Actions runner registration token.
  log "minting runner registration token"
  resp=$(gitea_curl POST "/api/v1/orgs/${ORG}/actions/runners/registration-token" "")
  token=$(echo "$resp" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$token" ]; then
    # Fallback: instance-level token (admin only).
    resp=$(gitea_curl GET "/api/v1/admin/runners/registration-token")
    token=$(echo "$resp" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  fi
  if [ -z "$token" ]; then
    fail "runner token mint did not return token"
  fi
  printf '%s' "$token"
}

gitea_ensure_webhook() {
  # $1=target-url
  # Idempotent: list webhooks, delete prior with same URL, recreate.
  target="$1"
  log "ensuring webhook → ${target}"
  hooks_json=$(gitea_curl GET "/api/v1/repos/${ORG}/${REPO}/hooks" || echo '[]')
  existing_id=$(echo "$hooks_json" \
    | tr ',' '\n' \
    | awk -v u="$target" '
        /"url"[[:space:]]*:/ { gsub(/.*"url"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); cur=$0 }
        /"id"[[:space:]]*:/  { gsub(/.*"id"[[:space:]]*:[[:space:]]*/, ""); gsub(/[^0-9].*/, ""); if (cur==u) print $0 }
      ' | head -1)
  if [ -n "$existing_id" ]; then
    log "removing prior webhook id=${existing_id}"
    gitea_curl_soft DELETE "/api/v1/repos/${ORG}/${REPO}/hooks/${existing_id}" >/dev/null
  fi
  gitea_curl POST "/api/v1/repos/${ORG}/${REPO}/hooks" \
    "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${target}\",\"content_type\":\"json\"}}" >/dev/null
  log "webhook configured"
}

# ── jenkins helpers ───────────────────────────────────────────────────────

jenkins_curl() {
  method="$1"; path="$2"; body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "Content-Type: application/xml" \
      -X "$method" "${JENKINS_URL}${path}" \
      --data "$body"
  else
    curl -fsS -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -X "$method" "${JENKINS_URL}${path}"
  fi
}

jenkins_curl_soft() {
  method="$1"; path="$2"
  curl -sS -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -o /tmp/resp -w '%{http_code}' \
    -X "$method" "${JENKINS_URL}${path}"
}

jenkins_ensure_job() {
  # Create or update a pipeline job that pulls the Jenkinsfile from Gitea.
  log "ensuring jenkins job: ${JENKINS_JOB}"

  giteaTokenForJenkins="$1"
  # Authenticated clone URL (admin user + token).
  authUrl="http://${GITEA_USER}:${giteaTokenForJenkins}@${GITEA_SVC}:${GITEA_PORT}/${ORG}/${REPO}.git"

  # config.xml for a pipeline job that fetches Jenkinsfile from Gitea.
  cat >/tmp/job-config.xml <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>ClusterFactory bootstrap pipeline — wired by post-install Job.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers/>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${authUrl}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
XML

  code=$(jenkins_curl_soft GET "/job/${JENKINS_JOB}/config.xml")
  if [ "$code" = "200" ]; then
    log "updating existing job ${JENKINS_JOB}"
    jenkins_curl POST "/job/${JENKINS_JOB}/config.xml" "$(cat /tmp/job-config.xml)" >/dev/null
  else
    log "creating job ${JENKINS_JOB}"
    jenkins_curl POST "/createItem?name=${JENKINS_JOB}" "$(cat /tmp/job-config.xml)" >/dev/null
  fi
  log "jenkins job ready: ${JENKINS_JOB}"
}

# ── kubernetes secret helpers ─────────────────────────────────────────────
# Use the K8s API directly (we have a ServiceAccount token) — avoids dragging
# in kubectl. Just need to upsert one Opaque secret with one key.

k8s_curl() {
  method="$1"; path="$2"; body="${3:-}"
  KUBE_API="https://kubernetes.default.svc"
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  if [ -n "$body" ]; then
    curl -fsS --cacert "$CACERT" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -X "$method" "${KUBE_API}${path}" \
      --data "$body"
  else
    curl -fsS --cacert "$CACERT" \
      -H "Authorization: Bearer ${TOKEN}" \
      -X "$method" "${KUBE_API}${path}"
  fi
}

k8s_curl_soft() {
  method="$1"; path="$2"
  KUBE_API="https://kubernetes.default.svc"
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  curl -sS --cacert "$CACERT" \
    -H "Authorization: Bearer ${TOKEN}" \
    -o /tmp/k8s-resp -w '%{http_code}' \
    -X "$method" "${KUBE_API}${path}"
}

upsert_secret() {
  # $1=name $2=key $3=value (plain)
  name="$1"; key="$2"; value="$3"
  b64=$(printf '%s' "$value" | base64 | tr -d '\n')
  body=$(cat <<JSON
{"apiVersion":"v1","kind":"Secret","metadata":{"name":"${name}"},"type":"Opaque","data":{"${key}":"${b64}"}}
JSON
)
  code=$(k8s_curl_soft GET "/api/v1/namespaces/${NAMESPACE}/secrets/${name}")
  if [ "$code" = "200" ]; then
    # Patch.
    patch=$(cat <<JSON
{"data":{"${key}":"${b64}"}}
JSON
)
    KUBE_API="https://kubernetes.default.svc"
    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    curl -fsS --cacert "$CACERT" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/strategic-merge-patch+json" \
      -X PATCH "${KUBE_API}/api/v1/namespaces/${NAMESPACE}/secrets/${name}" \
      --data "$patch" >/dev/null
    log "secret patched: ${name}"
  else
    k8s_curl POST "/api/v1/namespaces/${NAMESPACE}/secrets" "$body" >/dev/null
    log "secret created: ${name}"
  fi
}

upsert_result_configmap() {
  # $1=structural_sha $2=mode $3=wires-newline-list
  sha="$1"; mode="$2"; wires="$3"
  # Escape newlines in wires for JSON.
  wires_json=$(printf '%s' "$wires" | awk 'BEGIN{ORS="\\n"} {print}')
  body=$(cat <<JSON
{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"${RESULT_CONFIGMAP}"},"data":{"structural_sha":"${sha}","mode":"${mode}","wires":"${wires_json}"}}
JSON
)
  code=$(k8s_curl_soft GET "/api/v1/namespaces/${NAMESPACE}/configmaps/${RESULT_CONFIGMAP}")
  if [ "$code" = "200" ]; then
    KUBE_API="https://kubernetes.default.svc"
    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    curl -fsS --cacert "$CACERT" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -X PUT "${KUBE_API}/api/v1/namespaces/${NAMESPACE}/configmaps/${RESULT_CONFIGMAP}" \
      --data "$body" >/dev/null
    log "result configmap updated: ${RESULT_CONFIGMAP}"
  else
    k8s_curl POST "/api/v1/namespaces/${NAMESPACE}/configmaps" "$body" >/dev/null
    log "result configmap created: ${RESULT_CONFIGMAP}"
  fi
}

# ── main flow ─────────────────────────────────────────────────────────────

log "starting | mode=${MODE} namespace=${NAMESPACE}"

# 1. Wait for Gitea (always present).
wait_for_url "${GITEA_URL}/api/healthz" "gitea"

# 2. Bootstrap Gitea: org, repo, default files.
gitea_ensure_org
gitea_ensure_repo

# Push the Jenkinsfile if jenkins is involved.
case "$MODE" in
  jenkins|both)
    if [ -n "${JENKINSFILE_B64:-}" ]; then
      gitea_push_file "Jenkinsfile" "$JENKINSFILE_B64" "Add Jenkinsfile (clusterfactory bootstrap)"
    fi
    ;;
esac

# Push the Gitea Actions workflow if actions are involved.
case "$MODE" in
  gitea-actions|both)
    if [ -n "${WORKFLOW_B64:-}" ]; then
      gitea_push_file ".gitea/workflows/ci.yaml" "$WORKFLOW_B64" "Add Gitea Actions workflow (clusterfactory bootstrap)"
    fi
    ;;
esac

# 3. Mode-specific wiring.

case "$MODE" in
  gitea-actions|both)
    # Mint a runner registration token, store it in a secret the runner DaemonSet reads.
    runner_token=$(gitea_mint_runner_token)
    upsert_secret "${RUNNER_SECRET}" "token" "$runner_token"
    record_wire "gitea" "runner" "RunnerToken"
    ;;
esac

case "$MODE" in
  jenkins|both)
    # Mint a Gitea API token for Jenkins to use as git credentials.
    gitea_token=$(gitea_mint_token "jenkins-wiring")
    record_wire "gitea" "jenkins" "ApiToken"

    # Wait for Jenkins.
    wait_for_url "${JENKINS_URL}/login" "jenkins"

    # Configure the Jenkins job.
    jenkins_ensure_job "$gitea_token"
    record_wire "jenkins" "jenkins" "JobConfig"

    # Webhook from Gitea repo → Jenkins job trigger.
    webhook_target="${JENKINS_URL}/gitea-webhook/post"
    gitea_ensure_webhook "$webhook_target"
    record_wire "gitea" "jenkins" "Webhook"
    ;;
esac

# 4. Compute structural hash and write result ConfigMap.

# Sort wires, sha256, write result.
sorted_wires=$(printf '%s' "$WIRES" | grep -v '^$' | sort -u || true)
if [ -z "$sorted_wires" ]; then
  structural_sha=$(printf '' | sha256sum | cut -d' ' -f1)
else
  structural_sha=$(printf '%s\n' "$sorted_wires" | sha256sum | cut -d' ' -f1)
fi

log "structural_sha=${structural_sha}"
log "wires:"
printf '%s\n' "$sorted_wires" | sed 's/^/wire |   /'

upsert_result_configmap "$structural_sha" "$MODE" "$sorted_wires"

log "done"
