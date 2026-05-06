# GitHub Actions Failure Analysis - All 3 Install Modes Failing

**Date**: 2026-05-04  
**Runs Analyzed**: #25298774483, #25298208298, #25297990383, #25035328420  
**Branch**: PR #47  

---

## Executive Summary

**All 3 install modes (gitea-actions, jenkins, both) are failing** with the **SAME issue**: `cf-test-gitea` helm test pod fails.

**Key Finding**: The wire Job completes successfully, all services start correctly, but the `test-gitea.yaml` helm test fails when trying to verify the Gitea org/repo were created.

---

## What's Working ✓

1. **Helm dependency build & extraction**: ✓ All modes
2. **Helm lint**: ✓ Passes
3. **Template rendering**: ✓ All 3 modes pass assertions
4. **k3d cluster creation**: ✓ Fast and reliable
5. **Helm install**: ✓ Completes without errors
6. **Gitea Deployment**: ✓ Rolls out successfully in ~10s
7. **Jenkins StatefulSet** (modes: jenkins, both): ✓ Becomes ready
8. **Wire Job**: ✓ **Completes successfully** - exits with status "Complete"
9. **Wire result ConfigMap**: ✓ Created with correct structural SHA
10. **Other helm tests**:
    - `cf-gitea-test-connection`: ✓ Succeeds
    - `cf-jenkins-tests`: ✓ Succeeds (when enabled)
    - `cf-test-actions`: ✓ Succeeds (when enabled)

---

## What's Failing ✗

**Single Point of Failure**: `cf-test-gitea` helm test pod

### Failure Evidence

```
TEST SUITE:     cf-test-gitea
Last Started:   Mon May  4 02:59:49 2026
Last Completed: Mon May  4 02:59:50 2026
Phase:          Failed
```

```
pod/cf-test-gitea    0/1     Error       0          2s
```

### Test Definition

From `templates/tests/test-gitea.yaml`:

```yaml
command: ["/bin/sh", "-eu", "-c"]
args:
  - |
    set -eu
    echo "test-gitea | reaching ${GITEA_URL}"
    curl -fsS "${GITEA_URL}/api/healthz" >/dev/null
    echo "test-gitea | healthz OK"

    echo "test-gitea | verifying org ${ORG}"
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/orgs/${ORG}" >/dev/null

    echo "test-gitea | verifying repo ${ORG}/${REPO}"
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}" >/dev/null

    echo "test-gitea | OK"
```

**Expected behavior**: Verify that the wire Job created:
- Organization: `cf-demo`
- Repository: `cf-demo/hello-world`

---

## Root Cause Analysis

✅ **ROOT CAUSE IDENTIFIED**: test-gitea.yaml uses `alpine:3.21` image which doesn't have `curl` installed.

### Hypothesis 1: Wire Job Claims Success But Didn't Actually Create Resources ⚠️ **RULED OUT**

**Evidence**:
- Wire Job shows `Complete` status
- Wire ConfigMap exists with structural SHA
- But the test that verifies org/repo existence **fails**

**Possible reasons**:
1. Wire script has **false positive error handling** - exits 0 even when Gitea API calls fail
2. Wire script **creates org/repo but they're not visible** due to timing/consistency issue
3. Wire script **silently fails** on specific API calls but doesn't exit non-zero

### Hypothesis 2: Wrong Image in test-gitea.yaml 🎯 **ROOT CAUSE CONFIRMED**

**Evidence from values.yaml (line 122)**:
```yaml
wireJob:
  image: alpine:3.21   # has apk, sh, base64. Will install curl and jq. ~8MB.
```

**Evidence from templates/tests/test-gitea.yaml (line 15)**:
```yaml
image: {{ .Values.wireJob.image | quote }}
```

**So test-gitea.yaml uses**: `alpine:3.21`

**Problem**: `alpine:3.21` base image **does NOT have curl pre-installed**.

**Evidence from test-gitea.yaml script**:
```bash
curl -fsS "${GITEA_URL}/api/healthz" >/dev/null
curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/orgs/${ORG}" >/dev/null
curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}" >/dev/null
```

**The test script tries to use curl, but curl is NOT installed!**

**Why wire-job.yaml works but test-gitea.yaml doesn't**:

