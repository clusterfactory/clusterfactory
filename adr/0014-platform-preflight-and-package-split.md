# 0014 — Three layers: platform invariants, the preflight contract, customer policy

**Status:** Accepted
**Date:** 2026-09-20 (proposed and decided the same day; answers to the Q1–Q12 list are folded in here, ADR 0015 and ADR 0016)

## Context

Everything above the cluster is one Zarf package with strong guarantees.
Everything below it - OS, RKE2, storage, node network - was a script and a
tarball (ADR 0011), and real deployments fail at that seam: a CNI that does
not enforce NetworkPolicy, no default StorageClass, too little memory, an
API server the egress policy cannot express. At the same time, hardening
choices (CIS profile, PSA levels, deny-all egress, SELinux, TLS) differ per
customer, and baking them into the forge package makes it wrong for anyone
whose stance differs.

## Decision

**Rule of thumb:** if changing a setting changes what has to be *tested*, it
is a platform decision and stays fixed. If it only changes what is
*permitted*, it is policy and the customer owns it. That gives three layers.

### 1. Platform invariants (fixed, no knobs)

RKE2 ≥ v1.36 (`v1.36.4+rke2r1` pinned), **single node**, Canal, local-path
provisioner, image loading by tarball in the agent images directory, Zarf
init. Delivered as a custom Zarf init package with an `rke2` component
(ADR 0015). RKE2 configuration is written as drop-ins under
`/etc/rancher/rke2/config.yaml.d/`: the platform writes `10-platform.yaml`,
the policy profile writes `50-policy.yaml`.

Designed for one VM; multi-node join is not precluded (join variables kept,
`tls-san` set to a stable DNS name so the API endpoint is never a hardcoded
node IP). Three control planes are for the clusters the factory builds
later, not for the factory itself.

### 2. The contract: what the forge needs from any cluster (preflight)

The forge package depends only on this contract, never on the platform
package. A `preflight` component - first in `common/zarf.yaml`, actions
only - makes it executable; `PREREQUISITES.md` is generated from the same
table. **Contract checks are never bypassable**; advisory checks can be
skipped with `--set PREFLIGHT_STRICT=false`.

| Check | Class |
|---|---|
| Kubernetes ≥ 1.30; API reachable; `zarf init` present and the Zarf registry reachable from a pod | contract |
| A default `StorageClass` exists and a test PVC binds | contract |
| Cluster DNS resolves Services | contract |
| Pod Security Admission active: a privileged pod is rejected in a `restricted`-labelled test namespace, and `cf-build` may be `baseline` | contract |
| NetworkPolicy enforcement: positive control first (a pod reaches the API server), then deny-all applied, then the same connection must fail; throwaway namespace deleted afterwards. Run on **every** deploy - it takes seconds and customer clusters are where enforcement silently fails | contract |
| `kubernetes` EndpointSlice resolves to addresses the egress policy can express as `ipBlock` | contract |
| Allocatable CPU/memory/disk headroom for Gitea + Jenkins + Nexus + a build | advisory |
| Internet reachable from a pod | decided by the active policy profile (failure under `cis`, warning under `baseline`) |

### 3. Customer policy (flexible, forkable)

CIS profile on/off, PSA configuration, audit policy, default-deny and egress
stance, SELinux/firewalld expectations, TLS/CA, whether reachable internet
is a failure. Shipped as a small separate package
`clusterfactory-policy-<profile>` with `baseline` and `cis` as examples
(ADR 0016). **The forge ships only NetworkPolicy *allow* rules; the policy
package ships the *denies*** - so the forge is correct under any stance and
the deny-all is a customer decision they can read. Preflight reads the
active profile to decide which checks are hard.

### Other decisions from the question list

- **OS:** check and refuse; never configure the OS beyond what the policy
  profile asks for (the `etcd` user and CIS sysctls are consequences of
  `profile: cis`, applied only then). Zarf flavors of the init package per OS
  family: the RPM flavor carries `rke2-selinux` and `container-selinux`;
  preflight verifies their dependencies are installed rather than resolving
  RPMs offline. Tested on one RPM distro and Ubuntu.
- **Storage:** local-path by default, preflight as the contract so a customer
  with real storage skips ours. The local-path image travels in the host
  tarball directory and is deployed through
  `/var/lib/rancher/rke2/server/manifests/` into `kube-system` (which the
  Zarf agent ignores) - it must exist before the Zarf registry's PVC. The
  Zarf registry uses a PVC from local-path, not hostPath, so persistence is
  the same on customer clusters. Single-node mitigation is backup (etcd
  snapshots + PV backup procedure), a v0.5 item.
