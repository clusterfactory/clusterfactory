# ClusterFactory

**One `helm install` for a working CI/CD platform — Gitea, optionally Jenkins, optionally Gitea Actions. Online or airgapped via Zarf.**

ClusterFactory is a Helm chart that composes upstream Gitea and Jenkins charts and wires them together via a post-install Job. You pick a mode, run `helm install`, and you get a working CI/CD platform — including a bootstrap repo, a working pipeline, and (in modes that include it) a registered Gitea Actions runner.

## Modes

| Mode            | Gitea | Gitea Actions | Jenkins | Bootstrap pipeline |
|-----------------|:-----:|:-------------:|:-------:|--------------------|
| `gitea-actions` |   ✓   |       ✓       |    —    | `.gitea/workflows/ci.yaml` runs on push |
| `jenkins`       |   ✓   |       —       |    ✓    | Jenkinsfile runs on push (via webhook)  |
| `both`          |   ✓   |       ✓       |    ✓    | Both of the above                       |

## Install

### Connected

```sh
helm repo add gitea https://dl.gitea.com/charts/
helm repo add jenkins https://charts.jenkins.io
helm dependency build .

# Pick a mode. Gitea admin password is required.
helm install cf . \
  --namespace cicd --create-namespace \
  --set mode=both \
  --set jenkins.enabled=true \
  --set giteaAdmin.password='<your-password>'
```

After `helm install`:

```sh
# Watch the wire Job complete.
kubectl -n cicd logs -f job/cf-wire

# Verify functional wiring.
helm test cf -n cicd

# Read the wiring receipt.
kubectl -n cicd get configmap cf-wire-result -o yaml
```

### Airgapped

```sh
# In a connected environment, build the Zarf package:
zarf package create . --confirm

# Move the resulting zarf-package-clusterfactory-*.tar.zst across the airgap.

# In the airgapped environment:
zarf package deploy zarf-package-clusterfactory-*.tar.zst --confirm \
  --set GITEA_ADMIN_PASSWORD='<your-password>'
```

## What you get

- **Gitea** as the git host. Org and repo created automatically by the wire Job, with a bootstrap commit on `main`.
- **Jenkins** (in `jenkins`/`both` modes), with a pipeline job pre-configured to fetch `Jenkinsfile` from the bootstrap repo. A Gitea webhook triggers builds on push.
- **Gitea Actions** (in `gitea-actions`/`both` modes), with a DaemonSet runner registered to the Gitea instance. The bootstrap workflow runs on push.
- **A wiring receipt** at `cf-wire-result` ConfigMap — a structural sha of the wires performed, plus the sorted list of `producer:consumer:credential_kind` tuples. Same wiring graph → same hash, regardless of secret values.

## Three-minute demo

```sh
# 1. Install (mode=both).
helm install cf . -n cicd --create-namespace \
  --set mode=both --set jenkins.enabled=true \
  --set giteaAdmin.password=demo-password-12345

# 2. Wait for the wire Job (≈30s once pods are up).
kubectl -n cicd wait --for=condition=complete --timeout=5m job/cf-wire

# 3. Open Gitea.
kubectl -n cicd port-forward svc/cf-gitea-http 3000:3000 &
# → http://localhost:3000  (login: gitea-admin / demo-password-12345)
# → cf-demo/hello-world repo, with a Jenkinsfile and .gitea/workflows/ci.yaml

# 4. Open Jenkins.
PASS=$(kubectl -n cicd get secret cf-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
kubectl -n cicd port-forward svc/cf-jenkins 8080:8080 &
# → http://localhost:8080  (login: admin / $PASS)
# → "hello-world" job, wired to cf-demo/hello-world via webhook

# 5. Push a commit to Gitea, watch both pipelines run.
```

## What this is not

- Not an Operator. The wire Job runs once at install/upgrade and exits.
- Not a meta-installer. Subcharts are vanilla upstream Gitea (11.0.1) and Jenkins (5.9.9).
- Not a standard. See [docs/composing-platforms.md](docs/composing-platforms.md) for the conventions used here, in case they're useful for similar meta-charts.

## Documentation

- [docs/composing-platforms.md](docs/composing-platforms.md) — the discipline of composing N charts into one.
- [docs/airgap.md](docs/airgap.md) — Zarf-based airgap delivery.
- [CHANGELOG.md](CHANGELOG.md)

## License

See [LICENSE](LICENSE).
