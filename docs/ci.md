# CI: what runs where, and how to bring the air-gapped rig back

## Hosted (always on)

`ci.yaml` on every PR and push: `zarf dev lint` (forge and init definitions),
helm lint on the helper charts, yamllint, OSCAL schema, then `create` — builds
both packages, signs them when the repo secrets are present, extracts SBOMs,
runs the CVE gate (`.grype.yaml`, `hack/cve-gate.py`) and uploads
`zarf-package-upstream` (~1.2 GB) and `zarf-init-upstream` (~2.1 GB) as run
artifacts (5 days). `release.yaml` on a `v*` tag builds, signs, verifies and
attaches both to a GitHub release. `scan.yaml` runs Trivy config scans and
OSSF Scorecard weekly. None of this needs anything outside GitHub.

## The rig (optional; gated on the repo variable `CF_RIG`)

The deploy gates need a real, disconnected host. They are the `rke2` and
`rke2-negative` jobs in `ci.yaml`, the nightly `rke2-gate.yaml`,
`airgap-stage.yaml` and `vm-ops.yaml`, and they run only when the repository
variable `CF_RIG` is `1`. Without it they are skipped (grey), so a fork gets a
green CI from the hosted jobs alone.

The reference rig, as it was run for v0.4 (GCP, ~€1/h while the VM is up):

- **VM `cf-runner-1`**: Rocky 9, `n2-custom-16-32768`, 80 GB, shielded,
  **no external IP, no NAT**, OS Login on, in its own VPC `cf-runner` with a
  single ingress rule (IAP range `35.235.240.0/20` → tcp/22). Private Google
  Access on the subnet so it can read one bucket.
- **Bucket** `gs://cf-artifacts-<project>` with `platform/<rke2 version>/`
  (the RKE2 tarballs, RPMs, local-path manifest + images, staged once by
  `airgap-stage.yaml` via `hack/airgap-fetch.sh`), `forge/main/` (the two
  packages of the last green run on `main`, written by CI) and `runs/<id>/`
  (this run's packages, deleted at the end).
- **Identity**: Workload Identity Federation pool `github` restricted to this
  repository → service account `cf-runner-ops` (custom role: start/stop/reset
  that one instance, `iap.tunnelResourceAccessor`, `compute.osAdminLogin`,
  `iam.serviceAccountUser` on the VM's SA, objectAdmin on the bucket). The
  VM's own SA can only read the bucket. No key files anywhere.
- **Repo secrets**: `GCP_PROJECT_ID`, `GCP_WORKLOAD_IDENTITY_PROVIDER`,
  `GCP_SERVICE_ACCOUNT`, plus `COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD` for signing.

Flow per run: the hosted job uploads the packages to `runs/<id>/`, copies the
gate scripts to the VM with `gcloud compute scp --tunnel-through-iap` (the
tunnel cannot carry gigabytes), then over `gcloud compute ssh` the VM pulls the
packages, runs `zarf init` on the all-in-one of the previous `main` build,
gates, upgrades with this run's forge package, gates again, redeploys
idempotently, uninstalls. The negative job brings RKE2 up with flannel and no
default StorageClass (`hack/airgap-install.sh`) and asserts the preflight
refuses.

To recreate it: create the VPC/subnet/firewall/bucket/WIF/SA as above, set the
three secrets, set `CF_RIG=1`, run `airgap-stage.yaml` once to fill
`platform/`, then push. `vm-ops.yaml` stops and starts the VM; stop it when
idle. Everything about the manual install path is in
[`install-bare-host.md`](install-bare-host.md).
