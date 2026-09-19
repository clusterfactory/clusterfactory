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

## Local setup

`zarf` (version pinned in `.github/workflows/ci.yaml`), `helm`, `kubectl`, `kind`,
`docker`, `make`, `python3`, `yamllint`, `skopeo`.

```bash
make lint                      # gate 1
make package OUT=build         # gate 2 (builds the plugins + wire-engine images)
bundle/up.sh <dir with zarf-init-*.tar.zst>
zarf package deploy build/*.tar.zst --confirm --set NEXUS_ACCEPT_CE_EULA=true
tests/deploy-check.sh          # gates 3 + 4; EXPECT_IDEMPOTENT=1 after a redeploy
```

`bundle/up.sh` is re-runnable; run it again if a kind node restart changed the
API server IP (every ipBlock NetworkPolicy goes stale).

## How to…

- **Add a wiring step:** a function in `wire.py` that reads state, changes only
  what differs, calls `report(...)`, and is appended to `steps` in `main()`.
  Give it env/values in `charts/settings` if it needs configuration.
- **Bump an upstream chart/image:** edit the chart `version:` in `common/zarf.yaml`
  and/or the tag in `values/<app>-upstream-values.yaml`, re-pin the digest, update
  the root `images:` list, run the gate.
- **Add a Jenkins plugin:** add `name:version` to `jenkins/plugins.txt`, run
  `make plugins`, commit `plugins.lock`. CI fails if the lock drifts.
- **Add a flavor:** `values/<app>-<flavor>-values.yaml` per app, a component in
  `zarf.yaml` with `only.flavor`, a CI matrix entry. Behaviour must not change.
- **Add a namespace or policy:** `charts/config/values.yaml` (`namespaces`,
  `networkPolicy.additionalEgress`).

## Pull requests

One migration step or one change per PR; the CI gate must be green. Commit
messages: conventional prefixes (`refactor(uds):`, `ci:`, `docs(adr):`), body
says what was verified and how.
