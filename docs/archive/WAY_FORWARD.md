# clusterfactory — Way Forward

**One sentence:** clusterfactory is Zarf with worked examples — upstream-only
recipes for delivering software into an airgapped RKE2 cluster, each one
pinned, rebuildable and tested with egress blocked.

The first example is a CI area: Gitea, Jenkins and Nexus, wired together
once by an in-cluster Job. Most of this document is about that example
because it's the only one so far. The structure is meant to hold more.

## What you own

- **You build your own hardening.** We ship upstream components at a safe
  baseline (CIS profile, PSA restricted, default-deny egress). Beyond that
  is your threat model, not ours.
- **You own disaster recovery.** State lives in PVCs and etcd on your
  nodes. What gets copied off, where, how often — yours.
- **You own rollbacks.** `zarf package deploy` of the previous release is
  the mechanism; deciding when, and restoring data to match, is yours.
- **clusterfactory is just Zarf and upstream.** There is no clusterfactory
  runtime, controller, or agent in your cluster after the wire Job exits.
  If the project disappeared tomorrow, your cluster would not notice.

## What an example is

The CI stack — Gitea → Jenkins → Nexus connected on first boot — is one
recipe showing how to deliver several upstream components and connect them
without touching their images. Other examples follow the same shape. To be
in this repo, an example must have:

- upstream charts and images only, pinned by digest;
- a `values/` directory that is the whole of our configuration;
- if it needs wiring, a single in-cluster Job, idempotent, stdlib-only,
  deleted on completion, leaving least-privilege credentials;
- a CI job that deploys it with egress blocked and asserts the result;
- a `manifest.json` and a passing `make verify-release`;
- a one-page README: what it delivers, what you own afterwards.

Detailed design and decision log: [`rafactor-vanilla-way.md`](rafactor-vanilla-way.md).

---

## What we deliver

Three things on one piece of removable media:

| Artifact | What it is | Who made it |
|---|---|---|
| `rke2/` bundle | Pinned RKE2 release, airgap image tarball, install script, hardened `config.yaml` | Rancher (binaries), us (config) |
| `zarf-init-*.tar.zst` | Zarf's own init package: in-cluster registry + agent | Zarf upstream, unmodified |
| `zarf-package-clusterfactory-*.tar.zst` | Gitea, Jenkins, Nexus, Postgres, Jenkins plugins, Kaniko, wire-engine | Upstream charts + images, unmodified; our values, manifests and one small wire-engine image |

Install is three commands, in this order, and the runbook says so:

```
sudo ./rke2/install.sh          # RKE2 with CIS profile, local-path storage
zarf init --confirm             # in-cluster registry
zarf package deploy zarf-package-clusterfactory-*.tar.zst --confirm
```

Nothing is pulled from the internet at any step. Nothing is `helm install`ed
by hand. No images are preloaded by hand.

## What "upstream" means here

The package contains only unmodified upstream charts and images, plus our
values. Concretely:

- Every chart is the upstream chart at a pinned version, byte-identical to
  what the project publishes. We ship a `values/*.yaml` per chart and
  nothing else.
- Every image is the upstream tag, by digest. There is **no
  clusterfactory-built Jenkins, Gitea or Nexus image**. `Dockerfile.wire`
  goes away.
- The one image we build is `wire-engine`: `python:slim` + a stdlib-only
  script. It's small enough to read in one sitting.
- Jenkins plugins are pinned in `jenkins/plugins.txt`, resolved on the
  connected side with `jenkins-plugin-cli`, and mounted into the upstream
  Jenkins image as a volume. The Jenkins image is untouched.

Anyone can diff our package against upstream and see exactly what we added.

## Build your own security you can see

clusterfactory does not ask a security team to trust a package. It hands
them a recipe short enough to read and asks them to run it.

The recipe is `zarf.yaml`, `values/`, `manifests/`, `jenkins/plugins.txt`
and `wire-engine/Dockerfile`. All upstream references are pinned by digest
or checksum. So the verification path is:

```
git checkout v0.4.0
zarf package create . --confirm
make verify-release          # compares your digests to the published manifest
```

If the image digests and chart checksums your connected machine produced
match the ones in our release's `manifest.json`, you have independently
rebuilt the release. Nothing we shipped was needed — you now trust your
own build, and you can carry *that* across the fence instead of ours.

