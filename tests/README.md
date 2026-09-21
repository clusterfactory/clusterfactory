# tests/ — integration checks against a deployed forge

Run on the RKE2 runner (or any RKE2 host) after `zarf package deploy`. Each check is a small script that exits non-zero
on failure and prints one line per assertion. Planned (uds-way.md §11):

| Gate | Check |
|---|---|
| 3 airgapped deploy | all pods Ready, wire Job Complete, all Jenkins plugins loaded |
| 4 functional | pipeline runs on a pod agent, Kaniko builds from the Nexus-hosted base image, image lands in Nexus `docker-hosted` (covered by `deploy-check.sh`) |
| 5 upgrade N-1 → N | PVC data survives, wire Job converges with only `ok`/`skipped` lines |

- `deploy-check.sh [namespace]` — gate 3: all pods Ready, every image served by the Zarf registry, Gitea/Jenkins reachable in-cluster, cf-config admin credentials accepted, wire Job converged (set `EXPECT_IDEMPOTENT=1` after a redeploy to require only `ok` lines), demo pipeline builds green from Gitea, internet egress blocked.
