# Integration Testing Guide

This guide walks through setting up a test cluster and running integration tests for the Python factory engine.

## Prerequisites

- Kubernetes cluster (k3d, kind, or cloud cluster)
- `helm` CLI installed
- `kubectl` configured
- Docker running (for building wire image)

## Quick Start

```bash
# 1. Build Docker image
docker build -f Dockerfile.wire -t clusterfactory-wire:0.2.0 .

# 2. Create test cluster (k3d example)
k3d cluster create clusterfactory-test \
  --agents 2 \
  --registry-create test-registry:5000

# 3. Load image into cluster
k3d image import clusterfactory-wire:0.2.0 -c clusterfactory-test

# 4. Deploy with Python engine
helm install test . \
  --set wire.engine=python \
  --set wire.image.python=clusterfactory-wire:0.2.0 \
  --wait --timeout=10m

# 5. Run integration tests
export TEST_NAMESPACE=default
export GITEA_SERVICE=test-gitea-http
export JENKINS_SERVICE=test-jenkins
python3 -m pytest factory/testing/layers/integration/ -v
```

## Step-by-Step Setup

### 1. Build Wire Image

```bash
# From repo root
docker build -f Dockerfile.wire -t clusterfactory-wire:0.2.0 .

# Verify image
docker images | grep clusterfactory-wire
```

### 2. Create Test Cluster

#### Option A: k3d (Local)

```bash
# Create cluster with registry
k3d cluster create clusterfactory-test \
  --agents 2 \
  --registry-create test-registry:5000 \
  --k3s-arg="--disable=traefik@server:0"

# Import image
k3d image import clusterfactory-wire:0.2.0 -c clusterfactory-test
```

#### Option B: kind (Local)

```bash
# Create cluster
kind create cluster --name clusterfactory-test

# Load image
kind load docker-image clusterfactory-wire:0.2.0 --name clusterfactory-test
```

#### Option C: Cloud Cluster

```bash
# Push to your registry
docker tag clusterfactory-wire:0.2.0 your-registry/clusterfactory-wire:0.2.0
docker push your-registry/clusterfactory-wire:0.2.0

# Use in values.yaml
helm install test . --set wire.image.python=your-registry/clusterfactory-wire:0.2.0
```

### 3. Deploy ClusterFactory

#### Bash Engine (Baseline)

```bash
# Deploy with bash engine (default)
helm install test-bash . --wait --timeout=10m

# Check wire job
kubectl logs -l app.kubernetes.io/name=wire

# Verify Gitea
kubectl port-forward svc/test-bash-gitea-http 3000:3000

# Verify Jenkins
kubectl port-forward svc/test-bash-jenkins 8080:8080
```

#### Python Engine (Test)

```bash
# Deploy with Python engine
helm install test-python . \
  --set wire.engine=python \
  --set wire.image.python=clusterfactory-wire:0.2.0 \
  --wait --timeout=10m

# Check wire job logs
kubectl logs -l app.kubernetes.io/name=wire,wire.clusterfactory.io/engine=python

# Check platform ConfigMap
kubectl get configmap test-python-platform -o yaml
```

### 4. Run Integration Tests

```bash
# Set environment variables
export TEST_NAMESPACE=default
export GITEA_SERVICE=test-python-gitea-http
export JENKINS_SERVICE=test-python-jenkins
export GITEA_USER=gitea
export GITEA_PASS=$(kubectl get secret test-python-gitea-admin-secret -o jsonpath='{.data.password}' | base64 -d)
export JENKINS_PASS=$(kubectl get secret test-python-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

# Run integration tests
python3 -m pytest factory/testing/layers/integration/ -v

# Or use test runner
./run-tests.py integration -v
```

## Test Scenarios

### Basic Wiring

```bash
# Test full wire execution
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_full_gitea_jenkins_wire -v
```

### Health Checks

```bash
# Test component readiness
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_gitea_component_health_check -v
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_jenkins_component_health_check -v
```

### Idempotency

