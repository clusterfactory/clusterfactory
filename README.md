# clusterfactory

clusterfactory packages an opinionated CI stack — Gitea as the git server,
Jenkins as the workflow engine — as a single signed Zarf bundle that installs
on an airgapped Kubernetes cluster. A small Python wire engine runs in-cluster
on first deploy, mints a Gitea API token, stores it in Jenkins as a credential
the pipeline can use to clone, and emits a structural SHA so an operator can
prove the install matches the connected build without comparing secret values.

## Try it

```bash
# Connected machine
make wire-image
make package

# Airgapped target (after copying the .tar.zst over)
GITEA_ADMIN_PASSWORD=<your-password> make deploy
```

After deploy, port-forward Gitea (`:3000`) and Jenkins (`:8080`); both come up
pre-wired against `cf-demo/hello-world`. The structural SHA prints at the end
of `zarf package deploy` and is also persisted to the `cf-wire-result`
ConfigMap.

## Layout

| Path | What |
|------|------|
| `zarf.yaml` | Zarf package definition (charts, images, manifests, deploy actions) |
| `platform.yaml` | Wiring graph the Python engine reads |
| `engine/` | Python wire engine (`clusterfactory_engine`) — the only custom image |
| `manifests/` | Standalone K8s manifests Zarf applies (wire Job, RBAC, NetworkPolicy) |
| `values/` | Upstream Helm chart values for Gitea and Jenkins |
| `files/` | Bootstrap files committed into Gitea on first run (e.g., `Jenkinsfile`) |
| `engine/tests/` | pytest unit tests + bash e2e airgap install test |

## Status and scope

v0.3 demo. One mode: Gitea-as-git, Jenkins-as-workflow-engine. No Gitea
Actions, no Harbor, no OpenBao, no SDK packaging — those come in v0.4 and v1.0.
The full design and the rationale for the v0.3 reset are in
[`refactor-to-zarf.md`](refactor-to-zarf.md). Historical refactor notes live
under [`docs/history/`](docs/history/).
