#!/usr/bin/env bash
# On the air-gapped host: make sure the platform artifact set for one RKE2
# version is present and checksum-valid under the local cache, pulling from
# the bucket only what is missing or wrong. Nothing is re-downloaded on a
# host that already has it.
#   hack/airgap-pull.sh gs://bucket/platform/v1.36.4+rke2r1 /root/artifacts/platform/v1.36.4+rke2r1
set -euo pipefail
SRC="$1"; DST="$2"
mkdir -p "$DST" && cd "$DST"
gcloud storage cp "$SRC/SHA256SUMS" ./SHA256SUMS.new >/dev/null 2>&1
if [ -f SHA256SUMS ] && cmp -s SHA256SUMS SHA256SUMS.new && sha256sum -c SHA256SUMS --quiet 2>/dev/null; then
  rm -f SHA256SUMS.new; echo "platform cache valid: $DST ($(du -sh . | cut -f1))"; exit 0
fi
mv SHA256SUMS.new SHA256SUMS
missing=$(sha256sum -c SHA256SUMS 2>/dev/null | grep -v ': OK$' | cut -d: -f1 || true)
[ -z "$missing" ] && missing=$(cut -d' ' -f3- SHA256SUMS)
for f in $missing; do mkdir -p "$(dirname "$f")"; gcloud storage cp "$SRC/$f" "$f" >/dev/null 2>&1; done
sha256sum -c SHA256SUMS --quiet && echo "platform cache refreshed: $(echo "$missing" | wc -w) file(s) pulled"
