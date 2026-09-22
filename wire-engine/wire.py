#!/usr/bin/env python3
"""clusterfactory wire engine (ADR 0002).

Runs as an in-cluster Job after the apps are up and converges the
cross-service wiring. Every step is check-then-act and reports one of
ok / created / updated / skipped. Exit 0 only if every step converged.

Standard library only - nothing to mirror.

Steps (docs/design.md §4):
  1. Gitea: org, repo, Jenkinsfile content
  2. Gitea: integration user + API token, persisted in a Kubernetes Secret
     (tokens are not re-readable; the Secret is the source of truth on re-runs)
  3. Jenkins: username/password credential holding that token
  4. Jenkins: pipeline job pointing at the Gitea repo
  5. Nexus: admin password rotation, CE EULA (operator-accepted), DockerToken
     realm, anonymous off, docker-hosted repository
  6. Nexus: deploy user + scoped role, persisted in a Secret; Jenkins
     credential `nexus-docker`; Kaniko dockerconfigjson Secret in cf-build
  7. Nexus: pre-seed the demo base image from the Zarf registry
     (Registry API v2, no docker daemon)
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
DEMO_FILES_DIR = env("DEMO_FILES_DIR", "/etc/clusterfactory/demo")
DEMO_FILES = [f for f in env("DEMO_FILES", "Jenkinsfile,Dockerfile").split(",") if f]
INTEGRATION_USER = env("GITEA_INTEGRATION_USER", "jenkins-ci")
JENKINS_CREDENTIAL_ID = env("JENKINS_CREDENTIAL_ID", "gitea-token")
JENKINS_JOB = env("JENKINS_JOB", f"{DEMO_ORG}-{DEMO_REPO}")
TOKEN_SECRET = env("TOKEN_SECRET_NAME", "cf-wire-gitea-token")

NEXUS_URL = env("NEXUS_URL").rstrip("/")
NEXUS_DOCKER_HOST = env("NEXUS_DOCKER_HOST")
NEXUS_ADMIN_USER = env("NEXUS_ADMIN_USER", "admin")
NEXUS_ADMIN_PASSWORD = env("NEXUS_ADMIN_PASSWORD")
NEXUS_INITIAL_PASSWORD = env("NEXUS_INITIAL_ADMIN_PASSWORD", "admin123")
NEXUS_DOCKER_REPO = env("NEXUS_DOCKER_REPOSITORY", "docker-hosted")
NEXUS_ACCEPT_EULA = env("NEXUS_ACCEPT_CE_EULA", "false").lower() == "true"
NEXUS_DEPLOY_USER = env("NEXUS_DEPLOY_USER", "jenkins-ci")
NEXUS_DEPLOY_SECRET = env("NEXUS_DEPLOY_SECRET_NAME", "cf-wire-nexus-deploy")
JENKINS_NEXUS_CREDENTIAL_ID = env("JENKINS_NEXUS_CREDENTIAL_ID", "nexus-docker")
BUILD_NAMESPACE = env("BUILD_NAMESPACE", "cf-build")
DOCKER_CONFIG_SECRET = env("DOCKER_CONFIG_SECRET_NAME", "cf-nexus-docker-config")
ZARF_REGISTRY = env("ZARF_REGISTRY_HOST", "zarf-docker-registry.zarf.svc.cluster.local:5000")
ZARF_PULL_SECRET = env("ZARF_REGISTRY_PULL_SECRET", "private-registry")
BASE_IMAGE_REF = env("BASE_IMAGE_REF", "")
BASE_IMAGE_NEXUS_NAME = env("BASE_IMAGE_NEXUS_NAME", "alpine")
BASE_IMAGE_NEXUS_TAG = env("BASE_IMAGE_NEXUS_TAG", "latest")
NAMESPACE = env("NAMESPACE")
READY_TIMEOUT = int(env("READY_TIMEOUT_SECONDS", "300"))

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S_URL = f"https://{env('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{env('KUBERNETES_SERVICE_PORT', '443')}"

RESULTS: list[tuple[str, str]] = []
_last_headers: dict = {}
_last_location: str = ""


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
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            hdrs.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        global _last_headers, _last_location
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                _last_headers = dict(resp.headers)
                loc = resp.headers.get("Location", "")
                _last_location = loc if loc.startswith("/") else urllib.parse.urlsplit(loc).path + ("?" + urllib.parse.urlsplit(loc).query if urllib.parse.urlsplit(loc).query else "")
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


def secret_get(name: str, namespace: str = NAMESPACE) -> dict | None:
    status, body = k8s().json("GET", f"/api/v1/namespaces/{namespace}/secrets/{name}", ok=(200, 404))
    if status == 404:
        return None
    return {k: base64.b64decode(v).decode() for k, v in (body.get("data") or {}).items()}


def secret_put(name: str, data: dict[str, str], exists: bool, namespace: str = NAMESPACE,
               secret_type: str = "Opaque") -> None:
    manifest = {
        "apiVersion": "v1", "kind": "Secret", "type": secret_type,
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app.kubernetes.io/name": "cf-wire-engine",
                                "app.kubernetes.io/part-of": "clusterfactory"}},
        "data": {k: base64.b64encode(v.encode()).decode() for k, v in data.items()},
    }
    if exists:
        k8s().json("PUT", f"/api/v1/namespaces/{namespace}/secrets/{name}", manifest)
    else:
        k8s().json("POST", f"/api/v1/namespaces/{namespace}/secrets", manifest)


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


def ensure_repo_file(name: str) -> None:
    want = open(os.path.join(DEMO_FILES_DIR, name), "rb").read()
    path = f"/api/v1/repos/{DEMO_ORG}/{DEMO_REPO}/contents/{name}"
    status, cur = gitea.json("GET", f"{path}?ref={DEMO_BRANCH}", ok=(200, 404))
    payload = {"content": base64.b64encode(want).decode(), "branch": DEMO_BRANCH,
               "message": f"clusterfactory: sync demo {name}"}
    if status == 404:
        gitea.json("POST", path, payload)
        report(f"gitea {name}", "created")
    elif base64.b64decode(cur["content"]) == want:
        report(f"gitea {name}", "ok")
    else:
        payload["sha"] = cur["sha"]
        gitea.json("PUT", path, payload)
        report(f"gitea {name}", "updated")


def step_gitea_jenkinsfile() -> None:
    for name in DEMO_FILES:
        ensure_repo_file(name)


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


def ensure_jenkins_userpass(cred_id: str, username: str, secret: str, what: str) -> None:
    """Username/password credential; the secret's fingerprint in the description makes 'unchanged' detectable."""
    fp = token_fingerprint(secret)
    xml = f"""<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>{xml_escape(cred_id)}</id>
  <description>{xml_escape(what)} for {xml_escape(username)} (managed by cf-wire-engine, {fp})</description>
  <username>{xml_escape(username)}</username>
  <password>{xml_escape(secret)}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"""
    base = "/credentials/store/system/domain/_"
    status, cur = jenkins.json("GET", f"{base}/credential/{cred_id}/api/json", ok=(200, 404))
    hdrs = {**crumb(), "Content-Type": "application/xml"}
    if status == 404:
        jenkins.request("POST", f"{base}/createCredentials", xml.encode(), headers=hdrs)
        report(f"jenkins credential {cred_id}", "created")
    elif fp in (cur.get("description") or ""):
        report(f"jenkins credential {cred_id}", "ok")
    else:
        jenkins.request("POST", f"{base}/credential/{cred_id}/config.xml", xml.encode(), headers=hdrs)
        report(f"jenkins credential {cred_id}", "updated")


