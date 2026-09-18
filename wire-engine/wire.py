#!/usr/bin/env python3
"""clusterfactory wire engine (ADR 0002).

Runs as an in-cluster Job after the apps are up and converges the
cross-service wiring. Every step is check-then-act and reports one of
ok / created / updated / skipped. Exit 0 only if every step converged.

Standard library only - nothing to mirror.

Steps (uds-way.md §4):
  1. Gitea: org, repo, Jenkinsfile content
  2. Gitea: integration user + API token, persisted in a Kubernetes Secret
     (tokens are not re-readable; the Secret is the source of truth on re-runs)
  3. Jenkins: username/password credential holding that token
  4. Jenkins: pipeline job pointing at the Gitea repo
"""
from __future__ import annotations

import base64
import hashlib
import http.cookiejar
import json
import os
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as xml_escape

# ---------------------------------------------------------------- config ---

def env(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None:
        sys.exit(f"missing required environment variable {name}")
    return val

GITEA_URL = env("GITEA_URL").rstrip("/")
GITEA_ADMIN_USER = env("GITEA_ADMIN_USER")
GITEA_ADMIN_PASSWORD = env("GITEA_ADMIN_PASSWORD")
JENKINS_URL = env("JENKINS_URL").rstrip("/")
JENKINS_ADMIN_USER = env("JENKINS_ADMIN_USER")
JENKINS_ADMIN_PASSWORD = env("JENKINS_ADMIN_PASSWORD")

DEMO_ORG = env("DEMO_ORG", "cf-demo")
DEMO_REPO = env("DEMO_REPO", "hello-world")
DEMO_BRANCH = env("DEMO_BRANCH", "main")
JENKINSFILE_PATH = env("JENKINSFILE_PATH", "/etc/clusterfactory/demo/Jenkinsfile")
INTEGRATION_USER = env("GITEA_INTEGRATION_USER", "jenkins-ci")
JENKINS_CREDENTIAL_ID = env("JENKINS_CREDENTIAL_ID", "gitea-token")
JENKINS_JOB = env("JENKINS_JOB", f"{DEMO_ORG}-{DEMO_REPO}")
TOKEN_SECRET = env("TOKEN_SECRET_NAME", "cf-wire-gitea-token")
NAMESPACE = env("NAMESPACE")
READY_TIMEOUT = int(env("READY_TIMEOUT_SECONDS", "300"))

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_URL = f"https://{env('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{env('KUBERNETES_SERVICE_PORT', '443')}"

RESULTS: list[tuple[str, str]] = []


def report(step: str, status: str, detail: str = "") -> None:
    RESULTS.append((step, status))
    print(f"[{status:>7}] {step}{' - ' + detail if detail else ''}", flush=True)


# ------------------------------------------------------------------ http ---

class Http:
    """Tiny urllib wrapper: basic auth, JSON, explicit timeouts, no retries.

    Keeps a cookie jar per client: Jenkins ties its CSRF crumb to the
    session cookie, so the crumb is only valid alongside that cookie.
    """

    def __init__(self, base: str, user: str | None = None, password: str | None = None,
                 headers: dict | None = None, context: ssl.SSLContext | None = None):
        self.base, self.headers, self.ctx = base, dict(headers or {}), context
        if user is not None:
            tok = base64.b64encode(f"{user}:{password}".encode()).decode()
            self.headers["Authorization"] = f"Basic {tok}"
        handlers = [urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())]
        if context is not None:
            handlers.append(urllib.request.HTTPSHandler(context=context))
        self.opener = urllib.request.build_opener(*handlers)

    def request(self, method: str, path: str, body: bytes | dict | None = None,
                headers: dict | None = None, timeout: int = 30, ok=(200, 201, 204)):
        url = self.base + path
        hdrs = {**self.headers, **(headers or {})}
        data = body
        if isinstance(body, dict):
            data = json.dumps(body).encode()
            hdrs.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            if e.code in ok:
                return e.code, e.read()
            raise RuntimeError(f"{method} {url} -> {e.code}: {e.read()[:300]!r}") from None

    def json(self, method: str, path: str, body=None, ok=(200, 201, 204), **kw):
        status, raw = self.request(method, path, body, ok=ok, **kw)
        # Tolerated non-2xx responses (e.g. a 404 HTML page) carry no JSON.
        return status, (json.loads(raw) if raw and status < 300 else None)


def wait_ready(name: str, probe) -> None:
    deadline = time.time() + READY_TIMEOUT
    while True:
        try:
            if probe():
                return
        except Exception as e:  # noqa: BLE001 - any failure means "not yet"
            err = e
        else:
            err = "not ready"
        if time.time() > deadline:
            sys.exit(f"{name} not ready after {READY_TIMEOUT}s: {err}")
        time.sleep(5)


# ------------------------------------------------------------ kubernetes ---

def k8s() -> Http:
    token = open(f"{SA_DIR}/token").read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    return Http(K8S_URL, headers={"Authorization": f"Bearer {token}"}, context=ctx)


