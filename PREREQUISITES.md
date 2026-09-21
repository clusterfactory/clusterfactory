# Prerequisites

Generated from `preflight/preflight.sh` by `hack/gen-prerequisites.py` - do not edit by hand.
The `preflight` component runs these checks before anything is deployed and stops
`zarf package deploy` with the failing check's name if the cluster does not meet the contract (ADR 0014).
Results are also written to the ConfigMap `cf-system/cf-preflight-result`.

## The contract

| Check | Class | What must hold |
|---|---|---|
| `kubernetes-version` | **contract** - never bypassable | Kubernetes >= 1.30 and the API server reachable |
| `node-ready` | **contract** - never bypassable | at least one node Ready |
| `zarf-init` | **contract** - never bypassable | zarf init done (zarf-state present) and the Zarf registry reachable from a pod |
| `cluster-dns` | **contract** - never bypassable | cluster DNS resolves Service names from a pod |
| `default-storageclass` | **contract** - never bypassable | a default StorageClass exists and a 1Gi PVC binds |
| `pod-security-admission` | **contract** - never bypassable | Pod Security Admission is active (a privileged pod is rejected under `restricted`) |
| `apiserver-endpoint` | **contract** - never bypassable | the kubernetes EndpointSlice resolves to IPv4 addresses the egress policy can allow by ipBlock |
| `networkpolicy-enforcement` | **contract** - never bypassable | the CNI enforces NetworkPolicy (positive control reaches the API server; after deny-all it must not) |
| `resources` | **advisory** - a warning with `--set PREFLIGHT_STRICT=false` | allocatable >= 4 CPU and 8 GiB on the largest node |
| `internet-unreachable` | **profile** - hard or soft depending on the active policy profile (soft without one) | pods cannot reach the internet (hard under a profile that says so, otherwise a warning) |

## Beyond the checks

- A CNI that enforces `NetworkPolicy` (Canal, Calico, Cilium; plain flannel does not - the preflight checks it).
- `zarf init` done with the Zarf version pinned in `.github/workflows/ci.yaml`; the init package is in the deliverable.
- The namespaces in `contract/namespaces.yaml` may pre-exist (created by a policy profile); the forge never relabels them.
- Out of scope: host OS hardening, HA control planes, off-node backup cadence (see SECURITY.md).
