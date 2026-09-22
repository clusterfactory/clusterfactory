# Lessons: things that will bite the next person

All handled in the repo; all worth knowing before you change something.
The narrative of how the package came to be is in the 0.4.0 entry of
[`CHANGELOG.md`](../CHANGELOG.md); the decisions are in [`adr/`](../adr/README.md).

## Zarf, the apps, the platform

**Zarf**
- Rejects multi-arch *index* digests; pin the linux/amd64 *manifest* digest
  (`hack/pin-images.sh`). Renovate must not pin docker digests.
- Namespaces that exist before `zarf init` get `zarf.dev/agent=ignore`: the
  agent never rewrites their images and the node quietly pulls from the
  internet. CI creates namespaces after init and asserts every image is
  served by the Zarf registry.
- Package templates (`###ZARF_PKG_TMPL_*###`) are substituted only in
  `zarf.yaml`, not in values files; route them through `constants:`.
  `setVariables` is not allowed in `onCreate`.
- The "pull from the Docker daemon" fallback tags/untags images by id while
  pulling, races itself with several images in flight ("reference does not
  exist") and deletes the images afterwards. Locally built images go through
  a throwaway registry (`make local-registry`, `localhost:5001`).
- The API server is not a pod: deny-all-egress must allow it by `ipBlock`,
  resolved from the `kubernetes` EndpointSlice at deploy time (a Zarf
  `onDeploy.before` action). If the node IP changes, every such rule goes
  stale until the next deploy.

**Jenkins**
- `agent.restrictedPssSecurityContext: true` merges `capabilities.drop: ALL`
  into *every* container of a pod template. Off; contexts are explicit.
- The Kubernetes plugin injects its own default `inbound-agent` tag unless
  the pod YAML names a `jnlp` container. Pinned.
- `container()` needs a shell: use the `-debug` Kaniko image.
- CSRF crumbs are bound to the session cookie (the wire engine keeps a jar).
- `jenkins-plugin-cli` resolves transitive dependencies against the live
  update centre; a lock re-resolved from `plugins.txt` drifts within hours.
  `plugins.lock` is the source of truth; `make plugins-update` refreshes it.

**Gitea**
- Chart 12 renamed redis to valkey in values.
- Single instance on one RWO volume with the LevelDB queue must use
  `strategy: Recreate`; `RollingUpdate` with 100% surge crash-loops on the
  queue lock and every in-place upgrade fails.
- API tokens are not re-readable; the wire engine persists the one it mints.

**Nexus CE**
- The Docker connector answers 403 until the `DockerToken` realm is active
  **and** the CE EULA is accepted via REST. EULA acceptance is an operator
  variable (`NEXUS_ACCEPT_CE_EULA`), never a default.

**Kubelet / images**
- A kubelet caches by tag with `IfNotPresent`; rebuilding a locally built
  image under the same tag silently runs old bits. Tags are content hashes
  of the payload.

**Runners / registries**
- On Linux, bind-mounted directories must be writable by the container's uid
  (jenkins-plugin-cli runs as 1000); macOS hid this.
- `umask 077` set for writing a signing key leaks into the rest of the shell
  step. Use a subshell.
- `gcr.io` is retired ("requires billing"): `scorecard-action` v2.4.0 broke,
  and the Kaniko executor is published only there (ADR 0009 risk).

**Rocky 9 / SELinux**
- local-path-provisioner's directory must be `container_file_t`, or its helper
  pod cannot `mkdir` and every PVC (the Zarf registry's first) stays Pending.
- `sudo`'s `secure_path` on EL9 excludes `/usr/local/bin`: a non-login shell
  over SSH does not find `zarf`. Export PATH or call it by path.
- `rke2-uninstall.sh` leaves the CNI's host state behind. Calico's
  `blackhole 10.42.0.0/24` route makes every pod IP answer EINVAL on the next
  install (CoreDNS never Ready under flannel). Drop routes and
  `cni0`/`flannel.*`/`vxlan.calico` explicitly; the init package's remove
  action and `hack/airgap-install.sh down` do.
- The upstream init package *offers* an optional `k3s` component. Saying yes
  on an RKE2 host uninstalls k3s over it and leaves legacy iptables tables
  the host cannot list; only a reboot fixes it. The custom init package has
  no such slot; never run the upstream init on an RKE2 host interactively.

**Air gap plumbing**
- Zarf's registry cannot serve RKE2's own bootstrap images (chicken and egg):
  RKE2 images travel as tarballs in `/var/lib/rancher/rke2/agent/images/`,
  everything after that comes from the Zarf registry.
- local-path-provisioner's helper pod pulls `busybox`; ship that archive too.
- Google's IAP tunnel drops multi-gigabyte `scp` uploads ("Broken pipe" at
  ~1 GB). Scripts go over the tunnel; packages go through a bucket the VM
  can reach privately.
- The `rke2-images-<cni>` tarball is imported by containerd on start and
  pinned against GC via `.cache.json`; the manifest images for local-path
  are not, load them as docker-archives.


## What the gates verify (so you can trust green)

`tests/deploy-check.sh`: workload pods Ready; every container image from
the Zarf registry; Gitea/Jenkins/Nexus answer; anonymous docker pull 401;
cf-config credentials accepted by both APIs; all top-level plugins active;
wire Job converged (and, with `EXPECT_IDEMPOTENT=1`, only `ok`); the demo
pipeline build with its own number succeeds and its tag exists in Nexus;
`example.com` returns `000`. The upgrade path wraps this with
`tests/snapshot-state.sh` / `tests/compare-state.py` around an N-1→N deploy.
`tests/preflight-negative.sh` proves the preflight refuses a broken cluster.