def secret_get(name: str) -> dict | None:
    status, body = k8s().json("GET", f"/api/v1/namespaces/{NAMESPACE}/secrets/{name}", ok=(200, 404))
    if status == 404:
        return None
    return {k: base64.b64decode(v).decode() for k, v in (body.get("data") or {}).items()}


def secret_put(name: str, data: dict[str, str], exists: bool) -> None:
    manifest = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {"name": name, "namespace": NAMESPACE,
                     "labels": {"app.kubernetes.io/name": "cf-wire-engine",
                                "app.kubernetes.io/part-of": "clusterfactory"}},
        "data": {k: base64.b64encode(v.encode()).decode() for k, v in data.items()},
    }
    if exists:
        k8s().json("PUT", f"/api/v1/namespaces/{NAMESPACE}/secrets/{name}", manifest)
    else:
        k8s().json("POST", f"/api/v1/namespaces/{NAMESPACE}/secrets", manifest)


# ----------------------------------------------------------------- gitea ---

gitea = Http(GITEA_URL, GITEA_ADMIN_USER, GITEA_ADMIN_PASSWORD)


def gitea_ready() -> bool:
    status, _ = gitea.request("GET", "/api/v1/version")
    return status == 200


def step_gitea_org_repo() -> None:
    status, _ = gitea.json("GET", f"/api/v1/orgs/{DEMO_ORG}", ok=(200, 404))
    if status == 404:
        gitea.json("POST", "/api/v1/orgs", {"username": DEMO_ORG, "visibility": "public"})
        report("gitea org", "created", DEMO_ORG)
    else:
        report("gitea org", "ok", DEMO_ORG)

    status, _ = gitea.json("GET", f"/api/v1/repos/{DEMO_ORG}/{DEMO_REPO}", ok=(200, 404))
    if status == 404:
        gitea.json("POST", f"/api/v1/orgs/{DEMO_ORG}/repos", {
            "name": DEMO_REPO, "auto_init": True, "default_branch": DEMO_BRANCH,
            "description": "clusterfactory demo pipeline", "private": False,
        })
        report("gitea repo", "created", f"{DEMO_ORG}/{DEMO_REPO}")
    else:
        report("gitea repo", "ok", f"{DEMO_ORG}/{DEMO_REPO}")


def step_gitea_jenkinsfile() -> None:
    want = open(JENKINSFILE_PATH, "rb").read()
    path = f"/api/v1/repos/{DEMO_ORG}/{DEMO_REPO}/contents/Jenkinsfile?ref={DEMO_BRANCH}"
    status, cur = gitea.json("GET", path, ok=(200, 404))
    payload = {"content": base64.b64encode(want).decode(), "branch": DEMO_BRANCH,
               "message": "clusterfactory: sync demo Jenkinsfile"}
    if status == 404:
        gitea.json("POST", f"/api/v1/repos/{DEMO_ORG}/{DEMO_REPO}/contents/Jenkinsfile", payload)
        report("gitea Jenkinsfile", "created")
    elif base64.b64decode(cur["content"]) == want:
        report("gitea Jenkinsfile", "ok")
    else:
        payload["sha"] = cur["sha"]
        gitea.json("PUT", f"/api/v1/repos/{DEMO_ORG}/{DEMO_REPO}/contents/Jenkinsfile", payload)
        report("gitea Jenkinsfile", "updated")


def step_gitea_token() -> str:
    """Ensure the integration user and a working API token; persist in a Secret."""
    status, _ = gitea.json("GET", f"/api/v1/users/{INTEGRATION_USER}", ok=(200, 404))
    if status == 404:
        gitea.json("POST", "/api/v1/admin/users", {
            "username": INTEGRATION_USER, "email": f"{INTEGRATION_USER}@clusterfactory.local",
            "password": secrets.token_urlsafe(24), "must_change_password": False,
            "visibility": "public",
        })
        report("gitea integration user", "created", INTEGRATION_USER)
    else:
        report("gitea integration user", "ok", INTEGRATION_USER)

    stored = secret_get(TOKEN_SECRET)
    if stored and stored.get("token"):
        st, _ = Http(GITEA_URL, headers={"Authorization": f"token {stored['token']}"}).request(
            "GET", "/api/v1/user", ok=(200, 401))
        if st == 200:
            report("gitea token", "ok", f"secret/{TOKEN_SECRET}")
            return stored["token"]
        report("gitea token", "updated", "stored token rejected by Gitea; minting a new one")

    # Admins may mint tokens for other users with the admin's basic auth.
    token_name = "clusterfactory-jenkins"
    _, existing = gitea.json("GET", f"/api/v1/users/{INTEGRATION_USER}/tokens")
    for t in existing or []:
        if t.get("name") == token_name:
            gitea.request("DELETE", f"/api/v1/users/{INTEGRATION_USER}/tokens/{t['id']}")
    _, tok = gitea.json("POST", f"/api/v1/users/{INTEGRATION_USER}/tokens", {
        "name": token_name, "scopes": ["read:repository", "read:user", "read:organization"],
    })
    token = tok["sha1"]
    secret_put(TOKEN_SECRET, {"username": INTEGRATION_USER, "token": token}, exists=stored is not None)
    report("gitea token", "created" if stored is None else "updated", f"secret/{TOKEN_SECRET}")
    return token


