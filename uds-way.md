# Refactor: clusterfactory → UDS-style Zarf packages (upstream flavor)

Audience: Claude Code, working in the `clusterfactory/clusterfactory` repo.
Read this whole file before touching anything. Every section marked
**DECIDED** is settled; sections marked **OPEN** need a spike or a question
back to the human before implementing.

## 0. Why we are doing this

clusterfactory today is one monolithic `zarf.yaml` wrapping a root Helm
chart (Gitea + Jenkins as dependencies), with cross-service wiring baked
into a custom Jenkins image (`images/jenkins/Dockerfile.wire`) and a Python
"wire engine" run from the operator's machine after deploy. It works as a
demo but has three structural problems:

1. No separation between "unmodified upstream" and "clusterfactory glue" —
   every customization is a diff against upstream charts.
2. No mechanism for alternate image sources (hardened/Iron Bank/Chainguard)
   without editing values in place.
3. Wiring lives in an image build, so "vanilla upstream Jenkins" is not
   actually true.

Defense Unicorns' UDS packages have solved exactly this shape of problem
over years of real airgapped deployments. We adopt their **repo anatomy and
conventions** (not UDS Core, not Istio, not the UDS Operator — none of that
is a dependency here). Where their pattern is a poor fit for a lightweight
Gitea + Jenkins + Nexus forge, this doc says so and what we do instead.

Reference material Claude Code should read before implementing:

- UDS package anatomy (structure + GitLab walkthrough):
  https://uds.defenseunicorns.com/structure/packages/
- UDS package developer guide:
  https://github.com/defenseunicorns/uds-common/blob/main/docs/uds-packages/guide.md
- UDS package template repo: https://github.com/uds-packages/template
- Zarf's own Gitea package (canonical "deploy chart, then wire via API"
  example, incl. wait/retry/onFailure actions):
  https://github.com/zarf-dev/zarf/blob/main/packages/gitea/zarf.yaml
- Zarf docs: https://docs.zarf.dev (components, actions, healthChecks,
  variables, flavors, publish/OCI)

## 1. Principles (DECIDED)

1. **The package contains only unmodified upstream charts and images, plus
   our values and our helper charts.** No custom application image builds.
   If a component works only because CI had internet, it is a bug.
2. **Flavor = image provenance only.** Behaviour, charts, deploy order and
   wiring are identical across flavors. Only `values/<flavor>-values.yaml`
   and the component `images:` list change per flavor. We ship
   **`upstream` flavor only** for now; the seam exists for `registry1`/
   `chainguard`/etc. later.
3. **Wiring is a post-deploy, in-cluster, idempotent Job**, delivered as a
   Helm "settings" chart whose only responsibility is to template the Job
   manifest. All wiring *logic* stays in Python inside the Job's image.
   Never put wiring logic in Helm templates or Helm hooks.
4. **Auditable means:** signed package (cosign, native to Zarf), SBOM per
   image (native to Zarf, published per release), image digests pinned,
   ADRs for every decision, and a minimal OSCAL component definition.
   The old "structural SHA" is dropped — it was invented, non-standard, and
   auditors don't know what it is.
5. **Trusted-operator threat model.** `CHANGEME`-style default passwords
   in values are acceptable; anyone with `kubectl` already has full
   control. Do not build credential-secrecy machinery.
6. **Airgap is enforced, not assumed.** Deny-all-egress `NetworkPolicy` is
   shipped in the package; CI proves zero egress with a CNI that enforces
   policy.

## 2. Target repo layout (DECIDED)

