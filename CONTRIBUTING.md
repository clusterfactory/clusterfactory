# Contributing

## Ground rules

1. **Unmodified upstream.** Charts and images of Gitea/Jenkins/Nexus are used as
   published; customization goes in `values/`, `charts/config`, `charts/settings`
   or `wire-engine/wire.py`. If a component only works because your machine had
   internet, it is a bug.
2. **Wiring lives in `wire.py`**, never in Helm templates or hooks. Every step is
   check-then-act and reports `ok`/`created`/`updated`/`skipped`/`failed`.
3. **Every decision is an ADR** in `adr/` (Context / Decision / Consequences / Date).
4. **Every deviation from PSA `restricted`** gets a file in `docs/exemptions/`.
5. **Pin by digest.** `hack/pin-images.sh <image:tag>` gives the linux/amd64
   manifest digest Zarf needs (it rejects multi-arch index digests).

## Where things run

Nothing runs on a laptop. Lint and package builds run on GitHub-hosted
runners; every job that needs a cluster runs against `cf-runner-1`, an
air-gapped RKE2 host (Rocky 9, SELinux enforcing, no internet route) fed from
a private GCS bucket and driven over an IAP tunnel by the hosted job. A pull
request from a branch in this repository gets the full RKE2 gate; forks get
lint and create only. One job at a time on the VM - a queued PR waits.

The manual form of the install is `hack/airgap-install.sh` (`up`, `deploy`,
`down`) with an artifact directory produced by `hack/airgap-fetch.sh`; that
is also the runbook for any offline RKE2 host.

Tools for authoring: `zarf`, `helm`, `yamllint`, `python3`, `skopeo`
(`hack/pin-images.sh`), `docker` + `make` only if you build packages locally.

## How to…

- **Add a wiring step:** a function in `wire.py` that reads state, changes only
  what differs, calls `report(...)`, and is appended to `steps` in `main()`.
  Give it env/values in `charts/settings` if it needs configuration.
- **Bump an upstream chart/image:** edit the chart `version:` in `common/zarf.yaml`
  and/or the tag in `values/<app>-upstream-values.yaml`, re-pin the digest, update
  the root `images:` list, run the gate.
- **Add or bump a Jenkins plugin:** edit `jenkins/plugins.txt`, run
  `make plugins-update`, review and commit `plugins.lock`. `make plugins`
  installs the lock; CI fails if the lock is not self-consistent.
- **Add a flavor:** `values/<app>-<flavor>-values.yaml` per app, a component in
  `zarf.yaml` with `only.flavor`, a CI matrix entry. Behaviour must not change.
- **Add a namespace or policy:** `charts/config/values.yaml` (`namespaces`,
  `networkPolicy.additionalEgress`) and `contract/namespaces.yaml`.
- **Add a preflight check:** a `# CHECK: id | class | what` line plus a
  `check ...` call in `preflight/preflight.sh`, then `hack/gen-prerequisites.py`;
  make CI see it fail (`tests/preflight-negative.sh`).

## Pull requests

One migration step or one change per PR; the CI gate must be green. Commit
messages: conventional prefixes (`refactor(uds):`, `ci:`, `docs(adr):`), body
says what was verified and how.