# --------------------------------------------------------------- jenkins ---

jenkins = Http(JENKINS_URL, JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD)
_crumb: dict | None = None


def jenkins_ready() -> bool:
    status, _ = jenkins.request("GET", "/api/json")
    return status == 200


def crumb() -> dict:
    global _crumb
    if _crumb is None:
        _, data = jenkins.json("GET", "/crumbIssuer/api/json")
        _crumb = {data["crumbRequestField"]: data["crumb"]}
    return _crumb


def token_fingerprint(token: str) -> str:
    return "sha256:" + hashlib.sha256(token.encode()).hexdigest()[:16]


def step_jenkins_credential(token: str) -> None:
    fp = token_fingerprint(token)
    xml = f"""<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>{xml_escape(JENKINS_CREDENTIAL_ID)}</id>
  <description>Gitea token for {xml_escape(INTEGRATION_USER)} (managed by cf-wire-engine, {fp})</description>
  <username>{xml_escape(INTEGRATION_USER)}</username>
  <password>{xml_escape(token)}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"""
    base = "/credentials/store/system/domain/_"
    status, cur = jenkins.json("GET", f"{base}/credential/{JENKINS_CREDENTIAL_ID}/api/json", ok=(200, 404))
    hdrs = {**crumb(), "Content-Type": "application/xml"}
    if status == 404:
        jenkins.request("POST", f"{base}/createCredentials", xml.encode(), headers=hdrs)
        report("jenkins credential", "created", JENKINS_CREDENTIAL_ID)
    elif fp in (cur.get("description") or ""):
        report("jenkins credential", "ok", JENKINS_CREDENTIAL_ID)
    else:
        jenkins.request("POST", f"{base}/credential/{JENKINS_CREDENTIAL_ID}/config.xml", xml.encode(), headers=hdrs)
        report("jenkins credential", "updated", JENKINS_CREDENTIAL_ID)


def job_xml(repo_url: str) -> str:
    return f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>clusterfactory demo pipeline for {xml_escape(DEMO_ORG)}/{xml_escape(DEMO_REPO)} (managed by cf-wire-engine)</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>{xml_escape(repo_url)}</url>
          <credentialsId>{xml_escape(JENKINS_CREDENTIAL_ID)}</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/{xml_escape(DEMO_BRANCH)}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>"""


def job_essentials(xml_text: str) -> dict:
    """The fields we manage; Jenkins rewrites the rest of config.xml on save."""
    root = ET.fromstring(xml_text)
    f = lambda p: (root.findtext(p) or "").strip()  # noqa: E731
    return {
        "url": f("definition/scm/userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/url"),
        "credentialsId": f("definition/scm/userRemoteConfigs/hudson.plugins.git.UserRemoteConfig/credentialsId"),
        "branch": f("definition/scm/branches/hudson.plugins.git.BranchSpec/name"),
        "scriptPath": f("definition/scriptPath"),
        "disabled": f("disabled"),
    }


def step_jenkins_job() -> None:
    repo_url = f"{GITEA_URL}/{DEMO_ORG}/{DEMO_REPO}.git"
    want = job_xml(repo_url)
    hdrs = {**crumb(), "Content-Type": "application/xml"}
    status, cur = jenkins.request("GET", f"/job/{urllib.parse.quote(JENKINS_JOB)}/config.xml", ok=(200, 404))
    if status == 404:
        jenkins.request("POST", f"/createItem?name={urllib.parse.quote(JENKINS_JOB)}", want.encode(), headers=hdrs)
        report("jenkins job", "created", JENKINS_JOB)
    elif job_essentials(cur.decode()) == job_essentials(want):
        report("jenkins job", "ok", JENKINS_JOB)
    else:
        jenkins.request("POST", f"/job/{urllib.parse.quote(JENKINS_JOB)}/config.xml", want.encode(), headers=hdrs)
        report("jenkins job", "updated", JENKINS_JOB)


# ------------------------------------------------------------------ main ---

def main() -> int:
    print(f"cf-wire-engine: gitea={GITEA_URL} jenkins={JENKINS_URL} namespace={NAMESPACE}", flush=True)
    wait_ready("gitea", gitea_ready)
    wait_ready("jenkins", jenkins_ready)

    def step_token_and_credential() -> None:
        step_jenkins_credential(step_gitea_token())

    steps = [step_gitea_org_repo, step_gitea_jenkinsfile, step_token_and_credential, step_jenkins_job]
    for step in steps:
        try:
            step()
        except Exception as e:  # noqa: BLE001 - report and fail the Job
            report(step.__name__, "failed", str(e))
            print("FAILED: wiring did not converge", flush=True)
            return 1

    counts = {}
    for _, s in RESULTS:
        counts[s] = counts.get(s, 0) + 1
    print("converged: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