def step_jenkins_credential(token: str) -> None:
    ensure_jenkins_userpass(JENKINS_CREDENTIAL_ID, INTEGRATION_USER, token, "Gitea token")


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



# ----------------------------------------------------------------- nexus ---

nexus = Http(NEXUS_URL, NEXUS_ADMIN_USER, NEXUS_ADMIN_PASSWORD)
NX = "/service/rest/v1"


def nexus_ready() -> bool:
    status, _ = Http(NEXUS_URL).request("GET", f"{NX}/status")
    return status == 200


def step_nexus_admin_password() -> None:
    """Rotate the image's known initial password to the cf-config Secret value."""
    st, _ = nexus.request("GET", f"{NX}/status/check", ok=(200, 401, 403))
    if st == 200:
        report("nexus admin password", "ok")
        return
    initial = Http(NEXUS_URL, NEXUS_ADMIN_USER, NEXUS_INITIAL_PASSWORD)
    st, _ = initial.request("GET", f"{NX}/status/check", ok=(200, 401, 403))
    if st != 200:
        raise RuntimeError("neither the configured nor the initial Nexus admin password works")
    initial.request("PUT", f"{NX}/security/users/{NEXUS_ADMIN_USER}/change-password",
                    NEXUS_ADMIN_PASSWORD.encode(), headers={"Content-Type": "text/plain"})
    report("nexus admin password", "updated", "rotated from the initial password")


