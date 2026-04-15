# ClusterFactory Runner Refactor

## Summary

The Gitea Actions runner has been refactored from a **monolithic DaemonSet** (where jobs run inside the same persistent pod) to a **scheduler + ephemeral job pod** architecture (where each job gets a fresh, isolated pod).

This fixes state bleed, improves isolation, and matches how modern CI systems work (GitHub Actions Runner Controller, GitLab Runner, etc.).

---

## What Changed

### Architecture

**Before (DaemonSet - WRONG):**
```
runner-daemonset (permanent pod, one per node)
├─ job 1 runs here
├─ job 2 runs here  ← same pod, same filesystem!
└─ job 3 runs here  ← sees files from job 1 and 2
```

**After (Scheduler + Ephemeral Pods - CORRECT):**
```
runner-scheduler (Deployment, 1 replica, lightweight)
├─ polls Gitea for jobs
├─ spawns runner-job-abc pod → runs job → deleted
├─ spawns runner-job-def pod → runs job → deleted
└─ spawns runner-job-ghi pod → runs job → deleted

runner-prepull (DaemonSet, image caching)
└─ Keeps act_runner image cached on every node
```

### Files Changed

| File | Action | Purpose |
|------|--------|---------|
| `templates/runner-daemonset.yaml` | ❌ **Deleted** | Replaced by scheduler + prepull |
| `templates/runner-scheduler-deployment.yaml` | ✅ **New** | Lightweight scheduler (polls, spawns) |
| `templates/runner-prepull-ds.yaml` | ✅ **New** | Caches runner image on all nodes |
| `templates/runner-config-cm.yaml` | 📝 **Modified** | Bump capacity to 10, add workdir config |
| `templates/runner-rbac.yaml` | 📝 **Modified** | Add `pods/exec` and `patch` permissions |
| `values.yaml` | 📝 **Modified** | Add `jobTTL` and per-job resource limits |

---

## How It Works

### The Flow

```
1. Developer pushes workflow to Gitea
   ↓
2. Gitea creates job in database
   ↓
3. runner-scheduler pod (permanent) polls Gitea API
   ↓
4. Scheduler sees job: "Run on ubuntu-latest"
   ↓
5. Scheduler talks to Kubernetes API
   ↓
6. Kubernetes creates runner-job-<id> pod (ephemeral)
   ├─ Image: act_runner:0.3.1 (already cached by prepull DS)
   ├─ Workspace: Fresh emptyDir volume
   ├─ Resources: Isolated (cpu/mem limits)
   └─ Lifecycle: Auto-deleted after TTL
   ↓
7. runner-job pod executes workflow steps
   ↓
8. Pod completes → reports results to Gitea
   ↓
9. Pod auto-deleted (ttlSecondsAfterFinished: 300)
   ↓
10. Scheduler picks up next job → repeat
```

### Key Components

**1. runner-scheduler (Deployment)**
- **Purpose**: Polls Gitea, spawns job pods
- **Resources**: Tiny (50m CPU, 64Mi RAM)
- **Lifetime**: Permanent
- **Never**: Runs job steps itself

**2. runner-prepull (DaemonSet)**
- **Purpose**: Pre-pulls `act_runner` image to every node
- **Resources**: Negligible (1m CPU, 4Mi RAM for pause container)
- **Benefit**: Job pods start instantly (no image pull wait)

**3. runner-job-<id> (ephemeral pods)**
- **Purpose**: Runs one workflow, then deleted
- **Resources**: Configurable per-job limits
- **Isolation**: Fresh emptyDir, no state from previous jobs
- **Cleanup**: Automatic via TTL

---

## Benefits

| Problem | Before (DaemonSet) | After (Scheduler + Ephemeral) |
|---------|-------------------|-------------------------------|
| **State bleed** | ❌ Jobs share filesystem | ✅ Each job gets clean pod |
| **Image pull** | ❌ On every pod restart | ✅ Pre-pulled by DaemonSet |
| **Concurrency** | ❌ Threads in same pod | ✅ Real isolated pods |
| **Resource isolation** | ❌ Shared within pod | ✅ Per-job limits |
| **Cleanup** | ❌ Manual | ✅ Automatic (TTL) |
| **Architecture** | ❌ Wrong (runner is workload) | ✅ Correct (runner is scheduler) |

---

## Configuration

### Adjust Concurrency

Edit `values.yaml`:

```yaml
runner:
  capacity: 20  # Max concurrent job pods (default: 10)
```

### Per-Job Resources

Edit `values.yaml`:

```yaml
runner:
  job:
    resources:
      requests:
        cpu: 500m      # Minimum per job
        memory: 512Mi
      limits:
        cpu: 4000m     # Maximum per job
        memory: 2Gi
```

### Job Cleanup TTL

Edit `values.yaml`:

```yaml
runner:
  jobTTL: 600  # Keep completed job pods for 10 minutes (default: 300)
```

