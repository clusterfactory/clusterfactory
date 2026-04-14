# Python Factory Engine - Quick Reference

## 🚀 Quick Start

```bash
# Install dependencies
pip install -r requirements.txt

# Run tests
make test-unit

# Build image (when Docker available)
make build

# Deploy
helm install test . --set wire.engine=python
```

## 📁 Project Structure

```
factory/
├── model/           # Data models (Artifact, Platform, Credential)
├── engine/          # Core engine (Executor, Planner, Resolver)
├── components/      # Component implementations (Gitea, Jenkins)
├── credentials/     # Credential types (ApiToken, UserPass)
├── health/          # Health checking
└── testing/         # Test suites (unit, integration, airgap, upgrade)
```

## 🧪 Testing

```bash
# Unit tests (fast, no cluster needed)
./run-tests.py unit -v

# Integration tests (requires live cluster)
export TEST_NAMESPACE=default
./run-tests.py integration -v

# All tests
./run-tests.py all
```

## 🛠️ Development

```bash
# Create cluster
make cluster-create

# Build & deploy
make build
make cluster-import-image
make deploy-python

# View logs
make logs-python

# Port forward
make port-forward-gitea  # localhost:3000
make port-forward-jenkins # localhost:8080

# Cleanup
make clean-all
```

## 📊 Helm Usage

```yaml
# values.yaml
wire:
  engine: python  # or 'bash' for default
```

```bash
# Deploy with Python
helm install test . --set wire.engine=python

# Compare both engines
helm install test-bash . --set wire.engine=bash
helm install test-python . \
  --namespace python-test --create-namespace \
  --set wire.engine=python
```

## 🔍 Debugging

```bash
# Check wire job
kubectl get jobs -l app.kubernetes.io/name=wire
kubectl logs -l app.kubernetes.io/name=wire

# Check platform config (Python only)
kubectl get configmap test-platform -o yaml

# Check component readiness
kubectl get pods -l app.kubernetes.io/name=gitea
kubectl get pods -l app.kubernetes.io/name=jenkins
```

## 📚 Documentation

- [Wire Engines Comparison](./wire-engines.md)
- [Integration Testing Guide](./integration-testing.md)
- [Python Engine Usage](./python-engine-usage.md)
- [Refactoring Blueprint](./refactoring-python.md)

## 🔗 Links

- **PR:** https://github.com/clusterfactory/clusterfactory/pull/27
- **Branch:** refactoring-python
- **Commits:** 4 (Foundation → Components → Helm → Testing)
- **Tests:** 20 unit, 10 integration

## ✅ Status

- Progress: 90% complete
- Unit tests: 20/20 passing ✅
- Integration tests: 10 ready 🔧
- Docker image: Dockerfile ready ✅
- Helm integration: Complete ✅
- Documentation: Complete ✅

## 🎯 Next Steps

1. Build Docker image (`make build`)
2. Deploy to cluster (`make deploy-python`)
3. Run integration tests (`make test-integration`)
4. Update PR with results
5. Request code review

---

**Ready for:** Testing on live cluster  
**Not ready for:** Production (needs integration testing)  
**Breaking changes:** None (bash is default)
