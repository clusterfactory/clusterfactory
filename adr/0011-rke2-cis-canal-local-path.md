# 0011 — RKE2 with CIS profile, Canal CNI, local-path storage

**Status:** Accepted
**Date:** 2026-09-18

## Context

Nothing in Zarf or UDS examples covers standing up the cluster itself.
Customers receive an OS and need a supported, hardened Kubernetes before
`zarf init`. RKE2 ships an airgap tarball, a CIS hardening profile and
Canal, and is what Zarf's own docs test against.

## Decision

```
OS (customer) → RKE2 airgap install → zarf init → zarf package deploy
```

- `rke2/` holds: pinned version, airgap image tarball, install script,
  hardened `config.yaml` (`profile: cis`, `secrets-encryption: true`,
  `cni: canal`, `disable: rke2-ingress-nginx`), a local-path-provisioner
  manifest dropped into the RKE2 manifests dir and set as default
  StorageClass.
- Stateful pods and the Zarf registry are pinned to the storage node via
  `nodeSelector`.
- The install script creates the `etcd` user/group and applies the CIS
  sysctls **before** `systemctl start rke2-server`, or first boot fails.
- Zarf init package version is pinned to match the `zarf` CLI; the pinned
  Zarf agent/registry must admit under PSA `restricted` on a CIS cluster.
- Canal enforces `NetworkPolicy`, which the deny-all-egress design relies
  on.

## Consequences

- Out of scope, stated in PREREQUISITES.md: host OS STIG, etcd snapshot
  off-node cadence, multi-node HA.
- The RKE2 CI gate needs a VM, not kind; it runs nightly / on `rke2/`
  changes and includes `kube-bench` for the RKE2 CIS profile.
- Single-node storage pinning means the storage node is a single point of
  failure; acceptable for the demo and documented.
