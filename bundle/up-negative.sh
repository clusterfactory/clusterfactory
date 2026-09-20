#!/usr/bin/env bash
# The *negative* cluster for the preflight test (ADR 0014): kind with the
# default CNI disabled and plain flannel - no NetworkPolicy enforcement -
# and no default StorageClass. zarf init runs so the preflight can get its
# test image. Usage: bundle/up-negative.sh <dir containing zarf-init-*.tar.zst>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INIT_DIR="${1:-.}"
CLUSTER=clusterfactory-neg
# renovate: datasource=github-releases depName=flannel-io/flannel
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.9}"
# renovate: datasource=github-releases depName=containernetworking/plugins
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.9.1}"

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config "$HERE/kind-config-flannel.yaml" --wait 120s
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "== CNI plugins (kind's node image lacks 'bridge', which flannel delegates to)"
curl -sSfL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" -o /tmp/cni-plugins.tgz
# (streamed over exec: docker cp into the node's tmpfs /tmp is unreliable)
docker exec -i "${CLUSTER}-control-plane" tar -C /opt/cni/bin -xz < /tmp/cni-plugins.tgz

echo "== flannel ${FLANNEL_VERSION}"
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" >/dev/null
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=300s

echo "== zarf init"
kubectl get secret zarf-state -n zarf >/dev/null 2>&1 || (cd "$INIT_DIR" && zarf init --confirm --no-color)

echo "== no default StorageClass"
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class- >/dev/null 2>&1 || true
echo "== negative cluster ready: kind-$CLUSTER"
