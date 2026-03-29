#!/usr/bin/env bash
# hack/bundle.sh — build a self-contained airgap release tarball
#
# Output: dist/clusterfactory-<version>-airgap.tar.gz
#
# The tarball contains:
#   VERSIONS.env                  — pinned versions (informational)
#   charts/                       — all Helm charts as .tgz files
#   images/                       — all container images as .tar files (docker save)
#   platform/                     — the clusterfactory chart source
#   bootstrap.sh -> platform/bootstrap.sh (convenience symlink at root)
#
# Requirements (build machine, needs internet):
#   helm, docker (or crane), curl, jq
#
# Usage:
#   bash hack/bundle.sh
#   bash hack/bundle.sh --push registry.example.com/clusterfactory  # also push images

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/VERSIONS.env"

VERSION="${CLUSTERFACTORY_CHART_VERSION}"
DIST="${REPO_ROOT}/dist"
BUNDLE_DIR="${DIST}/clusterfactory-${VERSION}-airgap"
TARBALL="${DIST}/clusterfactory-${VERSION}-airgap.tar.gz"

PUSH_REGISTRY="${1:-}"
[ "${1:-}" = "--push" ] && PUSH_REGISTRY="${2:-}" && shift 2 || true

echo "Building clusterfactory ${VERSION} airgap bundle..."
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
for cmd in helm docker curl jq; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/charts" "${BUNDLE_DIR}/images" "${BUNDLE_DIR}/platform"

# ── Helm repos ────────────────────────────────────────────────────────────────
echo "  Adding Helm repos..."
helm repo add jetstack      "${REPO_JETSTACK}"      --force-update > /dev/null 2>&1
helm repo add gitea         "${REPO_GITEA}"         --force-update > /dev/null 2>&1
helm repo add argo          "${REPO_ARGO}"          --force-update > /dev/null 2>&1
helm repo add harbor        "${REPO_HARBOR}"        --force-update > /dev/null 2>&1
helm repo add openbao       "${REPO_OPENBAO}"       --force-update > /dev/null 2>&1
helm repo add crossplane    "${REPO_CROSSPLANE}"    --force-update > /dev/null 2>&1
helm repo add clusterfactory "${REPO_CLUSTERFACTORY}" --force-update > /dev/null 2>&1
helm repo update > /dev/null 2>&1

# ── Pull Helm charts ──────────────────────────────────────────────────────────
echo "  Pulling Helm charts..."

_pull() {
  local repo="$1" chart="$2" version="$3"
  echo "    ${chart} ${version}"
  helm pull "${repo}/${chart}" --version "${version}" --destination "${BUNDLE_DIR}/charts/"
}

_pull jetstack      cert-manager  "${CERTMANAGER_CHART_VERSION}"
_pull gitea         gitea         "${GITEA_CHART_VERSION}"
_pull clusterfactory clusterfactory "${CLUSTERFACTORY_CHART_VERSION}"
_pull argo          argo-cd       "${ARGOCD_CHART_VERSION}"
_pull harbor        harbor        "${HARBOR_CHART_VERSION}"
_pull openbao       openbao       "${OPENBAO_CHART_VERSION}"
_pull crossplane    crossplane    "${CROSSPLANE_CHART_VERSION}"

# ── Resolve container images from charts ──────────────────────────────────────
echo "  Resolving container images..."

# Start with explicitly known images
IMAGES=(
  "gitea/act_runner:${ACT_RUNNER_TAG}"
  "gitea/gitea:$(helm show chart gitea/gitea --version "${GITEA_CHART_VERSION}" | grep appVersion | awk '{print $2}' | tr -d '"')"
)

# Extract images from each chart using helm template
_extract_images() {
  local chart_tgz="$1"
  helm template release "${chart_tgz}" 2>/dev/null \
    | grep -oE 'image: ["\x27]?[a-zA-Z0-9./:-]+["\x27]?' \
    | sed 's/image: //; s/["\x27]//g' \
    | sort -u
}

for chart_tgz in "${BUNDLE_DIR}/charts/"*.tgz; do
  while IFS= read -r img; do
    [ -n "$img" ] && IMAGES+=("$img")
  done < <(_extract_images "${chart_tgz}")
done

# Deduplicate
IFS=$'\n' IMAGES=($(printf '%s\n' "${IMAGES[@]}" | sort -u))
unset IFS

# ── Pull and save container images ────────────────────────────────────────────
echo "  Pulling and saving container images (this takes a while)..."
IMAGE_LIST_FILE="${BUNDLE_DIR}/images/images.txt"
> "${IMAGE_LIST_FILE}"

