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
| [0010](0010-plain-http-port-forward.md) | Plain HTTP; Traefik Ingress by hostname on RKE2, port-forward fallback; TLS is policy (v0.5) | Accepted, amended |
| [0011](0011-rke2-cis-canal-local-path.md) | RKE2 (≥1.36), Canal, local-path storage; CIS moved to policy | Accepted, amended |
| [0012](0012-single-forge-package-plus-init.md) | One forge package; the platform is the init package (which also carries the forge) | Accepted |
| [0013](0013-argocd-optional-component.md) | Argo CD as an optional component | Proposed (roadmap) |
| [0014](0014-platform-preflight-and-package-split.md) | Three layers: platform invariants, preflight contract, customer policy | Accepted |
| [0015](0015-custom-init-package-rke2.md) | Custom Zarf init package with an `rke2` component | Accepted |
| [0016](0016-policy-profile-packages.md) | Policy profiles as separate, forkable packages | Accepted |

Source design document: [`docs/design.md`](../docs/design.md).
