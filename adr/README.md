# Architecture Decision Records

One file per decision, numbered, never edited after acceptance except to
change **Status** (e.g. to `Superseded by 00NN`). Format: Context /
Decision / Consequences / Date.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-adopt-uds-package-anatomy.md) | Adopt UDS package anatomy without UDS Core | Accepted |
| [0002](0002-wiring-as-settings-chart-job.md) | Wiring as settings-chart Job; logic in Python, never in Helm | Accepted |
| [0003](0003-upstream-flavor-only.md) | Upstream flavor only; flavor = image provenance | Accepted |
| [0004](0004-keep-cosign-sbom-drop-structural-sha.md) | Keep cosign + SBOM, drop structural SHA | Accepted |
| [0005](0005-trusted-operator-threat-model.md) | Trusted-operator threat model; CHANGEME defaults acceptable | Accepted |
| [0006](0006-jenkins-plugins-prebundled-volume.md) | Jenkins plugins via pre-bundled volume, `installPlugins: []` | Accepted |
| 0007 | Nexus `nxrm-ha` single replica CE | Pending spike (§6) |
| 0008 | Postgres chart choice | Pending spike (§6) |
| [0009](0009-kaniko-cf-build-baseline-exemption.md) | Kaniko + `cf-build` baseline exemption | Accepted |
| [0010](0010-plain-http-port-forward.md) | Plain HTTP + port-forward; cert-manager as upgrade path | Accepted |
| [0011](0011-rke2-cis-canal-local-path.md) | RKE2 CIS profile, Canal, local-path storage | Accepted |
| 0012 | Single package vs per-app packages + bundle | Open |

Source design document: [`uds-way.md`](../uds-way.md).