```
clusterfactory/
├── zarf.yaml                  # root: variables + one component per flavor,
│                              # each importing common/ (upstream only today)
├── common/
│   └── zarf.yaml              # base ZarfPackageConfig: charts in order,
│                              # healthChecks, actions. Flavor-agnostic.
├── charts/
│   ├── config/                # helper chart deployed BEFORE the apps:
│   │                          #   namespace labels (PSA), NetworkPolicies,
│   │                          #   admin Secrets the apps will consume
│   └── settings/              # helper chart deployed AFTER the apps:
│                              #   templates the wire-engine Job + RBAC
├── values/
│   ├── common-values.yaml     # config identical across flavors
│   └── upstream-values.yaml   # image repos/tags for upstream flavor
├── wire-engine/               # Python source + Dockerfile for the Job image
│   ├── Dockerfile             # python:3.x-slim, stdlib only, no pip
│   └── wire.py
├── jenkins/
│   ├── plugins.txt            # pinned plugin versions
│   └── plugins/               # resolved .hpi closure (generated, committed
│                              # or built in CI — see §5)
├── rke2/                      # platform layer, unchanged in scope (see §9)
├── adr/                       # one dated file per decision (see §10)
├── bundle/                    # test bundle: deploys package + throwaway
│                              # deps on a kind/k3d cluster. Never shipped.
├── tests/                     # integration checks run against bundle/
├── tasks/ + tasks.yaml        # maru/uds-cli task runner entrypoints
│                              # (or Makefile — see §12 OPEN)
├── oscal-component.yaml       # minimal NIST 800-53 mapping (see §8)
├── docs/exemptions/kaniko.md  # declared PSA exemption
├── renovate.json
└── README.md, SECURITY.md, CONTRIBUTING.md
```

Delete: `images/jenkins/Dockerfile.wire`, root `Dockerfile.wire`, the root
`Chart.yaml`/`values.yaml` umbrella chart (replaced by per-app upstream
charts referenced directly from `common/zarf.yaml`), all structural-SHA
code paths.

## 3. `common/zarf.yaml` shape (DECIDED)

One component, `clusterfactory`, with charts **in this exact order** (Zarf
deploys charts in listed order — use that instead of ad-hoc sequencing):

1. `cf-config` (`charts/config`) — namespaces with PSA labels,
   deny-all-egress + allow-DNS + allow-in-cluster `NetworkPolicy`, admin
   password Secrets for Gitea/Jenkins/Nexus/Postgres, the `cf-build`
   namespace at `baseline` with its own restrictive `NetworkPolicy`.
2. `postgresql` — upstream chart (see §6 OPEN for which one).
3. `gitea` — upstream chart `https://dl.gitea.com/charts/`, rootless image.
4. `jenkins` — upstream chart `https://charts.jenkins.io`, with the plugin
   volume mounted and `installPlugins: []`.
5. `nexus` — Sonatype `nxrm-ha` chart, single replica, Community Edition
   (see §6 OPEN).
6. `cf-settings` (`charts/settings`) — the wire-engine Job.

Readiness gating: prefer Zarf's component-level **`healthChecks:`** (kstatus
based, waits on arbitrary resources — Deployments/StatefulSets/Jobs) over
`actions.onDeploy.after: wait:` on pod labels. Use `wait:` only where
`healthChecks` can't express the condition. Copy the action structure from
Zarf's own Gitea package for the wire step:

```yaml
actions:
  onDeploy:
    after:
      - wait:
          cluster:
            kind: job
            name: cf-wire-engine
            namespace: clusterfactory
            condition: complete
        maxTotalSeconds: 600
        description: Wait for wiring to converge
    onFailure:
      - cmd: ./zarf tools kubectl logs -n clusterfactory job/cf-wire-engine --tail=200
        description: Dump wire-engine logs on failure
```

`zarf package deploy` must fail loudly if wiring does not converge.

Images: every image referenced by every chart's values goes in the root
`zarf.yaml` component `images:` list for the flavor. Use
`zarf dev find-images` to generate the initial list, then **pin to
digests** (`repo:tag@sha256:...`) in `values/upstream-values.yaml` and the
`images:` list. Renovate keeps them current (§11).

## 4. `charts/settings` — the wire engine (DECIDED)

The chart contains exactly:

- `templates/job.yaml` — a `batch/v1 Job`, `backoffLimit: 3`,
  `ttlSecondsAfterFinished` unset (keep it for logs/audit),
  `restartPolicy: Never`, non-root `securityContext` admitting under PSA
  `restricted`, env from the Secrets `cf-config` created, service DNS
  names/ports from values.
- `templates/rbac.yaml` — ServiceAccount + minimal Role (read Secrets in
  its namespace only, if needed at all).
