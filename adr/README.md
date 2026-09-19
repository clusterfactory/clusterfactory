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
| [0007](0007-nexus-ce-embedded-h2.md) | Nexus CE on embedded H2, own helper chart (supersedes the `nxrm-ha` plan) | Accepted |
| [0008](0008-no-postgres-component.md) | No Postgres component; deferred until a real need | Accepted |
| [0009](0009-kaniko-cf-build-baseline-exemption.md) | Kaniko + `cf-build` baseline exemption | Accepted |
| [0010](0010-plain-http-port-forward.md) | Plain HTTP + port-forward; cert-manager as upgrade path | Accepted |
| [0011](0011-rke2-cis-canal-local-path.md) | RKE2 CIS profile, Canal, local-path storage | Accepted |
| 0012 | Single package vs per-app packages + bundle | Open |
| [0013](0013-argocd-optional-component.md) | Argo CD as an optional component | Proposed |

Source design document: [`uds-way.md`](../uds-way.md). Pre-refactor decision table: [`docs/archive/rafactor-vanilla-way.md`](../docs/archive/rafactor-vanilla-way.md).
