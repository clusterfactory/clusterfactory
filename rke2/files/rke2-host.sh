#!/usr/bin/env bash
# Runs on the target host from the rke2 init component (root). Everything it
# needs is already on disk; there is no network.
set -euo pipefail
A=/root/rke2-artifacts
ROLE="${RKE2_ROLE:-server}"
cd "$A"
grep -E 'rke2\.linux-amd64\.tar\.gz' sha256sum-amd64.txt | sha256sum -c --quiet

echo "== SELinux policy RPMs"
if [ "$(getenforce 2>/dev/null || echo Disabled)" != Disabled ] && [ -d rpm ]; then
  rpm -q rke2-selinux >/dev/null 2>&1 || dnf -q -y install rpm/*.rpm >/dev/null 2>&1 || rpm -Uvh --replacepkgs rpm/*.rpm
fi
mkdir -p /opt/local-path-provisioner
semanage fcontext -a -t container_file_t "/opt/local-path-provisioner(/.*)?" 2>/dev/null || semanage fcontext -m -t container_file_t "/opt/local-path-provisioner(/.*)?" 2>/dev/null || true
restorecon -R /opt/local-path-provisioner 2>/dev/null || true

echo "== role-specific config"
mkdir -p /etc/rancher/rke2/config.yaml.d
if [ "$ROLE" = agent ]; then
  printf 'server: %s\ntoken: %s\n' "$RKE2_SERVER_URL" "$RKE2_TOKEN" > /etc/rancher/rke2/config.yaml.d/20-join.yaml
  chmod 600 /etc/rancher/rke2/config.yaml.d/20-join.yaml
  rm -f /var/lib/rancher/rke2/server/manifests/local-path-storage.yaml
elif [ -n "${RKE2_TLS_SAN:-}" ]; then
  printf 'tls-san:\n  - %s\n' "$RKE2_TLS_SAN" > /etc/rancher/rke2/config.yaml.d/20-server.yaml
fi
if [ -n "${POLICY_PROFILE:-}" ] && [ -f "$A/policy/${POLICY_PROFILE}/50-policy.yaml" ]; then
  cp "$A/policy/${POLICY_PROFILE}/50-policy.yaml" /etc/rancher/rke2/config.yaml.d/50-policy.yaml
fi

echo "== rke2 install (offline)"
INSTALL_RKE2_ARTIFACT_PATH="$A" INSTALL_RKE2_TYPE="$ROLE" sh "$A/install.sh"
systemctl enable --now "rke2-$ROLE"
[ "$ROLE" = server ] || { echo "agent started"; exit 0; }

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH="$PATH:/var/lib/rancher/rke2/bin"
for _ in $(seq 1 120); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
kubectl get nodes
kubectl -n kube-system rollout status deploy/rke2-coredns-rke2-coredns --timeout=300s
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s
kubectl get storageclass | grep -q 'local-path (default)'
# the following init components (injector, registry, agent) use this kubeconfig
mkdir -p /root/.kube && cp /etc/rancher/rke2/rke2.yaml /root/.kube/config && chmod 600 /root/.kube/config
echo "== rke2 ready"
