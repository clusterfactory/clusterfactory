#!/usr/bin/env python3
"""Gate 5: everything present before the upgrade must still be there after it."""
import json
import sys

before, after = (json.load(open(p)) for p in sys.argv[1:3])
bad = []
if after["gitea_commits"] < before["gitea_commits"]:
    bad.append(f"gitea commits {before['gitea_commits']} -> {after['gitea_commits']}")
for key in ("jenkins_builds", "nexus_tags"):
    missing = sorted(set(map(str, before[key])) - set(map(str, after[key])))
    if missing:
        bad.append(f"{key} lost: {missing}")
if bad:
    print("FAIL: data did not survive the upgrade: " + "; ".join(bad))
    sys.exit(1)
print(f"ok: upgrade kept {before['gitea_commits']} commits, {len(before['jenkins_builds'])} builds, {len(before['nexus_tags'])} tags")
