# Deployment Modes & Image Transparency Refactoring

**Date:** 2026-04-22  
**Status:** Planned - To be implemented after security PR merge  
**Priority:** High - Completes security story

---

## Executive Summary

Transform clusterfactory from a monolithic bootstrap tool into a **transparent, mode-based platform** with clear deployment options and verifiable image supply chain.

### Goals
1. **Formalize two distinct deployment modes**: Gitea Actions vs Jenkins
2. **Add image transparency**: Digest-pinned, verifiable images
3. **Enable airgap security scanning**: Pre-deployment verification
4. **Improve user clarity**: Clear documentation of what you're installing

---

## Problem Statement

### Current Issues
❌ **Ambiguous deployment model**: Users unclear if they need Jenkins AND Gitea Actions  
❌ **No image verification**: Tags can be mutated, no supply chain transparency  
❌ **Airgap blind spots**: Can't pre-scan what you're deploying  
❌ **Mixed messaging**: Are we a Jenkins tool? A Gitea Actions tool? Both?

### Impact
- Confusion in production deployments
- Security teams can't verify components
- Airgap deployments lack transparency
- No clear upgrade path from Jenkins → Gitea Actions

---

## Proposed Solution

## 1. Deployment Mode Selection

### Add mode selector to values.yaml

```yaml
# ═══════════════════════════════════════════════════════════
# Deployment Mode
# ═══════════════════════════════════════════════════════════
# Choose your CI/CD engine:
#   "gitea-actions" - Cloud-native, Kubernetes-first CI/CD
#   "jenkins"       - Traditional pipeline CI, enterprise-friendly
# ═══════════════════════════════════════════════════════════

mode: "gitea-actions"  # Options: "gitea-actions" | "jenkins"
```

### Mode Behavior

#### Mode: gitea-actions
```yaml
# Enabled:
gitea:
  enabled: true
  gitea:
    config:
      actions:
        ENABLED: "true"

runner:
  enabled: true

# Disabled:
jenkins:
  enabled: false

# Wire job creates:
- .gitea/workflows/ci.yaml ✅
- Jenkinsfile ❌ (skipped)
```

#### Mode: jenkins
```yaml
# Enabled:
gitea:
  enabled: true
  gitea:
    config:
      actions:
        ENABLED: "false"  # Git server only

jenkins:
  enabled: true

# Disabled:
runner:
  enabled: false

# Wire job creates:
- Jenkinsfile ✅
- .gitea/workflows/ci.yaml ❌ (skipped)
```

---

## 2. Image Transparency & Verification

### Add image digest pinning

```yaml
# ═══════════════════════════════════════════════════════════
# Image Transparency
# ═══════════════════════════════════════════════════════════
# All images pinned to SHA256 digests for:
#   - Reproducible deployments
#   - Supply chain verification
#   - Airgap security scanning
#   - SLSA compliance
# ═══════════════════════════════════════════════════════════

images:
  gitea:
    repository: gitea/gitea
    tag: "1.23.6"
    # Digest verified from: docker pull gitea/gitea:1.23.6
    # Inspect with: docker inspect --format='{{.RepoDigests}}' gitea/gitea:1.23.6
    digest: "sha256:abc123def456..."
    # SBOM: Run `syft gitea/gitea@sha256:abc123... -o json > gitea-sbom.json`
    # CVE scan: `grype gitea/gitea@sha256:abc123...`
    
  jenkins:
    repository: jenkins/jenkins
    tag: "2.541.3-jdk21"
    digest: "sha256:def456ghi789..."
    
  act_runner:
    repository: gitea/act_runner
    tag: "0.3.1"
    digest: "sha256:ghi789jkl012..."
    
  # Wire job images (used for bootstrapping)
  wire:
    bash:
      repository: alpine
      tag: "3.19"
      digest: "sha256:jkl012mno345..."
    python:
      repository: python
      tag: "3.12-alpine"
      digest: "sha256:mno345pqr678..."
```

### Template usage

```yaml
# Current (tag-based - mutable):
image: {{ .Values.gitea.image.repository }}:{{ .Values.gitea.image.tag }}

# Proposed (digest-based - immutable):
{{- if .Values.images.gitea.digest }}
image: {{ .Values.images.gitea.repository }}@{{ .Values.images.gitea.digest }}
{{- else }}
image: {{ .Values.images.gitea.repository }}:{{ .Values.images.gitea.tag }}
{{- end }}
```

---

## 3. Documentation Updates

### README.md Changes

#### Add "Deployment Modes" Section

