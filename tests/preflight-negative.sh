#!/usr/bin/env bash
# Every contract check must be seen failing at least once (ADR 0014):
# deploy the preflight-only package to a deliberately broken cluster and
# assert exactly the expected checks FAIL, reading the result ConfigMap.
#   tests/preflight-negative.sh <package.tar.zst> <expected-failing-ids,comma-separated>
set -euo pipefail
PKG="$1"; EXPECT="$2"
set +e
zarf package deploy "$PKG" --confirm --no-color > preflight-negative.out 2>&1
rc=$?
set -e
grep -E '^(ok|FAIL|WARN) ' preflight-negative.out || true
[[ $rc -ne 0 ]] || { echo "FAIL: preflight passed on a broken cluster"; exit 1; }
kubectl get configmap cf-preflight-result -n cf-system -o jsonpath='{.data.result\.json}' > preflight-result.json
python3 - "$EXPECT" <<'PY'
import json, sys
data = json.load(open("preflight-result.json"))
failed = {c["id"] for c in data["checks"] if c["status"] == "FAIL"}
expected = set(sys.argv[1].split(","))
missing, extra = expected - failed, failed - expected
if missing or extra:
    print(f"FAIL: expected failing {sorted(expected)}, got {sorted(failed)} (missing {sorted(missing)}, unexpected {sorted(extra)})")
    sys.exit(1)
print(f"ok: exactly {sorted(failed)} failed; {len(data['checks'])} checks ran; classes: "
      + ", ".join(f"{c['id']}={c['class']}" for c in data["checks"]))
PY
for _ in $(seq 1 30); do
  kubectl get ns -o name | grep -q '^namespace/cf-preflight-' || { echo "ok: throwaway namespace cleaned up"; exit 0; }
  sleep 2
done
echo "FAIL: throwaway namespace left behind"; kubectl get ns | grep cf-preflight; exit 1
