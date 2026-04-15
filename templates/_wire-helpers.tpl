{{/*
Wire container specification - bash engine
*/}}
{{- define "clusterfactory.wire.bash" -}}
image: {{ .Values.wire.image.bash }}
command: [sh, -c]
args:
  - |
    set -eu
    apk add -q curl jq

    log()  { echo "[wire] $*"; }
    die()  { echo "[wire] ERROR: $*" >&2; exit 1; }

    GITEA_URL="http://${GITEA_SVC}:3000"
    JENKINS_URL="http://${JENKINS_SVC}:8080"

    # ── Wait for Gitea ──────────────────────────────────────
    log "Waiting for Gitea..."
    i=0
    while [ $i -lt 60 ]; do
      code=$(curl -o /dev/null -sw "%{http_code}" --connect-timeout 3 "${GITEA_URL}" 2>/dev/null || true)
      [ "$code" = "200" ] && break
      i=$((i+1)); sleep 5
    done
    [ "$code" = "200" ] || die "Gitea not ready"
    log "Gitea ready"

    # ── Mint API token ──────────────────────────────────────
    log "Minting Gitea API token..."
    existing=$(curl -fsSL -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens" \
      | jq -r '.[] | select(.name=="jenkins-wiring") | .id // empty' 2>/dev/null || true)
    if [ -n "$existing" ]; then
      curl -fsSL -X DELETE \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens/${existing}" > /dev/null
    fi
    token_json=$(curl -fsSL -X POST \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -H "Content-Type: application/json" \
      -d '{"name":"jenkins-wiring","scopes":["write:repository","write:user","write:organization","write:issue"]}' \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens")
    GITEA_TOKEN=$(echo "$token_json" | jq -r ".sha1")
    [ -z "$GITEA_TOKEN" ] || [ "$GITEA_TOKEN" = "null" ] \
      && die "Token mint failed: $token_json"
    log "Token minted"

    # ── Create org ──────────────────────────────────────────
    log "Creating org ${ORG}..."
    curl -o /dev/null -w "" -fsSL -X POST \
      -H "Authorization: token ${GITEA_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${ORG}\",\"visibility\":\"private\"}" \
      "${GITEA_URL}/api/v1/orgs" 2>/dev/null || true

    # ── Wait for Jenkins ────────────────────────────────────
    log "Waiting for Jenkins..."
    i=0
    while [ $i -lt 60 ]; do
      code=$(curl -o /dev/null -sw "%{http_code}" --connect-timeout 3 \
        "${JENKINS_URL}/login" 2>/dev/null || true)
      [ "$code" = "200" ] && break
      i=$((i+1)); sleep 5
    done
    [ "$code" = "200" ] || die "Jenkins not ready"
    log "Jenkins ready"

    # ── Jenkins crumb ───────────────────────────────────────
    crumb_json=$(curl -fsSL \
      -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -c /tmp/jk-cookie.txt \
      "${JENKINS_URL}/crumbIssuer/api/json")
    crumb=$(echo "$crumb_json" | jq -r ".crumb")
    crumb_field=$(echo "$crumb_json" | jq -r ".crumbRequestField")
    [ -z "$crumb" ] || [ "$crumb" = "null" ] \
      && die "Crumb failed: $crumb_json"

    # ── Upsert Jenkins credential ───────────────────────────
    upsert_cred() {
      local id="$1" xml="$2"
      curl -fsSL -X POST \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -b /tmp/jk-cookie.txt \
        -H "${crumb_field}: ${crumb}" \
        "${JENKINS_URL}/credentials/store/system/domain/_/credential/${id}/doDelete" \
        > /dev/null 2>&1 || true
      local http
      http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X POST \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -b /tmp/jk-cookie.txt \
        -H "${crumb_field}: ${crumb}" \
        -H "Content-Type: application/xml" \
        --data-binary "$xml" \
        "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" 2>/dev/null || true)
      log "Credential ${id}: HTTP ${http}"
    }

    upsert_cred "gitea-api-token" \
      "<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl plugin=\"plain-credentials\">
        <scope>GLOBAL</scope><id>gitea-api-token</id>
        <description>Gitea API token</description>
        <secret>${GITEA_TOKEN}</secret>
      </org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>"

    upsert_cred "gitea-userpass" \
      "<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
        <scope>GLOBAL</scope><id>gitea-userpass</id>
        <description>Gitea username + API token (git clone)</description>
        <username>${GITEA_USER}</username>
        <password>${GITEA_TOKEN}</password>
      </com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"

    # ── Create Gitea repo ───────────────────────────────────
    log "Creating Gitea repo ${ORG}/${REPO}..."
    repo_http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X POST \
      -H "Authorization: token ${GITEA_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${REPO}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}" \
      "${GITEA_URL}/api/v1/orgs/${ORG}/repos" 2>/dev/null || true)
    log "Repo: HTTP ${repo_http} (201=created 409=exists)"

    # ── Push files via Contents API (no git needed) ─────────
    push_file() {
      local fpath="$1" b64="$2" msg="$3"
      local sha
      sha=$(curl -fsSL \
        -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}/contents/${fpath}" 2>/dev/null \
        | jq -r '.sha // empty' 2>/dev/null || true)
      if [ -n "$sha" ]; then
        http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X PUT \
          -H "Authorization: token ${GITEA_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"message\":\"update ${fpath}\",\"content\":\"${b64}\",\"sha\":\"${sha}\"}" \
          "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}/contents/${fpath}" 2>/dev/null || true)
        log "${fpath} update: HTTP ${http}"
      else
        http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X POST \
          -H "Authorization: token ${GITEA_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"message\":\"${msg}\",\"content\":\"${b64}\"}" \
          "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}/contents/${fpath}" 2>/dev/null || true)
        log "${fpath} create: HTTP ${http}"
      fi
    }

    push_file "Jenkinsfile"                    "${JENKINSFILE_B64}"  "initial commit"
    push_file ".gitea/workflows/ci.yaml"       "${WORKFLOW_B64}"     "add Gitea Actions workflow"

    # ── Create Jenkins job ──────────────────────────────────
    JOB_NAME="${ORG}-${REPO}"
    CLONE_URL="http://${GITEA_SVC}:3000/${ORG}/${REPO}.git"
    log "Creating Jenkins job ${JOB_NAME}..."
    JOB_XML="<?xml version=\"1.1\" encoding=\"UTF-8\"?>
    <flow-definition plugin=\"workflow-job\">
      <description>${JOB_NAME}</description>
      <keepDependencies>false</keepDependencies>
      <definition class=\"org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition\" plugin=\"workflow-cps\">
        <scm class=\"hudson.plugins.git.GitSCM\" plugin=\"git\">
          <configVersion>2</configVersion>
          <userRemoteConfigs>
            <hudson.plugins.git.UserRemoteConfig>
              <url>${CLONE_URL}</url>
              <credentialsId>gitea-userpass</credentialsId>
            </hudson.plugins.git.UserRemoteConfig>
          </userRemoteConfigs>
          <branches>
            <hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec>
          </branches>
          <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
          <extensions/>
        </scm>
        <scriptPath>Jenkinsfile</scriptPath>
        <lightweight>true</lightweight>
      </definition>
      <triggers/><disabled>false</disabled>
    </flow-definition>"

    job_http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X POST \
      -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -b /tmp/jk-cookie.txt \
      -H "${crumb_field}: ${crumb}" \
      -H "Content-Type: application/xml" \
      --data-binary "${JOB_XML}" \
      "${JENKINS_URL}/createItem?name=${JOB_NAME}" 2>/dev/null || true)
    if [ "$job_http" = "400" ]; then
      job_http=$(curl -o /dev/null -w "%{http_code}" -fsSL -X POST \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -b /tmp/jk-cookie.txt \
        -H "${crumb_field}: ${crumb}" \
        -H "Content-Type: application/xml" \
        --data-binary "${JOB_XML}" \
        "${JENKINS_URL}/job/${JOB_NAME}/config.xml" 2>/dev/null || true)
      log "Jenkins job update: HTTP ${job_http}"
    else
      log "Jenkins job create: HTTP ${job_http}"
    fi

    log "Done."
    log "  Gitea repo : ${GITEA_URL}/${ORG}/${REPO}"
    log "  Jenkins job: ${JENKINS_URL}/job/${JOB_NAME}"

    # ── Runner registration token → k8s Secret ──────────────
    log "Fetching runner registration token..."
    reg_json=$(curl -fsSL -X GET \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/admin/runners/registration-token" 2>/dev/null || true)
    reg_token=$(echo "$reg_json" | jq -r ".token // empty")
    if [ -z "$reg_token" ]; then
      log "WARN: could not get runner registration token"
    else
      reg_token_b64=$(printf '%s' "${reg_token}" | base64 | tr -d '\n')
      K8S="https://kubernetes.default.svc"
      SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
      CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      # Try PATCH first (update); fall back to POST (create)
      patch_status=$(curl -o /dev/null -w "%{http_code}" -fsSL -X PATCH \
        -H "Authorization: Bearer ${SA_TOKEN}" \
        -H "Content-Type: application/merge-patch+json" \
        --cacert "${CACERT}" \
        "${K8S}/api/v1/namespaces/${NAMESPACE}/secrets/${RUNNER_SECRET_NAME}" \
        -d "{\"data\":{\"token\":\"${reg_token_b64}\"}}" 2>/dev/null || true)
      if [ "$patch_status" = "404" ]; then
        curl -fsSL -X POST \
          -H "Authorization: Bearer ${SA_TOKEN}" \
          -H "Content-Type: application/json" \
          --cacert "${CACERT}" \
          "${K8S}/api/v1/namespaces/${NAMESPACE}/secrets" \
          -d "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${RUNNER_SECRET_NAME}\",\"namespace\":\"${NAMESPACE}\"},\"data\":{\"token\":\"${reg_token_b64}\"}}" > /dev/null
        log "Runner token secret created"
      else
        log "Runner token secret updated"
      fi
      
      log ""
      log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      log "NEXT: Install Runner on Kubernetes Host"
      log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      log ""
      log "Get token: kubectl get secret ${RUNNER_SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.token}' | base64 -d"
      log "Install: See docs/runner-host-install.md"
      log ""
    fi

    log "Wiring complete"
{{- end }}

{{/*
Wire container specification - Python engine
*/}}
{{- define "clusterfactory.wire.python" -}}
image: {{ .Values.wire.image.python }}
command: ["python", "-m", "factory"]
args:
  - "--platform"
  - "/config/platform.yaml"
  - "--namespace"
  - "{{ .Release.Namespace }}"
  - "--log-level"
  - "INFO"
volumeMounts:
  - name: platform-config
    mountPath: /config
    readOnly: true
{{- end }}

{{/*
Select wire container spec based on engine
*/}}
{{- define "clusterfactory.wire.container" -}}
{{- if eq .Values.wire.engine "python" }}
{{- include "clusterfactory.wire.python" . }}
{{- else }}
{{- include "clusterfactory.wire.bash" . }}
{{- end }}
{{- end }}
