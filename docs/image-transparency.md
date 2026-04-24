# Image Transparency & Supply Chain Security

ClusterFactory provides complete transparency into the container images you deploy, enabling security scanning, SBOM generation, and airgap deployments with verifiable supply chain.

---

## Why Digest Pinning Matters

### Tag-based Images (❌ Mutable)

```yaml
image: gitea/gitea:1.23.6
```

**Problems:**
- Tags can be overwritten (supply chain attack vector)
- No cryptographic verification
- Different pulls may get different images
- Can't verify what you deployed 6 months ago

### Digest-based Images (✅ Immutable)

```yaml
image: gitea/gitea@sha256:abc123def456...
```

**Benefits:**
- ✅ Cryptographically verified
- ✅ Immutable (same digest = same bits, always)
- ✅ Reproducible deployments
- ✅ SLSA-compliant
- ✅ Airgap-friendly

---

## Configuration

### Option 1: Use Tags (Default)

```yaml
images:
  gitea:
    repository: gitea/gitea
    tag: "1.23.6"
    digest: ""  # Empty = use tag
```

**When to use:**
- Development/testing
- Fast iteration
- When pulling latest security patches automatically

### Option 2: Pin Digests (Recommended for Production)

```yaml
images:
  gitea:
    repository: gitea/gitea
    tag: "1.23.6"  # Human-readable reference
    digest: "sha256:7c9e4b8b3a2f1d0e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5"
```

**When to use:**
- Production deployments
- Airgap environments
- Security-sensitive workloads
- Compliance requirements

---

## Updating Digests

### Automated Script

```bash
# Pull images and update values.yaml with digests
./hack/update-digests.sh

# Dry-run (see what would change)
./hack/update-digests.sh --dry-run
```

### Manual Process

```bash
# 1. Pull the image
docker pull gitea/gitea:1.23.6

# 2. Inspect to get digest
docker inspect gitea/gitea:1.23.6 --format='{{index .RepoDigests 0}}'
# Output: gitea/gitea@sha256:7c9e4b8b3a2f...

# 3. Update values.yaml
yq eval -i '.images.gitea.digest = "sha256:7c9e4b8b3a2f..."' values.yaml
```

### Using Helm

```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --set gitea.gitea.admin.password=secure123 \
  --set images.gitea.digest=sha256:7c9e4b8b3a2f1d0e...
```

---

## Pre-Deployment Verification

### Generate SBOM (Software Bill of Materials)

