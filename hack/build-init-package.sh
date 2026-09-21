#!/usr/bin/env bash
# Build the clusterfactory init package (rke2/zarf.yaml) on a CONNECTED host.
# Resolves the checksums Zarf verifies at create time, produces the local-path
# files, then `zarf package create`. Output: zarf-init-amd64-<zarf version>.tar.zst
#   hack/build-init-package.sh [output-dir]      (needs zarf, skopeo, curl, python3)
set -euo pipefail
OUT="${1:-build}"
RKE2_VERSION=$(grep -A1 'name: RKE2_VERSION' rke2/zarf.yaml | tail -1 | awk '{print $2}')
ZARF_VERSION=$(awk '/^  version:/ {print $2; exit}' rke2/zarf.yaml)
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.37}"
U="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
W=$(mktemp -d)

echo "== checksums of the RKE2 release artifacts"
curl -sSfL "$U/sha256sum-amd64.txt" -o "$W/sums.txt"
sum() { grep " $1\$" "$W/sums.txt" | awk '{print $1}'; }
S_TARBALL=$(sum rke2.linux-amd64.tar.gz); S_CORE=$(sum rke2-images-core.linux-amd64.tar.zst); S_CANAL=$(sum rke2-images-canal.linux-amd64.tar.zst)
S_SUMS=$(sha256sum "$W/sums.txt" | awk '{print $1}')
for v in S_TARBALL S_CORE S_CANAL; do [ -n "${!v}" ] || { echo "missing checksum for $v"; exit 1; }; done

echo "== checksums of the SELinux RPMs (downloaded once here, again by zarf at create)"
rpm_sha() { curl -sSfL "$1" | sha256sum | awk '{print $1}'; }
S_RKE2_SELINUX=$(rpm_sha "$(grep -o 'https://rpm.rancher.io[^ ]*rke2-selinux[^ ]*\.rpm' rke2/zarf.yaml | head -1)")
S_CONTAINER_SELINUX=$(rpm_sha "$(grep -o 'https://dl.rockylinux.org[^ ]*container-selinux[^ ]*\.rpm' rke2/zarf.yaml | head -1)")

echo "== local-path-provisioner ${LOCAL_PATH_VERSION}: manifest (default class) + image archives"
curl -sSfL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" -o rke2/files/local-path-storage.yaml
python3 - <<'PY'
p='rke2/files/local-path-storage.yaml'; s=open(p).read()
s=s.replace('kind: StorageClass\nmetadata:\n  name: local-path\n','kind: StorageClass\nmetadata:\n  name: local-path\n  annotations:\n    storageclass.kubernetes.io/is-default-class: "true"\n')
open(p,'w').write(s)
PY
for img in $(grep -o 'image: *[^ ]*' rke2/files/local-path-storage.yaml | awk '{print $2}' | sort -u); do
  ref="$img"; case "$ref" in */*) ;; *) ref="docker.io/library/$ref" ;; esac; case "$ref" in *:*) ;; *) ref="$ref:latest" ;; esac
  name=$(basename "${ref%%:*}"); rm -f "rke2/files/${name}.tar"   # docker-archive cannot be overwritten
  skopeo copy --override-os linux --override-arch amd64 "docker://$ref" "docker-archive:rke2/files/${name}.tar:${ref}" >/dev/null
  echo "   $ref -> files/${name}.tar"
done

echo "== zarf package create"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
# zarf reads zarf-config.toml from the working directory: the upstream components' create-time templates
cd rke2
zarf package create . --confirm --no-color -o "$OUT" \
  --set SHA_RKE2_TARBALL="$S_TARBALL" --set SHA_RKE2_IMAGES_CORE="$S_CORE" --set SHA_RKE2_IMAGES_CANAL="$S_CANAL" \
  --set SHA_RKE2_SUMS="$S_SUMS" --set SHA_RKE2_SELINUX="$S_RKE2_SELINUX" --set SHA_CONTAINER_SELINUX="$S_CONTAINER_SELINUX" \
  ${SIGNING_KEY:+--signing-key "$SIGNING_KEY" --signing-key-pass "$SIGNING_KEY_PASS"} 2>&1 | grep -E "ERR|WRN|writing package|creating"
cd ..
ls -lh "$OUT"/zarf-init-*.tar.zst
