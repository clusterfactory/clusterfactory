# Building Container Images with Kaniko

ClusterFactory's Gitea Actions runners use **Kaniko** for building container images instead of Docker-in-Docker (DinD). This approach:

- ✅ Avoids privileged containers
- ✅ Works with Kubernetes security policies (PSP, PSS, OPA)
- ✅ No Docker daemon required
- ✅ Ephemeral build pods
- ✅ Proper resource isolation

## Architecture

```
Gitea Actions
      │
      ▼
act_runner (DaemonSet)
      │
      ▼
kubectl create job
      │
      ▼
Kaniko pod builds image
      │
      ▼
push → registry
```

## Example Workflow

### Basic Kaniko Build

Create `.gitea/workflows/build.yaml` in your repository:

```yaml
name: Build Container Image

on:
  push:
    branches:
      - main

jobs:
  build-image:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Build and push with Kaniko
        run: |
          kubectl create job kaniko-build-${{ github.run_number }} \
            --image=gcr.io/kaniko-project/executor:latest \
            --restart=Never \
            -- \
            --context=dir://$(pwd) \
            --dockerfile=Dockerfile \
            --destination=my-registry.example.com/myapp:${{ github.sha }} \
            --destination=my-registry.example.com/myapp:latest
```

### With Registry Credentials

For private registries, create a Kubernetes secret with your Docker config:

```bash
kubectl create secret generic docker-config \
  --from-file=config.json=$HOME/.docker/config.json \
  -n your-namespace
```

Then reference it in your workflow:

```yaml
- name: Build and push with Kaniko
  run: |
    cat <<EOF | kubectl apply -f -
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: kaniko-build-${{ github.run_number }}
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: kaniko
            image: gcr.io/kaniko-project/executor:latest
            args:
            - --context=git://github.com/${{ github.repository }}.git#refs/heads/${{ github.ref_name }}
            - --dockerfile=Dockerfile
            - --destination=${{ secrets.REGISTRY }}/myapp:${{ github.sha }}
            volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
              readOnly: true
          volumes:
          - name: docker-config
            secret:
              secretName: docker-config
    EOF
    
    kubectl wait --for=condition=complete --timeout=600s \
      job/kaniko-build-${{ github.run_number }}
```

### Multi-stage Build

```yaml
- name: Build multi-stage image
  run: |
    kubectl create job kaniko-build-${{ github.run_number }} \
      --image=gcr.io/kaniko-project/executor:latest \
      -- \
      --context=dir://$(pwd) \
      --dockerfile=Dockerfile \
      --target=production \
      --cache=true \
      --cache-repo=my-registry.example.com/cache \
      --destination=my-registry.example.com/myapp:${{ github.sha }}
```

### Build Arguments

```yaml
- name: Build with build args
  run: |
    kubectl create job kaniko-build-${{ github.run_number }} \
      --image=gcr.io/kaniko-project/executor:latest \
      -- \
      --context=dir://$(pwd) \
      --dockerfile=Dockerfile \
      --build-arg=VERSION=${{ github.ref_name }} \
      --build-arg=BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --destination=my-registry.example.com/myapp:${{ github.sha }}
```

## Kaniko Executor Options

Common flags for the Kaniko executor:

| Flag | Description |
|------|-------------|
| `--context` | Build context (dir://, git://, tar://, etc.) |
| `--dockerfile` | Path to Dockerfile (default: Dockerfile) |
| `--destination` | Registry destination (can be specified multiple times) |
| `--build-arg` | Build-time variables |
| `--target` | Target stage in multi-stage builds |
| `--cache` | Enable layer caching |
| `--cache-repo` | Repository for caching layers |
| `--skip-tls-verify` | Skip TLS verification (insecure) |
| `--insecure` | Use insecure registry |
| `--registry-mirror` | Use registry mirror |

## Best Practices

1. **Use specific tags**: Tag images with commit SHA for traceability
   ```yaml
   --destination=registry/image:${{ github.sha }}
   ```

2. **Enable caching**: Speed up builds with layer caching
   ```yaml
   --cache=true --cache-repo=registry/cache
   ```

3. **Clean up jobs**: Delete completed jobs to avoid clutter
   ```yaml
   - name: Cleanup
     if: always()
     run: kubectl delete job kaniko-build-${{ github.run_number }} || true
   ```

4. **Wait for completion**: Ensure build finishes before proceeding
   ```yaml
   kubectl wait --for=condition=complete --timeout=600s job/kaniko-build-${{ github.run_number }}
   ```

5. **Check logs on failure**:
   ```yaml
   - name: Show build logs on failure
     if: failure()
     run: kubectl logs job/kaniko-build-${{ github.run_number }}
   ```

## Security Considerations

- Kaniko runs **without privileged containers**
- Build pods are **ephemeral** and cleaned up after completion
- No Docker socket exposure
- Compatible with Pod Security Standards (restricted)
- Registry credentials managed via Kubernetes secrets

## Troubleshooting

### Build fails with "permission denied"

Ensure the runner ServiceAccount has permissions to create Jobs:

```bash
kubectl auth can-i create jobs --as=system:serviceaccount:your-namespace:your-release-runner
```

### Cannot pull from private registry

Create a Docker config secret:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=my-registry.example.com \
  --docker-username=myuser \
  --docker-password=mypassword
```

Then use it in imagePullSecrets:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
      - name: regcred
```

### Build context not found

When using `dir://$(pwd)`, the context is the runner's working directory. For Git context, use:

```yaml
--context=git://github.com/${{ github.repository }}.git#refs/heads/${{ github.ref_name }}
```

## Migration from Docker-in-Docker

If migrating from DinD, replace:

```yaml
# Old DinD approach
- name: Build image
  run: |
    docker build -t myimage:latest .
    docker push myimage:latest
```

With:

```yaml
# New Kaniko approach
- name: Build image
  run: |
    kubectl create job kaniko-build-${{ github.run_number }} \
      --image=gcr.io/kaniko-project/executor:latest \
      -- \
      --context=dir://$(pwd) \
      --dockerfile=Dockerfile \
      --destination=myregistry/myimage:latest
```

## References

- [Kaniko Documentation](https://github.com/GoogleContainerTools/kaniko)
- [Kaniko Executor Options](https://github.com/GoogleContainerTools/kaniko#additional-flags)
- [Gitea Actions Documentation](https://docs.gitea.com/usage/actions/overview)