- `values.yaml` — image (repo/tag/digest), Gitea/Jenkins/Nexus service
  hosts + ports, demo org/repo names, feature flags per deployment mode.

The Job's image is `wire-engine/Dockerfile`: `python:3.x-slim`, stdlib
`urllib`/`json`/`base64` only, **no pip**, so there is nothing to mirror.

`wire.py` steps, **every one idempotent (check-then-act)**:

1. Gitea: ensure org `cf-demo` and repo `hello-world` exist; ensure
   `Jenkinsfile` content matches (update if drifted).
2. Gitea: ensure an API token for the Jenkins integration user exists
   (create if missing; tokens are not re-readable, so store it in a
   Kubernetes Secret the Job owns and reuse it on re-run).
3. Jenkins: ensure credential `gitea-token` exists with that token
   (update in place).
4. Jenkins: ensure pipeline job `cf-demo-hello-world` exists pointing at
   the Gitea repo (update config.xml in place).
5. Nexus: ensure `docker-hosted` repository exists (HTTP connector on a
   fixed port, anonymous pull off).
6. Nexus: ensure a deploy user exists; store as Jenkins credential
   `nexus-docker` (update in place).
7. Nexus: ensure the demo base image (e.g. `alpine`) is present in
   `docker-hosted` — copy it from the in-cluster Zarf registry
   (`zarf-docker-registry.zarf.svc.cluster.local:5000`) using Docker
   Registry API v2 blob mount/push from Python, no docker daemon.
8. Exit 0 only if all steps converged; log a one-line summary per step
   (`ok`, `created`, `updated`, `skipped`).

Re-run semantics: `zarf package deploy` over an existing install runs
`helm upgrade` per chart and re-creates the Job (Helm replaces it because
the chart is upgraded; if it doesn't, set an annotation with the release
revision so the spec changes). Operator can also `kubectl delete job` +
redeploy. No long-lived controller.

## 5. Jenkins plugins without a custom image (DECIDED)

- `jenkins/plugins.txt` pins exact versions of: `gitea`,
  `workflow-aggregator`, `kubernetes`, `credentials-binding`, `git`, and
  whatever the demo Jenkinsfile needs.
- `make plugins` (or `uds run plugins`) runs `jenkins-plugin-cli` in a
  throwaway container on the connected side to resolve the full transitive
  closure into `jenkins/plugins/`.
- A Zarf component `jenkins-plugins` ships that directory as `files:` into
  a PVC via an initContainer (or a ConfigMap if under size limits — it
  won't be; use the PVC route), mounted at `$JENKINS_HOME/plugins`.
- Upstream Jenkins chart values: `controller.installPlugins: []`,
  `controller.initializeOnce: true`, update center disabled.
- CI gate: Jenkins must reach Ready in an egress-blocked cluster with every
  plugin in `plugins.txt` reported loaded (`/pluginManager/api/json`).

## 6. Nexus + PostgreSQL (OPEN — needs a spike before step 5 in §13)

- **Nexus chart:** Sonatype's official `nxrm-ha` (the community
  `nexus-repository-manager` chart is archived). Run single-replica with
  Community Edition. HA needs Pro, but the chart is expected to work with
  one replica. **Spike first:** confirm CE image + `nxrm-ha` + external
  Postgres actually boots. Fallback: raw manifests with `sonatype/nexus3`
  and its embedded H2 store (acceptable for a demo; document the
  limitation).
- **Postgres chart:** `nxrm-ha` needs external Postgres. Options, in
  preference order:
  1. **CloudNativePG** operator — actively maintained, freely pullable
     images, single-replica cluster CR is tiny; more images to mirror.
  2. Zalando `postgres-operator` — this is what the UDS ecosystem packages
     (`ghcr.io/uds-packages/postgres-operator`); proven in airgap.
  3. Bitnami `postgresql` — **only if** images are still freely pullable;
     Bitnami changed distribution in 2025. Verify before pinning.
  Pick by image count + airgap friendliness; record in an ADR.
- Do not reuse Gitea's bundled Postgres. Keep services decoupled.
- Wiring scope for Nexus: **Docker hosted registry only.** No
  Maven/npm/PyPI proxies — proxies are useless with zero egress.