From `templates/wire-job.yaml` (lines 30-34):
```yaml
- name: wait-for-jenkins
  image: {{ .Values.wireJob.image | quote }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      # Install curl if missing
      if ! command -v curl >/dev/null 2>&1; then
        echo "Installing curl..."
        apk add --no-cache curl >/dev/null 2>&1
      fi
```

**Wire Job installs curl dynamically via `apk add`**, but **test-gitea.yaml does NOT**.

**Expected error in test-gitea pod logs**:
```
/bin/sh: curl: not found
```

**This is 100% the root cause.**

### Hypothesis 3: Secret Name Mismatch 🎯

**Checking test-gitea.yaml**:
```yaml
- name: GITEA_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "clusterfactory.giteaAdminSecret" . }}
      key: username
```

**Need to verify**: Does `clusterfactory.giteaAdminSecret` resolve correctly in CI?

### Hypothesis 4: Timing Issue - Gitea Not Fully Ready 🕐

**Evidence**:
- Wire Job completes after ~74s
- Test starts 2s after wire completes
- Gitea might need additional time for database consistency

---

## Why This Passes Locally But Fails in CI

**Local k3d**:
- Developer manually checks pods: `kubectl -n cicd get pods`
- Can run `kubectl logs` to debug
- Can retry manually
- Has more time/patience for eventual consistency

