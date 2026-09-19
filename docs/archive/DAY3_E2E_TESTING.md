# Day 3: E2E Testing Guide

This guide walks through end-to-end testing of the v0.3 wire engine on k3d.

## Prerequisites

### 1. Start Docker Desktop
```bash
open -a Docker
# Wait for Docker to start (whale icon in menu bar)
docker ps  # Should work when ready
```

### 2. Install Zarf CLI
```bash
# Option A: Homebrew
brew tap defenseunicorns/tap
brew install zarf

# Option B: Direct download (v0.44+)
curl -sL https://github.com/defenseunicorns/zarf/releases/latest/download/zarf_$(uname -s)_$(uname -m) -o /usr/local/bin/zarf
chmod +x /usr/local/bin/zarf

# Verify
zarf version
```

### 3. Verify tools
```bash
docker version
k3d version
zarf version
kubectl version --client
```

## Step-by-Step Test

### Step 1: Create k3d cluster
```bash
# Create a lightweight k3s cluster in Docker
k3d cluster create cf-test \
  --agents 0 \
  --k3s-arg '--disable=traefik@server:0' \
  --wait

# Verify
kubectl get nodes
```

### Step 2: Build wire engine image
```bash
cd /path/to/clusterfactory

# Build the Python wire engine image
make wire-image

# This does:
# 1. docker build -t ghcr.io/clusterfactory/clusterfactory-wire:0.3.0 engine/
# 2. k3d image import ghcr.io/clusterfactory/clusterfactory-wire:0.3.0 -c cf-test

# Verify image is in k3d
docker exec k3d-cf-test-server-0 crictl images | grep wire
```

### Step 3: Create Zarf package
```bash
# Create the airgap bundle (includes Gitea + Jenkins + our wire image)
make package

# This creates: clusterfactory-ci-0.3.0-amd64.tar.zst
# Includes:
# - Gitea chart from https://dl.gitea.com/charts/
# - Jenkins chart from https://charts.jenkins.io
# - All container images by digest
# - Wire engine manifests
# - SBOM for supply chain transparency

# Verify
ls -lh clusterfactory-ci-0.3.0-amd64.tar.zst
zarf package inspect clusterfactory-ci-0.3.0-amd64.tar.zst
```

### Step 4: Deploy package
```bash
# Deploy everything to k8s
export GITEA_ADMIN_PASSWORD=demo123
make deploy

# This does:
# 1. Creates namespace cicd
# 2. Deploys NetworkPolicies
# 3. Creates gitea-admin Secret
# 4. Installs Gitea chart
# 5. Installs Jenkins chart
# 6. Creates platform ConfigMap
# 7. Runs wire Job
# 8. Waits for Job completion
# 9. Prints structural SHA

# Watch deployment
kubectl get pods -n cicd -w
```

### Step 5: Watch wire Job logs
```bash
# In another terminal, follow wire engine logs
kubectl logs -n cicd -f job/cf-wire

# Expected output:
# [engine] INFO clusterfactory wire engine v0.3.0
# [engine] INFO loading platform spec from /config/platform.yaml
# [engine] INFO resolving components...
# [engine] INFO resolved gitea (gitea)
# [engine] INFO resolved jenkins (jenkins)
# [engine] INFO waiting for components to be ready...
# [gitea] INFO ready at http://cf-gitea-http:3000
# [jenkins] INFO ready at http://cf-jenkins:8080
# [engine] INFO building wiring graph...
# [engine] INFO wiring graph: 1 edges
# [engine] INFO executing wiring...
# [engine] INFO wiring | gitea → jenkins | UserPass
# [gitea] INFO minting API token: jenkins-wiring
# [gitea] INFO token minted: jenkins-wiring
# [gitea] INFO creating org: cf-demo
# [gitea] INFO org ready: cf-demo
# [gitea] INFO creating repo: cf-demo/hello-world
# [gitea] INFO repo ready: cf-demo/hello-world
# [gitea] INFO pushing file: Jenkinsfile
# [gitea] INFO file pushed: Jenkinsfile
# [jenkins] INFO injecting userpass: gitea-userpass
# [jenkins] INFO credential created: gitea-userpass
# [jenkins] INFO creating pipeline job: demo-pipeline
# [jenkins] INFO pipeline job created: demo-pipeline
# [engine] INFO wired  | sha=abc123...
# [engine] INFO executed 1 wires
# [engine] INFO verifying wires...
# [engine] INFO all wires verified
# [engine] INFO structural_sha: def456789abcdef...
# [engine] INFO writing result ConfigMap...
# [engine] INFO created cf-wire-result ConfigMap
# [engine] INFO wire engine complete
```

