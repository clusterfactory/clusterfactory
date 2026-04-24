# Deployment Modes Guide

ClusterFactory supports three deployment modes, each optimized for specific use cases. Choose based on your team's needs and infrastructure requirements.

## Quick Comparison

| Feature | gitea-actions | jenkins | both |
|---------|--------------|---------|------|
| **Gitea Server** | ✅ + Actions | ✅ Git only | ✅ + Actions |
| **Gitea Actions** | ✅ Enabled | ❌ Disabled | ✅ Enabled |
| **Runners** | ✅ DaemonSet | ❌ None | ✅ DaemonSet |
| **Jenkins** | ❌ Not deployed | ✅ Full | ✅ Full |
| **Resource Usage** | Low | Medium | High |
| **Best For** | Modern CI/CD | Enterprise/Legacy | Migration |

---

## Mode 1: gitea-actions (Default)

**Cloud-native, Kubernetes-first CI/CD**

### What You Get
- ✅ Gitea server with Actions engine enabled
- ✅ Gitea Actions runners (DaemonSet, auto-scaling)
- ✅ Kaniko for Docker-less container builds
- ✅ GitHub Actions compatibility
- ❌ Jenkins (not deployed)

### Use Cases
- Modern development teams
- GitHub Actions users migrating to self-hosted
- Kubernetes-native workflows
- Teams that want lightweight CI/CD
- Testing Gitea Actions workflows locally before cluster deployment

### Deployment

```bash
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=gitea-actions \
  --set gitea.gitea.admin.password=<secure-password>
```

### What Gets Created
- Gitea server (Git + Actions API)
- Runner DaemonSet (one runner per node)
- Pre-wired hello-world repo with `.gitea/workflows/ci.yaml`
- Runner registration token (auto-created by wire job)

### Testing Workflows

The beauty of this mode: **you can test Gitea Actions workflows without spinning up a cluster**:

```bash
# 1. Deploy locally (kind, minikube, k3d)
kind create cluster
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=gitea-actions \
  --set gitea.gitea.admin.password=test123

# 2. Port-forward and develop
kubectl port-forward svc/cf-gitea-http 3000:3000

# 3. Edit workflows in browser at http://localhost:3000
# 4. See them run immediately on your laptop
# 5. No GitHub rate limits, no external dependencies
```

### Resource Requirements (Minimum)
- **Gitea**: 50m CPU, 128Mi RAM
- **Runner** (per node): 100m CPU, 128Mi RAM
- **Total**: ~200m CPU, ~300Mi RAM per node

---

## Mode 2: jenkins

**Traditional CI/CD with enterprise pedigree**

### What You Get
- ✅ Gitea server (Git-only, Actions disabled)
- ✅ Jenkins controller with pre-configured plugins
- ✅ Pre-wired Gitea credentials in Jenkins
- ✅ Pipeline job auto-created
- ❌ Gitea Actions (disabled to avoid confusion)
- ❌ Runners (not deployed)

### Use Cases
- Enterprise teams with Jenkins expertise
- Migration from GitHub + Jenkins
- Groovy pipeline users
- Complex build requirements (heavy plugins, enterprise integrations)
- Legacy infrastructure that needs Jenkins compatibility

### Deployment

```bash
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=jenkins \
  --set gitea.gitea.admin.password=<secure-password>
```

### What Gets Created
- Gitea server (Actions: `ENABLED=false`)
- Jenkins controller
- Pre-wired credentials:
  - `gitea-api-token` (secret text for API calls)
  - `gitea-userpass` (username+token for git clone)
- Pre-created Jenkins job: `clusterfactory-hello-world`
- Pre-wired Jenkinsfile in repository

### Accessing Services

```bash
# Gitea (Git server only)
kubectl port-forward svc/cf-gitea-http 3000:3000
# http://localhost:3000

# Jenkins
kubectl port-forward svc/cf-jenkins 8080:8080
# http://localhost:8080
# User: admin
# Pass: kubectl get secret cf-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

### Resource Requirements (Minimum)
- **Gitea**: 50m CPU, 128Mi RAM
- **Jenkins**: 100m CPU, 256Mi RAM
- **Total**: ~200m CPU, ~400Mi RAM

---

## Mode 3: both

**Hybrid setup for migration scenarios**

### What You Get
- ✅ Gitea server with Actions enabled
- ✅ Gitea Actions runners
- ✅ Jenkins controller
- ✅ Both CI/CD engines running simultaneously

### Use Cases
- **Migration path**: Moving from Jenkins → Gitea Actions
- **Gradual transition**: Run both engines while migrating pipelines
- **Legacy + modern**: Keep Jenkins for old pipelines, use Actions for new projects
- **Comparison testing**: A/B test workflows between engines
- **Not recommended for production long-term** (higher resource usage)

### Deployment

```bash
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=both \
  --set gitea.gitea.admin.password=<secure-password>
