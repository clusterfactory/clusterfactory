# Kaniko Migration Guide

## What Changed

ClusterFactory has been refactored to use **Kaniko** for container image builds instead of Docker-in-Docker (DinD). This removes the need for privileged containers while maintaining full CI/CD functionality.

### Before (DinD)

```
Gitea Actions → act_runner → Docker daemon (privileged) → docker build
```

### After (Kaniko)

```
Gitea Actions → act_runner → kubectl create job → Kaniko pod → registry
```

## Breaking Changes

### Removed Configuration

The following values have been **removed**:

```yaml
# ❌ REMOVED
runner:
  mode: host | dind
  dindImage: docker:27-dind
```

### New Configuration

```yaml
# ✅ NEW
runner:
  enabled: true
  image: gitea/act_runner:0.3.1
  capacity: 2  # max concurrent workflow runs per runner
```

### Runner Labels

- **Before**: `ubuntu-latest:docker` or `ubuntu-latest:host`
- **After**: `ubuntu-latest:kubernetes`

## Upgrading from 0.1.x to 0.2.0

### 1. Review Your Workflows

If you have workflows that use Docker commands, they need to be updated.

**Before (DinD mode):**
```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build image
        run: |
          docker build -t myimage:latest .
          docker push myimage:latest
```

**After (Kaniko):**
```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        
      - name: Build image
        run: |
          kubectl create job kaniko-build-${{ github.run_number }} \
            --image=gcr.io/kaniko-project/executor:latest \
            --restart=Never \
            -- \
            --context=dir://$(pwd) \
            --dockerfile=Dockerfile \
            --destination=myregistry/myimage:latest
```

### 2. Update Helm Values

Remove deprecated values from your overrides:

```bash
# If you had this in your values.yaml or --set flags:
# runner.mode=dind
# runner.dindImage=docker:27-dind

# Remove them before upgrading
```

### 3. Perform the Upgrade

```bash
helm upgrade --install cf clusterfactory/clusterfactory \
  --namespace cicd \
  --version 0.2.0 \
  --timeout 15m
```

The upgrade will:
- Remove DinD sidecar containers
- Create ServiceAccount and RBAC for the runner
- Re-register runners with `kubernetes` label
- No data loss (Gitea and Jenkins continue running)

### 4. Verify Runner Registration

```bash
# Check runner pods are running
kubectl get pods -n cicd -l app.kubernetes.io/name=gitea-runner

# Check runner registration in Gitea UI
# Navigate to: Admin → Actions → Runners
# You should see runners labeled with "ubuntu-latest:kubernetes"
```

## Security Improvements

| Aspect | Before (DinD) | After (Kaniko) |
|--------|---------------|----------------|
| Privileged containers | ✓ Required for DinD | ✗ None |
| Docker daemon | ✓ Running per node | ✗ Not needed |
| Build isolation | Pod-level | Job-level (ephemeral) |
| Resource limits | Shared with runner | Per-job |
| Pod Security Standards | Baseline required | Restricted compatible |
| Attack surface | Docker socket, daemon | Minimal |

## Common Migration Scenarios

### Scenario 1: Simple Docker Build

**Before:**
```yaml
- run: docker build -t app:latest .
```

**After:**
```yaml
- run: |
    kubectl create job build-${{ github.run_number }} \
      --image=gcr.io/kaniko-project/executor:latest \
      -- \
      --context=dir://$(pwd) \
      --dockerfile=Dockerfile \
      --destination=registry/app:latest
```

### Scenario 2: Multi-platform Builds

DinD with buildx is **not supported** in Kaniko. For multi-platform:

1. Use separate Kaniko jobs per architecture
2. Create a manifest list to combine them
3. Or use a dedicated build service (e.g., GitLab Runner with buildkit)

### Scenario 3: Docker Compose

`docker-compose` is **not supported**. Alternatives:

1. Convert to Kubernetes manifests (`kompose convert`)
2. Use Helm charts for deployment
3. Use Kustomize overlays

### Scenario 4: Running Containers in Workflows

**Before:**
```yaml
- run: docker run --rm alpine:latest echo "test"
```

**After:**
```yaml
- run: kubectl run test-${{ github.run_number }} --rm -i --image=alpine:latest -- echo "test"
```

## Rollback Plan

If you need to rollback to DinD (not recommended):

1. Reinstall previous chart version:
   ```bash
   helm upgrade --install cf clusterfactory/clusterfactory \
     --namespace cicd \
     --version 0.1.8 \
     --set runner.mode=dind
   ```

2. Note: Chart version 0.2.0+ does **not support** DinD mode

## FAQ

### Can I still build Docker images?

**Yes**, using Kaniko. Kaniko produces OCI-compliant images compatible with Docker, containerd, and all container runtimes.

### Do I need kubectl in my workflows?

**Yes**, for Kaniko builds. The runner pods have access to the Kubernetes API with appropriate RBAC.

### What about caching?

Kaniko supports layer caching via `--cache=true --cache-repo=registry/cache`. See [docs/kaniko-builds.md](kaniko-builds.md).

### Can I use Docker Compose?

**No**. Convert to Kubernetes manifests or use Helm/Kustomize.

### What about private registries?

Create a Kubernetes secret with Docker credentials and mount it in Kaniko pods. See [docs/kaniko-builds.md](kaniko-builds.md#with-registry-credentials).

### Performance comparison?

Kaniko is slightly slower for cold builds but comparable with layer caching enabled. Benefit: no shared daemon lock contention.

## Need Help?

- Read the full guide: [docs/kaniko-builds.md](kaniko-builds.md)
- Check examples: [files/.gitea/workflows/ci.yaml](../files/.gitea/workflows/ci.yaml)
- Report issues: [GitHub Issues](https://github.com/clusterfactory/clusterfactory/issues)

---

**Migration Checklist:**

- [ ] Reviewed all workflows for Docker commands
- [ ] Updated workflows to use Kaniko
- [ ] Removed deprecated `runner.mode` from values
- [ ] Tested build workflows in dev/staging
- [ ] Upgraded chart to 0.2.0
- [ ] Verified runner registration in Gitea
- [ ] Confirmed workflows execute successfully
