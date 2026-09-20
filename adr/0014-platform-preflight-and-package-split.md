# 0014 — Where Zarf helps below the package: a preflight component, and a separate platform bundle

**Status:** Proposed (questions open, see end)
**Date:** 2026-09-20

## Context

Everything above the cluster is one Zarf package with strong guarantees:
signed, SBOM'd, CVE-gated, tested airgapped, upgrade-tested. Everything
below it - the OS, RKE2, storage, the node network - is a shell script and a
tarball per ADR 0011, verified only on a nightly VM job that does not exist
yet. Real deployments fail at that seam: the wrong CNI (kindnet-style, no
NetworkPolicy enforcement), no default StorageClass, too little memory for
Nexus, a control plane the pods cannot reach through the egress policy, an
API server whose IP is not what the policy resolved.

Zarf cannot install RKE2 (it needs a cluster), but two things it does well
apply here:

1. **Actions run on the operator's machine before anything is deployed.**
   A `preflight` component can assert the cluster meets `PREREQUISITES.md`
   and stop `zarf package deploy` with a plain message before Helm runs.
2. **A package is a signed, versioned, transported artifact.** The RKE2
   tarball, binary, checksums, `config.yaml`, the local-path-provisioner
   manifest and the install script can travel as a Zarf package too - not
   deployed *into* a cluster, but unpacked on the host with a `files:`
   component and Zarf `onDeploy` actions running `install.sh`. Zarf supports
   this ("zarf package deploy" of a package with no cluster components); UDS
   uses the same trick for host-level pieces.

## Decision (proposed)

### A. `preflight` component in the application package

First component in `common/zarf.yaml`, `required: true`, no charts, only
`onDeploy.before` actions using `./zarf tools kubectl`. Each check prints
`ok:`/`FAIL:` like `tests/deploy-check.sh` and the component fails fast:

| Check | Why |
|---|---|
| Kubernetes ≥ 1.30, one Ready node with ≥ 4 CPU / 8 GiB allocatable (values-driven) | Nexus + Jenkins + a build |
| A default `StorageClass` exists and a test PVC binds | Gitea/Jenkins/Nexus persistence |
| The CNI enforces `NetworkPolicy`: create a throwaway namespace with deny-all, a pod, and assert it cannot reach the API server; then delete | the whole airgap story is a no-op on kindnet/flannel-without-policy |
| PSA admission active: a privileged pod in a `restricted`-labelled test namespace is rejected | CM-7 claim |
| `kubernetes` EndpointSlice resolves to exactly the addresses the policy will allow; warn if the API is behind a VIP the policy cannot express | the ipBlock rule |
| `zarf init` present, registry reachable from a pod | image rewriting works |
| Optional: no internet from a pod (warn only) | confirms the environment is what the operator thinks |

The checks are the executable form of `PREREQUISITES.md`; the doc is
generated from the same table.

### B. A separate **platform bundle**, not a component of the forge package

`rke2/` becomes its own Zarf package (`clusterfactory-platform`, host-side,
no cluster components): `files:` for the RKE2 artifacts, `config.yaml`,
local-path-provisioner and the CIS sysctl/user setup; `onDeploy` actions
that run `install.sh` with `INSTALL_RKE2_ARTIFACT_PATH`, create the `etcd`
user, apply sysctls, enable the service, then wait for the node Ready and
run `zarf init`. Signed and versioned like the forge package, transported
the same way, but with its own release cadence - RKE2 patches monthly, the
forge does not.

Deploy story on the target host:

```
zarf package deploy zarf-package-clusterfactory-platform-*.tar.zst --key cosign.pub   # RKE2 + storage + zarf init
zarf package deploy zarf-package-clusterfactory-*.tar.zst --key cosign.pub            # preflight + forge
```

Kept out of scope, still: host OS STIG, multi-node HA, etcd snapshot
off-node cadence.

## Consequences

- One transport, one signing key, one verification story for both layers.
- The forge package refuses to deploy on a cluster that cannot honour its
  guarantees, with a message an operator can act on, instead of a Helm
  timeout 15 minutes later.
- Two packages, two version numbers, one more thing to document; the
  platform package can only be tested on a VM (nightly gate, ADR 0011).
- The preflight's NetworkPolicy check needs the CNI to be *installed and
  enforcing* - on kind that means Calico; the test matches CI exactly.

## Open questions

See the list sent with this ADR; answers become the Decision section.
