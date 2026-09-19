# Security

## Threat model (ADR 0005)

**Trusted operator, untrusted network.** The person who deploys the package
holds cluster-admin `kubectl`; they can already read every Secret. We defend the
cluster boundary, not the operator:

- Deny-all egress in every application namespace; only DNS, in-namespace
  traffic and the Kubernetes API server are allowed (`charts/config`). CI
  deploys into a cluster with egress denied and asserts the demo still works.
- Pod Security Admission `restricted` on every namespace except `cf-build`
  (`baseline`, for Kaniko — [`docs/exemptions/kaniko.md`](docs/exemptions/kaniko.md)).
- No Ingress, no TLS in-cluster; access is `kubectl port-forward` (ADR 0010).
  cert-manager with a cluster CA is the documented upgrade path.
- Update checkers, telemetry and the Jenkins update centre are off; Jenkins
  plugins are shipped pinned in the package.
- Admin passwords default to `CHANGEME-*` and are meant to be overridden with
  `--set`; there is deliberately no secret-management machinery.

## What is verified on every change

- `zarf dev lint`, `helm lint --strict`, `yamllint`, OSCAL schema check.
- Package build, signed with cosign; SBOM per image; **grype** on every SBOM
  under the policy in `.grype.yaml`, enforced by `hack/cve-gate.py`:
  anything on CISA's **Known Exploited Vulnerabilities** list blocks, in any
  image; any **Critical with a fix** blocks in the images this repo builds;
  everything else is reported in the job summary. The only ignore is the
  archived Kaniko executor, with a review date.
- Airgapped deploy on kind + Calico: every container image served from the
  in-cluster Zarf registry, all workloads Ready, admin credentials work, all
  Jenkins plugins active, wire Job converged, redeploy idempotent, Kaniko build
  pushed to Nexus, internet egress `000`.
- Trivy config scan and OSSF Scorecard (`scan.yaml`).

## Known gaps (honest list)

- **Upstream images carry Critical CVEs with fixes in their OS layer** - even
  the newest official tags do (openssl in `alpine:3.22`, perl/glibc in the
  Debian-based Jenkins images, bundled jars in Jenkins). We ship those images
  unmodified (ADR 0001), so the gate reports rather than blocks on them; the
  remedies are Renovate keeping tags current and a hardened flavor
  (registry1 / Chainguard, ADR 0003), which nobody has built yet.
- **Kaniko is archived upstream** and will never receive fixes for its Go
  findings; it is ignored in `.grype.yaml` with a justification and a review
  date. The recorded alternative (ko / Jib / apko) is in ADR 0009.
- **Nexus CE on embedded H2** is single-node and not what Sonatype recommends
  for production loads (ADR 0007). Moving to Postgres is additive.
- **Plain HTTP** everywhere in-cluster; Kaniko pushes with `--insecure`.
- **Kaniko runs as root** (default capability set, nothing added) in `cf-build`.
- **Gitea API tokens** are SHA-1 hashed upstream; the wire engine mints a
  read-only token for a dedicated integration user and persists it in a Secret.
- **Signing key custody**: one cosign key, held by the maintainers and in the
  repository secrets; no HSM, no rotation schedule yet.

## Reporting a vulnerability

Do not open a public issue. Use a
[GitHub Security Advisory](https://github.com/clusterfactory/clusterfactory/security/advisories/new)
with a description, reproduction steps and affected versions. You will get a
response within 72 hours.