## 7. In-cluster builds: Kaniko (DECIDED, with recorded alternative)

- `gcr.io/kaniko-project/executor` pinned by digest in the `images:` list.
- Jenkins Kubernetes plugin runs builds as pod agents in namespace
  `cf-build`; the demo Jenkinsfile uses a `kaniko` container with the
  Nexus credential mounted as `/kaniko/.docker/config.json`.
- Demo Dockerfile `FROM nexus-docker.clusterfactory.svc:<port>/alpine` —
  never Docker Hub. Nexus is the only registry the pipeline knows.
- Plain HTTP: `--insecure --skip-tls-verify` accepted under the threat
  model; cert-manager with a cluster CA is the documented upgrade path.
- PSA: `cf-build` at `baseline` (not `privileged`). Kaniko runs uid 0 and
  violates only `RequireNonRootUser`; no privileged, no caps, no hostPath,
  no SA token, seccomp `RuntimeDefault`, root fs writable (Kaniko writes to
  `/` and `/kaniko`). `NetworkPolicy` on `cf-build` allows egress only to
  Gitea and Nexus. Exemption recorded in `docs/exemptions/kaniko.md`
  (title, scope, justification, review date), modelled on UDS Core's
  `Exemption` pattern.
- **Recorded alternative:** `ko` / Jib / `apko` need no root and would
  remove the exemption, at the cost of a language-specific demo. Revisit
  if the exemption becomes a blocker for an assessor.

## 8. Auditability artifacts (DECIDED)

- **Signing:** `zarf package create --signing-key cosign.key`; publish
  `cosign.pub` in the repo and in the release. Consumers deploy with
  `--key`. Do not remove this — it is native, free, and expected.
- **SBOMs:** Zarf generates them at create time. CI extracts them
  (`zarf package inspect sbom --output sboms/`) and attaches the directory
  to every GitHub release. Add a CI job that scans them (grype or trivy)
  and fails on critical CVEs with no fix, mirroring what the SWF repos do.
- **`oscal-component.yaml`:** minimal component definition mapping what we
  actually enforce to NIST 800-53 control IDs — PSA restricted (CM-7,
  AC-6), NetworkPolicy deny-all (SC-7), secrets encryption at rest (SC-28),
  audit logging via RKE2 CIS profile (AU-2/AU-12), signed artifacts +
  SBOM (SA-10, SR-4). Validate with Lula in CI if practical; otherwise
  schema-validate only. Keep it small and true; do not claim controls we
  don't enforce.
- **Digest pinning** for every image (see §3); Renovate (§11) updates the
  digests so pins don't rot.
- **ADRs** (§10) are the human-readable audit trail.

## 9. Platform layer: RKE2 (DECIDED, unchanged)

Kept as previously specified — nothing in Zarf or UDS examples covers
standing up the cluster, so there's nothing to borrow.

```
OS (customer) → RKE2 airgap install → zarf init → zarf package deploy
```

- `rke2/`: pinned version, airgap image tarball, install script, hardened
  `config.yaml` (`profile: cis`, `secrets-encryption: true`, `cni: canal`,
  `disable: rke2-ingress-nginx`), local-path-provisioner manifest dropped
  into the RKE2 manifests dir, set as default StorageClass. Stateful pods
  and the Zarf registry pinned to the storage node via `nodeSelector`.
- Install script must create the `etcd` user/group and apply the CIS
  sysctls **before** `systemctl start rke2-server` or first boot fails.
- Zarf init package version pinned to match the `zarf` CLI; verify the
  pinned Zarf agent/registry admit under PSA `restricted` on a CIS cluster
  (recent versions do).
- Out of scope, stated in PREREQUISITES: host OS STIG, etcd snapshot
  off-node cadence, multi-node HA.

## 10. ADRs replace the Decisions table (DECIDED)

Create `adr/NNNN-<slug>.md` (Context / Decision / Consequences / Date) for
each of the following at minimum. Migrate the existing Decisions table
into these; delete the table.

