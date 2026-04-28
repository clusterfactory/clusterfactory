# Wire Job Debug Findings

## Root Causes Identified

### 1. ✅ Network Policy Label Issue (RESOLVED in debug)
**Problem**: Wire pod couldn't connect to Gitea/Jenkins  
**Cause**: Pod label `app.kubernetes.io/name: wire` required by NetworkPolicy  
**Status**: Label is correctly defined in wire-job.yaml line 29  
**Note**: This works in the real job, was only an issue in manual debug pod

### 2. ✅ Gitea Password Mismatch (RESOLVED)
**Problem**: 401 Unauthorized from Gitea API  
**Cause**: Shell interpretation of `!` character  
- Deployed with: `GITEA_ADMIN_PASSWORD="ZarfRocks!"`  
- Secret contains: `ZarfRocks` (no !)  
**Fix**: Need to escape or quote properly during deployment

### 3. ❌ Jenkins Credentials Plugin Missing (BLOCKING)
**Problem**: 404 error creating Jenkins credential  
**Cause**: Removed all plugins including `credentials` and `plain-credentials`  
**Impact**: Wire engine cannot inject Git credentials into Jenkins  

## Wire Engine Execution Results

### Successful Steps ✅
1. Components resolved: gitea, jenkins
2. Ready checks passed for both services  
3. Wiring graph built (1 edge: gitea → jenkins)
4. Gitea operations:
   - API token minted: `jenkins-wiring`
   - Org created: `cf-demo`
   - Repo created: `cf-demo/hello-world`
   - File pushed: `Jenkinsfile`

### Failed Step ❌
- Jenkins credential injection: 404 (credentials plugin endpoint doesn't exist)

## Required Fixes

### Fix 1: Jenkins Plugins (CRITICAL)
**Options:**

A. **Use pre-built Jenkins image with plugins** (RECOMMENDED)
   - Build custom image FROM jenkins/jenkins:2.541.3-jdk21
   - Install required plugins in Dockerfile
   - Update zarf.yaml to use custom image

B. **Re-enable minimal plugin list**  
   - Use only: `credentials`, `plain-credentials`, `git`
   - These have no external deps in modern versions
   - May still fail in airgap

C. **Skip wire engine for v0.3 demo**
   - Document manual credential setup
   - Focus on Gitea + Jenkins running

### Fix 2: Password Handling
Update deployment to properly escape special chars:
```bash
export GITEA_ADMIN_PASSWORD='ZarfRocks!'  # single quotes
# or
export GITEA_ADMIN_PASSWORD="ZarfRocks\!" # escape
```

## Recommended Path Forward

1. **Short-term (for v0.3 demo)**:
   - Document that wire engine needs Jenkins credentials plugin
   - Show Gitea working, Jenkins working
   - Manual credential setup documented

2. **Medium-term (v0.4)**:
   - Build custom Jenkins image with essential plugins baked in
   - Package the custom image in Zarf
   - Wire engine will then work end-to-end

## Current Working State

```
Gitea: ✅ Running, API working, repos created
Jenkins: ✅ Running, UI accessible, API working
Wire: ⚠️  Gitea operations complete, Jenkins blocked by missing plugin
```

## Test Commands

```bash
# Port-forward to Jenkins
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080

# Port-forward to Gitea  
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000

# View Gitea repo
open http://localhost:3000/cf-demo/hello-world

# Jenkins admin password
kubectl get secret cf-jenkins -n cicd -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

