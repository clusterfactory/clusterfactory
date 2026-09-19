# 0004 — Keep cosign + SBOM, drop structural SHA

**Status:** Accepted
**Date:** 2026-09-18

## Context

Earlier versions computed a "structural SHA" over the wired cluster state
and exposed it as a Zarf variable / ConfigMap for "auditability". It was
invented here, non-standard, and no assessor recognises it. Meanwhile Zarf
natively signs packages with cosign and generates per-image SBOMs at
create time; both were underused.

## Decision

- **Drop the structural SHA** entirely: code paths, ConfigMap, Zarf
  action, docs.
- **Keep cosign signing** — `zarf package create --signing-key cosign.key`;
  `cosign.pub` published in the repo and in every release; consumers deploy
  with `--key`.
- **Publish SBOMs** — CI extracts them (`zarf package inspect sbom
  --output sboms/`) and attaches the directory to every GitHub release; a
  CI job scans them (grype or trivy) and fails on critical CVEs with no fix.
- Add a minimal `oscal-component.yaml` mapping only what we actually
  enforce to NIST 800-53 control IDs.
- Pin every image by digest.

## Consequences

- Auditability artifacts are all standard (Sigstore, SPDX/CycloneDX,
  OSCAL) and tool-verifiable.
- The `STRUCTURAL_SHA` variable, `cf-wire-result` ConfigMap and
  `hasher.py` are removed during migration; nothing consumes them.