- 0001 adopt UDS package anatomy without UDS Core
- 0002 wiring as settings-chart Job, logic in Python, never in Helm
- 0003 upstream flavor only; flavor = image provenance
- 0004 keep cosign + SBOM, drop structural SHA
- 0005 trusted-operator threat model; CHANGEME defaults acceptable
- 0006 Jenkins plugins via pre-bundled volume, `installPlugins: []`
- 0007 Nexus `nxrm-ha` single replica CE (after spike)
- 0008 Postgres chart choice (after spike)
- 0009 Kaniko + `cf-build` baseline exemption
- 0010 plain HTTP + port-forward; cert-manager as upgrade path
- 0011 RKE2 CIS profile, Canal, local-path storage
- 0012 single package vs per-app packages + bundle (see §12)

## 11. CI gates (DECIDED)

Every PR runs, in order; every gate must pass:

1. **Lint/schema:** `zarf dev lint`, Helm lint on helper charts, yamllint,
   OSCAL schema check.
2. **Create:** `zarf package create . -f upstream --confirm` on a connected
   runner; extract SBOMs; CVE scan.
3. **Airgapped deploy:** kind cluster with **Calico or Cilium** (kindnet
   does not enforce `NetworkPolicy` — the test is a silent no-op without
   this), default-deny egress applied to all namespaces, `zarf init`,
   `zarf package deploy --key`, assert all pods Ready, wire Job Complete,
   all Jenkins plugins loaded.
4. **Functional:** push to `cf-demo/hello-world` (via port-forward from the
   runner), assert the pipeline runs, Kaniko builds, image lands in Nexus
   `docker-hosted`.
5. **Upgrade (N-1 → N):** deploy the previous release tag, then the current
   package over it; assert PVC data (demo repo, Jenkins job, Nexus image)
   survives and the wire Job converges with only `ok`/`skipped` lines.
6. **RKE2 (slow, VM-based, nightly or on `rke2/` changes only):** boot RKE2
   from the airgap bundle in a VM with no egress, `zarf init`, run
   `kube-bench` for the RKE2 CIS profile, then run gate 3 against it.

Renovate config: group chart bumps, image digest bumps, Jenkins plugin
bumps, and CI-action bumps into separate PRs; pin `zarf`/`uds` CLI
versions and bump them explicitly.

## 12. Single package vs per-app packages + bundle (OPEN — ADR 0012)

Two viable end states:

