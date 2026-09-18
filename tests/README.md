# tests/ — integration checks against the CI cluster

Run against the cluster stood up from `bundle/` after
`zarf package deploy`. Each check is a small script that exits non-zero
on failure and prints one line per assertion. Planned (uds-way.md §11):

| Gate | Check |
|---|---|
| 3 airgapped deploy | all pods Ready, wire Job Complete, all Jenkins plugins loaded |
| 4 functional | push to `cf-demo/hello-world`, pipeline runs, Kaniko builds, image lands in Nexus |
| 5 upgrade N-1 → N | PVC data survives, wire Job converges with only `ok`/`skipped` lines |

- `deploy-check.sh [namespace]` — gate 3: all pods Ready, every image served by the Zarf registry, Gitea/Jenkins reachable in-cluster, cf-config admin credentials accepted, internet egress blocked.