```markdown
## Deployment Modes

clusterfactory supports two distinct CI/CD deployment models:

### Mode 1: Gitea Actions (Default)
**Best for**: Cloud-native, Kubernetes-first teams

- **What you get**:
  - Gitea as Git server + Actions engine
  - Gitea Actions runner (Kaniko-based)
  - No Jenkins overhead
  
- **Use case**: Modern CI/CD, container-native workflows, GitHub Actions compatibility

```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --set mode=gitea-actions \
  --set gitea.gitea.admin.password=<your-password>
```

### Mode 2: Jenkins + Gitea
**Best for**: Enterprise teams with existing Jenkins expertise

- **What you get**:
  - Gitea as Git server only (Actions disabled)
  - Jenkins for pipeline orchestration
  - Pre-wired Jenkins credentials
  
- **Use case**: Traditional CI/CD, Groovy pipelines, Jenkins ecosystem

```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --set mode=jenkins \
  --set gitea.gitea.admin.password=<your-password>
```

---

## Migration Path

### Jenkins → Gitea Actions
```bash
# 1. Deploy in gitea-actions mode
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=gitea-actions \
  --reuse-values

# 2. Jenkins is automatically disabled
# 3. Gitea Actions workflows are created
# 4. Runners auto-register
```

### Gitea Actions → Jenkins
```bash
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=jenkins \
  --reuse-values
```
```

#### Add "Image Transparency" Section

```markdown
## Image Transparency & Verification

All container images are **digest-pinned** for supply chain security.

### Why Digest Pinning?

| Tag-based (❌ Mutable) | Digest-based (✅ Immutable) |
|------------------------|----------------------------|
| `gitea/gitea:1.23.6` | `gitea/gitea@sha256:abc...` |
| Tag can be overwritten | Digest is cryptographically verified |
| No verification possible | Reproducible deployments |
| Supply chain attacks possible | SLSA-compliant |

### Verify Images Before Deploy

```bash
# 1. Inspect digest
docker pull gitea/gitea:1.23.6
docker inspect gitea/gitea:1.23.6 | grep RepoDigests

# 2. Generate SBOM (Software Bill of Materials)
syft gitea/gitea@sha256:abc123... -o json > gitea-sbom.json

# 3. Scan for CVEs
grype gitea/gitea@sha256:abc123... --only-fixed

# 4. Verify signatures (if available)
cosign verify gitea/gitea@sha256:abc123...
```

### Airgap Deployment Workflow

```bash
# 1. Pull images by digest
docker pull gitea/gitea@sha256:abc123...
docker pull jenkins/jenkins@sha256:def456...
docker pull gitea/act_runner@sha256:ghi789...

# 2. Scan images
grype gitea/gitea@sha256:abc123... --output json > scan-results.json

# 3. Generate SBOMs
syft gitea/gitea@sha256:abc123... -o spdx-json > gitea-spdx.json

# 4. Export to tarball
docker save \
  gitea/gitea@sha256:abc123... \
  jenkins/jenkins@sha256:def456... \
  -o clusterfactory-images.tar

# 5. Transfer to airgap environment

# 6. Import and deploy
docker load -i clusterfactory-images.tar
helm upgrade --install cf clusterfactory-*.tgz \
  --set gitea.image.pullPolicy=IfNotPresent
```
```

---

## 4. Implementation Tasks

### Phase 1: Mode Selection Logic

- [ ] **File**: `values.yaml`
  - Add `mode` selector at top level
  - Add mode documentation
  - Set default to `gitea-actions`

- [ ] **File**: `templates/_mode-helpers.tpl` (NEW)
  ```yaml
  {{- define "clusterfactory.mode.isGiteaActions" -}}
  {{- eq .Values.mode "gitea-actions" }}
  {{- end }}
  
  {{- define "clusterfactory.mode.isJenkins" -}}
  {{- eq .Values.mode "jenkins" }}
  {{- end }}
  ```

- [ ] **File**: `templates/wire-job.yaml`
  - Conditional Jenkinsfile creation based on mode
  - Conditional Gitea Actions workflow based on mode

- [ ] **File**: `Chart.yaml`
  - Update dependencies conditions:
    ```yaml
    dependencies:
      - name: jenkins
        condition: jenkins.enabled
      - name: gitea
        condition: gitea.enabled
    ```

