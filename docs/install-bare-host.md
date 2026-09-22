# Installing clusterfactory on a new, air-gapped VM — by hand

One file, one command. This is the manual path a person walks; CI walks the
same one on every change (`.github/workflows/ci.yaml`, job `rke2`).

## 1. Where the `.tar.zst` comes from

| Source | What you get | When |
|---|---|---|
| **GitHub Release** `https://github.com/clusterfactory/clusterfactory/releases/tag/v<version>` | `zarf-init-amd64-<zarf>.tar.zst` (all-in-one, ~2.1 GB), `zarf-package-clusterfactory-amd64-<version>-upstream.tar.zst` (forge only, ~1.2 GB), `cosign.pub`, `clusterfactory-<version>-SHA256SUMS`, SBOMs. Signed. | Always prefer this. |
| **CI run artifacts** (Actions → the run → *Artifacts*: `zarf-init-upstream`, `zarf-package-upstream`) | The same two files for any commit; signed when built from this repo. Kept 5 days. | Testing an unreleased change. |
| **Build it yourself** on a connected Linux box with docker, zarf, helm, skopeo, make: `make package && make init-package` | The same two files in `build/`, unsigned unless you pass `SIGNING_KEY`. | You forked it (see README "Fork it"). |

The Zarf CLI comes from Zarf's releases; its version is in the init file name:
`https://github.com/zarf-dev/zarf/releases/download/<zarf>/zarf_<zarf>_Linux_amd64`.

Fetch on a connected machine — literally, for the current release
`v0.4.0-rc.2` (the first one that carries the all-in-one file; `v0.4.0-rc.1`
and older have only the forge-only package):

```bash
mkdir clusterfactory-0.4.0-rc.2 && cd clusterfactory-0.4.0-rc.2
curl -sSfLO https://github.com/clusterfactory/clusterfactory/releases/download/v0.4.0-rc.2/zarf-init-amd64-v0.75.0.tar.zst
curl -sSfLO https://github.com/clusterfactory/clusterfactory/releases/download/v0.4.0-rc.2/cosign.pub
curl -sSfLO https://github.com/clusterfactory/clusterfactory/releases/download/v0.4.0-rc.2/clusterfactory-0.4.0-rc.2-SHA256SUMS
curl -sSfL  https://github.com/zarf-dev/zarf/releases/download/v0.75.0/zarf_v0.75.0_Linux_amd64 -o zarf
sha256sum -c clusterfactory-0.4.0-rc.2-SHA256SUMS --ignore-missing
```

Expected:

```
zarf-init-amd64-v0.75.0.tar.zst: OK
cosign.pub: OK
```

(`zarf` itself is not in our SHA256SUMS; Zarf publishes its own checksums at
`https://github.com/zarf-dev/zarf/releases/download/v0.75.0/checksums.txt`.)

You end up with four files, about 2.3 GB:

```
clusterfactory-0.4.0-rc.2/
├── zarf                              188 MB   the CLI, v0.75.0
├── zarf-init-amd64-v0.75.0.tar.zst   2.1 GB   RKE2 + Zarf + the forge, signed
├── cosign.pub                        178 B    the project's public key
└── clusterfactory-0.4.0-rc.2-SHA256SUMS
```

For an unreleased commit instead: `gh run download <run-id> -n zarf-init-upstream`
(Actions → the run → Artifacts) and take `cosign.pub` from the repo at that commit.

## 2. The VM

Requirements (checked by the package; it refuses, it does not fix):

- Rocky Linux / RHEL 9, x86_64. SELinux enforcing is fine (policy RPMs are inside).
- 4+ CPUs, 16 GB+ RAM (Jenkins + Nexus + a Kaniko build), 20 GB+ free under `/var/lib`
  (the package unpacks ~6 GB of images; 80 GB disk is comfortable).
- root, `nm-cloud-setup` not enabled (RKE2 requirement; on cloud images:
  `systemctl disable --now nm-cloud-setup.service nm-cloud-setup.timer` and reboot).
- No RKE2/k3s already on it. No internet needed at any point.

Example — GCP, no public IP, no NAT (i.e. genuinely offline; reach it with IAP):

```bash
gcloud compute instances create cf-host --zone europe-west1-b \
  --machine-type n2-custom-16-32768 --image-family rocky-linux-9 --image-project rocky-linux-cloud \
  --boot-disk-size 80GB --no-address --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
# copy files through the IAP tunnel (small ones only; the 2 GB file goes via a bucket or a disk image):
gcloud compute scp --tunnel-through-iap zarf cosign.pub clusterfactory-0.4.0-rc.2-SHA256SUMS cf-host:/tmp/ --zone europe-west1-b
```