```

### What Gets Created
- Everything from `gitea-actions` mode
- Everything from `jenkins` mode
- Both Jenkinsfile and `.gitea/workflows/ci.yaml` in repo

### Migration Strategy

**Phase 1: Deploy Both**
```bash
helm upgrade cf clusterfactory --set mode=both --reuse-values
```

**Phase 2: Migrate Pipelines**
```bash
# Convert Jenkinsfile → .gitea/workflows/ci.yaml
# Test side-by-side
# Gradually move workloads
```

**Phase 3: Remove Jenkins**
```bash
helm upgrade cf clusterfactory --set mode=gitea-actions --reuse-values
```

### Resource Requirements (Minimum)
- **Gitea**: 50m CPU, 128Mi RAM
- **Jenkins**: 100m CPU, 256Mi RAM  
- **Runner** (per node): 100m CPU, 128Mi RAM
- **Total**: ~300m CPU, ~550Mi RAM per node

⚠️ **Warning**: This mode has the highest resource usage. Only use for specific migration or testing needs.

---

## Switching Between Modes

### From gitea-actions → jenkins

```bash
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=jenkins \
  --reuse-values
```

**What happens:**
- ❌ Runners are deleted
- ❌ Gitea Actions disabled in config
- ✅ Jenkins deployed
- ✅ Jenkinsfile created in repo
- ⚠️ Existing Actions workflow files remain (but inactive)

### From jenkins → gitea-actions

```bash
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=gitea-actions \
  --reuse-values
```

**What happens:**
- ✅ Gitea Actions enabled
- ✅ Runners deployed
- ✅ Workflows created in repo
- ❌ Jenkins controller remains (use `--set jenkins.enabled=false` to remove)
- ⚠️ Jenkins PVCs remain (manual cleanup if needed)

### From both → gitea-actions or jenkins

Just set the target mode. Resources for the disabled engine will be removed on the next `helm upgrade`.

---

## Transparency Benefits

All modes share the same supply chain transparency features:

### What You Can See
1. **Exact images deployed** (digest-pinned if configured)
2. **Component versions** (Gitea, Jenkins, runners)
3. **Network policies** (what talks to what)
4. **RBAC permissions** (runner pod permissions)

### What You Can Verify Before Deployment

```bash
# 1. Generate SBOM
syft gitea/gitea@sha256:... -o spdx-json > gitea-sbom.json

# 2. Scan for CVEs
grype gitea/gitea@sha256:... --only-fixed

# 3. Verify signatures (if available)
cosign verify gitea/gitea@sha256:...

# 4. Pull for airgap
docker save \
  gitea/gitea@sha256:... \
  jenkins/jenkins@sha256:... \
  gitea/act_runner@sha256:... \
  -o clusterfactory-images.tar
```

---

## Decision Tree

```
Do you need Jenkins for legacy pipelines?
│
├─ Yes → Do you also need Gitea Actions?
│  │
│  ├─ Yes (migration scenario) → mode=both
│  │
│  └─ No (Jenkins only) → mode=jenkins
│
└─ No → mode=gitea-actions (default)
```

---

## Real-World Examples

### Startup / SME Team
- **Mode**: `gitea-actions`
- **Why**: Lightweight, modern, no Jenkins complexity
- **Setup time**: ~2 minutes

### Enterprise with Jenkins Investment
- **Mode**: `jenkins`
- **Why**: Existing pipelines, Groovy expertise, enterprise plugins
- **Setup time**: ~3 minutes

### Migration Project
- **Mode**: `both` (temporary)
- **Why**: Gradual Jenkins → Actions migration
- **Duration**: 3-6 months, then switch to `gitea-actions`

### OSS Project Testing CI
- **Mode**: `gitea-actions`
- **Why**: Test Gitea Actions compatibility without GitHub Actions usage
- **Setup time**: ~2 minutes on local cluster

---

## FAQ

**Q: Can I run multiple Jenkins instances with different modes?**  
A: No. Use Helm release names to deploy multiple clusterfactory instances if needed.

**Q: Does mode=jenkins disable Gitea Actions permanently?**  
A: No. Switch to `gitea-actions` or `both` to re-enable.

**Q: Why would I use mode=both in production?**  
A: You typically wouldn't long-term. It's for migrations or A/B testing workflows.

**Q: Can I security-scan images before deployment?**  
A: Yes! See [Image Transparency Guide](./image-transparency.md) for SBOM and CVE scanning.

**Q: What if I need custom Jenkins plugins?**  
A: Override `jenkins.controller.installPlugins` in values.yaml.

---

## Next Steps

- [Image Transparency Guide](./image-transparency.md) - Digest pinning and supply chain security
- [Airgap Deployment Guide](./airgap-deployment.md) - Deploy without internet access
- [README](../README.md) - Quick start and installation

---

**Changed your mode?** Remember to run:
```bash
helm upgrade cf clusterfactory --set mode=<new-mode> --reuse-values
```
