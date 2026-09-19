# Successful Local K3D Deployment - clusterfactory v0.3

## Status: ✅ Gitea and Jenkins Running

**Date:** 2026-04-25
**Cluster:** k3d cf-local
**Zarf Version:** v0.75.0

## Deployed Components

### ✅ Working
- **Zarf Init**: Registry and Gitea working
- **Gitea 1.23.6**: Running (1/1 pods)
- **Jenkins 2.541.3**: Running (StatefulSet 1/1)
- **Network Policies**: Applied
- **Secrets**: Created

### ❌ Failed
- **Wire Job**: CrashLoopBackOff then exceeded backoff limit
  - Job timed out after multiple restart attempts
  - Need to investigate wire engine logs from failed pod

## Fixes Applied

### 1. Gitea Image Mismatch
**Problem:** Chart expects `docker.gitea.com/gitea:1.23.6-rootless` but zarf.yaml had `gitea/gitea:1.23.6`
**Fix:** Updated zarf.yaml line 55

### 2. Jenkins Sidecar Version Mismatch  
**Problem:** Chart expects `kiwigrid/k8s-sidecar:2.5.0` but zarf.yaml had `1.27.1`
**Fix:** Updated zarf.yaml line 73

### 3. Jenkins Admin Config Deprecated
**Problem:** `controller.adminUser` renamed to `controller.admin.username`
**Fix:** Updated values/jenkins.yaml

### 4. Jenkins Plugins in Airgap
**Problem:** Plugins can't download dependencies in airgap environment
**Fix:** Removed installPlugins list (use image with pre-installed plugins)

### 5. Makefile Package Name
**Problem:** Wrong package filename in deploy target
**Fix:** Updated to `zarf-package-clusterfactory-ci-amd64-0.3.0.tar.zst`

## Current Resources

```
NAME                            READY   STATUS    RESTARTS   AGE
pod/cf-gitea-5b86676897-xqkwb   1/1     Running   0          3m35s
pod/cf-jenkins-0                2/2     Running   0          3m2s

NAME                       TYPE        CLUSTER-IP      PORT(S)     
service/cf-gitea-http      ClusterIP   None            3000/TCP    
service/cf-gitea-ssh       ClusterIP   None            22/TCP      
service/cf-jenkins         ClusterIP   10.43.112.112   8080/TCP    
service/cf-jenkins-agent   ClusterIP   10.43.252.2     50000/TCP   

NAME                          READY   AGE
statefulset.apps/cf-jenkins   1/1     3m2s

NAME                STATUS   COMPLETIONS   
job.batch/cf-wire   Failed   0/1           
```

## Next Steps

1. **Debug Wire Job**: Recreate with logging to see why it's crashing
2. **Test Gitea Access**: Port-forward and verify admin login
3. **Test Jenkins Access**: Port-forward and verify UI loads
4. **Fix Wire Engine**: Investigate the credential wiring issue

## Port-Forward Commands

```bash
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080
```

## Credentials

- **Gitea**: gitea-admin / ZarfRocks!
- **Jenkins**: admin / `kubectl get secret cf-jenkins -n cicd -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`