def step_nexus_eula() -> None:
    _, eula = nexus.json("GET", f"{NX}/system/eula")
    if eula.get("accepted"):
        report("nexus CE EULA", "ok")
        return
    if not NEXUS_ACCEPT_EULA:
        raise RuntimeError("Nexus Community Edition requires accepting its EULA before the Docker connector "
                           "works: https://links.sonatype.com/products/nxrm/ce-eula - redeploy with "
                           "--set NEXUS_ACCEPT_CE_EULA=true to accept it on the operator's behalf")
    nexus.json("POST", f"{NX}/system/eula", {**eula, "accepted": True})
    report("nexus CE EULA", "updated", "accepted via NEXUS_ACCEPT_CE_EULA=true")


def step_nexus_security() -> None:
    _, realms = nexus.json("GET", f"{NX}/security/realms/active")
    if "DockerToken" in realms:
        report("nexus DockerToken realm", "ok")
    else:
        nexus.json("PUT", f"{NX}/security/realms/active", realms + ["DockerToken"])
        report("nexus DockerToken realm", "updated")

    _, anon = nexus.json("GET", f"{NX}/security/anonymous")
    if anon.get("enabled"):
        nexus.json("PUT", f"{NX}/security/anonymous", {**anon, "enabled": False})
        report("nexus anonymous access", "updated", "disabled")
    else:
        report("nexus anonymous access", "ok", "disabled")


def step_nexus_docker_repo() -> None:
    want = {
        "name": NEXUS_DOCKER_REPO, "online": True,
        "storage": {"blobStoreName": "default", "strictContentTypeValidation": True, "writePolicy": "ALLOW"},
        "docker": {"v1Enabled": False, "forceBasicAuth": True, "httpPort": 5000},
    }
    st, cur = nexus.json("GET", f"{NX}/repositories/docker/hosted/{NEXUS_DOCKER_REPO}", ok=(200, 404))
    if st == 404:
        nexus.json("POST", f"{NX}/repositories/docker/hosted", want)
        report("nexus docker repository", "created", NEXUS_DOCKER_REPO)
    elif cur.get("docker", {}).get("httpPort") == 5000 and cur.get("online"):
        report("nexus docker repository", "ok", NEXUS_DOCKER_REPO)
    else:
        nexus.json("PUT", f"{NX}/repositories/docker/hosted/{NEXUS_DOCKER_REPO}", want)
        report("nexus docker repository", "updated", NEXUS_DOCKER_REPO)


