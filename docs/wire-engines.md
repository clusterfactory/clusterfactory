# Wire Engine Selection

ClusterFactory supports two wire engines:

## Bash Engine (Default, Stable)

```yaml
wire:
  engine: bash
```

- **Status:** Stable, production-tested
- **Image:** `alpine:3.19` + runtime `apk add curl jq`
- **Implementation:** Inline bash script in wire-job.yaml
- **Use when:** You need stability and proven behavior

## Python Engine (Experimental)

```yaml
wire:
  engine: python
```

- **Status:** Experimental, under development
- **Image:** `ghcr.io/kube-tarian/clusterfactory-wire:0.2.0`
- **Implementation:** Typed Python factory engine
- **Benefits:**
  - Airgap compliant (no runtime package installation)
  - Component interface for extensibility
  - Full test coverage (unit, integration, airgap, upgrade)
  - Structural SHA for deterministic wiring
  - Upgrade planning and verification

## Feature Comparison

| Feature | Bash | Python |
|---------|------|--------|
| Gitea → Jenkins wiring | ✅ | ✅ |
| Airgap compliance | ⚠️ (runtime apk add) | ✅ |
| Component extensibility | ❌ | ✅ |
| Upgrade planning | ❌ | ✅ |
| Test coverage | Manual | 4-layer automated |
| SHA verification | ❌ | ✅ |

## Migration Path

1. **Development:** Use `engine: python` to test new features
2. **Testing:** Run parallel installations (bash in prod, python in test)
3. **Validation:** Compare structural SHAs between engines
4. **Cutover:** Switch production to `engine: python`
5. **Deprecation:** Remove bash engine when Python is stable

## Architecture

### Bash Engine
```
wire-job → bash script → curl/jq → Gitea/Jenkins APIs
```

### Python Engine
```
wire-job → Python factory → Component instances → Gitea/Jenkins APIs
                ↓
         platform.yaml (ConfigMap)
```

## Troubleshooting

### Bash Engine
```bash
kubectl logs -n <namespace> -l app.kubernetes.io/name=wire
```

### Python Engine
```bash
# View factory logs
kubectl logs -n <namespace> -l app.kubernetes.io/name=wire

# Inspect platform config
kubectl get configmap <release>-platform -o yaml
```

## Development

To build the Python wire image:
```bash
docker build -f Dockerfile.wire -t clusterfactory-wire:dev .
```

To test locally:
```bash
python3 -m factory --platform platform.yaml --log-level DEBUG
```