What this requires of us, and is therefore a Phase 1 deliverable:

- every image in `zarf.yaml` pinned `@sha256:…`;
- every plugin in `plugins.txt` pinned with its sha256;
- `manifest.json` published per release: image digests, chart sha256s,
  plugin sha256s, wire-engine image digest and the git SHA it was built
  from;
- `make verify-release` that rebuilds and diffs against that manifest;
- `PROVENANCE.md`: image → digest → upstream signature status (which
  projects publish cosign signatures, and whether CI verified them);
- Zarf package signing kept (`--signing-key` / `--key`), public key in the
  repo and delivered out-of-band. This is distinct from the structural-SHA
  ceremony we removed.

The SBOMs Zarf generates at `package create` ride inside the package, so
`zarf package inspect --sbom` and an offline `grype` scan work on the
airgapped side with no network.

## What "wired" means here

After deploy, one Kubernetes `Job` runs inside the cluster and converges
the following, idempotently:

1. Gitea: admin API token, `cf-demo/hello-world` repo, demo `Jenkinsfile`
2. Jenkins: Gitea credential, Nexus credential, pipeline job for the repo
3. Nexus: `docker-hosted` registry, pre-seeded demo base image copied from
   the Zarf registry

The credentials it leaves behind are least-privilege: a Gitea token scoped
to the demo repo, a Nexus user that can push to one repository. Jenkins
never holds an admin Secret. The Job itself is deleted after it completes;
the admin Secrets stay in their namespaces, readable only by the operator.

Result: push to Gitea → Jenkins builds with Kaniko → image lands in Nexus.
All inside the fence.

Re-running the Job changes nothing if nothing changed. Re-running
`zarf package deploy` is the upgrade path.

## What we are shipping, honestly

Gitea, Jenkins, Nexus and RKE2 together are about the largest attack
surface a delivery system can have. Jenkins has the worst CVE record in
CI and a plugin ecosystem with no unified security model; Nexus *is* the
supply chain — write access to `docker-hosted` poisons every later build;
Gitea holds source integrity; RKE2 is the substrate. The wiring chains
them: a compromise anywhere flows downstream.

Airgap removes remote exploitation of published CVEs. It does nothing
about a malicious commit, a poisoned plugin, or an insider with `kubectl`.

**clusterfactory is not a hardened CI platform.** It delivers upstream CI
components into an airgap with the exposure *visible and bounded*, not
small. What that means in practice:

| Component | Where the exposure really is | What we do about it | What we don't |
|---|---|---|---|
| Jenkins | Plugins, script console, held credentials | Pinned plugin set with sha256s; no plugin auto-update; runs restricted; holds only *scoped* creds, never admin Secrets | Harden Jenkins itself; audit plugin code |
| Gitea | Admin API token, webhooks, SSH | Wire Job mints a repo-scoped token for Jenkins, not admin; SSH disabled unless needed | Replace Gitea auth model |
| Nexus | Write access to the registry | Dedicated deploy user, push to one repo only; anonymous access off; admin password rotated by wire Job on first run | Content trust / image signing on push (future) |
| RKE2 | API server, etcd, kubelet, node OS | `profile: cis`, secrets encryption, PSA restricted, NetworkPolicy | Host OS, physical access, operator identity |
| The glue | Wire Job holds admin on all three at once | Runs once, exits, Job deleted; leaves behind least-privilege creds only; its ~200 lines are readable | Make it unnecessary |

**The real security question is cadence, not design.** Jenkins advisories
land roughly monthly. The commitment that matters to a security team is:
advisory published → pin bumped → package rebuilt, verified, signed → on
media, in *N* days. We commit to a target and publish the actual number per
release. A package that can't be refreshed quickly is a liability no
amount of PSA labels fixes.

## Security posture — the fundamentals we keep

We are deploying to a trusted operator's airgapped cluster. `kubectl`
access is already root. We don't pretend otherwise, and we don't add
ceremony that doesn't reduce risk. We do keep these:

