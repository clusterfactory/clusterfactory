#!/usr/bin/env bash
# Stand up the CI test cluster (uds-way.md §11 gate 3):
#   kind (default CNI off) + Calico, then zarf init, THEN default-deny
#   egress in every namespace the package touches.
#
# Order matters: namespaces that exist before `zarf init` are labelled
# zarf.dev/agent=ignore, the agent never rewrites their images to the
# in-cluster registry, and the node quietly pulls from the internet -
# the airgap test passes without testing anything. tests/deploy-check.sh
# asserts every image comes from the Zarf registry to catch a regression.
#
# Usage: bundle/up.sh <path-to-zarf-init-package-dir>
#   (zarf init looks for zarf-init-<arch>-<version>.tar.zst in that dir / cwd)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# renovate: datasource=github-releases depName=projectcalico/calico
CALICO_VERSION="${CALICO_VERSION:-v3.29.3}"
CLUSTER="clusterfactory-ci"
INIT_DIR="${1:-.}"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config "$HERE/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "== installing Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null 2>&1
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

echo "== zarf init"
(cd "$INIT_DIR" && zarf init --confirm --no-color)

echo "== default-deny egress"
# The API server is reached at its node IP after DNAT, so allow it by ipBlock.
API_IP=$(kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
API_PORT=$(kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}')
echo "   apiserver ${API_IP}:${API_PORT}"
for ns in default zarf clusterfactory cf-build argocd; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  sed -e "s#__APISERVER_IP__#${API_IP}#" -e "s#__APISERVER_PORT__#${API_PORT}#" "$HERE/default-deny-egress.yaml" \
    | kubectl apply -n "$ns" -f - >/dev/null
done
kubectl get networkpolicy -A
echo "== cluster ready: kind-${CLUSTER}"