### Step 6: Verify results

#### Check structural SHA
```bash
kubectl get cm -n cicd cf-wire-result -o yaml

# Should show:
# data:
#   structural_sha: <64-char hex string>
```

#### Check Gitea
```bash
# Port forward
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000 &

# Browse to http://localhost:3000
# Login: gitea-admin / demo123
# Navigate to: Organizations → cf-demo → hello-world
# Verify: Jenkinsfile exists in repo
```

#### Check Jenkins
```bash
# Port forward
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080 &

# Browse to http://localhost:8080
# Login: admin / admin (from values/jenkins.yaml)
# Navigate to: Credentials → System → Global credentials
# Verify: gitea-userpass credential exists
# Navigate to: Dashboard → demo-pipeline job
# Verify: Job is configured with Gitea repo
```

#### Trigger pipeline build
```bash
# In Jenkins UI:
# 1. Click "demo-pipeline"
# 2. Click "Build Now"
# 3. Watch build logs
# 4. Should clone from Gitea successfully
# 5. Should execute Jenkinsfile (simple "Hello World" script)
```

### Step 7: Check wiring topology
```bash
# The structural SHA is deterministic - same platform.yaml = same SHA
# Even if we redeploy with different passwords, the topology SHA is identical

# Redeploy with different password
export GITEA_ADMIN_PASSWORD=newpass456
make deploy

# The structural SHA should be IDENTICAL because:
# - Same components (gitea, jenkins)
# - Same wiring (gitea → jenkins with UserPass)
# - Only the secret VALUES differ, not the TOPOLOGY
```

## Troubleshooting

### Wire Job fails
```bash
# Check Job status
kubectl get job -n cicd cf-wire
kubectl describe job -n cicd cf-wire

# Check logs
kubectl logs -n cicd job/cf-wire

# Common issues:
# - Gitea not ready: Wait longer, check gitea pod logs
# - Jenkins not ready: Check jenkins pod, may need more memory
# - Network policy: Check if wire can reach gitea/jenkins
# - Secrets: Verify gitea-admin secret exists
```

### Gitea pod not starting
```bash
kubectl get pod -n cicd -l app.kubernetes.io/name=gitea
kubectl describe pod -n cicd -l app.kubernetes.io/name=gitea
kubectl logs -n cicd -l app.kubernetes.io/name=gitea

# Common issues:
# - PVC not bound: Check storage class
# - Image pull: Verify k3d has gitea image
# - Init container: Check gitea-init logs
```

### Jenkins pod not starting
```bash
kubectl get pod -n cicd -l app.kubernetes.io/name=jenkins
kubectl describe pod -n cicd -l app.kubernetes.io/name=jenkins
kubectl logs -n cicd -l app.kubernetes.io/name=jenkins

# Common issues:
# - Memory: Jenkins needs ~1GB, check node resources
# - Plugins: Check init container logs for plugin installs
# - PVC: Check if jenkins-home is bound
```

## Cleanup

### Delete cluster
```bash
k3d cluster delete cf-test
```

### Clean build artifacts
```bash
make clean
```

## Success Criteria

Day 3 is successful when:
- ✅ Wire Job completes successfully
- ✅ Structural SHA is written to ConfigMap
- ✅ Gitea has cf-demo/hello-world repo with Jenkinsfile
- ✅ Jenkins has gitea-userpass credential
- ✅ Jenkins has demo-pipeline job configured
- ✅ Triggering Jenkins build clones from Gitea successfully
- ✅ Redeploying with different password produces SAME structural SHA

## Next Steps (Day 4)

Once Day 3 passes:
- Day 4: Airgap testing (offline registry)
- Day 5: Documentation + v0.3.0 release