| We do | Because |
|---|---|
| RKE2 `profile: cis`, PSA `restricted` cluster-wide | Cheap, upstream-supported, auditable baseline |
| `secrets-encryption: true` | Admin passwords live in Secrets |
| Every pod non-root, caps dropped, seccomp `RuntimeDefault` | Upstream images already support it; we just set the values |
| Default-deny egress `NetworkPolicy` shipped in the package | Airgap is enforced, not assumed; phone-home fails visibly |
| Update checks / telemetry off in every app | No startup stalls, no noisy errors, no surprise egress |
| **One** declared exemption: Kaniko runs as uid 0 in `cf-build` at PSA `baseline` | It needs root to unpack layers. No privileged, no caps, no hostPath, no SA token. Written up in `docs/exemptions/kaniko.md` with a review date |
| CI deploys into a cluster with egress blocked | "Works airgapped" is tested, not claimed |

| We don't | Because |
|---|---|
| Cosign signing, structural SHA "proof" | Over-scoped for the threat model; removed |
| TLS between services, ingress | Plain HTTP in-cluster + `kubectl port-forward` for now; cert-manager is the future path, documented |
| Host OS STIG, multi-node HA, off-node backups | Customer's platform team; stated in PREREQUISITES |

## What we deliberately don't do

- No custom controllers, operators or long-lived reconcilers.
- No Maven/npm/PyPI proxies in Nexus (useless in airgap without seeding).
- No Cilium, Longhorn, cert-manager, ingress — each is a good tool and each
  is more images, more moving parts, more to explain. Add when a real need
  appears, not before.
- No `--set` password plumbing; the Job reads the Secrets the charts create.

## Phases

Each phase ends green in CI and is independently useful.

**Phase 0 — Platform spike (1–2 weeks)**
RKE2 + `profile: cis` + `zarf init` in a no-egress VM. Confirm Zarf's own
pods admit under `restricted`. Ship `rke2/` bundle and install script.
*Exit: kube-bench passes, `zarf init` succeeds offline.*

**Phase 1 — Upstream-only Gitea + Jenkins (2 weeks)**
Delete `Dockerfile.wire` and the structural SHA. Plugin volume via
`plugins.txt`. wire-engine as in-cluster Job with idempotent Gitea/Jenkins
steps, reading chart Secrets. Egress-blocked kind CI job with Calico.
Digest pinning, `manifest.json`, `make verify-release`, `PROVENANCE.md`,
Zarf package signing.
*Exit: push to Gitea triggers a Jenkins pipeline, offline, on RKE2; a
second machine rebuilds the package and `verify-release` passes.*

**Phase 2 — Nexus + Kaniko (2 weeks)**
Postgres + `nxrm-ha` (CE, single replica) components. Wire engine creates
`docker-hosted`, seeds base image, adds Jenkins credential. `cf-build`
namespace, Kaniko exemption doc, NetworkPolicy. Demo Jenkinsfile builds
and pushes.
*Exit: image built in-cluster appears in Nexus, offline.*

**Phase 3 — Day-2 and docs (1 week)**
Upgrade test N-1 → N in CI. Define and document the advisory-to-media
cadence; add a `make bump` flow (Renovate PRs with digest diffs) so a
Jenkins/Gitea/Nexus advisory can become a verified, signed package in
days, not weeks. PREREQUISITES.md, RUNBOOK.md (three commands +
port-forward table + how to re-run wiring). Rewrite README and SECURITY.md.
Delete the ~20 stale planning/report `.md` files at repo root; this file
and `rafactor-vanilla-way.md` are the record.
*Exit: a new operator can install from the runbook alone.*

## Open risks (tracked, not blocking)

- `nxrm-ha` chart with Community Edition, single replica — needs the
  Phase 2 spike; fallback is raw manifests with `sonatype/nexus3`.
- Bitnami image distribution changes — confirm Postgres images are
  pullable before pinning, or use CloudNativePG.
- RKE2 CI needs a VM, not kind — slowest gate; decide PR vs nightly.
- kind's kindnet ignores `NetworkPolicy` — the egress test must install
  Calico or it passes for the wrong reason.

## Success looks like

An operator with no clusterfactory context, one USB stick, and a RHEL box
runs three commands, waits ten minutes, port-forwards to Jenkins, and sees
a green build that pushed an image to Nexus — and can explain every
component in the cluster by pointing at an upstream project page.
