# Test: Runner Isolation Between Jobs

This directory contains Gitea Actions workflows that verify the runner provides proper isolation between jobs.

## Test Scenarios

### 1. File Isolation Test (`test-file-isolation.yaml`)
- **Job A** creates files in `/tmp`, `/workspace`, and subdirectories
- **Job B** runs immediately after and verifies it CANNOT see Job A's files
- **Proves**: No filesystem state bleed

### 2. Environment Variable Test (`test-env-isolation.yaml`)
- **Job A** sets custom environment variables (including secrets)
- **Job B** runs immediately after and verifies clean environment
- **Proves**: No environment state bleed

### 3. Process Isolation Test (`test-process-isolation.yaml`)
- **Job A** starts long-running background processes and servers
- **Job B** runs immediately after and verifies clean process table
- **Proves**: No process leakage

### 4. Concurrent Job Test (`test-concurrent-isolation.yaml`)
- **3 jobs** run in parallel, each writing to same file paths
- Each job verifies it only sees its own data (not others')
- **Proves**: Concurrent jobs are fully isolated

### 5. Cleanup Test (`test-cleanup.yaml`)
- Verifies job pods are automatically deleted after TTL
- Provides manual verification steps
- **Proves**: No pod accumulation, automatic cleanup

### 6. Test Suite (`test-suite.yaml`)
- Runs all isolation tests in a single workflow
- Comprehensive validation
- **Quick smoke test** of runner architecture

---

## How to Use

### Option 1: Copy to Your Test Repo

1. Create a test repository in Gitea (e.g., `runner-tests`)
2. Copy these workflows to `.gitea/workflows/` in that repo
3. Push to trigger the workflows
4. Check results in **Gitea → Repository → Actions** tab

```bash
# Clone your test repo
git clone http://localhost:3000/youruser/runner-tests.git
cd runner-tests

# Copy test workflows
cp -r /path/to/clusterfactory/tests/workflows/.gitea .

# Commit and push
git add .gitea/
git commit -m "Add runner isolation tests"
git push
```

### Option 2: Manual Trigger

1. Go to your Gitea repository
2. Click **Actions** tab
3. Click **Run workflow** button
4. Select a test workflow
5. Click **Run**

### Option 3: Automated Testing

Add to your CI/CD pipeline to automatically test runner isolation:

```yaml
# .gitea/workflows/ci.yaml
name: CI
on: [push, pull_request]

jobs:
  test-runner-isolation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run isolation tests
        run: |
          # Trigger test workflows
          # Check results
          # Fail if any test fails
```

---

## Expected Results

### ✅ With New Architecture (Scheduler + Ephemeral Pods)

All tests should **PASS**:

```
✅ test-file-isolation.yaml         PASSED
✅ test-env-isolation.yaml          PASSED
✅ test-process-isolation.yaml      PASSED
✅ test-concurrent-isolation.yaml   PASSED
✅ test-cleanup.yaml                PASSED (manual verification)
✅ test-suite.yaml                  PASSED
```

**Why**: Each job runs in a fresh, isolated pod with:
- Clean `emptyDir` workspace
- Fresh environment
- Isolated process namespace
- Automatic cleanup after completion

### ❌ With Old Architecture (DaemonSet)

These tests would **FAIL**:

```
❌ test-file-isolation.yaml         FAILED (Job B sees Job A files)
❌ test-env-isolation.yaml          FAILED (Environment vars leak)
❌ test-process-isolation.yaml      FAILED (Processes persist)
❌ test-concurrent-isolation.yaml   FAILED (Race conditions, overwrites)
❌ test-cleanup.yaml                FAILED (Pods never deleted)
```

**Why**: All jobs ran in the same persistent pod, sharing:
- Same filesystem
- Same environment
- Same process namespace
- No automatic cleanup

---

## Interpreting Results

### Success Indicators

✅ **File Isolation**: Job B cannot find Job A's files  
✅ **Env Isolation**: Job B has clean environment  
✅ **Process Isolation**: Job B sees minimal process count  
✅ **Concurrent Isolation**: Each parallel job sees only its own data  
✅ **Cleanup**: Pods disappear after 5-10 minutes  

### Failure Indicators

❌ **File found from previous job** → State bleed  
❌ **Environment variable leaked** → Env contamination  
❌ **Background process from previous job** → Process leak  
❌ **Marker file corrupted by concurrent job** → No isolation  
❌ **Pods accumulate forever** → No auto-cleanup  

---

## Troubleshooting

### Tests fail unexpectedly

```bash
# Check if scheduler is running
kubectl get deployment -n cicd cf-runner-scheduler

# Check scheduler logs
kubectl logs -n cicd -l app.kubernetes.io/name=gitea-runner-scheduler

# Check if job pods are created
kubectl get pods -n cicd -l app.kubernetes.io/component=runner-job

# Check specific job pod logs
kubectl logs -n cicd runner-job-<id>
```

### Pods not being cleaned up

```bash
# Check TTL configuration
kubectl get jobs -n cicd -l app.kubernetes.io/component=runner-job -o yaml | grep ttlSecondsAfterFinished

# Should show: ttlSecondsAfterFinished: 300

# Check TTL controller is enabled in cluster
kubectl get pods -n kube-system | grep ttl
```

### Concurrent tests fail randomly

This indicates race conditions or insufficient isolation:

```bash
# Check how many pods can run concurrently
kubectl get deployment -n cicd cf-runner-scheduler -o yaml | grep capacity

# Increase if needed (values.yaml):
runner:
  capacity: 20  # Increase from default 10
```

---

## Integration with CI

Add these tests to your ClusterFactory test suite:

```yaml
# In clusterfactory CI pipeline
test-runner-isolation:
  runs-on: ubuntu-latest
  steps:
    - name: Deploy ClusterFactory
      run: helm install cf . -n cicd --create-namespace
      
    - name: Create test repo
      run: |
        # Create repo via Gitea API
        # Push test workflows
        
    - name: Run isolation tests
      run: |
        # Trigger workflows
        # Wait for completion
        # Check results
        
    - name: Verify all passed
      run: |
        # Assert all tests passed
        # Fail CI if any test failed
```

---

## Files

- `README.md` - This file
- `test-file-isolation.yaml` - Filesystem isolation test
- `test-env-isolation.yaml` - Environment isolation test
- `test-process-isolation.yaml` - Process isolation test
- `test-concurrent-isolation.yaml` - Concurrent job isolation test
- `test-cleanup.yaml` - Pod cleanup verification
- `test-suite.yaml` - All tests in one workflow

---

## Why These Tests Matter

These tests prove that the runner refactor **actually works** and provides:

1. **Correctness**: Jobs don't interfere with each other
2. **Security**: No data leakage between jobs
3. **Reliability**: Predictable, isolated execution
4. **Performance**: Automatic cleanup prevents resource exhaustion

Without these tests passing, the runner would be **unsafe for production use**.

With these tests passing, you can confidently run **untrusted workflows** knowing they can't affect each other.

---

## Contributing

To add more isolation tests:

1. Create a new workflow file: `test-your-scenario.yaml`
2. Follow the pattern: Job A does something, Job B verifies isolation
3. Make sure it fails with the old architecture
4. Add it to `test-suite.yaml`
5. Document it in this README
