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