---

## Comparison Table

| Aspect | Old (DaemonSet) | New (Scheduler + Ephemeral) |
|--------|----------------|----------------------------|
| Deployment | DaemonSet (one per node) | Deployment (1 scheduler) + DaemonSet (image cache) |
| Job execution | Inside scheduler pod | Fresh pod per job |
| State isolation | ❌ None | ✅ Full (emptyDir per job) |
| Image pull speed | ❌ Slow on cold start | ✅ Instant (pre-pulled) |
| Resource footprint | Heavy (runs jobs) | Light (scheduler) + ephemeral (jobs) |
| Helm-managed | Yes | Yes |
| VM access required | No | No |
| Matches industry patterns | No | Yes (ARC, GitLab Runner) |

---

## Migration Guide

### For Existing Deployments

Helm upgrade automatically handles the migration:

```bash
# 1. Upgrade chart
helm upgrade cf . -n cicd

# What happens:
# - Old DaemonSet deleted
# - New scheduler Deployment created
# - New prepull DaemonSet created
# - RBAC updated
# - ConfigMap updated

# 2. Verify
kubectl get pods -n cicd
# Should see:
# - cf-runner-scheduler-xxx (1 pod)
# - cf-runner-prepull-xxx (1 per node)
# - cf-gitea-xxx
# - cf-jenkins-xxx

# 3. Check scheduler logs
kubectl logs -n cicd -l app.kubernetes.io/name=gitea-runner-scheduler

# 4. Push a workflow to test
# You should see ephemeral runner-job-xxx pods appear and disappear
```

### Rollback (if needed)

```bash
helm rollback cf -n cicd
```

---

## Troubleshooting

### Scheduler shows as "offline" in Gitea

```bash
# Check scheduler pod
kubectl get pods -n cicd -l app.kubernetes.io/name=gitea-runner-scheduler

# Check logs
kubectl logs -n cicd -l app.kubernetes.io/name=gitea-runner-scheduler

# Common causes:
# - Registration token not available yet (wait for wire job)
# - Gitea service not accessible
# - Registration failed (check init container logs)
```

### Jobs stay "Pending"

```bash
# Check if scheduler is running
kubectl get deployment -n cicd cf-runner-scheduler

# Check scheduler logs for errors
kubectl logs -n cicd -l app.kubernetes.io/name=gitea-runner-scheduler -f

# Common causes:
# - Scheduler at capacity (all 10 slots busy)
# - No matching label (workflow needs different runs-on)
# - RBAC issue (scheduler can't create pods)
```

### Job pods fail to start

```bash
# List job pods
kubectl get pods -n cicd -l app.kubernetes.io/component=runner-job

# Check specific job pod
kubectl describe pod runner-job-xxx -n cicd

# Common causes:
# - Image not cached (prepull DaemonSet not running)
# - Resource limits too low
# - Node capacity exhausted
```

### Image pull takes too long

```bash
# Check if prepull DaemonSet is running
kubectl get daemonset -n cicd cf-runner-prepull

# Verify image is cached on nodes
kubectl get pods -n cicd -l app.kubernetes.io/name=gitea-runner-prepull

# If not running on all nodes:
kubectl describe daemonset -n cicd cf-runner-prepull
```

---

## What Stays The Same

- ✅ Wire job flow (token creation, registration)
- ✅ RBAC scoping (namespace-bound)
- ✅ Helm management (no VM-level access needed)
- ✅ Airgap compatibility (add `gcr.io/google_containers/pause:3.1` to bundle)
- ✅ Kaniko for builds (still works)
- ✅ Jenkins integration (unaffected)

---

## Performance Impact

**Scheduler overhead:**
- Tiny: 50m CPU, 64Mi RAM
- Always ready (no cold start)

**Prepull DaemonSet:**
- Per-node cost: 1m CPU, 4Mi RAM
- Benefit: Zero job pod image pull time

**Job pods:**
- Resource isolated
- Start instantly (image pre-pulled)
- Auto-cleanup (no manual intervention)

**Net result:** Faster, more reliable, better isolated.

---

## References

- [Gitea Actions Documentation](https://docs.gitea.com/next/usage/actions/overview)
- [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller)
- [act_runner GitHub](https://gitea.com/gitea/act_runner)
- [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [TTL Controller](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/)

---

## Summary

This refactor moves ClusterFactory from a **flawed monolithic design** to a **correct scheduler-based architecture** that:

- ✅ Eliminates state bleed between jobs
- ✅ Provides real isolation (fresh pod per job)
- ✅ Matches industry best practices
- ✅ Stays 100% Helm-managed in Kubernetes
- ✅ No VM-level access required
- ✅ Automatic cleanup
- ✅ Faster cold starts (pre-pulled images)

The pattern now matches how GitHub Actions, GitLab Runner, and other modern CI systems work: **lightweight scheduler + ephemeral execution units**.
