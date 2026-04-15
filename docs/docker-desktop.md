# ClusterFactory on Docker Desktop

This guide helps you install and run ClusterFactory on **Docker Desktop** for macOS or Windows.

## Prerequisites

1. **Docker Desktop** installed and running
2. **Kubernetes enabled** in Docker Desktop settings
3. **Helm 3.x** installed
4. At least **4GB RAM** allocated to Docker Desktop

## Quick Start

```bash
# Install with Docker Desktop optimized settings
./install-docker-desktop.sh

# Or manually
helm install cf . -f values-docker-desktop.yaml --namespace cicd --create-namespace
```

## What's Different on Docker Desktop?

Docker Desktop's Kubernetes has limitations compared to production clusters:

| Feature | Docker Desktop | Production (k3d/kind) |
|---------|---------------|----------------------|
| Gitea Actions Runner | ❌ Disabled | ✅ Enabled |
| Resource Limits | Lower | Higher |
| Number of Nodes | 1 (single-node) | Multiple |
| Pod Scheduling | Basic | Full K8s features |

### Why is the Runner Disabled?

The Gitea Actions runner requires the `kubernetes` execution schema, which uses Kubernetes pod scheduling features not fully supported by Docker Desktop. The runner works perfectly on:
- k3d
- kind  
- minikube
- Real Kubernetes clusters

**You can still use Jenkins for CI/CD!** The runner is only needed for Gitea Actions workflows.

## Access Services

After installation, port-forward the services:

```bash
# Gitea (Git server + web UI)
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000

# Jenkins (CI/CD)
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080
```

Then open in your browser:
- **Gitea**: http://localhost:3000
- **Jenkins**: http://localhost:8080

## Default Credentials

**Gitea**
- Username: `gitea`
- Password: `r8sA8CPHD9!bt6d`

**Jenkins**
- Username: `admin`
- Password: Get with: 
  ```bash
  kubectl get secret -n cicd cf-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
  ```

## Verify Installation

```bash
# Check all pods are running
kubectl get pods -n cicd

# Expected output:
# NAME                       READY   STATUS      RESTARTS   AGE
# cf-gitea-xxx               1/1     Running     0          2m
# cf-jenkins-0               2/2     Running     0          2m
# cf-wire-xxx                0/1     Completed   0          2m
```

## Testing the Wiring

The wire job automatically:
1. ✅ Creates org `clusterfactory` in Gitea
2. ✅ Creates repo `clusterfactory/hello-world`
3. ✅ Pushes Jenkinsfile to the repo
4. ✅ Creates Jenkins credentials for Gitea access
5. ✅ Creates Jenkins pipeline job

Verify it worked:
```bash
kubectl logs -n cicd -l app.kubernetes.io/name=wire
```

## Troubleshooting

### Pods stuck in Pending
Docker Desktop has limited resources. Try:
```bash
# Check resource usage
kubectl top nodes

# Increase Docker Desktop resources in Settings > Resources
```

### Port-forward fails
Make sure nothing else is using ports 3000 or 8080:
```bash
lsof -i :3000
lsof -i :8080
```

### Installation hangs
Check if Kubernetes is healthy:
```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## Cleanup

```bash
# Uninstall
helm uninstall cf -n cicd

# Delete namespace
kubectl delete namespace cicd
```

## Want to Test the Full Setup?

For testing Gitea Actions (with working runner), use k3d or kind:

```bash
# Install k3d
brew install k3d  # macOS
# or
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Create cluster
k3d cluster create cf-test

# Install with full features
helm install cf . --namespace cicd --create-namespace

# Now the runner will work!
```

## Next Steps

- Visit Gitea at http://localhost:3000
- Visit Jenkins at http://localhost:8080/job/clusterfactory-hello-world
- Trigger a build manually (Gitea Actions won't work without runner)
- Explore the wired credentials in Jenkins

## Support

For issues specific to Docker Desktop, check:
- Docker Desktop documentation
- [Kubernetes in Docker Desktop](https://docs.docker.com/desktop/kubernetes/)

For ClusterFactory issues:
- GitHub Issues: https://github.com/clusterfactory/clusterfactory/issues