- [ ] **File**: `templates/NOTES.txt` (NEW)
  ```
  ╔════════════════════════════════════════════════════════╗
  ║  ClusterFactory Deployed Successfully!                 ║
  ╚════════════════════════════════════════════════════════╝
  
  Mode: {{ .Values.mode }}
  {{- if eq .Values.mode "gitea-actions" }}
  CI/CD Engine: Gitea Actions
  Runner: DaemonSet ({{ .Values.runner.replicaCount }} pods)
  {{- else }}
  CI/CD Engine: Jenkins
  Pipeline: Configured at /job/{{ .Values.wire.org }}/{{ .Values.wire.repo.name }}
  {{- end }}
  
  Access Gitea:
    kubectl port-forward -n {{ .Release.Namespace }} svc/{{ .Release.Name }}-gitea-http 3000:3000
    URL: http://localhost:3000
    User: {{ .Values.gitea.gitea.admin.username }}
    Pass: kubectl get secret {{ .Release.Name }}-gitea-admin -o jsonpath='{.data.password}' | base64 -d
  
  {{- if eq .Values.mode "jenkins" }}
  Access Jenkins:
    kubectl port-forward -n {{ .Release.Namespace }} svc/{{ .Release.Name }}-jenkins 8080:8080
    URL: http://localhost:8080
    User: admin
    Pass: kubectl get secret {{ .Release.Name }}-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
  {{- end }}
  ```

### Phase 2: Image Transparency

- [ ] **File**: `values.yaml`
  - Add top-level `images:` section
  - Document digest verification process
  - Pin all image digests

- [ ] **Script**: `hack/update-digests.sh` (NEW)
  ```bash
  #!/bin/bash
  # Update image digests in values.yaml
  
  IMAGES=(
    "gitea/gitea:1.23.6"
    "jenkins/jenkins:2.541.3-jdk21"
    "gitea/act_runner:0.3.1"
    "alpine:3.19"
    "python:3.12-alpine"
  )
  
  for img in "${IMAGES[@]}"; do
    echo "Fetching digest for: $img"
    digest=$(docker pull "$img" 2>&1 | grep Digest | awk '{print $2}')
    echo "  → $digest"
    # Update values.yaml with yq
  done
  ```

- [ ] **File**: `templates/_helpers.tpl`
  - Add `clusterfactory.image` helper:
    ```yaml
    {{- define "clusterfactory.image" -}}
    {{- $img := index .Values.images .name }}
    {{- if $img.digest }}
    {{- printf "%s@%s" $img.repository $img.digest }}
    {{- else }}
    {{- printf "%s:%s" $img.repository $img.tag }}
    {{- end }}
    {{- end }}
    ```

- [ ] **Update all templates**
  - Replace hardcoded images with `{{ include "clusterfactory.image" (dict "Values" .Values "name" "gitea") }}`

### Phase 3: Documentation

- [ ] **File**: `README.md`
  - Add "Deployment Modes" section
  - Add "Image Transparency" section
  - Add "Airgap Security Scanning" guide
  - Update Quick Start examples

- [ ] **File**: `docs/deployment-modes.md` (NEW)
  - Deep dive on each mode
  - Migration guides
  - Best practices

- [ ] **File**: `docs/airgap-deployment.md` (NEW)
  - Complete airgap workflow
  - Image verification steps
  - SBOM generation
  - Security scanning examples

- [ ] **File**: `docs/image-transparency.md` (NEW)
  - Why digest pinning matters
  - How to verify images
  - Supply chain security
  - Cosign/SLSA integration

### Phase 4: Validation

- [ ] **File**: `values.schema.json`
  - Add mode validation:
    ```json
    {
      "properties": {
        "mode": {
          "type": "string",
          "enum": ["gitea-actions", "jenkins"],
          "description": "Deployment mode"
        }
      }
    }
    ```

- [ ] **CI**: Update test workflows
  - Test both modes separately
  - Verify digest usage
  - SBOM generation in CI

- [ ] **File**: `hack/verify-images.sh` (NEW)
  ```bash
  # Verify all images are digest-pinned
  # Run in CI to enforce policy
  ```

---

## 5. Security Benefits

### Supply Chain Security
✅ **Immutable deployments**: Digest pinning prevents tag mutation attacks  
✅ **Reproducible builds**: Same digest = same bits, always  
✅ **Provenance tracking**: Know exactly what's running  
✅ **Signature verification**: Cosign integration ready  

### Airgap Transparency
✅ **Pre-deployment scanning**: Scan images before import  
✅ **SBOM generation**: Full component inventory  
✅ **CVE analysis**: Know vulnerabilities before deploy  
✅ **Compliance ready**: Meet enterprise security requirements  

### Operational Clarity
✅ **Clear deployment models**: No ambiguity  
✅ **Migration paths**: Jenkins ↔ Gitea Actions  
✅ **Reduced complexity**: One mode at a time  
✅ **Better documentation**: Users know what they're getting  

---

## 6. User Impact

### Before
```bash
# Unclear: Do I get Jenkins AND Gitea Actions?
helm install cf clusterfactory/clusterfactory

# Result: Both deployed, resource waste, confusion
```

