#!/usr/bin/env bash
# Update image digests in values.yaml for supply chain security
# 
# Usage: ./hack/update-digests.sh [--dry-run]
#
# Pulls images, extracts SHA256 digests, and updates values.yaml.
# Use --dry-run to see what would be updated without modifying files.

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🔍 DRY RUN MODE - no files will be modified"
  echo ""
fi

VALUES_FILE="values.yaml"

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "❌ Error: $VALUES_FILE not found"
  exit 1
fi

log() {
  echo "[$(date +'%H:%M:%S')] $*"
}

# Extract current image references from values.yaml
GITEA_REPO=$(yq eval '.images.gitea.repository' "$VALUES_FILE")
GITEA_TAG=$(yq eval '.images.gitea.tag' "$VALUES_FILE")

JENKINS_REPO=$(yq eval '.images.jenkins.repository' "$VALUES_FILE")
JENKINS_TAG=$(yq eval '.images.jenkins.tag' "$VALUES_FILE")

ACTRUNNER_REPO=$(yq eval '.images.actRunner.repository' "$VALUES_FILE")
ACTRUNNER_TAG=$(yq eval '.images.actRunner.tag' "$VALUES_FILE")

ALPINE_REPO=$(yq eval '.images.wire.bash.repository' "$VALUES_FILE")
ALPINE_TAG=$(yq eval '.images.wire.bash.tag' "$VALUES_FILE")

WIRE_PYTHON_REPO=$(yq eval '.images.wire.python.repository' "$VALUES_FILE")
WIRE_PYTHON_TAG=$(yq eval '.images.wire.python.tag' "$VALUES_FILE")

echo "═══════════════════════════════════════════════════════════════"
echo "Image Digest Update Tool"
echo "═══════════════════════════════════════════════════════════════"
echo ""

update_digest() {
  local name="$1"
  local repo="$2"
  local tag="$3"
  local yq_path="$4"
  
  local image="${repo}:${tag}"
  
  log "Pulling $name: $image"
  if ! docker pull "$image" > /dev/null 2>&1; then
    echo "  ⚠️  Failed to pull $image, skipping"
    return
  fi
  
  local digest
  digest=$(docker inspect "$image" --format='{{index .RepoDigests 0}}' | sed 's/.*@//')
  
  if [[ -z "$digest" || "$digest" == "null" ]]; then
    echo "  ⚠️  Could not extract digest for $image"
    return
  fi
  
  log "  → Digest: $digest"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would update: $yq_path = \"$digest\""
  else
    yq eval -i "$yq_path = \"$digest\"" "$VALUES_FILE"
    log "  ✓ Updated $VALUES_FILE"
  fi
  
  echo ""
}

# Update all images
update_digest "Gitea" "$GITEA_REPO" "$GITEA_TAG" ".images.gitea.digest"
update_digest "Jenkins" "$JENKINS_REPO" "$JENKINS_TAG" ".images.jenkins.digest"
update_digest "Act Runner" "$ACTRUNNER_REPO" "$ACTRUNNER_TAG" ".images.actRunner.digest"
update_digest "Alpine (wire)" "$ALPINE_REPO" "$ALPINE_TAG" ".images.wire.bash.digest"
update_digest "Wire Python" "$WIRE_PYTHON_REPO" "$WIRE_PYTHON_TAG" ".images.wire.python.digest"

if [[ "$DRY_RUN" == "false" ]]; then
  echo "═══════════════════════════════════════════════════════════════"
  echo "✓ All digests updated in $VALUES_FILE"
  echo ""
  echo "Next steps:"
  echo "  1. Review changes: git diff $VALUES_FILE"
  echo "  2. Test deployment: helm template . | grep 'image:'"
  echo "  3. Commit: git add $VALUES_FILE && git commit -m 'chore: update image digests'"
  echo "═══════════════════════════════════════════════════════════════"
else
  echo "═══════════════════════════════════════════════════════════════"
  echo "🔍 DRY RUN complete. Run without --dry-run to apply changes."
  echo "═══════════════════════════════════════════════════════════════"
fi
