# ClusterFactory Kaniko Refactoring - Summary

## Overview

Successfully refactored ClusterFactory to use **Kaniko** for container image builds instead of Docker-in-Docker (DinD), eliminating the need for privileged containers while maintaining full CI/CD functionality.

## Architecture Changes

### Before
```
Gitea Actions
      │
      ▼
act_runner (DaemonSet)
      │
      ▼
Docker daemon (privileged sidecar)
      │
      ▼
docker build/push
```

### After
```
Gitea Actions
      │
      ▼
act_runner (DaemonSet)
      │
      ▼
kubectl create job
      │
      ▼
Kaniko pod builds image
      │
      ▼
push → registry
```

## Files Modified

### Core Templates
1. **templates/runner-config-cm.yaml**
   - Changed from `labels: []` to `labels: ["ubuntu-latest:kubernetes"]`
   - Removed mode-dependent network configuration
   - Added configurable capacity parameter
   - Simplified config structure

2. **templates/runner-daemonset.yaml**
   - Removed DinD sidecar container completely
   - Removed privileged security context
   - Added ServiceAccount reference
   - Updated runner labels to "kubernetes"
   - Improved resource limits (100m/128Mi → 1000m/512Mi)
   - Removed Docker socket environment variables
   - Hardened security context (drop ALL capabilities)

3. **templates/runner-rbac.yaml** *(NEW)*
   - Created ServiceAccount for runner
   - Added Role with permissions for pods and jobs
   - Created RoleBinding

### Configuration
4. **values.yaml**
   - Removed `runner.mode` (host/dind options)
   - Removed `runner.dindImage`
   - Added `runner.capacity` parameter (default: 2)
   - Updated comments to reflect Kaniko architecture

### Documentation
5. **README.md**
   - Updated component table to mention Kaniko
   - Replaced "Runner mode" section with "Runner and container builds"
   - Added architecture diagram
   - Listed security benefits
   - Added link to Kaniko documentation

6. **docs/kaniko-builds.md** *(NEW)*
   - Comprehensive guide on using Kaniko with Gitea Actions
   - Architecture explanation
   - Example workflows (basic, with credentials, multi-stage, build args)
   - Kaniko executor options reference
   - Best practices
   - Security considerations
   - Troubleshooting section
   - Migration examples from DinD

7. **docs/kaniko-migration.md** *(NEW)*
   - Breaking changes documentation
   - Step-by-step upgrade guide
   - Security improvements comparison
   - Common migration scenarios
   - Rollback instructions
   - FAQ section
   - Migration checklist

### Example Workflow
8. **files/.gitea/workflows/ci.yaml**
   - Updated comments to reflect Kaniko approach
   - Removed references to DinD/host modes
   - Added Kaniko build example
   - Added reference to documentation

## Security Improvements

| Aspect | Before (DinD) | After (Kaniko) |
|--------|---------------|----------------|
| **Privileged containers** | Required | None |
| **Docker daemon** | Running per node | Not needed |
| **Build isolation** | Pod-level | Job-level (ephemeral) |
| **Resource limits** | Shared with runner | Per-job isolation |
| **Pod Security Standards** | Baseline required | Restricted compatible ✓ |
| **Attack surface** | Docker socket + daemon | Minimal |
| **Capabilities** | ALL (via privileged) | Dropped ALL |

## Breaking Changes

### Removed Values
```yaml
# These values are no longer supported
runner:
  mode: host | dind        # ❌ REMOVED
  dindImage: docker:27-dind # ❌ REMOVED
```

### New Values
```yaml
runner:
  enabled: true
  capacity: 2  # max concurrent workflow runs per runner
```

### Runner Labels
- **Old**: `ubuntu-latest:docker` or `ubuntu-latest:host`
- **New**: `ubuntu-latest:kubernetes`

## Testing Performed

✅ Helm lint passes with no errors
✅ Template rendering successful
✅ No privileged containers in rendered manifests
✅ No Docker/DinD references in templates
✅ ServiceAccount and RBAC correctly configured
✅ ConfigMap with kubernetes labels
✅ DaemonSet with hardened security context

## Validation Commands

```bash
# Lint the chart
helm lint .

# Render templates
helm template test . --namespace test

# Verify no privileged containers
helm template test . --namespace test | grep -i privileged
# Expected: no output

# Verify ServiceAccount
helm template test . --namespace test --show-only templates/runner-rbac.yaml

# Verify runner configuration
helm template test . --namespace test --show-only templates/runner-config-cm.yaml
```

## Upgrade Path

For users upgrading from 0.1.x to 0.2.0:

1. Review workflows for Docker commands → See `docs/kaniko-migration.md`
2. Remove deprecated values from overrides
3. Run `helm upgrade` with new chart version
4. Verify runner registration in Gitea UI
5. Test workflow execution

## Benefits

### For Users
- ✅ No privileged containers required
- ✅ Compatible with strict Pod Security Policies
- ✅ Better resource isolation per build
- ✅ Ephemeral build pods (clean builds)
- ✅ No Docker daemon maintenance

### For Cluster Operators
- ✅ Reduced security risk surface
- ✅ Easier compliance (SOC2, PCI-DSS, etc.)
- ✅ Works on managed Kubernetes (EKS, GKE, AKS) without special permissions
- ✅ Compatible with admission controllers (OPA, Kyverno)
- ✅ No privileged pod security exceptions needed

### For Developers
- ✅ Same Docker/OCI image output
- ✅ Layer caching support
- ✅ Multi-stage builds supported
- ✅ Build args and secrets supported
- ✅ Clear kubectl-based workflow

## Next Steps

### Recommended Follow-ups
1. Update CI/CD pipeline tests to include Kaniko builds
2. Add example workflow with registry authentication
3. Consider adding build cache configuration examples
4. Update airgap bundle to include Kaniko executor image
5. Add metrics/monitoring for build job execution

### Future Enhancements
- Consider adding helper templates for common Kaniko patterns
- Add support for build matrix (multiple architectures)
- Integration with image signing (cosign)
- Build job resource quota management

## References

- [Kaniko Project](https://github.com/GoogleContainerTools/kaniko)
- [Gitea Actions Documentation](https://docs.gitea.com/usage/actions/overview)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

**Refactoring completed successfully** ✅

All tests passing, no privileged containers, Kaniko-ready architecture deployed.