for img in "${IMAGES[@]}"; do
  [ -z "$img" ] && continue
  echo "    ${img}"
  # Sanitize image name for use as filename
  filename=$(echo "${img}" | tr '/:' '__')
  docker pull "${img}" --quiet
  docker save "${img}" -o "${BUNDLE_DIR}/images/${filename}.tar"
  echo "${img}" >> "${IMAGE_LIST_FILE}"
done

# ── Copy platform source ───────────────────────────────────────────────────────
echo "  Copying platform source..."
cp -r "${REPO_ROOT}/platform/"* "${BUNDLE_DIR}/platform/"
cp "${REPO_ROOT}/VERSIONS.env" "${BUNDLE_DIR}/"

# ── Write load.sh — image loader for the target node ─────────────────────────
cat > "${BUNDLE_DIR}/load.sh" << 'LOADEOF'
#!/usr/bin/env bash
# load.sh — load bundled images into the local container runtime
#
# Run this on the target node before bootstrap.sh --airgap
# Supports: docker, containerd (via ctr), RKE2 (via /var/lib/rancher/rke2/bin/ctr)
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${BUNDLE_DIR}/images"

if command -v docker > /dev/null 2>&1; then
  LOAD_CMD="docker load -i"
elif [ -x /var/lib/rancher/rke2/bin/ctr ]; then
  LOAD_CMD="/var/lib/rancher/rke2/bin/ctr images import"
elif command -v ctr > /dev/null 2>&1; then
  LOAD_CMD="ctr images import"
else
  echo "ERROR: no supported container runtime found (docker / ctr)"
  exit 1
fi

echo "Loading images using: ${LOAD_CMD}"
for tar in "${IMAGES_DIR}"/*.tar; do
  echo "  $(basename "${tar}")"
  ${LOAD_CMD} "${tar}"
done
echo "Done. $(wc -l < "${IMAGES_DIR}/images.txt") images loaded."
LOADEOF
chmod +x "${BUNDLE_DIR}/load.sh"

# ── Write airgap-overrides.env — repo URLs pointing at local Harbor ───────────
cat > "${BUNDLE_DIR}/airgap-overrides.env" << 'OVERRIDESEOF'
# airgap-overrides.env — sourced by bootstrap.sh --airgap
#
# Set CF_HARBOR_HOST before running bootstrap.sh --airgap
# e.g.: CF_HARBOR_HOST=harbor.internal:5000 bash bootstrap.sh --airgap
#
# bootstrap.sh will:
#   1. Run load.sh to import images into the runtime
#   2. Push all images to CF_HARBOR_HOST
#   3. Override all REPO_* variables to point at CF_HARBOR_HOST OCI endpoints
#   4. Run the normal install sequence from local charts and images

: "${CF_HARBOR_HOST:=localhost:5000}"

REPO_JETSTACK="oci://${CF_HARBOR_HOST}/charts"
REPO_GITEA="oci://${CF_HARBOR_HOST}/charts"
REPO_CLUSTERFACTORY="oci://${CF_HARBOR_HOST}/charts"
REPO_ARGO="oci://${CF_HARBOR_HOST}/charts"
REPO_HARBOR="oci://${CF_HARBOR_HOST}/charts"
REPO_OPENBAO="oci://${CF_HARBOR_HOST}/charts"
REPO_CROSSPLANE="oci://${CF_HARBOR_HOST}/charts"
OVERRIDESEOF

# ── Package ───────────────────────────────────────────────────────────────────
echo "  Packaging..."
mkdir -p "${DIST}"
tar -czf "${TARBALL}" -C "${DIST}" "$(basename "${BUNDLE_DIR}")"
rm -rf "${BUNDLE_DIR}"

echo ""
echo "  ✓ ${TARBALL}"
echo "    $(du -sh "${TARBALL}" | cut -f1) — $(wc -l < /dev/stdin <<< "${IMAGES[@]}"  ) charts + ${#IMAGES[@]} images"
echo ""
echo "  Deploy to air-gapped node:"
echo "    scp ${TARBALL} node:/tmp/"
echo "    ssh node 'cd /tmp && tar -xzf $(basename "${TARBALL}") && bash clusterfactory-${VERSION}-airgap/load.sh'"
echo "    ssh node 'CF_HOST=my.internal CF_HARBOR_HOST=harbor.internal bash clusterfactory-${VERSION}-airgap/platform/bootstrap.sh --airgap'"

# ── Optional: push images to a registry ───────────────────────────────────────
if [ -n "${PUSH_REGISTRY}" ]; then
  echo ""
  echo "  Pushing images to ${PUSH_REGISTRY}..."
  while IFS= read -r img; do
    target="${PUSH_REGISTRY}/$(echo "${img}" | sed 's|.*/||')"
    docker tag "${img}" "${target}"
    docker push "${target}"
    echo "    pushed: ${target}"
  done < "${DIST}/clusterfactory-${VERSION}-airgap/images/images.txt" 2>/dev/null || true
fi
