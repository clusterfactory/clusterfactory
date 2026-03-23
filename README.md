# clusterfactory

One `helm install`. Five upstream components. Pre-wired and ready.

<br>

<p align="center">
  <img src="https://img.shields.io/badge/Gitea-609926?style=for-the-badge&logo=gitea&logoColor=white" alt="Gitea"/>
  <img src="https://img.shields.io/badge/ArgoCD-EF7B4D?style=for-the-badge&logo=argo&logoColor=white" alt="ArgoCD"/>
  <img src="https://img.shields.io/badge/Harbor-60B932?style=for-the-badge&logo=harbor&logoColor=white" alt="Harbor"/>
  <img src="https://img.shields.io/badge/OpenBao-FFD814?style=for-the-badge&logo=vault&logoColor=black" alt="OpenBao"/>
  <img src="https://img.shields.io/badge/Crossplane-EF3B2D?style=for-the-badge&logo=crossplane&logoColor=white" alt="Crossplane"/>
  <img src="https://img.shields.io/badge/Headlamp-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="Headlamp"/>
</p>

<p align="center">
  <strong>100% upstream. No custom controllers. No operators. No magic.</strong><br>
  Just the official charts, connected by plain YAML.
</p>

<br>

---

## install

**Prerequisites:** `helm` and `kubectl` in PATH, a running cluster in your kubeconfig.

### from the Helm repo (recommended)

```bash
helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory
helm repo update
helm pull clusterfactory/clusterfactory --untar
bash ./clusterfactory/bootstrap.sh
```

### from source

```bash
git clone https://github.com/clusterfactory/clusterfactory
bash ./clusterfactory/platform/bootstrap.sh
```

`bootstrap.sh` prompts for namespace, host, and kubectl context — then runs `helm install`.

### manual helm install

```bash
helm repo add clusterfactory https://clusterfactory.github.io/clusterfactory
helm repo update
helm install clusterfactory clusterfactory/clusterfactory \
  --namespace clusterfactory \
  --create-namespace \
  --set host=localhost \
  --timeout 20m
```

### follow progress

```bash
kubectl get jobs -n clusterfactory -w
kubectl logs job/clusterfactory-init    -n clusterfactory -f
kubectl logs job/clusterfactory-wiring  -n clusterfactory -f
kubectl logs job/clusterfactory-summary -n clusterfactory
```

### upgrade

```bash
helm repo update
helm upgrade clusterfactory clusterfactory/clusterfactory \
  --namespace clusterfactory \
  --set host=localhost \
  --timeout 20m
```

### uninstall

```bash
helm uninstall clusterfactory -n clusterfactory
kubectl delete namespace clusterfactory
```

---

## what you get

