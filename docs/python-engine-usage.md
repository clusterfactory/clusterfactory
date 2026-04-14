# Python Factory Engine Usage

The Python factory engine is an alternative to the bash wire-job script, providing typed, testable, and extensible component wiring.

## Quick Start

### Using Bash Engine (Default)

```yaml
# values.yaml
wire:
  engine: bash  # Default, stable
```

```bash
helm install my-release clusterfactory/clusterfactory
```

### Using Python Engine (Experimental)

```yaml
# values.yaml
wire:
  engine: python
  image:
    python: ghcr.io/kube-tarian/clusterfactory-wire:0.2.0
```

```bash
helm install my-release clusterfactory/clusterfactory \
  --set wire.engine=python
```

## Features

### Component Interface

Every component implements a standard interface:

```python
class Component(ABC):
    def ready() -> bool           # Health check
    def produces() -> list[type]  # Credential types this generates
    def consumes() -> list[type]  # Credential types this accepts
    def extract() -> Credential   # Generate credential
    def inject(Credential)        # Accept credential
    def verify(Credential) -> bool # Prove wire holds
```

### SHA-Based Determinism

```yaml
# Platform SHA identifies configuration
platform_sha: 8c6a3ee0f8c38a53850243ad3bb59c0b29c9cda6e376c50b628934f0099c0f6a

# Structural SHA proves wiring executed correctly
structural_sha: <computed from all credential SHAs>
```

Same configuration → same platform SHA  
Same wiring → same structural SHA

### Extensibility

Add new components by implementing the interface:

```python
# factory/components/harbor.py
class HarborComponent(Component):
    def produces(self):
        return [RegistryPush]
    
    def consumes(self):
        return [OIDCConfig]
    
    # ... implement other methods
```

Update platform.yaml:

```yaml
artifacts:
  - name: harbor
    chart: harbor/harbor
    version: "1.14.0"
    image: harbor/harbor:2.10.0

wiring:
  - from: keycloak
    to: harbor
    credential: oidc-config
```

The engine handles the rest automatically.

## Testing

### Run Unit Tests

```bash
# Quick test
make test-unit

# Or directly
python3 -m pytest factory/testing/layers/unit/ -v
```

### Run Integration Tests

Requires live cluster with Gitea and Jenkins deployed:

```bash
# Set environment
export TEST_NAMESPACE=default
export GITEA_SERVICE=my-release-gitea-http
export JENKINS_SERVICE=my-release-jenkins

# Run tests
make test-integration
```

### Run All Tests

```bash
./run-tests.py all -v
```

## Development

### Build Wire Image

```bash
make build
# Or:
docker build -f Dockerfile.wire -t clusterfactory-wire:dev .
```

### Test Locally

```bash
# Load platform
python3 -m factory --platform platform.yaml --log-level DEBUG

# Run unit tests in watch mode
make test-watch
```

### Create Test Cluster

```bash
# Create k3d cluster with registry
make cluster-create

# Build and import image
make cluster-import-image

# Deploy with Python engine
make deploy-python
```

## Migration Path

### Phase 1: Development (Current)
- Python engine available as opt-in
- Bash remains default
- Both engines coexist

### Phase 2: Testing
```bash
# Deploy both engines
helm install test-bash clusterfactory/clusterfactory \
  --set wire.engine=bash

helm install test-python clusterfactory/clusterfactory \
  --namespace python-test --create-namespace \
  --set wire.engine=python
```

### Phase 3: Validation
- Compare wiring results
- Verify structural SHAs
- Run integration tests

### Phase 4: Adoption
```yaml
# Switch default in values.yaml
wire:
  engine: python  # New default
```

### Phase 5: Deprecation
- Remove bash engine
- Clean up old templates

## Troubleshooting

### Check Wire Job Status

```bash
# View logs
kubectl logs -l app.kubernetes.io/name=wire

# Describe job
kubectl describe job -l app.kubernetes.io/name=wire
```

### Python Engine Specific

```bash
# Check platform ConfigMap
kubectl get configmap my-release-platform -o yaml

# View Python engine logs
kubectl logs -l wire.clusterfactory.io/engine=python

# Check if components resolved
kubectl logs -l app.kubernetes.io/name=wire | grep "resolved.*components"
```

### Component Not Ready

```bash
# Check Gitea
kubectl port-forward svc/my-release-gitea-http 3000:3000
curl http://localhost:3000

# Check Jenkins
kubectl port-forward svc/my-release-jenkins 8080:8080
curl http://localhost:8080/login
```

## Configuration

### Component Credentials

Set via environment variables:

```yaml
# values.yaml (for bash engine)
gitea:
  gitea:
    admin:
      username: gitea
      password: changeme123!

jenkins:
  controller:
    adminPassword: adminpwd
```

Python engine reads these automatically.

### Custom Platform

Mount your own platform.yaml:

```yaml
# values.yaml
wire:
  engine: python
  platformConfigMap: my-custom-platform
```

```yaml
# custom-platform.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-custom-platform
data:
  platform.yaml: |
    platform:
      name: custom-platform
      version: "1.0.0"
    artifacts:
      - name: gitea
        ...
    wiring:
      - from: gitea
        to: jenkins
        credential: api-token
```

## Architecture

### Bash Engine
```
wire-job
  └── alpine:3.19
      └── apk add curl jq (runtime)
          └── bash script
              └── Gitea/Jenkins APIs
```

### Python Engine
```
wire-job
  └── python:3.12-slim
      ├── All deps baked in (build time)
      └── Factory Engine
          ├── Resolver → Components
          ├── Planner → Graph
          ├── Executor → Wiring
          └── Verifier → Validation
```

## Resources

- [Wire Engine Selection](./wire-engines.md)
- [Integration Testing Guide](./integration-testing.md)
- [Refactoring Blueprint](./refactoring-python.md)
- [Component Interface](../factory/components/base.py)
- [Example Platform](../platform.yaml)

## Support

- File issues: https://github.com/clusterfactory/clusterfactory/issues
- View PR: https://github.com/clusterfactory/clusterfactory/pull/27
- Docs: https://github.com/clusterfactory/clusterfactory/tree/main/docs
