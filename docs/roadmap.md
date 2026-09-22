# Roadmap

What is ahead, in the order it is likely to happen. Decisions are taken in
ADRs when the work starts; nothing here is promised.

| Item | What | Why / ADR |
|---|---|---|
| Policy profiles | `policy/baseline` (default-deny egress, PSA restricted, the current `charts/config` denies) and `policy/cis` (RKE2 CIS profile, audit) as separate packages; the preflight reads the applied profile | ADR 0016; the forge stops carrying customer policy |
| Ubuntu flavor of the init package | deb variant of the `rke2` component (no SELinux RPMs, AppArmor) | ADR 0015 |
| Ingress | Traefik `Ingress` by hostname (`INGRESS_CLASS`, `BASE_DOMAIN`), port-forward stays the fallback; TLS via a policy profile | ADR 0010 |
| Registry on a PVC | the Zarf registry's storage as an override of the init package | ADR 0015 |
| Argo CD | optional component, off by default | ADR 0013 |
| Backups | etcd snapshot + PV backup procedure; upgrade of RKE2 in place | ADR 0014 Q9 |
| `registry1` flavor | Iron Bank images; one values file per app, one component | ADR 0003 |
| v0.4.0 | first release carrying the all-in-one init package | — |

Recently done: the all-in-one init package (one `zarf init` on a bare host),
the preflight contract, CI on a physically air-gapped host — see
[`CHANGELOG.md`](../CHANGELOG.md).