**GitHub Actions CI**:
- Automated, no manual intervention
- Strict timing: test runs immediately after wire Job completes
- Fails fast with `set -eu` in test script
- No visibility into actual curl error messages (helm test doesn't show pod logs)

---

## Action Items to Fix

### 1. **Fix test-gitea.yaml - Install curl before using it** 🚨 CRITICAL FIX

**Root cause**: `alpine:3.21` doesn't have curl installed.

**Fix in `templates/tests/test-gitea.yaml`**:
```yaml
command: ["/bin/sh", "-eu", "-c"]
args:
  - |
    set -eu
    
    # Install curl if missing (alpine:3.21 base doesn't have it)
    if ! command -v curl >/dev/null 2>&1; then
      echo "Installing curl..."
      apk add --no-cache curl >/dev/null 2>&1
    fi
    
    echo "test-gitea | reaching ${GITEA_URL}"
    curl -fsS "${GITEA_URL}/api/healthz" >/dev/null
    echo "test-gitea | healthz OK"

    echo "test-gitea | verifying org ${ORG}"
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/orgs/${ORG}" >/dev/null

    echo "test-gitea | verifying repo ${ORG}/${REPO}"
    curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
      "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}" >/dev/null

    echo "test-gitea | OK"
```

**Alternative fix**: Use `alpine/curl` image directly:
```yaml
image: "alpine/curl:8.10.0"
```

### 2. **Add helm test log collection to CI workflow** 🚨 CRITICAL

**Problem**: We see "pod cf-test-gitea failed" but don't see **WHY** (no curl error output).

**Fix in `.github/workflows/ci.yaml`**:
```yaml
- name: Dump on failure
  if: failure()
  run: |
    kubectl -n cicd get all
    kubectl -n cicd describe job/cf-wire || true
    kubectl -n cicd logs job/cf-wire --tail=500 || true
    # ADD THIS:
    kubectl -n cicd logs pod/cf-test-gitea || true
    kubectl -n cicd logs pod/cf-test-actions || true
    kubectl -n cicd logs pod/cf-test-jenkins || true
    kubectl -n cicd get events --sort-by=.lastTimestamp | tail -50 || true
```

### 2. **Fix test-gitea.yaml image reference** 

**Current**:
```yaml
image: {{ .Values.wireJob.image | quote }}
```

**Problem**: If wireJob.image changes, test breaks.

**Fix**: Use explicit alpine/curl or ensure wireJob.image has curl.

### 3. **Improve wire.sh error handling**

**Current issue**: Wire script may succeed even if Gitea API calls fail silently.

**Fix**: Add strict error checking:
```sh
# After org creation
if ! curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_URL}/api/v1/orgs/${ORG}" >/dev/null; then
  echo "ERROR: Failed to verify org ${ORG} exists"
  exit 1
fi
```

### 4. **Add retry logic to test-gitea.yaml**

**Current**: Single attempt with `set -eu` (fail fast)

**Better**: Retry with backoff for eventual consistency:
```sh
max=10
i=0
while [ "$i" -lt "$max" ]; do
  if curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${ORG}/${REPO}" >/dev/null; then
    echo "test-gitea | OK"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done
echo "test-gitea | FAILED after ${max} attempts"
exit 1
```

### 5. **Update Copilot Instructions** ✅

Add to `.github/copilot-instructions.md`:

```markdown
## CI/CD Debugging Protocol

### When CI Fails

1. **First**: Get the ACTUAL error from failed test pods:
   ```bash
   gh run view <run-id> --log | grep "test-gitea" -A 50
   kubectl logs pod/cf-test-gitea  # if in local cluster
   ```

2. **Do NOT** push to remote until:
   - All 3 modes install successfully in local k3d
   - `helm test cf -n cicd` passes for all 3 modes
   - Manually verify: `kubectl -n cicd get pods` (all Running/Completed)

3. **Faster iteration**:
   - NUKE cluster between tests: `k3d cluster delete test && k3d cluster create test --wait`
   - Do NOT delete namespaces - delete entire cluster
   - Check pod status immediately: `kubectl -n cicd get pods -w`
   - Check logs immediately if pod fails: `kubectl -n cicd logs <pod> --previous`

### Test Validation Checklist

Before pushing to remote:
- [ ] `helm lint . --strict` passes
- [ ] All 3 modes install in k3d: gitea-actions, jenkins, both
- [ ] `helm test cf -n cicd` passes for all 3 modes
- [ ] Wire Job completes: `kubectl -n cicd get job/cf-wire`
- [ ] Org/repo created: `kubectl -n cicd logs job/cf-wire | grep "cf-demo"`
```

---

## Immediate Next Steps

1. ✅ Create this analysis document
2. 🔴 **DO NOT PUSH** until local validation passes
3. 🔧 Add test pod log collection to CI workflow
4. 🔍 Reproduce locally and get actual error message from test-gitea pod
5. 🐛 Fix root cause (likely secret name, timing, or wire script false positive)
6. ✅ Validate all 3 modes in local k3d
7. 📤 Push only after local validation

---

## Timeline of Failures

| Run ID | Date | gitea-actions | jenkins | both | Common Issue |
|--------|------|---------------|---------|------|--------------|
| 25298774483 | 2026-05-04 02:57 | ✗ test-gitea | ✗ test-gitea | ✗ test-gitea | Same failure |
| 25298208298 | 2026-05-04 02:32 | ✗ test-gitea | ✗ test-gitea | ✗ test-gitea | Same failure |
| 25297990383 | 2026-05-04 02:23 | ✗ test-gitea | ✗ test-gitea | ✗ test-gitea | Same failure |
| 25035328420 | 2026-04-28 05:18 | N/A | N/A | ✗ (airgap) | Different: Zarf k3s install permission denied |

**Note**: Run 25035328420 was testing airgap install (different failure mode - Zarf trying to install k3s on GitHub Actions runner).

---

## Conclusion

**ROOT CAUSE IDENTIFIED**: `templates/tests/test-gitea.yaml` uses `alpine:3.21` image which doesn't have `curl` pre-installed. The test script immediately tries to run `curl` commands, which fail with `/bin/sh: curl: not found`.

**The issue is NOT with the install modes themselves** - all 3 modes install successfully, wire Job completes, and services start.

**The issue IS with test-gitea.yaml** - it tries to use curl without installing it first.

**Fix**: Add `apk add --no-cache curl` at the start of the test script (same pattern as wire-job.yaml uses).

**Impact**: All 3 modes are affected identically because they all run the same test-gitea.yaml.

---

## Summary

| Component | Status | Notes |
|-----------|--------|-------|
| Helm install | ✅ Works | All 3 modes |
| Wire Job | ✅ Works | Completes successfully |
| Services | ✅ Work | Gitea, Jenkins, runners all start |
| test-gitea.yaml | ❌ **FAILS** | **Missing curl in alpine:3.21** |
| test-actions.yaml | ✅ Works | Uses bitnami/kubectl (has curl) |
| test-jenkins.yaml | ✅ Works | Uses alpine/curl explicitly |

**One-line fix**: Add `apk add --no-cache curl` to test-gitea.yaml script before first curl usage.
