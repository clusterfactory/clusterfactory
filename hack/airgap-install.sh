#!/usr/bin/env bash
# Air-gapped RKE2 + clusterfactory install from a staged artifact set.
# Runs as root on a host with NO internet; the only source is ARTIFACT_DIR,
# filled from the GCS bucket (Private Google Access) by hack/airgap-fetch.sh
# or from a USB stick. This is the manual form of what the rke2 init
# component (ADR 0015) automates; the CI gate runs exactly this.
#
#   ARTIFACT_DIR=/root/artifacts hack/airgap-install.sh up       # RKE2 + local-path + zarf init
#   ARTIFACT_DIR=/root/artifacts hack/airgap-install.sh deploy   # forge package + gate
#   hack/airgap-install.sh down                                  # uninstall everything
set -euo pipefail
A="${ARTIFACT_DIR:-/root/artifacts}"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="$PATH:/var/lib/rancher/rke2/bin:$A"
CNI="${CNI:-canal}"

up() {
  if systemctl is-active --quiet rke2-server 2>/dev/null || [ -d /var/lib/rancher/rke2 ]; then
    echo "== previous RKE2 present - removing for a clean slate"; down
  fi
  echo "== host: $(hostname) $(. /etc/os-release; echo "$PRETTY_NAME") selinux=$(getenforce) egress-test: github.com $(curl -sS -m 5 -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null || echo 000)"
  cd "$A"
  sha256sum -c --ignore-missing sha256sum-amd64.txt | grep -v OK && { echo "checksum mismatch"; exit 1; } || echo "rke2 artifacts: checksums OK"

  echo "== images for containerd (imported on rke2 start, pinned against GC)"
  mkdir -p /var/lib/rancher/rke2/agent/images
  # every image the local-path manifest references (provisioner + the busybox helper pod)
  cp rke2-images-core.linux-amd64.tar.zst "rke2-images-${CNI}.linux-amd64.tar.zst" local-path-provisioner.tar busybox.tar /var/lib/rancher/rke2/agent/images/
  touch /var/lib/rancher/rke2/agent/images/.cache.json

  echo "== config drop-ins"
  mkdir -p /etc/rancher/rke2/config.yaml.d
  cat > /etc/rancher/rke2/config.yaml.d/10-platform.yaml <<YAML
cni: ${CNI}
embedded-registry: true
disable:
  - rke2-metrics-server
  - rke2-snapshot-controller
  - rke2-snapshot-controller-crd
YAML
  cat > /etc/rancher/rke2/registries.yaml <<'YAML'
mirrors:
  "*":
YAML

  echo "== local-path-provisioner via the RKE2 manifests dir (SELinux: container_file_t on its data dir)"
  mkdir -p /var/lib/rancher/rke2/server/manifests /opt/local-path-provisioner
  cp local-path-storage.yaml /var/lib/rancher/rke2/server/manifests/
  semanage fcontext -a -t container_file_t "/opt/local-path-provisioner(/.*)?" 2>/dev/null || semanage fcontext -m -t container_file_t "/opt/local-path-provisioner(/.*)?"
  restorecon -R /opt/local-path-provisioner

  if [ "$(getenforce 2>/dev/null)" = Enforcing ] && [ -d "$A/rpm" ]; then
    echo "== SELinux policy RPMs (rke2-selinux, container-selinux) from the artifact set"
    dnf -q -y install "$A"/rpm/*.rpm >/dev/null 2>&1 || rpm -Uvh --replacepkgs "$A"/rpm/*.rpm
  fi
  echo "== rke2 install (offline, INSTALL_RKE2_ARTIFACT_PATH)"
  INSTALL_RKE2_ARTIFACT_PATH="$A" sh install.sh
  systemctl enable --now rke2-server
  for i in $(seq 1 90); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
  kubectl get nodes
  timeout 300 kubectl -n kube-system rollout status deploy/rke2-coredns-rke2-coredns
  timeout 300 kubectl -n local-path-storage rollout status deploy/local-path-provisioner
  kubectl get storageclass | grep -q 'local-path (default)' || { echo "local-path not default"; exit 1; }

  echo "== zarf init"
  install -m 755 "$A/zarf" /usr/local/bin/zarf
  cd "$A" && timeout 900 zarf init --confirm --no-color 2>&1 | grep -E "ERR|init complete"
  kubectl get pods -n zarf
}

deploy() {
  cd "$A"
  PKG=$(ls zarf-package-clusterfactory-*.tar.zst | head -1)
  [ -f cosign.pub ] && KEY="--key cosign.pub" || KEY=""
  echo "== deploy $PKG $KEY"
  timeout 1200 zarf package deploy "$PKG" $KEY --confirm --no-color --timeout 15m --set NEXUS_ACCEPT_CE_EULA=true 2>&1 | grep -E "ERR|Verified|wire engine|health checks$" | tail -5
}

down() {
  (rke2-uninstall.sh || /usr/local/bin/rke2-uninstall.sh) >/dev/null 2>&1 || true
  rm -rf /var/lib/rancher /etc/rancher /opt/local-path-provisioner
  echo "clean"
}

case "${1:-}" in up) up ;; deploy) deploy ;; down) down ;; *) echo "usage: $0 up|deploy|down"; exit 2 ;; esac