Any other VM (an AWS EL9 jumpbox was the first real one) works the same;
only the transfer differs.

## 3. Transfer

Put the four files in one directory on the host, e.g. `/root/clusterfactory-0.4.0-rc.2/`:
USB, `scp` through a jump host, a bucket the VM can reach privately — whatever
the gap allows. Re-verify after the transfer: `sha256sum -c … --ignore-missing`.

## 4. Install

As root, on the host:

```bash
cd /root/clusterfactory-0.4.0-rc.2
install -m 755 zarf /usr/local/bin/zarf
export PATH=$PATH:/usr/local/bin          # sudo's secure_path lacks /usr/local/bin on EL9
zarf init --confirm --key cosign.pub \
  --set NEXUS_ACCEPT_CE_EULA=true \
  --set GITEA_ADMIN_PASSWORD='…' --set JENKINS_ADMIN_PASSWORD='…' --set NEXUS_ADMIN_PASSWORD='…'
```

What happens, in order (≈8 minutes on 16 vCPU):

1. `preflight ok: Rocky Linux 9.8 … selinux=Enforcing` — host checks.
2. RKE2 v1.36.4+rke2r1 from tarballs; SELinux RPMs; local-path StorageClass; `== rke2 ready`.
3. Zarf injector → seed registry → registry → agent (`zarf` namespace).
4. Cluster preflight (NetworkPolicy enforced, default StorageClass binds, PSA, DNS, registry, API endpoint).
5. cf-config → Gitea → Jenkins → Nexus → wire engine: `wire engine: cf-wire-engine-r1=…Complete:True`.
6. `init complete.`

## 5. Verify and use

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes; kubectl get pods -A
kubectl port-forward -n clusterfactory svc/gitea-http 3000:3000   # http://localhost:3000  gitea-admin
kubectl port-forward -n clusterfactory svc/jenkins    8080:8080   # http://localhost:8080  admin
kubectl port-forward -n clusterfactory svc/nexus      8081:8081   # http://localhost:8081  admin
```

Full gate (what CI runs, incl. a real Kaniko build pushed to Nexus): copy
`tests/deploy-check.sh` and `jenkins/plugins.txt` (into `jenkins/` next to it)
from the repo and run `tests/deploy-check.sh clusterfactory`.

## 6. Upgrade

Deploy the forge-only package of the newer release over it; the all-in-one is
not re-run (its host preflight refuses a host that already has RKE2):

```bash
curl -sSfLO https://github.com/clusterfactory/clusterfactory/releases/download/v0.4.0/zarf-package-clusterfactory-amd64-0.4.0-upstream.tar.zst
# … carry it across …
zarf package deploy zarf-package-clusterfactory-amd64-0.4.0-upstream.tar.zst \
  --key cosign.pub --confirm --set NEXUS_ACCEPT_CE_EULA=true
```

## 7. Remove

`zarf package remove init --confirm` removes the forge, then RKE2 and its
state. For a host you want to reuse for another install, also make sure the
CNI left nothing behind (the RKE2 uninstaller does not): no `blackhole 10.42.…`
route in `ip route`, no `cni0`/`flannel.*`/`vxlan.calico` links — the package's
remove action does this, `hack/airgap-install.sh down` does too.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `zarf: command not found` under `sudo` | EL9 `secure_path` excludes `/usr/local/bin`; `export PATH=$PATH:/usr/local/bin` or `sudo /usr/local/bin/zarf …`. |
| `RKE2 already running on this host` | Intentional refusal. Remove first (§7), or use the forge-only package if the cluster is meant to stay. |
| `nm-cloud-setup is enabled` | Disable it and reboot (RKE2 requirement on cloud images). |
| local-path pods `CrashLoopBackOff`, PVC Pending, SELinux enforcing | `/opt/local-path-provisioner` must be `container_file_t`; the package labels it — if the dir pre-existed with another label: `restorecon -R /opt/local-path-provisioner`. |
| CoreDNS never Ready, probes fail with `connect: invalid argument` | A `blackhole 10.42.0.0/24` route from a previous Calico/Canal install. `ip route del blackhole 10.42.0.0/24`, restart `rke2-server`. |
| Zarf pulls images from the internet after init | A namespace existed before `zarf init` and got `zarf.dev/agent=ignore`. Start from a clean host. |