### After
```bash
# Clear: I want Gitea Actions
helm install cf clusterfactory/clusterfactory --set mode=gitea-actions

# Result: Only Gitea + Actions, clear deployment
```

---

## 7. Migration Guide for Existing Users

### Detect Current Mode
```bash
# Check if Jenkins is deployed
if kubectl get deployment -n cicd cf-jenkins 2>/dev/null; then
  echo "Current mode: jenkins"
else
  echo "Current mode: gitea-actions (or custom)"
fi
```

### Upgrade with Explicit Mode
```bash
# Preserve current behavior
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=jenkins \  # or gitea-actions
  --reuse-values
```

### Switch Modes
```bash
# Switch from Jenkins to Gitea Actions
helm upgrade cf clusterfactory/clusterfactory \
  --set mode=gitea-actions \
  --reuse-values

# Note: Jenkins PVCs remain but are unused
```

---

## 8. Testing Strategy

### Unit Tests
- [ ] Mode selection logic
- [ ] Image digest rendering
- [ ] Conditional template rendering

### Integration Tests
```bash
# Test gitea-actions mode
helm install test-ga . --set mode=gitea-actions --set gitea.gitea.admin.password=test
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=runner -n default --timeout=300s

# Test jenkins mode
helm install test-jenkins . --set mode=jenkins --set gitea.gitea.admin.password=test
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=jenkins-controller -n default --timeout=300s
```

### Security Tests
```bash
# Verify digest pinning
helm template . | grep "image:" | grep -v "@sha256:" && exit 1 || echo "All images digest-pinned ✅"

# SBOM generation
syft $(helm template . | grep "image:" | head -1 | awk '{print $2}') -o json

# CVE scan
grype $(helm template . | grep "image:" | head -1 | awk '{print $2}')
```

---

## 9. Rollout Plan

### Stage 1: Implementation (Week 1)
- Implement mode selection
- Add image digests
- Update templates

### Stage 2: Documentation (Week 1-2)
- README updates
- New guides (airgap, modes, images)
- Migration documentation

### Stage 3: Testing (Week 2)
- CI/CD updates
- Both modes tested
- SBOM/scanning validation

### Stage 4: Release (Week 3)
- Chart version bump (0.3.0)
- CHANGELOG.md update
- Release notes with migration guide

---

## 10. Success Metrics

### User Clarity
- ✅ Deployment mode explicitly chosen
- ✅ Clear documentation of what's installed
- ✅ Migration path documented

### Security Posture
- ✅ 100% images digest-pinned
- ✅ SBOM generation documented
- ✅ CVE scanning possible pre-deploy
- ✅ Supply chain transparency

### Operational Excellence
- ✅ Reduced resource usage (one mode at a time)
- ✅ Faster deployments (less to install)
- ✅ Clear upgrade paths

---

## 11. Breaking Changes

### For New Users
- **None** - Default mode (`gitea-actions`) maintains current behavior

### For Existing Users
- **Must specify mode** on upgrade (auto-detected based on existing deployment)
- **Recommended**: Add `--set mode=<current-mode>` to upgrade command

### Deprecation Path
- v0.3.0: Introduce `mode` selector, both modes supported
- v0.4.0: Deprecate implicit mode selection
- v0.5.0: Mode required, no default

---

## 12. Open Questions

1. **Should digest updates be automated?**
   - GitHub Action to update digests weekly?
   - Renovate/Dependabot for digest updates?

2. **Cosign signature verification?**
   - Require signed images in values.yaml?
   - Document how to verify signatures?

3. **SLSA attestation?**
   - Generate SLSA provenance for chart?
   - Verify SLSA provenance of images?

4. **Default mode?**
   - Keep `gitea-actions` as default?
   - Force users to choose explicitly?

---

## 13. References

- [SLSA Framework](https://slsa.dev/)
- [Sigstore Cosign](https://docs.sigstore.dev/cosign/overview/)
- [Syft SBOM Tool](https://github.com/anchore/syft)
- [Grype Vulnerability Scanner](https://github.com/anchore/grype)
- [Docker Content Trust](https://docs.docker.com/engine/security/trust/)

---

## 14. Estimated Effort

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| Mode selection logic | 4 hours | None |
| Image digest pinning | 2 hours | Mode logic |
| Template updates | 3 hours | Digests |
| Documentation | 4 hours | All above |
| Testing & validation | 3 hours | All above |
| **Total** | **16 hours** | **~2 days** |

---

## Next Steps

1. **Review this plan** - Get feedback/approval
2. **Create GitHub issue** - Track implementation
3. **Implement after security PR merge** - Keep PRs focused
4. **Target release**: v0.3.0

**Priority**: High - Completes the security story with transparency and clarity