def step_nexus_deploy_user() -> str:
    """Scoped push/pull role + deploy user; password persisted in a Secret and verified against the connector."""
    role = {"id": "cf-docker-push", "name": "cf-docker-push", "description": "push/pull " + NEXUS_DOCKER_REPO,
            "privileges": [f"nx-repository-view-docker-{NEXUS_DOCKER_REPO}-*"], "roles": []}
    st, _ = nexus.json("GET", f"{NX}/security/roles/{role['id']}", ok=(200, 404))
    if st == 404:
        nexus.json("POST", f"{NX}/security/roles", role)
        report("nexus role cf-docker-push", "created")
    else:
        report("nexus role cf-docker-push", "ok")

    stored = secret_get(NEXUS_DEPLOY_SECRET)
    password = stored["password"] if stored else secrets.token_urlsafe(24)
    _, users = nexus.json("GET", f"{NX}/security/users?userId={NEXUS_DEPLOY_USER}")
    user = {"userId": NEXUS_DEPLOY_USER, "firstName": "Jenkins", "lastName": "CI",
            "emailAddress": f"{NEXUS_DEPLOY_USER}@clusterfactory.local", "status": "active",
            "roles": [role["id"]]}
    if not any(u.get("userId") == NEXUS_DEPLOY_USER for u in users or []):
        nexus.json("POST", f"{NX}/security/users", {**user, "password": password})
        report("nexus deploy user", "created", NEXUS_DEPLOY_USER)
    else:
        # Make sure the persisted password is the live one (e.g. Secret lost). The
        # deploy user only holds the docker role, so verify against the connector.
        st, _ = Http(f"http://{NEXUS_DOCKER_HOST}", NEXUS_DEPLOY_USER, password).request("GET", "/v2/", ok=(200, 401, 403))
        if st != 200:
            nexus.request("PUT", f"{NX}/security/users/{NEXUS_DEPLOY_USER}/change-password",
                          password.encode(), headers={"Content-Type": "text/plain"})
            report("nexus deploy user", "updated", "password reset to the persisted value")
        else:
            report("nexus deploy user", "ok", NEXUS_DEPLOY_USER)
    if stored is None or stored.get("password") != password:
        secret_put(NEXUS_DEPLOY_SECRET, {"username": NEXUS_DEPLOY_USER, "password": password}, exists=stored is not None)
    return password


def step_kaniko_docker_config(password: str) -> None:
    auth = base64.b64encode(f"{NEXUS_DEPLOY_USER}:{password}".encode()).decode()
    cfg = json.dumps({"auths": {NEXUS_DOCKER_HOST: {"auth": auth}}})
    cur = secret_get(DOCKER_CONFIG_SECRET, BUILD_NAMESPACE)
    if cur and cur.get(".dockerconfigjson") == cfg:
        report("kaniko docker config", "ok", f"{BUILD_NAMESPACE}/{DOCKER_CONFIG_SECRET}")
        return
    secret_put(DOCKER_CONFIG_SECRET, {".dockerconfigjson": cfg}, exists=cur is not None,
               namespace=BUILD_NAMESPACE, secret_type="kubernetes.io/dockerconfigjson")
    report("kaniko docker config", "created" if cur is None else "updated", f"{BUILD_NAMESPACE}/{DOCKER_CONFIG_SECRET}")


# -------------------------------------------------- registry v2 copy ---

MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
])


def zarf_registry_client() -> Http:
    pull = secret_get(ZARF_PULL_SECRET)
    cfg = json.loads(pull[".dockerconfigjson"])
    entry = next(iter(cfg["auths"].values()))
    user, pw = base64.b64decode(entry["auth"]).decode().split(":", 1)
    return Http(f"http://{ZARF_REGISTRY}", user, pw)


def zarf_repo_and_digest(ref: str) -> tuple[str, str]:
    """docker.io/library/alpine:3.20@sha256:... -> ('library/alpine', 'sha256:...') as Zarf stores it."""
    if "@" not in ref:
        raise RuntimeError(f"BASE_IMAGE_REF must be digest-pinned: {ref}")
    name, digest = ref.split("@", 1)
    name = name.rsplit(":", 1)[0] if ":" in name.split("/")[-1] else name
    if name.startswith("docker.io/"):
        name = name[len("docker.io/"):]
    return name, digest


