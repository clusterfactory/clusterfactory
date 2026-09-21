#!/usr/bin/env python3
"""Generate PREREQUISITES.md from the `# CHECK:` lines in preflight/preflight.sh (ADR 0014)."""
import re
import sys

src = open("preflight/preflight.sh").read()
rows = re.findall(r"^# CHECK: (\S+) \| (\S+) \| (.+)$", src, re.M)
classes = {
    "contract": "**contract** - never bypassable",
    "advisory": "**advisory** - a warning with `--set PREFLIGHT_STRICT=false`",
    "profile": "**profile** - hard or soft depending on the active policy profile (soft without one)",
}
out = ["# Prerequisites", "",
       "Generated from `preflight/preflight.sh` by `hack/gen-prerequisites.py` - do not edit by hand.",
       "The `preflight` component runs these checks before anything is deployed and stops",
       "`zarf package deploy` with the failing check's name if the cluster does not meet the contract (ADR 0014).",
       "Results are also written to the ConfigMap `cf-system/cf-preflight-result`.", "",
       "## The contract", "", "| Check | Class | What must hold |", "|---|---|---|"]
for cid, cls, what in rows:
    out.append(f"| `{cid}` | {classes.get(cls, cls)} | {what} |")
out += ["", "## Beyond the checks", "",
        "- A CNI that enforces `NetworkPolicy` (Canal, Calico, Cilium; plain flannel does not - the preflight checks it).",
        "- `zarf init` done with the Zarf version pinned in `.github/workflows/ci.yaml`; the init package is in the deliverable.",
        "- The namespaces in `contract/namespaces.yaml` may pre-exist (created by a policy profile); the forge never relabels them.",
        "- Out of scope: host OS hardening, HA control planes, off-node backup cadence (see SECURITY.md).", ""]
open("PREREQUISITES.md", "w").write("\n".join(out))
print("PREREQUISITES.md written (%d checks)" % len(rows))