```bash
# Test running wire twice produces same SHA
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_wire_is_idempotent -v
```

### Component Operations

```bash
# Test Gitea operations
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_gitea_creates_org -v
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_gitea_creates_repo -v

# Test Jenkins operations
pytest factory/testing/layers/integration/test_gitea_jenkins.py::test_jenkins_creates_pipeline -v
```

## Comparing Bash vs Python

Deploy both engines side-by-side:

```bash
# Deploy bash engine
helm install test-bash . \
  --set wire.engine=bash \
  --wait --timeout=10m

# Deploy Python engine in different namespace
kubectl create namespace python-test
helm install test-python . \
  --namespace python-test \
  --set wire.engine=python \
  --set wire.image.python=clusterfactory-wire:0.2.0 \
  --wait --timeout=10m

# Compare logs
kubectl logs -l app.kubernetes.io/name=wire,wire.clusterfactory.io/engine=bash
kubectl logs -n python-test -l app.kubernetes.io/name=wire,wire.clusterfactory.io/engine=python

# Compare structural SHAs (future: both should match)
# Bash doesn't produce structural SHA yet
# Python should output: "factory complete | structural_sha=<hash>"
```

## Troubleshooting

### Wire Job Failed

```bash
# Check job status
kubectl get jobs -l app.kubernetes.io/name=wire

# View logs
kubectl logs -l app.kubernetes.io/name=wire --tail=100

# Describe job
kubectl describe job -l app.kubernetes.io/name=wire
```

### Gitea Not Ready

```bash
# Check Gitea pod
kubectl get pods -l app.kubernetes.io/name=gitea

# View logs
kubectl logs -l app.kubernetes.io/name=gitea --tail=50

# Port forward and test
kubectl port-forward svc/test-gitea-http 3000:3000
curl http://localhost:3000
```

### Jenkins Not Ready

```bash
# Check Jenkins pod
kubectl get pods -l app.kubernetes.io/name=jenkins

# View logs
kubectl logs -l app.kubernetes.io/name=jenkins --tail=50

# Port forward and test
kubectl port-forward svc/test-jenkins 8080:8080
curl http://localhost:8080/login
```

### Python Engine Issues

```bash
# Check platform ConfigMap
kubectl get configmap test-platform -o yaml

# Check wire container logs
kubectl logs -l app.kubernetes.io/name=wire -c wire

# Check environment variables
kubectl get pods -l app.kubernetes.io/name=wire -o yaml | grep -A20 "env:"

# Exec into wire pod (if still running)
kubectl exec -it $(kubectl get pods -l app.kubernetes.io/name=wire -o name) -- /bin/sh
python3 -m factory --platform /config/platform.yaml --log-level DEBUG
```

## Cleanup

```bash
# Delete releases
helm uninstall test-bash
helm uninstall test-python -n python-test

# Delete cluster (k3d)
k3d cluster delete clusterfactory-test

# Delete cluster (kind)
kind delete cluster --name clusterfactory-test
```

## CI Integration

Add to your CI pipeline:

```yaml
# .github/workflows/integration-tests.yml
name: Integration Tests

on: [push, pull_request]

jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up k3d
        run: |
          curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
          k3d cluster create test --agents 2
      
      - name: Build wire image
        run: docker build -f Dockerfile.wire -t clusterfactory-wire:test .
      
      - name: Load image
        run: k3d image import clusterfactory-wire:test
      
      - name: Deploy with Python engine
        run: |
          helm install test . \
            --set wire.engine=python \
            --set wire.image.python=clusterfactory-wire:test \
            --wait --timeout=10m
      
      - name: Run integration tests
        run: |
          export TEST_NAMESPACE=default
          python3 -m pytest factory/testing/layers/integration/ -v
```

## Next Steps

1. Run unit tests first: `./run-tests.py unit`
2. Deploy to test cluster
3. Run integration tests: `./run-tests.py integration`
4. Compare bash vs python results
5. Report findings in PR