- **Ingress:** RKE2's bundled Traefik (default from v1.36; ingress-nginx is
  removed in v1.37) with hostPort 80/443 on the single node, **plain HTTP
  Ingress by hostname in v0.4**; TLS is v0.5 and belongs to policy (customer
  CA or self-signed, injected into Jenkins and Kaniko trust). Port-forward
  stays as the fallback. Amends ADR 0010.
- **Image loading:** manual tarballs placed by the `rke2` component - the
  `core` and `canal` tarballs rather than the all-in-one, plus a small
  tarball for local-path. Hauler only for the clusters the factory builds.
- **Upgrades:** manual, etcd snapshot first; promise is that PVC data and the
  Zarf registry contents survive, and a single node means downtime. Tested
  N-1→N nightly. `system-upgrade-controller` is for factory-built clusters.
- **Platform gate:** tier 1 nightly - RKE2 installed directly on a GitHub
  runner from the artifacts, egress blocked with iptables after the
  download (~10 min, no nested VM). Tier 2 weekly and before each release -
  a self-hosted Rocky VM, SELinux enforcing, snapshot-revert.
- **Deliverable:** a plain tar (no recompression) built early, because the
  nightly gate needs it anyway: the Zarf binary, the custom init package,
  the forge package, the example policy profiles, `cosign.pub`, a signed
  `SHA256SUMS`, a ten-line install script and the runbook.
- **Reusable bootstrap:** the `rke2` component is parameterised by role,
  server URL, token and policy profile from day one, even though the
  factory only ever uses `server` with one node, because the factory later
  builds real clusters the same way.

## Amendments 2026-09-20 (before 10a was built)

**Hostnames / Ingress (10c):**
- `INGRESS_CLASS` is a variable; empty means *create no Ingress objects*
  (customer clusters will not be `traefik`; kind has no controller).
- No `registry.` hostname in v0.4: nothing in the demo needs the Zarf
  registry outside the node, and exposure is a "what is permitted" question
  - a profile's.
- Two URL sets: external URLs (Gitea `ROOT_URL`, Jenkins location URL)
  follow `BASE_DOMAIN`; all wiring (webhooks, checkouts, Kaniko pushes)
  stays on Service names. Nothing hashes the external URLs (the structural
  SHA is gone, ADR 0004), so `BASE_DOMAIN` cannot change any "proof".
- Runbook: git is HTTP-only in v0.4 (SSH does not go through the Ingress);
  Gitea redirects to `ROOT_URL` even over port-forward, so the fallback
  needs the hosts entry too; the deploy prints the exact `/etc/hosts` line.

**Airgap proof, split in two claims instead of weakened:**
1. *"Deploys with zero egress"* - a property of the package alone, proven
   by the runner-native gate with egress blocked.
2. *"Workloads cannot call out at runtime"* - needs the package **plus a
   profile**.

Consequences of moving denies into profiles: allow rules are only tested
under default-deny (a missing allow is invisible without a deny), so
**`baseline` must include default-deny** - it is not a lighter profile -
and **CI runs the forge under both `baseline` and `cis`**. Namespace names
become an interface: profiles create the forge's namespaces (PSA labels and
denies are namespaced) before the forge deploys; the forge publishes the
list in `contract/namespaces.yaml` and tolerates namespaces that already
exist (`lookup`-guarded creation in `charts/config`).

**Preflight specifics (10a):** every contract check is shown *failing* in
CI (a second RKE2 with `cni: flannel` for enforcement and no StorageClass
for storage - RKE2 is the only cluster this project tests on); it runs as a Zarf
action with `./zarf tools kubectl` so the host needs no kubectl; the
component lists its own test image; test pods pass PSA `restricted`; the
throwaway namespace is deleted in `onFailure` too; results are emitted as
data (`cf-system/cf-preflight-result` ConfigMap + JSON on stdout) so the
nightly job can assert which checks ran and how each was classified.

## Consequences

- Three packages instead of one: init (platform), policy profile, forge.
  One transport, one signing key, one verification story.
- `charts/config` changes: the deny-all NetworkPolicies move to the policy
  package; cf-config keeps namespaces, PSA labels, Secrets and the allow
  rules. CI deploys with the `baseline` profile so the egress test keeps
  meaning.
- The forge refuses to deploy where it cannot honour its guarantees, with a
  message an operator can act on, instead of a Helm timeout later.
- `PREREQUISITES.md` is generated, never hand-written.
- Things that are now explicitly *not* ours: host OS STIG, HA control
  planes, off-node backup cadence (documented, v0.5 for backup procedure).