| component | role | default port |
|---|---|---|
| [Gitea](https://gitea.io) | git server + Actions CI | `:30080` |
| [ArgoCD](https://argoproj.github.io/cd/) | GitOps CD | `:8080` |
| [Harbor](https://goharbor.io) | container + Helm registry | `:30002` |
| [OpenBao](https://openbao.org) | secrets management (open-source Vault fork) | `:30820` |
| [Crossplane](https://crossplane.io) | cloud resources as Kubernetes objects | — |
| [Headlamp](https://headlamp.dev) | cluster UI | `:4466` |
| Cockpit | browser terminal + status dashboard | `:4000` |

All official upstream charts. Versions pinned in [`platform/Chart.yaml`](platform/Chart.yaml).

---

## the wiring pattern

The components don't know about each other out of the box. **Wiring** is what connects them.

Every connection between components lives in [`wiring/`](platform/wiring/) as a plain YAML file — a Kubernetes Secret, ConfigMap, or CRD that one component needs to talk to another. Nothing more.

```
wiring/argocd-repo-secret.yaml   — ArgoCD authenticates to Gitea
wiring/argocd-applications.yaml  — ArgoCD watches deploy/ in Gitea
wiring/runner-token-secret.yaml  — Gitea Actions runner joins Gitea
wiring/harbor-pull-secret.yaml   — cluster pulls images from Harbor
wiring/openbao-k8s-auth.yaml     — pods authenticate to OpenBao
wiring/crossplane-providers.yaml — Crossplane manages in-cluster resources
```

Query everything wiring touches:

```bash
kubectl get all -A -l clusterfactory/wiring
```

---

## how it works — three phases

Install is a single `helm install`. Under the hood, three phases run in order via Helm post-install hooks:

```
Phase 1 — helm install
  Installs Gitea, Harbor, ArgoCD, OpenBao, Crossplane, Headlamp, Cockpit.

Phase 2 — init job  (hook weight 0)
  Waits for components to be ready.
  Seeds Gitea with a demo repo and CI workflow.
  Obtains tokens (runner, ArgoCD, Headlamp).
  Configures OpenBao (Kubernetes auth, policies, credentials).
  Stores everything in clusterfactory-wiring-tokens Secret.

Phase 3 — wiring job  (hook weight 10)
  Reads clusterfactory-wiring-tokens.
  Substitutes $VARIABLES in each wiring/ file.
  kubectl apply -f each file.

Phase 4 — summary job  (hook weight 20)
  Reads all credentials from OpenBao.
  Prints access summary: URLs, passwords, tokens.
```

The only contract between phases is `clusterfactory-wiring-tokens`. Phase 3 does not care how Phase 2 produced those values.

---

## how it's built — standard Helm mechanics

No controllers. No operators. Every mechanism is standard Kubernetes:

| mechanism | used for |
|---|---|
| `helm dependency` | pulls upstream charts |
| `helm post-install hooks` | orders the init → wiring → summary phases |
| `ConfigMap` + volume mount | delivers scripts and seed files to jobs |
| `Secret` | passes tokens between phases (`clusterfactory-wiring-tokens`) |
| `kubectl apply -f` | applies wiring files after variable substitution |
| `emptyDir` volume | cockpit initContainer installs npm deps, shares with main container |

The init job runs from a ConfigMap (`clusterfactory-init-scripts`) mounted at `/scripts`. The wiring job reads a ConfigMap (`clusterfactory-wiring`) mounted at `/wiring`. Everything is readable, diffable, and replaceable.

---

## everything is transparent

- **Scripts**: [`wiring/scripts/gitea-init.sh`](platform/wiring/scripts/gitea-init.sh) and [`wiring/scripts/summary.sh`](platform/wiring/scripts/summary.sh) — plain shell, no framework
- **Wiring files**: [`wiring/*.yaml`](platform/wiring/) — plain Kubernetes YAML with `$VARIABLE` placeholders
- **Cockpit**: [`files/terminal/server.js`](platform/files/terminal/server.js) + [`index.html`](platform/files/terminal/index.html) — plain Node.js, embedded in a ConfigMap
- **Jobs**: [`templates/init-job.yaml`](platform/templates/init-job.yaml), [`templates/wiring-job.yaml`](platform/templates/wiring-job.yaml), [`templates/summary-job.yaml`](platform/templates/summary-job.yaml) — standard batch/v1 Jobs

Nothing happens outside of what you can read in this repo.

---

## cloud providers (Crossplane)

After install, connect AWS, Azure, or GCP via the Gitea Actions workflow:

1. Add credentials to Gitea repo secrets (`AWS_ACCESS_KEY_ID`, `AZURE_CREDENTIALS_JSON`, `GCP_CREDENTIALS_JSON`)
2. Run **Actions → configure-cloud** → choose cloud

The workflow applies a `ProviderConfig` to the cluster. ArgoCD auto-installs the provider controllers from `deploy/crossplane/`.

Provider configs and credential templates are in [`files/crossplane/`](platform/files/crossplane/).

---

## adding a connection

1. Create a YAML file in `wiring/` describing the Kubernetes object
2. Use `$VARIABLE` placeholders for runtime values
3. Add the sed substitution + `kubectl apply` block in `templates/wiring-job.yaml`
4. If the variable comes from a component, generate it in `wiring/scripts/gitea-init.sh` and add it to `clusterfactory-wiring-tokens`

---

## debug

```bash
kubectl get jobs -n clusterfactory
kubectl logs job/clusterfactory-init    -n clusterfactory
kubectl logs job/clusterfactory-wiring  -n clusterfactory
kubectl logs job/clusterfactory-summary -n clusterfactory
```

---

## license

Apache 2.0