**A. One Zarf package** (this doc's default): `common/zarf.yaml` holds all
six charts in one component. Simplest transfer story, one signature, one
SBOM set, one `zarf package deploy`. Downside: Gitea, Jenkins, Nexus and
Postgres version together; swapping Nexus for something else means editing
the shared package.

**B. Per-app Zarf packages + one UDS bundle** (the UDS model): separate
`packages/{postgres,gitea,jenkins,nexus,wire-engine}/zarf.yaml`, composed
by `uds-bundle.yaml` with `overrides` and deploy-time `variables`.
`uds-cli` bundles do **not** require UDS Core. Upside: independent
versioning, per-app swapping, bundle-level variables are the natural home
for "deployment modes". Downside: a second CLI (`uds`) in the toolchain,
more moving parts, and Zarf's `healthChecks`/actions become per-package.

**Recommendation:** ship **A** for this refactor, but structure
`common/zarf.yaml` so each app's chart + values + images are self-contained
blocks that can be lifted into per-app packages later. Re-evaluate for
**B** when either a second deployment mode or a Nexus→Artifactory swap is
actually requested. Record in ADR 0012.

Also OPEN: task runner. UDS repos use `tasks.yaml` + `uds run` (maru).
That's a good fit if we go **B**; if we stay **A**, a plain `Makefile` is
fewer dependencies. Decide together with ADR 0012.

## 13. Migration steps (DECIDED order; each step is a PR that passes CI)

0. Add `adr/` with ADRs 0001–0006 and 0009–0011 written up front from this
   doc. Add `renovate.json`. Add the lint gate (§11.1).
1. Create the new layout skeleton: `common/zarf.yaml`, root `zarf.yaml`
   with the single `upstream` flavor component importing `common/`,
   `values/common-values.yaml`, `values/upstream-values.yaml`,
   `charts/config`, `charts/settings` (empty templates), `bundle/`,
   `tests/`. Wire the create gate (§11.2). Package must build even if it
   deploys nothing useful yet.
2. Move Gitea and Jenkins to upstream charts referenced from
   `common/zarf.yaml`. Delete the umbrella chart and both `Dockerfile.wire`
   files. Add `securityContext` to every values file so pods admit under
   PSA `restricted`. Add the egress-blocked deploy gate (§11.3) — from
   here on every PR must pass it.
3. `charts/config`: namespaces + PSA labels, deny-all-egress
   `NetworkPolicy`, admin Secrets. Disable update checkers/telemetry in
   Gitea and Jenkins values.
4. Jenkins plugin volume (§5). Gate: Jenkins Ready with all plugins loaded
   in the airgapped cluster.
5. Wire engine (§4): `wire-engine/` image + `charts/settings` Job + RBAC,
   steps 1–4 only (Gitea + Jenkins), fully idempotent. `healthChecks` +
   `wait: condition: complete` + `onFailure` log dump in `common/zarf.yaml`.
   Remove all structural-SHA code. Gate: wire Job Complete; second deploy
   yields only `ok`/`skipped`.
6. **Spike (§6):** `nxrm-ha` CE single replica + chosen Postgres chart on
   the egress-blocked cluster. Write ADRs 0007/0008 with the result. If the
   spike fails, take the fallback and say so in the ADR.
7. Add Postgres and Nexus components per the spike. Extend `charts/config`
   with their Secrets and `NetworkPolicy` entries. Disable Nexus outreach/
   telemetry.
8. Wire engine steps 5–7 (Nexus repo, credential, base-image pre-seed).
   Add Kaniko executor + demo base image to `images:`. `cf-build`
   namespace, exemption doc, `NetworkPolicy`. Update the demo Jenkinsfile
   to build with Kaniko and push to Nexus. Add the functional gate (§11.4).
9. Signing + SBOM publishing + CVE scan in CI (§8). `oscal-component.yaml`.
   Add the upgrade gate (§11.5).
10. `rke2/` bundle and the VM-based RKE2 gate (§11.6).
11. Docs: README (install flow, port-forward access, what's in the
    package), SECURITY.md (threat model, what is and isn't enforced, the
    Kaniko exemption), CONTRIBUTING.md (how to add a flavor, how to add a
    wiring step), PREREQUISITES.md. Delete `refactor-to-zarf.md` and
    `DEPLOYMENT_MODES_IMPLEMENTATION.md` once their content lives in ADRs.
12. Tag a release; attach `.tar.zst`, `cosign.pub`, SBOMs. Optionally
    `zarf package publish oci://ghcr.io/clusterfactory/clusterfactory`.

## 14. Remaining risks

- `nxrm-ha` + CE + single replica is unverified until the §6 spike.
- Jenkins plugin closure must resolve offline; a missing transitive plugin
  only shows up at boot in the airgapped cluster — the §5 CI gate exists
  to catch exactly this.
- Bitnami distribution changes may make its Postgres images unpullable;
  prefer CloudNativePG or Zalando.
- kind + kindnet silently passes the egress test; CI **must** install
  Calico or Cilium.
- Zarf's registry NodePort is on `127.0.0.1:31999` by default; the wire
  Job must use the in-cluster `zarf-docker-registry.zarf.svc` Service, and
  the `NetworkPolicy` for the `clusterfactory` namespace must allow egress
  to the `zarf` namespace on that port.
- Nexus CE has a component/request cap (3.77+); a demo won't hit it;
  document it.
- Kaniko vs `readOnlyRootFilesystem` conflicts; keep root fs writable and
  lock everything else down.
- Zarf `healthChecks` field availability depends on the pinned Zarf
  version; if too old, fall back to `wait:` actions and note it.
- RKE2 CI needs a VM, not kind. It will be the slowest gate; keep it
  nightly/path-filtered.
- Gitea API tokens are not re-readable after creation; the wire engine
  must persist its token in a Secret or it will create a new token on
  every run (idempotency failure, token sprawl).