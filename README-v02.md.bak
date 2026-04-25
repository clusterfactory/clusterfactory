# clusterfactory

[![Chart Tests](https://github.com/clusterfactory/clusterfactory/actions/workflows/test.yaml/badge.svg)](https://github.com/clusterfactory/clusterfactory/actions/workflows/test.yaml)
[![Security Scan](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml/badge.svg)](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/clusterfactory/clusterfactory/badge)](https://securityscorecards.dev/viewer/?uri=github.com/clusterfactory/clusterfactory)
[![Trivy](https://img.shields.io/badge/trivy-scanned-blue?logo=aquasecurity)](https://github.com/clusterfactory/clusterfactory/security/code-scanning)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![SLSA 2](https://slsa.dev/images/gh-badge-level2.svg)](https://slsa.dev)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/12366/badge)](https://www.bestpractices.dev/projects/12366)

A Helm chart that bootstraps a fully wired Gitea + Jenkins platform in one command — connected or airgapped. Use it as a seed for real CI/CD infrastructure, or as a starting point for more complex platform builds.

---

## What it is

clusterfactory installs vanilla upstream Gitea and Jenkins (or just Gitea), wires them together automatically, and leaves you with a working CI platform ready to use. No manual steps, no kubectl exec, no post-install scripts.

It is designed as a **bootstrap tool** — state lives in emptyDir by default, the wire job re-runs idempotently on every upgrade, and the hello-world pipeline proves the wiring works before you build on top of it.

**Three deployment modes:**
- **gitea-actions**: Gitea + Actions runners (cloud-native CI/CD)
- **jenkins**: Gitea (git only) + Jenkins (traditional CI/CD)
- **both**: Everything enabled (for migration scenarios)

| Component | gitea-actions | jenkins | both |
|-----------|---------------|---------|------|
| Gitea | ✅ + Actions | ✅ Git only | ✅ + Actions |
| Jenkins | ❌ | ✅ | ✅ |
| Gitea Actions runner | ✅ DaemonSet | ❌ | ✅ DaemonSet |
| hello-world repo | ✅ Workflow | ✅ Jenkinsfile | ✅ Both |
| Wire job | ✅ Actions setup | ✅ Jenkins setup | ✅ Both |

---

## Quick start

### Choose your deployment mode

clusterfactory supports three modes:

**1. Gitea Actions (default)** — Modern, cloud-native CI/CD
```bash
helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory/
helm repo update
helm upgrade --install cf clusterfactory/clusterfactory \
  --namespace cicd --create-namespace \
  --set mode=gitea-actions \
  --set jenkins.enabled=false \
  --set gitea.gitea.admin.password=<your-secure-password> \
  --timeout 15m
```

**2. Jenkins** — Traditional enterprise CI/CD
```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --namespace cicd --create-namespace \
  --set mode=jenkins \
  --set jenkins.enabled=true \
  --set gitea.gitea.admin.password=<your-secure-password> \
  --timeout 15m
```

**3. Both** — Hybrid mode for migration scenarios
```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --namespace cicd --create-namespace \
  --set mode=both \
  --set jenkins.enabled=true \
  --set gitea.gitea.admin.password=<your-secure-password> \
  --timeout 15m
```

**Security Note:** The Gitea admin password is **required** and must be provided at install time. Never commit passwords to source control.

See [Deployment Modes Guide](docs/deployment-modes.md) for detailed mode comparison and use cases.

### Access the services

**Gitea Actions mode:**
```bash
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000
```

**Jenkins or Both modes:**
```bash
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000 &
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080 &
```

| Service | URL | User | Mode |
|---------|-----|------|------|
| Gitea | http://localhost:3000 | `gitea-admin` / password you set | All |
| Jenkins | http://localhost:8080 | `admin` / see below | jenkins, both |

Jenkins password:
```bash
kubectl get secret cf-jenkins -n cicd \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d && echo
```

**Install from source:**

```bash
git clone https://github.com/clusterfactory/clusterfactory.git
cd clusterfactory
helm upgrade --install cf . \
  --namespace cicd --create-namespace \
  --set mode=gitea-actions \
  --set jenkins.enabled=false \
  --set gitea.gitea.admin.password=<your-secure-password> \
  --timeout 15m
```

---

## Compatibility matrix

Each chart version is tested against one specific component pair. The wiring is not adaptive — do not mix versions without testing.

```bash
helm show values clusterfactory/clusterfactory | grep -A5 "^compatibility:"
```

| Chart | Gitea | Jenkins | act_runner |
|-------|-------|---------|------------|
| 0.1.8 | 1.23.6 | 2.541.3-jdk21 | 0.3.1 |

To pin specific versions at install time:

```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --set gitea.image.tag=1.23.6 \
  --set jenkins.controller.image.tag=2.541.3-jdk21
```

---

## Tested platforms

| Platform | Status |
|----------|--------|
| Docker Desktop | ✓ tested |
| kind | ✓ tested (CI) |
| k3d | ✓ tested (CI) |
| k3s / RKE2 | ✓ compatible |
| EKS / GKE / AKS | ✓ compatible |

---

## Configuration

### Runner and container builds

The Gitea Actions runner runs as a DaemonSet and uses **Kaniko** for building container images:

```yaml
runner:
  enabled: true
  capacity: 2   # max concurrent workflow runs per runner
```

**Architecture:**
```
Gitea Actions → act_runner (DaemonSet) → kubectl create job → Kaniko pod → registry
```

This approach:
- ✅ No privileged containers
- ✅ No Docker daemon required
- ✅ Compatible with Pod Security Standards (restricted)
- ✅ Ephemeral build pods with proper resource isolation

For container image builds in workflows, use Kaniko executor. See [docs/kaniko-builds.md](docs/kaniko-builds.md) for examples and migration guide.

### Persistence

State does not survive pod restarts by default. This is correct for a bootstrap tool.

```yaml
persistence:
  enabled: false   # default — emptyDir, works on any cluster
  # enabled: true  # opt-in — requires a StorageClass
  # storageClassName: local-path   # RKE2/k3s
  # storageClassName: standard     # kind/GKE
  # storageClassName: gp3          # EKS
```

When `persistence.enabled=true`, a preflight Job runs before install and fails fast with a human-readable error if no usable StorageClass is found — no silent 15-minute timeout.

### Org and repo

```yaml
wire:
  org: clusterfactory     # Gitea org created on install
  repo:
    name: hello-world     # repo pushed on install
```

---

## Airgap

Build a self-contained bundle on an internet-connected machine:

```bash
./hack/bundle.sh              # outputs to ./dist/
./hack/bundle.sh /path/to/output
```

Produces `dist/clusterfactory-airgap-<version>.tar.gz`:

```
clusterfactory-airgap-0.1.8/
├── clusterfactory-0.1.8.tgz   — packaged Helm chart
├── images.tar                  — all container images (docker save)
├── images.txt                  — list of bundled image references
├── values-airgap.yaml          — image overrides for a local registry
└── load.sh                     — run this on the airgapped machine
```

Transfer and install:

```bash
scp dist/clusterfactory-airgap-0.1.8.tar.gz user@airgapped-host:/opt/
ssh user@airgapped-host
tar xzf /opt/clusterfactory-airgap-0.1.8.tar.gz
cd clusterfactory-airgap-0.1.8

# images already visible to your cluster (Docker Desktop / kind / k3d)
./load.sh direct

# push images to a local registry first, then install
./load.sh registry 192.168.1.10:5000
```

The airgap bundle is tested in CI on every push — a dedicated GitHub Actions job builds the bundle, loads all images into k3d containerd with `pullPolicy: Never`, installs the chart, and runs helm tests to confirm no external pulls occurred.

---

## How the wire job works

The `wire` Job runs as a Helm `post-install,post-upgrade` hook:

1. Waits for Gitea HTTP 200
2. Mints a Gitea API token
3. Creates the org
4. Waits for Jenkins HTTP 200
5. Creates `gitea-api-token` and `gitea-userpass` credentials in Jenkins
6. Creates the Gitea repo
7. Pushes `Jenkinsfile` and `.gitea/workflows/ci.yaml` via the Gitea Contents API
8. Creates the Jenkins pipeline job pointing at the repo
9. Fetches the runner registration token and writes it to a Kubernetes Secret

The runner DaemonSet's init container polls for the Secret, registers, then the main container runs `act_runner daemon`. The whole sequence is idempotent — re-running on upgrade upserts all resources without duplicating them.

---

## Migrating from Jenkins to Gitea Actions

If you have existing Jenkinsfiles you want to migrate, `hack/migrate.sh` helps with the credential mapping — the most manual part of any Jenkins migration.

With Jenkins and Gitea both port-forwarded:

```bash
# pull everything from a live Jenkins job
./hack/migrate.sh --job-name my-pipeline --gitea-org myorg

# or use a local Jenkinsfile
./hack/migrate.sh --jenkinsfile ./Jenkinsfile --job-name my-pipeline --gitea-org myorg
```

The script extracts credential references from the Jenkinsfile, cross-references them with the live Jenkins credential store to get their types, creates matching empty placeholder secrets in the Gitea org, and produces a migration report with the exact `${{ secrets.* }}` syntax for each one.

Output goes to `./migrate-output/`:
- `migration-report.md` — credential mapping table, plugin equivalents, syntax reference
- `Jenkinsfile` — fetched from Jenkins if not provided locally
- `jenkins-plugins.txt` — installed plugin inventory for the migration report

Use the report alongside the Jenkinsfile as context when converting pipelines.

---

## What to build on top

clusterfactory is designed as a seed. The hello-world pipeline proves the wiring, then you replace it with your own. Some directions:

**Harden with SSO** — add Authentik or Zitadel as an IdP, configure Gitea and Jenkins OIDC, put nginx forward-auth in front. The platform already has all the components that need to be wired.

**Add a registry** — Harbor as a subchart alongside Gitea and Jenkins, wired with credentials the same way Jenkins is wired today. Gives you a complete build, store, and deploy loop.

**Add secrets management** — OpenBao (Vault-compatible) as a subchart, wired to Jenkins credentials via the Vault plugin and to Gitea Actions via environment injection.

**Enterprise substitution** — Jenkins is optional. If your organisation runs Gitea Actions natively, disable Jenkins entirely (`jenkins.enabled=false` equivalent via subchart values) and use the runner DaemonSet alone. Or keep Jenkins as the execution engine and disable the Actions runner.

These are not part of the current chart but are natural extensions. Contributions and examples are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Security

Automated scans run on every push to `main`, every PR, and weekly:

| Scanner | What it checks | Results |
|---------|---------------|---------|
| [Trivy](https://github.com/aquasecurity/trivy) | Helm/K8s misconfigurations, CVEs | [GitHub Security tab](https://github.com/clusterfactory/clusterfactory/security/code-scanning) |
| [OSSF Scorecard](https://securityscorecards.dev) | Supply chain security posture | [scorecard.dev](https://securityscorecards.dev/viewer/?uri=github.com/clusterfactory/clusterfactory) |
| Helm lint | Chart validity, strict mode | [Actions](https://github.com/clusterfactory/clusterfactory/actions/workflows/scan.yaml) |

All actions are pinned to commit SHAs. Dependabot keeps them current weekly.

### Known Limitations

**Gitea API Token Hashing**: Gitea uses SHA-1 for API token storage. While this is an upstream limitation, we recommend:
- Regular token rotation (30-day cycles)
- Network isolation for Gitea services
- Monitoring [Gitea upstream](https://github.com/go-gitea/gitea) for SHA-256 migration

See [SECURITY.md](SECURITY.md) for detailed mitigation strategies.

To report a vulnerability, see [SECURITY.md](SECURITY.md). Do not open a public issue.

---

## Uninstall

```bash
helm uninstall cf -n cicd
kubectl delete namespace cicd
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local development setup, testing instructions, and the PR checklist.
