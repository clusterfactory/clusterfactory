# 0011 — RKE2 with CIS profile, Canal CNI, local-path storage

**Status:** Accepted (amended 2026-09-20; delivery superseded by ADR 0015)
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

## Amendment 2026-09-20 — decisions from ADR 0014

- Delivery is a custom Zarf init package with an `rke2` component
  (ADR 0015), not a script.
- Pin the `v1.36.x+rke2r1` line (`v1.36.4+rke2r1`); Traefik stays enabled
  (ADR 0010 amendment); `core` + `canal` tarballs, not the all-in-one.
- Configuration by drop-ins in `/etc/rancher/rke2/config.yaml.d/`:
  `10-platform.yaml` (platform) and `50-policy.yaml` (policy profile).
  `profile: cis`, the `etcd` user and the CIS sysctls belong to the `cis`
  profile (ADR 0016), not to the platform.
- `tls-san` is a stable DNS name; join variables exist even though the
  factory is single-node.
- local-path-provisioner is deployed from the RKE2 manifests directory into
  `kube-system` before Zarf's registry needs a PVC; the Zarf registry uses
  a local-path PVC, not hostPath.
- Upgrades: manual, etcd snapshot first, single-node downtime stated.

## Amendment 2026-09-20 — RKE2 air-gap install specifics

Facts from the RKE2 air-gap guide that shape `rke2/`:

- **Two artifacts, one directory.** `install.sh` runs offline with
  `INSTALL_RKE2_ARTIFACT_PATH=<dir>` holding `rke2.linux-amd64.tar.gz`,
  `rke2-images.linux-amd64.tar.zst` (or `-core` + a CNI-specific tarball)
  and `sha256sum-amd64.txt`. The whole directory is copied to every node;
  no curl on the offline host.
- **Image loading is per node, on every start.** Archives placed in
  `/var/lib/rancher/rke2/agent/images/` are imported at each RKE2 start,
  delaying the kubelet. An empty `.cache.json` in that directory (v1.33.1+)
  makes imports conditional on archive size/mtime. `rke2/` ships the
  `.cache.json` and documents the trade-off (pruned images are not
  re-imported automatically).
- **RKE2 images never go through Zarf.** They come from the RKE2 tarball;
  Zarf's registry serves only the application images. The doc's alternative
  loaders (private registry, Hauler, embedded registry mirror) are not used:
  the manual tarball is the fewest moving parts for one to three nodes.
- **Ingress.** RKE2 ≥ v1.36 defaults to Traefik instead of ingress-nginx;
  the package disables the packaged ingress either way
  (`disable: rke2-ingress-nginx` and, on ≥ 1.36, `rke2-traefik`) - access is
  port-forward (ADR 0010).
- **Upgrades** are manual (replace artifacts, restart) for now; the
  system-upgrade-controller route needs its images in a registry and is
  deferred.
- Pin: `v1.33.x+rke2r1` line (first with conditional imports); exact
  version in `rke2/VERSION`, digests via `sha256sum-amd64.txt`.

## Consequences

- Out of scope, stated in PREREQUISITES.md: host OS STIG, etcd snapshot
  off-node cadence, multi-node HA.
- The RKE2 CI gate needs a VM, not kind; it runs nightly / on `rke2/`
  changes and includes `kube-bench` for the RKE2 CIS profile.
- Single-node storage pinning means the storage node is a single point of
  failure; acceptable for the demo and documented.