Using [Syft](https://github.com/anchore/syft):

```bash
# Generate SBOM in SPDX format
syft gitea/gitea@sha256:7c9e4b8b3a2f... -o spdx-json > gitea-sbom-spdx.json

# Generate SBOM in CycloneDX format
syft gitea/gitea@sha256:7c9e4b8b3a2f... -o cyclonedx-json > gitea-sbom-cyclonedx.json

# Human-readable table
syft gitea/gitea@sha256:7c9e4b8b3a2f... -o table
```

**Example output:**
```
NAME                    VERSION      TYPE
git                     2.43.0       apk
curl                    8.5.0        apk
postgresql-client       16.2         apk
...
```

### Scan for Vulnerabilities

Using [Grype](https://github.com/anchore/grype):

```bash
# Scan for all CVEs
grype gitea/gitea@sha256:7c9e4b8b3a2f...

# Only show fixable CVEs
grype gitea/gitea@sha256:7c9e4b8b3a2f... --only-fixed

# JSON output for CI/CD pipelines
grype gitea/gitea@sha256:7c9e4b8b3a2f... -o json > gitea-cve-scan.json

# Fail if critical or high CVEs found
grype gitea/gitea@sha256:7c9e4b8b3a2f... --fail-on high
```

**Example output:**
```
NAME           INSTALLED  FIXED-IN  TYPE  VULNERABILITY   SEVERITY
libcurl        8.5.0      8.5.1     apk   CVE-2024-1234   High
openssl        3.1.4      3.1.5     apk   CVE-2024-5678   Critical
```

### Verify Signatures (Cosign)

Using [Cosign](https://github.com/sigstore/cosign):

```bash
# Verify signature (if image is signed)
cosign verify gitea/gitea@sha256:7c9e4b8b3a2f... \
  --certificate-identity-regexp=".*" \
  --certificate-oidc-issuer-regexp=".*"

# Get attestations
cosign verify-attestation gitea/gitea@sha256:7c9e4b8b3a2f... \
  --type=slsaprovenance
```

---

## Images in ClusterFactory

### Core Images

| Component | Default Image | Purpose |
|-----------|---------------|---------|
| **Gitea** | `gitea/gitea:1.23.6` | Git server + Actions engine |
| **Jenkins** | `jenkins/jenkins:2.541.3-jdk21` | CI/CD controller |
| **Act Runner** | `gitea/act_runner:0.3.1` | Gitea Actions executor |

### Wire Job Images

| Engine | Image | Purpose |
|--------|-------|---------|
| **bash** | `alpine:3.19` | Lightweight bootstrap (default) |
| **python** | `ghcr.io/kube-tarian/clusterfactory-wire:0.2.0` | Python-based wiring |

---

## Full Pre-Deployment Workflow

### Step 1: Pull Images

```bash
# Define images from values.yaml
GITEA_IMAGE="gitea/gitea:1.23.6"
JENKINS_IMAGE="jenkins/jenkins:2.541.3-jdk21"
RUNNER_IMAGE="gitea/act_runner:0.3.1"
ALPINE_IMAGE="alpine:3.19"

# Pull all images
docker pull $GITEA_IMAGE
docker pull $JENKINS_IMAGE  # if mode=jenkins or mode=both
docker pull $RUNNER_IMAGE   # if mode=gitea-actions or mode=both
docker pull $ALPINE_IMAGE
```

### Step 2: Extract Digests

```bash
# Get digests
GITEA_DIGEST=$(docker inspect $GITEA_IMAGE --format='{{index .RepoDigests 0}}' | sed 's/.*@//')
JENKINS_DIGEST=$(docker inspect $JENKINS_IMAGE --format='{{index .RepoDigests 0}}' | sed 's/.*@//')
RUNNER_DIGEST=$(docker inspect $RUNNER_IMAGE --format='{{index .RepoDigests 0}}' | sed 's/.*@//')
ALPINE_DIGEST=$(docker inspect $ALPINE_IMAGE --format='{{index .RepoDigests 0}}' | sed 's/.*@//')

echo "Gitea:   $GITEA_DIGEST"
echo "Jenkins: $JENKINS_DIGEST"
echo "Runner:  $RUNNER_DIGEST"
echo "Alpine:  $ALPINE_DIGEST"
```

### Step 3: Generate SBOMs

```bash
# Generate SBOMs for all components
syft gitea/gitea@$GITEA_DIGEST -o spdx-json > sbom-gitea.json
syft jenkins/jenkins@$JENKINS_DIGEST -o spdx-json > sbom-jenkins.json
syft gitea/act_runner@$RUNNER_DIGEST -o spdx-json > sbom-runner.json
syft alpine@$ALPINE_DIGEST -o spdx-json > sbom-alpine.json

# Combine into single SBOM package
mkdir sboms
mv sbom-*.json sboms/
tar czf clusterfactory-sboms.tar.gz sboms/
```

### Step 4: Vulnerability Scanning

```bash
# Scan all images
grype gitea/gitea@$GITEA_DIGEST -o json > scan-gitea.json
grype jenkins/jenkins@$JENKINS_DIGEST -o json > scan-jenkins.json
grype gitea/act_runner@$RUNNER_DIGEST -o json > scan-runner.json
grype alpine@$ALPINE_DIGEST -o json > scan-alpine.json

# Check for critical/high CVEs
grype gitea/gitea@$GITEA_DIGEST --fail-on high
```

### Step 5: Update values.yaml

```bash
# Use automated script
./hack/update-digests.sh

# Or manually
yq eval -i ".images.gitea.digest = \"$GITEA_DIGEST\"" values.yaml
yq eval -i ".images.jenkins.digest = \"$JENKINS_DIGEST\"" values.yaml
yq eval -i ".images.actRunner.digest = \"$RUNNER_DIGEST\"" values.yaml
yq eval -i ".images.wire.bash.digest = \"$ALPINE_DIGEST\"" values.yaml
```

### Step 6: Verify Helm Templates

```bash
# Verify all images use digests
helm template . --set gitea.gitea.admin.password=test | grep "image:" | grep -v "@sha256:"

# If above returns nothing, all images are digest-pinned ✅
```

---

## Airgap Deployment

### Step 1: Export Images

```bash
# Save images to tarball
docker save \
  gitea/gitea@$GITEA_DIGEST \
  jenkins/jenkins@$JENKINS_DIGEST \
  gitea/act_runner@$RUNNER_DIGEST \
  alpine@$ALPINE_DIGEST \
  -o clusterfactory-images-v0.2.0.tar

# Compress (optional)
gzip clusterfactory-images-v0.2.0.tar
```

### Step 2: Package Helm Chart

```bash
# Package chart
helm package .

# Output: clusterfactory-0.2.0.tgz
```

### Step 3: Transfer to Airgap

```bash
# Bundle everything
mkdir airgap-bundle
mv clusterfactory-0.2.0.tgz airgap-bundle/
mv clusterfactory-images-v0.2.0.tar.gz airgap-bundle/
mv clusterfactory-sboms.tar.gz airgap-bundle/
mv scan-*.json airgap-bundle/

# Create manifest
cat > airgap-bundle/manifest.txt << EOF
ClusterFactory Airgap Bundle
Version: 0.2.0
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Images:
- gitea/gitea@$GITEA_DIGEST
- jenkins/jenkins@$JENKINS_DIGEST
- gitea/act_runner@$RUNNER_DIGEST
- alpine@$ALPINE_DIGEST

Files:
- clusterfactory-0.2.0.tgz (Helm chart)
- clusterfactory-images-v0.2.0.tar.gz (Container images)
- clusterfactory-sboms.tar.gz (SBOMs)
- scan-*.json (CVE scan results)

Verification:
  sha256sum *.tar.gz *.tgz > checksums.txt
EOF

# Create checksums
cd airgap-bundle
sha256sum *.tar.gz *.tgz > checksums.txt
cd ..

# Final bundle
tar czf clusterfactory-airgap-v0.2.0.tar.gz airgap-bundle/
```

### Step 4: Deploy in Airgap

```bash
# 1. Extract bundle
tar xzf clusterfactory-airgap-v0.2.0.tar.gz
cd airgap-bundle

# 2. Verify checksums
sha256sum -c checksums.txt

# 3. Load images
gunzip clusterfactory-images-v0.2.0.tar.gz
docker load -i clusterfactory-images-v0.2.0.tar

# 4. Tag images for local registry (if needed)
docker tag gitea/gitea@$GITEA_DIGEST harbor.airgap.local/clusterfactory/gitea:1.23.6
docker push harbor.airgap.local/clusterfactory/gitea:1.23.6

# 5. Install Helm chart
helm upgrade --install cf clusterfactory-0.2.0.tgz \
  --set gitea.gitea.admin.password=secure123 \
  --set images.gitea.repository=harbor.airgap.local/clusterfactory/gitea \
  --set images.gitea.digest=$GITEA_DIGEST \
  --set gitea.image.pullPolicy=IfNotPresent
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Security Scan

on: [pull_request]

jobs:
  scan-images:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install tools
        run: |
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh
          curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh
      
      - name: Extract image refs
        run: |
          yq '.images.gitea.repository + "@" + .images.gitea.digest' values.yaml > gitea-ref.txt
      
      - name: Generate SBOM
        run: syft $(cat gitea-ref.txt) -o spdx-json > gitea-sbom.json
      
      - name: Scan for CVEs
        run: grype $(cat gitea-ref.txt) --fail-on high
      
      - name: Upload SBOM
        uses: actions/upload-artifact@v4
        with:
          name: sbom
          path: gitea-sbom.json
```

---

## Best Practices

### 1. Always Pin Digests in Production

```yaml
# ✅ Good
images:
  gitea:
    digest: "sha256:7c9e4b8b3a2f..."

# ❌ Avoid in production
images:
  gitea:
    digest: ""  # Uses tag, mutable
```

### 2. Automate Digest Updates

```bash
# Add to CI/CD pipeline
./hack/update-digests.sh
git diff values.yaml  # Review changes
git commit -m "chore: update image digests"
```

### 3. Store SBOMs with Releases

```bash
# Tag release
git tag v0.2.0

# Generate SBOMs
syft gitea/gitea@sha256:... -o spdx-json > sbom-gitea-v0.2.0.json

# Upload to release
gh release upload v0.2.0 sbom-gitea-v0.2.0.json
```

### 4. Fail Fast on CVEs

```bash
# In CI/CD
grype gitea/gitea@sha256:... --fail-on critical
```

### 5. Document Your Supply Chain

```yaml
# values.yaml
images:
  gitea:
    repository: gitea/gitea
    tag: "1.23.6"
    digest: "sha256:7c9e4b8b3a2f..."
    # Verified on: 2024-04-23
    # Scanned with: grype v0.74.0
    # CVE count: 0 critical, 2 high (all in base OS, patches available)
    # SBOM: https://github.com/org/repo/releases/v0.2.0/sbom-gitea.json
```

---

## Troubleshooting

### Image Pull Failures with Digest

```bash
# Error: manifest unknown
# Solution: Digest may be incorrect, verify with docker inspect

docker pull gitea/gitea:1.23.6
docker inspect gitea/gitea:1.23.6 --format='{{index .RepoDigests 0}}'
```

### Template Shows Tag Instead of Digest

```bash
# Check if digest is set
helm template . --set gitea.gitea.admin.password=test | grep "gitea/gitea"

# Should show: gitea/gitea@sha256:...
# If shows tag: gitea/gitea:1.23.6
# → Digest is empty or helper not used
```

### Digest Update Script Fails

```bash
# Requires yq
brew install yq  # macOS
apt install yq   # Ubuntu

# Requires docker
docker ps
```

---

## References

- [SLSA Framework](https://slsa.dev/) - Supply chain security levels
- [Sigstore Cosign](https://docs.sigstore.dev/cosign/overview/) - Image signing
- [Syft](https://github.com/anchore/syft) - SBOM generation
- [Grype](https://github.com/anchore/grype) - Vulnerability scanning
- [SPDX](https://spdx.dev/) - SBOM standard
- [CycloneDX](https://cyclonedx.org/) - SBOM standard

---

**Next Steps:**
- [Deployment Modes Guide](./deployment-modes.md) - Choose your CI/CD engine
- [Airgap Deployment Guide](./airgap-deployment.md) - Deploy without internet
- [README](../README.md) - Quick start
