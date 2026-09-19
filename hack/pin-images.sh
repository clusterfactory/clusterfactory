#!/usr/bin/env bash
# Resolve the linux/<arch> *manifest* digest for an image tag.
# Zarf refuses OCI index digests ("resolved to an OCI image index"), so the
# images: list and values/*-upstream-values.yaml must carry the per-platform
# manifest digest, not the multi-arch index digest Renovate would pin.
#
# Usage: hack/pin-images.sh IMAGE:TAG [IMAGE:TAG ...]      (ARCH=amd64 by default)
set -euo pipefail
ARCH="${ARCH:-amd64}"
command -v skopeo >/dev/null || { echo "skopeo required" >&2; exit 1; }
for ref in "$@"; do
  raw=$(skopeo inspect --raw "docker://${ref}")
  digest=$(printf '%s' "$raw" | python3 -c '
import json, sys, hashlib
arch = sys.argv[1]; raw = sys.stdin.read(); m = json.loads(raw)
manifests = m.get("manifests")
if manifests is None:  # single-platform manifest: digest of the raw bytes
    print("sha256:" + hashlib.sha256(raw.encode()).hexdigest()); sys.exit()
for e in manifests:
    p = e.get("platform", {})
    if p.get("os") == "linux" and p.get("architecture") == arch:
        print(e["digest"]); sys.exit()
sys.exit(f"no linux/{arch} manifest in index for {sys.argv[2]}")
' "$ARCH" "$ref")
  echo "${ref}@${digest}"
done
