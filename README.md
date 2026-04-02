# gitea-jenkins

[![Security Scan](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml/badge.svg)](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/clusterfactory/clusterfactory/badge)](https://securityscorecards.dev/viewer/?uri=github.com/clusterfactory/clusterfactory)
[![Trivy](https://img.shields.io/badge/trivy-scanned-blue?logo=aquasecurity)](https://github.com/clusterfactory/clusterfactory/security/code-scanning)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

One `helm install`. Gitea + Jenkins + Gitea Actions runner — fully wired and ready.

## What it does

| Component | Details |
|-----------|---------|
| **Gitea** | Self-hosted Git, SQLite, Actions enabled |
| **Jenkins** | Pipeline CI, pre-wired with Gitea credentials |
| **Gitea Actions runner** | Kubernetes DaemonSet, registered automatically |
| **hello-world repo** | Pushed to Gitea on install — includes Jenkinsfile + Actions workflow |

A single `helm install` will:
1. Install Gitea and Jenkins via subcharts
2. Create a Gitea admin user and API token
3. Create the `clusterfactory` org
4. Push the `hello-world` repo (Jenkinsfile + `.gitea/workflows/ci.yaml`)
5. Create the `clusterfactory-hello-world` Jenkins job pointing at the repo
6. Register a Gitea Actions runner in the cluster
7. Store Jenkins credentials (`gitea-userpass`, `gitea-api-token`) ready for pipelines

No `kubectl exec`. No port-forwards during install. No manual steps.

---

## Requirements

- Kubernetes cluster (Docker Desktop, kind, k3s, etc.)
- `helm` >= 3.x
- `kubectl` configured

---

## Install

```bash
helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory/
helm repo update
helm upgrade --install cf clusterfactory/clusterfactory \
  --namespace cicd --create-namespace \
  --atomic --timeout 15m
```

That's it.

**Install from source:**
```bash
git clone https://github.com/clusterfactory/clusterfactory.git
cd clusterfactory
helm upgrade --install cf . \
  --namespace cicd --create-namespace \
  --atomic --timeout 15m
```

---

## Get credentials

**Jenkins password** (randomly generated each install):
```bash
kubectl get secret cf-jenkins -n cicd \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d && echo
```

**Gitea password** is set in `values.yaml` under `gitea.gitea.admin.password` (default: `changeme123!`).

---

## Access via browser

Start port-forwards:
```bash
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000 &
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080 &
```

| Service | URL | User |
|---------|-----|------|
| Gitea | http://localhost:3000 | `gitea-admin` |
| Jenkins | http://localhost:8080 | `admin` |

---

## Configuration

All configuration lives in `values.yaml`.

```yaml
wire:
  org: clusterfactory        # Gitea org created on install
  repo:
    name: hello-world        # Repo pushed on install

runner:
  enabled: true
  image: gitea/act_runner:latest
  labels: "ubuntu-latest:host,ubuntu-22.04:host"

gitea:
  gitea:
    admin:
      username: gitea-admin
      password: changeme123!
```

---

## Repo structure

```
.
├── Chart.yaml                        # Declares gitea + jenkins as subchart deps
├── values.yaml                       # All config
├── charts/
│   ├── gitea-11.0.1.tgz
│   └── jenkins-5.9.9.tgz
├── files/
│   ├── Jenkinsfile                   # Hello world Jenkins pipeline
│   └── .gitea/
│       └── workflows/
│           └── ci.yaml               # Hello world Gitea Actions workflow
└── templates/
    ├── wire-job.yaml                 # post-install Job: wires everything together
    ├── wire-rbac.yaml                # ServiceAccount + Role for wire job
    ├── runner-daemonset.yaml         # Gitea Actions runner DaemonSet
    └── runner-config-cm.yaml         # act_runner config
```

---

## How the wire job works

The `wire` Job runs as a Helm `post-install,post-upgrade` hook:

1. Waits for Gitea to return HTTP 200
2. Mints a Gitea API token (`jenkins-wiring` scope)
3. Creates the org
4. Waits for Jenkins to return HTTP 200
5. Creates `gitea-api-token` (secret text) and `gitea-userpass` (username+token) credentials in Jenkins
6. Creates the Gitea repo via API
7. Pushes `Jenkinsfile` and `.gitea/workflows/ci.yaml` via Gitea Contents API
8. Creates the Jenkins pipeline job pointing at the repo with credentials
9. Fetches the Gitea Actions runner registration token and stores it in a k8s Secret

The runner DaemonSet's init container waits for the Secret, registers once (skips if already registered), then the main container runs `act_runner daemon`.

---

## Upgrade

```bash
helm repo update
helm upgrade cf clusterfactory/clusterfactory --namespace cicd --atomic --timeout 10m
```

The wire job re-runs on every upgrade and upserts all resources idempotently.

---

## Security

Automated scans run on every push to `main`, every PR, and weekly:

| Scanner | What it checks | Results |
|---------|---------------|---------|
| [Trivy](https://github.com/aquasecurity/trivy) | Helm/K8s misconfigurations, CVEs | [GitHub Security tab](https://github.com/clusterfactory/clusterfactory/security/code-scanning) |
| [OSSF Scorecard](https://securityscorecards.dev) | Branch protection, dependency pinning, CI, vulnerability reporting | [scorecard.dev](https://securityscorecards.dev/viewer/?uri=github.com/clusterfactory/clusterfactory) |
| Helm lint | Chart validity, strict mode | [Actions](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml) |

---

## Airgap

Run this on an **internet-connected** machine to produce a self-contained bundle:

```bash
./hack/bundle.sh              # outputs to ./dist/
./hack/bundle.sh /path/to/output
```

Produces `dist/clusterfactory-airgap-<version>.tar.gz`:

```
clusterfactory-airgap-0.1.2/
├── clusterfactory-0.1.2.tgz   — packaged Helm chart
├── images.tar                  — all container images (docker save)
├── images.txt                  — plain list of image references bundled
├── values-airgap.yaml          — image overrides pointing at local registry
└── load.sh                     — run this on the airgapped machine
```

**Transfer to airgapped machine:**
```bash
scp dist/clusterfactory-airgap-0.1.2.tar.gz user@airgapped-host:/opt/
```

**On the airgapped machine — two modes:**

```bash
tar xzf clusterfactory-airgap-0.1.2.tar.gz
cd clusterfactory-airgap-0.1.2

# Mode 1: images already visible to your cluster (Docker Desktop / kind)
./load.sh direct

# Mode 2: push images to a local registry first
./load.sh registry 192.168.1.10:5000
```

`load.sh registry` will:
1. `docker load` all images from `images.tar`
2. Retag and push each image to `<registry>/<original-name>:<tag>`
3. Replace `REGISTRY` in `values-airgap.yaml` with your registry address
4. Run `helm upgrade --install` with the resolved overrides

**Requirements:** `docker`, `helm` on both machines; `kubectl` on the airgapped machine.

---

## Uninstall

```bash
helm uninstall cf -n cicd
kubectl delete namespace cicd
```
