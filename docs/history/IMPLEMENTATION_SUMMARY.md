# Deployment Modes Implementation Summary

**Date:** 2024-04-24  
**Status:** ✅ Complete and Tested

---

## What Was Implemented

### 1. Three Deployment Modes

**Mode: `gitea-actions` (default)**
- ✅ Gitea server + Actions engine
- ✅ Gitea Actions runners (DaemonSet)
- ✅ Kaniko-based builds
- ❌ Jenkins disabled
- **Use case:** Modern CI/CD, cloud-native workflows, local Actions testing

**Mode: `jenkins`**
- ✅ Gitea server (Git-only, Actions disabled)
- ✅ Jenkins controller
- ✅ Pre-wired credentials
- ❌ Runners disabled
- **Use case:** Enterprise teams with Jenkins expertise

**Mode: `both`**
- ✅ Everything enabled
- ✅ Both CI/CD engines
- ⚠️ Higher resource usage
- **Use case:** Migration scenarios, A/B testing

### 2. Image Transparency

All images now support optional digest pinning:

```yaml
images:
  gitea:
    repository: gitea/gitea
    tag: "1.23.6"
    digest: ""  # Optional sha256:... for immutable pinning
```

**Benefits:**
- Reproducible deployments
- Pre-deployment CVE scanning
- SBOM generation
- Airgap readiness
- Supply chain verification

### 3. Automation & Documentation

**Created:**
- `hack/update-digests.sh` - Automated digest updating
- `docs/deployment-modes.md` - Comprehensive mode guide
- `docs/image-transparency.md` - Supply chain security guide
- `templates/NOTES.txt` - Post-install deployment info
- `templates/_mode-helpers.tpl` - Mode detection helpers

**Updated:**
- `values.yaml` - Added mode selector and images section
- `Chart.yaml` - Conditional dependencies
- `values.schema.json` - Mode and digest validation
- All runner templates - Mode-aware rendering
- Wire job - Conditional Jenkins/Actions setup

---

## Key Features

### 🎯 Clarity
- Explicit mode selection (no ambiguity)
- Clear documentation of what gets deployed
- Post-install NOTES show deployment details

### 🔒 Security
- Optional digest pinning for all images
- Pre-deployment SBOM generation possible
- CVE scanning before deploy
- Verifiable supply chain

### 🚀 Flexibility
- Test Gitea Actions locally without GitHub
- Gradual migration Jenkins → Actions
- Switch modes with simple `helm upgrade`

### 📦 Airgap Ready
- Complete transparency of dependencies
- Know exactly what images you need
- Security scan before transfer
- Reproducible deployments

---

## Testing Results

All modes tested and validated:

✅ **Mode: gitea-actions**
- Runner DaemonSet deployed
- No Jenkins resources
- Gitea Actions enabled
- Wire job creates workflows only

✅ **Mode: jenkins**
- No runner resources
- Jenkins deployed
- Gitea Actions disabled
- Wire job creates Jenkinsfile + Jenkins jobs

✅ **Mode: both**
- Runner + Jenkins both deployed
- Both engines active
- Wire job creates everything

✅ **Image Digests**
- Tags used when digest empty
- Digests used when set
- All images support pinning

---

## Usage Examples

### Deploy with Gitea Actions (default)
```bash
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=gitea-actions \
  --set gitea.gitea.admin.password=secure123
```

### Deploy with Jenkins
```bash
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=jenkins \
  --set gitea.gitea.admin.password=secure123
```

### Deploy with Digest Pinning
```bash
# Update digests
./hack/update-digests.sh

# Deploy with pinned images
helm upgrade --install cf oci://ghcr.io/kube-tarian/clusterfactory \
  --set mode=gitea-actions \
  --set gitea.gitea.admin.password=secure123 \
  -f values.yaml
```

