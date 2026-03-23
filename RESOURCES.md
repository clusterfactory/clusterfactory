# resource strategy

## the problem

A full platform stack (Gitea, ArgoCD, Harbor, OpenBao, Crossplane, Headlamp, Cockpit)
has two resource modes that are completely different:

| mode | CPU | RAM |
|---|---|---|
| **startup spike** (all pods initializing at once) | ~4 cores | ~6Gi |
| **steady state** (everything idle) | ~0.5 cores | ~3Gi |

Local Kubernetes runtimes allocate a fixed VM budget. If that budget is smaller than
the startup spike, pods crash with OOMKilled or get throttled into failure loops —
not because the stack is too heavy, but because nobody told the user to configure more.

The fix is not disabling components. It is telling the user exactly what they need,
before the install starts.

---

## design decisions

### 1. all components, always

Profiles that disable components to save resources are a trap:
- users get a different system than what they deployed to staging/production
- bugs appear in components that weren't tested locally
- the mental model of the platform changes depending on where you run it

The stack runs everywhere. What changes is the preflight — not what gets installed.

### 2. slim requests, honest limits

Kubernetes schedules pods based on **requests**. Pods can burst up to **limits**.

Setting requests = true idle minimum means the scheduler places pods freely.
Setting limits = true startup maximum means the node is never surprised.

The preflight validates that the node has enough **allocatable** capacity to handle
all pods bursting simultaneously — which is exactly what happens on first install.

```
requests  → what the pod needs at idle    → used for scheduling
limits    → what the pod can use at peak  → used for enforcement
preflight → sum(limits) ≤ allocatable     → checked before install
```

### 3. hard preflight, not soft warnings

Soft warnings get ignored. The bootstrap script detects the environment,
measures what is actually available, and **exits with a non-zero code and explicit
instructions** if the cluster cannot support the stack.

```
✗  insufficient memory

   you are on:  Rancher Desktop
   allocatable: 2.0 CPU  /  3.8Gi RAM
   required:    4.0 CPU  /  6.0Gi RAM

   fix:
     Preferences → Virtual Machine → Hardware
     set Memory to 8Gi, CPU to 4
     then restart Rancher Desktop and re-run this script.
```

No guessing. No mystery 20-minute hang. Exit immediately with the exact fix.

---

## minimum requirements

These numbers account for startup spike across all components simultaneously.

| requirement | value | reason |
|---|---|---|
| CPU | **4 cores allocatable** | Harbor init + ArgoCD controller + Gitea + PG all spike at start |
| RAM | **6Gi allocatable** | Trivy downloads CVE database on first start; all containers uncompressing |
| Disk | **20Gi** | PVCs: Gitea 5Gi + Gitea PG 2Gi + Harbor registry 10Gi + Harbor PG 1Gi |

---

## environment detection

The preflight identifies the runtime by inspecting the kubeconfig context name
and cluster server URL, then provides environment-specific fix instructions.

| environment | detection | minimum VM config |
|---|---|---|
| Docker Desktop | context = `docker-desktop` or server contains `docker.internal` | Settings → Resources → 4 CPU / 8Gi |
| Rancher Desktop | context contains `rancher-desktop` | Preferences → Virtual Machine → 4 CPU / 8Gi |
| Podman Desktop | context contains `podman` | Settings → Resources → 4 CPU / 8Gi |
| minikube | context = `minikube` | `minikube start --cpus=4 --memory=8192` |
| kind | context starts with `kind-` | node config with `system-reserved` tuning |
| Amazon EKS | server contains `eks.amazonaws.com` | node group: t3.xlarge minimum |
| Google GKE | context starts with `gke_` | node pool: n1-standard-4 minimum |
| Azure AKS | server contains `azmk8s.io` | node pool: Standard_D4s_v3 minimum |
| generic | everything else | ensure 4 allocatable cores and 6Gi allocatable RAM |

---

## per-component resource budget

Requests are tuned to true idle minimums. Limits allow startup bursting.

| component | CPU request | RAM request | CPU limit | RAM limit |
|---|---|---|---|---|
| Gitea | 100m | 128Mi | 1000m | 512Mi |
| Gitea PostgreSQL | 100m | 128Mi | 500m | 256Mi |
| Gitea Valkey | 50m | 64Mi | 200m | 128Mi |
| ArgoCD server | 50m | 64Mi | 500m | 256Mi |
| ArgoCD repo-server | 50m | 64Mi | 500m | 256Mi |
| ArgoCD app-controller | 100m | 128Mi | 1000m | 512Mi |
| ArgoCD redis | 50m | 64Mi | 200m | 128Mi |
| Harbor core | 25m | 64Mi | 500m | 256Mi |
| Harbor registry | 25m | 64Mi | 500m | 256Mi |
| Harbor jobservice | 25m | 64Mi | 500m | 256Mi |
| Harbor portal | 25m | 32Mi | 100m | 128Mi |
| Harbor nginx | 25m | 32Mi | 100m | 128Mi |
| Harbor trivy | 50m | 128Mi | 500m | 512Mi |
| Harbor database | 100m | 128Mi | 500m | 256Mi |
| Harbor redis | 50m | 64Mi | 200m | 128Mi |
| OpenBao | 50m | 64Mi | 200m | 256Mi |
| Crossplane | 50m | 64Mi | 200m | 256Mi |
| Crossplane RBAC | 50m | 64Mi | 200m | 128Mi |
| Headlamp | 25m | 32Mi | 100m | 128Mi |
| Cockpit | 50m | 128Mi | 500m | 256Mi |
| CI Runner | 50m | 64Mi | 500m | 256Mi |
| **Total requests** | **~1.0 CPU** | **~1.6Gi** | | |
| **Total limits** | **~7.5 CPU** | **~5.1Gi** | | |

The preflight requires 4 CPU / 6Gi allocatable — safely between the total limits
and the observed peak during startup.

---

## what happens on different machines

| machine | config needed | result |
|---|---|---|
| Intel MacBook (5yr, 8Gi) | Docker Desktop: 4 CPU / 6Gi | runs, slow startup |
| M-Max MacBook (36Gi) | Docker Desktop or Rancher: 4 CPU / 8Gi | fast |
| Rancher Desktop default (2 CPU / 4Gi) | **preflight blocks** — shows fix | blocked, user fixes config |
| EKS t3.medium (2 vCPU / 4Gi) | **preflight blocks** — suggests t3.xlarge | blocked |
| EKS t3.xlarge (4 vCPU / 16Gi) | passes | runs |
| GKE n1-standard-4 (4 vCPU / 15Gi) | passes | runs |

---

## extending the preflight

To add a new environment or tighten requirements, edit the `preflight` function
in `bootstrap.sh`. The structure is:

```
detect environment  →  measure allocatable  →  compare against minimums
                                                        ↓
                                                  pass: continue
                                                  fail: print env-specific fix + exit 1
```

No changes to the chart are needed. The preflight is purely a bootstrap concern.
