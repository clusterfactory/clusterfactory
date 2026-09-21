#!/usr/bin/env bash
# Stage every artifact an air-gapped install needs into a GCS bucket (or a
# directory). Runs on a CONNECTED machine (CI hosted runner or a laptop).
#   hack/airgap-fetch.sh gs://bucket/v1     # or a local dir
set -euo pipefail
DEST="$1"
RKE2_VERSION="${RKE2_VERSION:-v1.36.4+rke2r1}"
ZARF_VERSION="${ZARF_VERSION:-v0.75.0}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.37}"
PACKAGE="${PACKAGE:-}"          # path to zarf-package-clusterfactory-*.tar.zst (+ cosign.pub next to it), optional
W=$(mktemp -d)
cd "$W"
U="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
for f in rke2-images-core.linux-amd64.tar.zst rke2-images-canal.linux-amd64.tar.zst rke2-images-flannel.linux-amd64.tar.zst rke2.linux-amd64.tar.gz sha256sum-amd64.txt; do
  curl -sSfL -o "$f" "$U/$f"
done
curl -sfL https://get.rke2.io -o install.sh
sha256sum -c --ignore-missing sha256sum-amd64.txt
# RPM flavor: the tarball install on an SELinux host needs the rke2-selinux
# policy (RKE2 docs: "SELinux RPM - required for airgapped nodes"). Resolve
# rke2-selinux + container-selinux with dependencies using dnf on this
# (Rocky/RHEL 9) staging host - no containers involved.
mkdir -p rpm
if command -v dnf >/dev/null; then
  sudo tee /etc/yum.repos.d/rancher-rke2-common.repo >/dev/null <<R
[rancher-rke2-common]
name=Rancher RKE2 common
baseurl=https://rpm.rancher.io/rke2/stable/common/centos/9/noarch
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
R
  sudo dnf -q -y install dnf-plugins-core >/dev/null 2>&1 || true
  sudo dnf -q -y download --resolve --destdir "$W/rpm" rke2-selinux container-selinux >/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$W/rpm"
else
  echo "warning: no dnf here - SELinux RPMs not staged (run this on a Rocky/RHEL 9 host)"
fi
ls rpm
LP="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
curl -sSfL "$LP" -o local-path-storage.yaml
LP_IMG=$(grep -o 'image: rancher/local-path-provisioner:[^ ]*' local-path-storage.yaml | head -1 | cut -d' ' -f2)
BB_IMG=$(grep -o 'image: busybox' local-path-storage.yaml | head -1 | cut -d' ' -f2)
# default class + pinned images in the manifest we ship
python3 - <<'PY'
import re
p='local-path-storage.yaml'; s=open(p).read()
s=s.replace('kind: StorageClass\nmetadata:\n  name: local-path\n','kind: StorageClass\nmetadata:\n  name: local-path\n  annotations:\n    storageclass.kubernetes.io/is-default-class: "true"\n')
open(p,'w').write(s)
PY
skopeo copy --override-os linux --override-arch amd64 "docker://docker.io/$LP_IMG" "docker-archive:local-path-provisioner.tar:$LP_IMG"
skopeo copy --override-os linux --override-arch amd64 "docker://docker.io/library/busybox:1.37.0" "docker-archive:busybox.tar:busybox:latest"
curl -sSfL "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf_${ZARF_VERSION}_Linux_amd64" -o zarf && chmod +x zarf
curl -sSfLO "https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/zarf-init-amd64-${ZARF_VERSION}.tar.zst"
[ -n "$PACKAGE" ] && cp "$PACKAGE" . && cp "$(dirname "$PACKAGE")/cosign.pub" . 2>/dev/null || true
sha256sum -- * > SHA256SUMS
ls -lh
case "$DEST" in
  gs://*) gcloud storage cp -r ./* "$DEST/" ;;
  *) mkdir -p "$DEST" && cp -r ./* "$DEST/" ;;
esac
echo "staged to $DEST"