### Pre-deployment Security Scan
```bash
# Update and verify digests
./hack/update-digests.sh

# Get digest
GITEA_DIGEST=$(yq '.images.gitea.digest' values.yaml)

# Generate SBOM
syft gitea/gitea@$GITEA_DIGEST -o spdx-json > sbom.json

# Scan for CVEs
grype gitea/gitea@$GITEA_DIGEST --fail-on high
```

---

## Real-World Power

### Local Actions Testing
```bash
# Spin up local cluster
kind create cluster

# Deploy in minutes
helm install cf . --set mode=gitea-actions --set gitea.gitea.admin.password=test

# Port-forward
kubectl port-forward svc/cf-gitea-http 3000:3000

# Test GitHub Actions workflows locally without GitHub!
```

### Airgap Deployment
```bash
# 1. Pull and verify (connected environment)
./hack/update-digests.sh
grype gitea/gitea@sha256:... --only-fixed
syft gitea/gitea@sha256:... -o spdx-json > sbom.json

# 2. Export images
docker save gitea/gitea@sha256:... -o images.tar

# 3. Transfer to airgap

# 4. Deploy with confidence (airgap environment)
docker load -i images.tar
helm install cf . --set images.gitea.digest=sha256:...
```

### Migration Strategy
```bash
# Phase 1: Deploy both
helm install cf . --set mode=both --set gitea.gitea.admin.password=secure

# Phase 2: Migrate pipelines (both running, no downtime)
# Convert Jenkinsfiles → .gitea/workflows/*.yaml

# Phase 3: Switch to Actions only
helm upgrade cf . --set mode=gitea-actions
```

---

## Files Changed

**New (8 files):**
- `templates/_mode-helpers.tpl`
- `templates/NOTES.txt`
- `docs/deployment-modes.md`
- `docs/image-transparency.md`
- `hack/update-digests.sh`
- `DEPLOYMENT_MODES_IMPLEMENTATION.md`
- `IMPLEMENTATION_SUMMARY.md` (this file)

**Modified (8 files):**
- `values.yaml`
- `Chart.yaml`
- `values.schema.json`
- `templates/_helpers.tpl`
- `templates/_wire-helpers.tpl`
- `templates/runner-daemonset.yaml`
- `templates/runner-config-cm.yaml`
- `templates/runner-rbac.yaml`

---

## Next Steps

### For Users

1. **Choose your mode:**
   - Modern CI/CD? → `mode=gitea-actions`
   - Enterprise Jenkins? → `mode=jenkins`
   - Migrating? → `mode=both`

2. **For production, consider digest pinning:**
   ```bash
   ./hack/update-digests.sh
   # Review changes, commit
   ```

3. **Read the guides:**
   - [Deployment Modes](docs/deployment-modes.md)
   - [Image Transparency](docs/image-transparency.md)

### For Maintainers

1. **CI/CD updates:**
   - Test all three modes in CI
   - Add digest update automation
   - SBOM generation on releases

2. **Future enhancements:**
   - Automated weekly digest updates
   - Cosign signature verification
   - SLSA provenance generation

---

## Success Metrics

✅ **User clarity:** Deployment mode explicitly chosen  
✅ **Security:** 100% images can be digest-pinned  
✅ **Transparency:** Complete visibility into supply chain  
✅ **Flexibility:** Switch modes easily, test locally  
✅ **Airgap:** Pre-deployment scanning enabled  
✅ **Testing:** All modes validated

---

## The Bottom Line

ClusterFactory now provides **crystal-clear transparency** over what you deploy:

- 🎯 **Choose your mode** - No ambiguity about what gets installed
- 🔒 **Verify your images** - Digest pinning, SBOM, CVE scanning
- 🚀 **Test locally** - Gitea Actions without GitHub
- 📦 **Deploy airgap** - Know exactly what you're transferring
- 🔄 **Migrate safely** - Jenkins → Actions with zero downtime

**The power is transparency.** You see what you bolt, what images run, what you take airgap, and you can security-scan everything before deployment.

---

✅ **Implementation complete and tested**
🎉 **Ready for production use**
📚 **Fully documented**
