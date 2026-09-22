# 0015 — Custom Zarf init package with an `rke2` component

**Status:** Accepted — implemented and verified 2026-09-21
**Date:** 2026-09-20

## Context

Zarf's upstream init package (`kind: ZarfInitConfig`) already contains a
distro component: `k3s`, made of `files:` (binary, systemd unit, airgap
image tarball) and `onDeploy` actions (host checks, `systemctl enable`,
start), followed by `zarf-injector`, `zarf-seed-registry`,
`zarf-registry`, `zarf-agent` and the optional `git-server`. Zarf only
connects to a cluster when a component needs one, so a `files` + `actions`
component runs on a bare host. Verified against Zarf v0.75.0
(`zarf.yaml` and `packages/distros/k3s/zarf.yaml` in the zarf repo).
Defense Unicorns' `uds-rke2` follows the same pattern.

## Decision

`rke2/zarf.yaml` is a **custom init package**: an `rke2` component in the
slot where upstream puts `k3s`, followed by the upstream init components
imported by name from `oci://ghcr.io/zarf-dev/packages/init:<pinned version>`
(import syntax verified at implementation time against the pinned Zarf;
the README's "0.32.0+" was long stale).

The `rke2` component:

- `files:` - `rke2.linux-amd64.tar.gz`, `rke2-images-core.linux-amd64.tar.zst`,
  `rke2-images-canal.linux-amd64.tar.zst`, `sha256sum-amd64.txt`, `install.sh`,
  the local-path-provisioner manifest + image tarball, `.cache.json`,
  `10-platform.yaml` (drop-in). RPM flavor adds `rke2-selinux`/`container-selinux`.
- `actions.onDeploy.before` - host preflight: architecture, hostname,
  OS family vs flavor, SELinux/firewalld state as the policy profile
  expects, free disk, and refuse otherwise. Never configures the OS beyond
  what the profile asks (`etcd` user + CIS sysctls only under `cis`).
- `actions.onDeploy.after` - `INSTALL_RKE2_ARTIFACT_PATH=... sh install.sh`,
  write drop-ins, `systemctl enable --now rke2-server`, wait for node Ready
  and the local-path StorageClass, export the kubeconfig for the following
  components.
- Variables: `RKE2_ROLE` (`server`/`agent`), `RKE2_SERVER_URL`,
  `RKE2_TOKEN`, `RKE2_TLS_SAN`, `POLICY_PROFILE`. The factory uses
  `server` on one node; the parameters exist for the clusters it builds.
- Upstream Zarf registry component overridden to use a PVC (local-path)
  instead of hostPath.

Operator story on the target host:

```
zarf init --confirm --set POLICY_PROFILE=cis ...        # RKE2 + local-path + Zarf registry/agent
zarf package deploy clusterfactory-policy-cis-*.tar.zst  # denies, PSA config, audit policy
zarf package deploy clusterfactory-*.tar.zst --key cosign.pub   # preflight + forge
```

## Verified 2026-09-21

`rke2/zarf.yaml` built on the connected staging host (`hack/build-init-package.sh`,
897 MB, Zarf checksums every file at create; upstream components imported from
`oci://ghcr.io/zarf-dev/packages/init:v0.75.0` with upstream's create-time values
in `rke2/zarf-config.toml`). On a bare Rocky 9.8 host with SELinux enforcing and
no route to the internet, `zarf init --confirm` went from nothing to a Ready RKE2
`v1.36.4+rke2r1` node with local-path (default), Zarf registry and agent in
**3m39s**; the forge package then deployed and passed the full gate (Kaniko build
pushed to Nexus, egress 000). The whole offline kit is `zarf`,
`zarf-init-amd64-v0.75.0.tar.zst`, `zarf-package-clusterfactory-*.tar.zst`.

Two host facts the component carries because the air-gapped test found them:
the local-path helper pod needs the `busybox` archive loaded, and the provisioner
directory must be labelled `container_file_t`.

## Consequences

- No nested `zarf` calls; no separate "platform package" (ADR 0014's
  first proposal is superseded by this).
- RKE2 images never pass through the Zarf registry; application images
  always do.
- The init package is tested by the nightly runner-native RKE2 gate
  (ADR 0014); it cannot be tested on kind.
- Zarf version, RKE2 version and the init package version are pinned
  together; Renovate bumps them one at a time.

## Amendment 2026-09-21: the init package carries the forge

The init package imports the root package's `preflight` and `clusterfactory`
components after `zarf-agent` (same flavor; one home for pins and values). One
file, one command: `zarf init --confirm --key cosign.pub` on a bare host gives
RKE2, the Zarf registry and the wired forge. Zarf names a flavored init package
`zarf-init-<arch>-<version>-<flavor>.tar.zst` and `zarf init` has no flavor
flag, so the build renames it to the canonical name.

The forge-only package stays: it is the artifact for clusters the customer
brings, and the upgrade path for everyone — Helm release names are the chart
names, not derived from the package, so the forge package upgrades releases
the all-in-one created. A second `zarf init` is refused by the host preflight
("RKE2 already running") on purpose; RKE2 upgrades are a separate, manual
procedure (ADR 0014 Q9).

Versions are coupled in the all-in-one (RKE2, Zarf, forge): every forge change
ships a new 2 GB file. Accepted — the alternative (customer assembles two files)
is exactly what the single-file story removes. CI installs from the all-in-one
of the previous `main` build and upgrades with the forge package under test, so
both paths are exercised on every change; the nightly gate runs the release
exactly as a customer would.
