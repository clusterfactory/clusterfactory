# Copilot Instructions for ClusterFactory Development

## Critical Debugging Workflow

### Fast Iteration Loop (< 30 seconds)

**USE THIS for quick checks - DON'T wait 5+ minutes for installs:**

```bash
# Quick status check (instant)
./quick-check.sh

# If something looks broken, check immediately
kubectl -n cicd get pods              # See what's running NOW
kubectl -n cicd describe pod <name>   # Why is it failing?
kubectl -n cicd logs <pod-name>       # What's the error?

# Fix and re-test without waiting
helm uninstall cf -n cicd
helm install cf . -n cicd --create-namespace [your-flags]
./quick-check.sh                      # Check status instantly
```

**Key principle: Check pods immediately, don't wait for timeouts!**

### After Running Helm Install

**Check status IMMEDIATELY** (don't wait 5 minutes):

```bash
# Instant status (shows what's actually deployed)
./quick-check.sh

# Or manual check
kubectl -n cicd get pods,job,statefulsets,deployments
```

If there are issues:
1. **Check pod status first**: `kubectl -n cicd get pods` - is it Running/Pending/CrashLoopBackOff?
2. **Check logs immediately**: `kubectl -n cicd logs <pod-name>`
3. **Check events**: `kubectl -n cicd get events --sort-by='.lastTimestamp'`
4. **Describe failing resources**: `kubectl -n cicd describe pod <pod-name>`

### When Encountering Unclear Errors

**FIRST OPTION: Nuke and recreate k3d cluster** (30 seconds total)

```bash
k3d cluster delete test
k3d cluster create test --wait
# Now re-test - clean state, no stale resources
```

**SECOND OPTION: Quick namespace cleanup** (5 seconds)

```bash
helm uninstall cf -n cicd
kubectl delete ns cicd
# Faster than cluster recreation, good for most issues
```

This provides a clean state and speeds up debugging significantly. Don't waste time debugging stale state or waiting for long timeouts.

### CI/CD Workflow Monitoring

**After every push, monitor GitHub Actions automatically:**

1. Check workflow status: Visit https://github.com/clusterfactory/clusterfactory/actions
2. If any job fails:
   - Click into the failed job
   - Read the error output carefully
   - Copy the FULL error message (not just the summary)
   - Fix the issue locally using the debugging workflow above
   - Test the fix locally with `k3d cluster delete && create`
   - Only push when local tests pass
3. **Act immediately on failures** - don't wait for user to report them

## Chart Development Guidelines

### Testing Locally

1. **Always test with extracted charts** (Helm v3.16+ requirement):
   ```bash
   helm dependency build .
   cd charts && tar -xzf gitea-*.tgz && tar -xzf jenkins-*.tgz && cd ..
   ```

2. **Test all three modes**:
   - `mode=gitea-actions --set jenkins.enabled=false --set gitea.gitea.config.actions.ENABLED=true`
   - `mode=jenkins --set jenkins.enabled=true --set gitea.gitea.config.actions.ENABLED=false`
   - `mode=both --set jenkins.enabled=true --set gitea.gitea.config.actions.ENABLED=true`

3. **Minimum password length**: 8 characters (enforced by values.schema.json)

### Common Issues

#### Wire Job Failures

The wire Job is the post-install hook that configures Gitea + Jenkins/Actions. Common failures:

1. **RBAC issues**: Check `templates/wire-rbac.yaml` - K8s requires separate rules for `create` (without resourceNames) vs `get/update` (with resourceNames)

2. **Gitea Actions not enabled**: Must pass `--set gitea.gitea.config.actions.ENABLED=true` for gitea-actions/both modes

3. **API endpoint failures**: 
   - Gitea runner tokens: Use repo-level endpoint `/api/v1/repos/{org}/{repo}/actions/runners/registration-token`
   - Admin endpoints may return 403 even for admin users depending on Gitea version

4. **Check wire logs**: `kubectl -n cicd logs -l app.kubernetes.io/name=wire`

#### Helm Lint Failures

- Helm v3.16+ with `--strict` requires **extracted chart directories** in `charts/`, not just `.tgz` files
- Add after `helm dependency build`: `cd charts && tar -xzf gitea-*.tgz && tar -xzf jenkins-*.tgz && cd ..`

### CI/CD Workflow

The `.github/workflows/ci.yaml` has three jobs:
1. **lint**: shellcheck + helm lint --strict
2. **template**: Render templates for all 3 modes with assertions
3. **install**: Full install + helm test on k3d for all 3 modes

All jobs extract charts after dependency build.

### Git Workflow

**Do NOT push to remote until local tests pass**:
1. Test locally with k3d
2. Verify all three modes work
3. Run `helm lint . --strict` locally
4. Only then commit and push

## Architecture Notes

### Wire Script (`files/wire.sh`)

- POSIX sh (not bash) - runs in alpine/curl container
- Idempotent - safe to re-run
- Branches on `$MODE` env var (gitea-actions | jenkins | both)
- Uses Kubernetes ServiceAccount token for API calls (no kubectl needed)
- Emits structural SHA to `cf-wire-result` ConfigMap

### Mode Helpers (`templates/_mode-helpers.tpl`)

- Derives flags from single `mode` value
- Validates consistency (e.g., jenkins mode requires jenkins.enabled=true)
- Compares strings not bools (avoid type mismatches)

### Subchart Dependencies

- Gitea 11.0.1 from https://dl.gitea.com/charts/
- Jenkins 5.9.9 from https://charts.jenkins.io
- Conditional via `gitea.enabled` / `jenkins.enabled`

## File Organization

```
.
├── Chart.yaml              # Subchart dependencies
├── values.yaml             # Single knob: mode
├── values.schema.json      # Validates mode + password
├── templates/
│   ├── _mode-helpers.tpl   # Mode → derived flags
│   ├── wire-job.yaml       # Post-install hook
│   ├── wire-rbac.yaml      # Wire Job permissions
│   ├── runner-*.yaml       # Gitea Actions runner (mode-gated)
│   └── tests/*.yaml        # Functional helm tests
├── files/
│   ├── wire.sh             # Main wiring logic (449 lines)
│   ├── Jenkinsfile         # Bootstrap pipeline
│   └── .gitea/workflows/   # Bootstrap workflow
└── zarf.yaml               # Airgap packaging
```

## Parked Code

`engine/` directory contains the Python wire engine from v0.3. It's parked (not deleted) but not used. Tests still pass. Don't modify or reference it unless explicitly reverting to Python engine.

## Documentation

- `docs/composing-platforms.md` - The pattern (the actual contribution)
- `docs/airgap.md` - Zarf usage
- `docs/history/` - Old v0.3 drift docs (archived)

---

**Last Updated**: 2026-04-30
**Chart Version**: 0.4.1
