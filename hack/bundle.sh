#!/usr/bin/env bash
# hack/bundle.sh
# ──────────────────────────────────────────────────────────────────────────────
# Build an airgap bundle on an internet-connected machine.
#
# Usage:
#   ./hack/bundle.sh                  # outputs to ./dist/
#   ./hack/bundle.sh /path/to/output  # custom output dir
#
# Produces:
#   clusterfactory-airgap-<version>.tar.gz
#     ├── clusterfactory-<version>.tgz   — packaged Helm chart
#     ├── images.tar                     — all container images (docker save)
#     ├── values-airgap.yaml             — image overrides for a local registry
#     └── load.sh                        — run this on the airgapped machine
#
# Requirements: docker, helm
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-${ROOT_DIR}/dist}"
CHART_VERSION="$(grep '^version:' "${ROOT_DIR}/Chart.yaml" | awk '{print $2}')"
BUNDLE_NAME="clusterfactory-airgap-${CHART_VERSION}"
WORK_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"

log()  { echo ">> $*"; }
ok()   { echo "   OK  $*"; }
sep()  { echo; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

for cmd in docker helm; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

sep "Preparing bundle dir"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
log "Output: ${WORK_DIR}"

sep "Packaging Helm chart"
helm dependency update "${ROOT_DIR}" > /dev/null 2>&1
helm package "${ROOT_DIR}" -d "${WORK_DIR}" 2>/dev/null
ok "Packaged clusterfactory-${CHART_VERSION}.tgz"

sep "Collecting images"
# Images from rendered templates + known init containers
IMAGES=$(helm template cf "${ROOT_DIR}" 2>/dev/null \
  | python3 -c "
import sys, yaml

def extract_images(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'image' and isinstance(v, str) and v.strip():
                yield v.strip()
            else:
                yield from extract_images(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from extract_images(item)

images = sorted(set(
    img
    for doc in yaml.safe_load_all(sys.stdin)
    if doc
    for img in extract_images(doc)
))
for img in images:
    print(img)
")

log "Images to bundle:"
echo "$IMAGES" | while read -r img; do echo "    $img"; done

sep "Pulling images"
echo "$IMAGES" | while read -r img; do
  log "Pulling ${img}..."
  docker pull "${img}"
  ok "${img}"
done

sep "Writing images.txt"
echo "$IMAGES" > "${WORK_DIR}/images.txt"
ok "images.txt ($(echo "$IMAGES" | wc -l | tr -d ' ') images)"

sep "Saving images"
IMAGE_LIST=$(echo "$IMAGES" | tr '\n' ' ')
log "Running docker save..."
# shellcheck disable=SC2086
docker save ${IMAGE_LIST} -o "${WORK_DIR}/images.tar"
ok "images.tar ($(du -sh "${WORK_DIR}/images.tar" | cut -f1))"

sep "Writing values-airgap.yaml"
cat > "${WORK_DIR}/values-airgap.yaml" <<'EOF'
# values-airgap.yaml
# ──────────────────────────────────────────────────────────────────────────────
# Override image references to point at a local registry.
# Replace REGISTRY with your registry address (e.g. 192.168.1.10:5000).
#
# Usage:
#   helm upgrade --install cf ./clusterfactory-*.tgz \
#     --namespace cicd --create-namespace \
#     --values values-airgap.yaml
# ──────────────────────────────────────────────────────────────────────────────

wire:
  image: REGISTRY/alpine:3.19

runner:
  image: REGISTRY/gitea/act_runner:0.3.1
  dindImage: REGISTRY/docker:27-dind

gitea:
  image:
    registry: REGISTRY
    repository: gitea/gitea
    tag: "1.23.6-rootless"
  test:
    image:
      name: REGISTRY/busybox
      tag: "latest"

jenkins:
  controller:
    image:
      registry: REGISTRY
      repository: jenkins/jenkins
      tag: "2.541.3-jdk21"
    sidecars:
      configAutoReload:
        image:
          registry: REGISTRY
          repository: kiwigrid/k8s-sidecar
          tag: "2.5.0"
  helmtest:
    bats:
      image:
        registry: REGISTRY
        repository: bats/bats
        tag: "1.13.0"
EOF
ok "values-airgap.yaml written"

sep "Writing load.sh"
cat > "${WORK_DIR}/load.sh" <<'LOAD_EOF'
#!/usr/bin/env bash
# load.sh — run on the airgapped machine
# ──────────────────────────────────────────────────────────────────────────────
# Loads images and installs the clusterfactory Helm chart.
#
# Modes:
#   ./load.sh direct          — load images straight into Docker (docker-desktop / kind)
#   ./load.sh registry <url>  — retag + push to local registry, install with overrides
#
# Usage examples:
#   ./load.sh direct
#   ./load.sh registry 192.168.1.10:5000
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-direct}"
REGISTRY="${2:-}"
CHART=$(ls "${SCRIPT_DIR}"/clusterfactory-*.tgz | head -1)

log()  { echo ">> $*"; }
ok()   { echo "   OK  $*"; }

sep() { echo; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

sep "Loading images (mode: ${MODE})"
log "Importing images.tar..."
docker load -i "${SCRIPT_DIR}/images.tar"
ok "Images loaded"

if [ "${MODE}" = "registry" ]; then
  [ -z "${REGISTRY}" ] && { echo "ERROR: provide registry URL as second argument"; exit 1; }

  sep "Retagging and pushing to ${REGISTRY}"
  docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "^<none>" | while read -r img; do
    new="${REGISTRY}/${img}"
    docker tag "${img}" "${new}"
    docker push "${new}"
    ok "Pushed ${new}"
  done

  sep "Installing chart with registry overrides"
  sed "s|REGISTRY|${REGISTRY}|g" "${SCRIPT_DIR}/values-airgap.yaml" > /tmp/values-airgap-resolved.yaml
  helm upgrade --install cf "${CHART}" \
    --namespace cicd --create-namespace \
    --atomic --timeout 15m \
    --values /tmp/values-airgap-resolved.yaml
else
  sep "Installing chart (images already in Docker)"
  helm upgrade --install cf "${CHART}" \
    --namespace cicd --create-namespace \
    --atomic --timeout 15m
fi

sep "Done"
JENKINS_PASS=$(kubectl get secret cf-jenkins -n cicd \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
echo "  Gitea  : kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000"
echo "  Jenkins: kubectl port-forward -n cicd svc/cf-jenkins 8080:8080"
echo "  Jenkins password: ${JENKINS_PASS}"
LOAD_EOF

chmod +x "${WORK_DIR}/load.sh"
ok "load.sh written"

sep "Creating archive"
cd "${OUTPUT_DIR}"
tar czf "${BUNDLE_NAME}.tar.gz" "${BUNDLE_NAME}/"
ok "$(du -sh "${BUNDLE_NAME}.tar.gz" | cut -f1)  →  ${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"

sep "Bundle complete"
echo
echo "  Transfer to airgapped machine:"
echo "    scp ${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz user@airgapped-host:/opt/"
echo
echo "  On the airgapped machine:"
echo "    tar xzf ${BUNDLE_NAME}.tar.gz"
echo "    cd ${BUNDLE_NAME}"
echo "    ./load.sh direct                     # docker-desktop / kind"
echo "    ./load.sh registry 192.168.1.10:5000 # with local registry"
echo