def step_preseed_base_image() -> None:
    if not BASE_IMAGE_REF:
        report("nexus base image", "skipped", "BASE_IMAGE_REF not set")
        return
    src_repo, digest = zarf_repo_and_digest(BASE_IMAGE_REF)
    src = zarf_registry_client()
    dst = Http(f"http://{NEXUS_DOCKER_HOST}", NEXUS_ADMIN_USER, NEXUS_ADMIN_PASSWORD)
    dst_repo, tag = BASE_IMAGE_NEXUS_NAME, BASE_IMAGE_NEXUS_TAG
    accept = {"Accept": MANIFEST_TYPES}

    # Resolve to a single-platform manifest (Zarf stores amd64 manifests, but be safe).
    _, raw = src.request("GET", f"/v2/{src_repo}/manifests/{digest}", headers=accept)
    manifest = json.loads(raw)
    if "manifests" in manifest:
        entry = next(m for m in manifest["manifests"]
                     if m.get("platform", {}).get("architecture") == "amd64" and m["platform"].get("os") == "linux")
        digest = entry["digest"]
        _, raw = src.request("GET", f"/v2/{src_repo}/manifests/{digest}", headers=accept)
        manifest = json.loads(raw)
    media_type = manifest.get("mediaType", "application/vnd.oci.image.manifest.v1+json")

    existed, same = _tag_state(dst, dst_repo, tag, digest)
    if same:
        report("nexus base image", "ok", f"{dst_repo}:{tag} = {digest[:19]}")
        return

    for blob in [manifest["config"], *manifest["layers"]]:
        bd = blob["digest"]
        st, _ = dst.request("HEAD", f"/v2/{dst_repo}/blobs/{bd}", ok=(200, 404))
        if st == 200:
            continue
        _, data = src.request("GET", f"/v2/{src_repo}/blobs/{bd}", timeout=300)
        dst.request("POST", f"/v2/{dst_repo}/blobs/uploads/", b"", ok=(202,))
        location = _last_location
        sep = "&" if "?" in location else "?"
        dst.request("PUT", f"{location}{sep}digest={bd}", data,
                    headers={"Content-Type": "application/octet-stream"}, timeout=300, ok=(201,))
    dst.request("PUT", f"/v2/{dst_repo}/manifests/{tag}", raw, headers={"Content-Type": media_type}, ok=(201,))
    report("nexus base image", "updated" if existed else "created", f"{dst_repo}:{tag} = {digest[:19]}")


def _tag_state(client: Http, repo: str, tag: str, digest: str) -> tuple[bool, bool]:
    """(tag exists, tag already points at digest)"""
    status, _ = client.request("HEAD", f"/v2/{repo}/manifests/{tag}", headers={"Accept": MANIFEST_TYPES}, ok=(200, 404))
    return status == 200, status == 200 and _last_headers.get("Docker-Content-Digest", "") == digest


# ------------------------------------------------------------------ main ---

def main() -> int:
    print(f"cf-wire-engine: gitea={GITEA_URL} jenkins={JENKINS_URL} nexus={NEXUS_URL} namespace={NAMESPACE}", flush=True)
    wait_ready("gitea", gitea_ready)
    wait_ready("jenkins", jenkins_ready)
    wait_ready("nexus", nexus_ready)

    def step_token_and_credential() -> None:
        step_jenkins_credential(step_gitea_token())

    def step_nexus_deploy_and_credentials() -> None:
        password = step_nexus_deploy_user()
        ensure_jenkins_userpass(JENKINS_NEXUS_CREDENTIAL_ID, NEXUS_DEPLOY_USER, password, "Nexus deploy user")
        step_kaniko_docker_config(password)

    steps = [
        step_gitea_org_repo, step_gitea_jenkinsfile, step_token_and_credential, step_jenkins_job,
        step_nexus_admin_password, step_nexus_eula, step_nexus_security, step_nexus_docker_repo,
        step_nexus_deploy_and_credentials, step_preseed_base_image,
    ]
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
