# Exemption: Kaniko builds in `cf-build` at PSA `baseline`

Modelled on the UDS Core `Exemption` pattern: every deviation from the
cluster-wide `restricted` posture is written down here with scope,
justification and a review date.

| Field | Value |
|---|---|
| **Title** | Kaniko image builds run as uid 0 |
| **Scope** | Namespace `cf-build` only; pods created by the Jenkins Kubernetes plugin; container `kaniko` |
| **PSA level** | `baseline` (not `privileged`). The only `restricted` control violated is `RequireNonRootUser`; the root filesystem is writable because Kaniko unpacks layers into `/` |
| **Still enforced** | no `privileged`, no capabilities beyond the runtime default set (baseline forbids additions; `drop: ALL` is not possible because root then lacks `DAC_OVERRIDE`/`CHOWN`/`FOWNER` to write the agent workspace and extract layers), no hostPath, no host namespaces, seccomp `RuntimeDefault`, no ServiceAccount token, `allowPrivilegeEscalation: false` |
| **Network** | `cf-build` egress only to DNS and the `clusterfactory` namespace (Gitea, Jenkins, Nexus); no API server, no internet |
| **Justification** | Building OCI images from a Dockerfile without a daemon requires extracting layers with root-owned files; Kaniko is the maintained, daemonless way to do that. ADR 0009 |
| **Recorded alternative** | `ko` / Jib / `apko` need no root and would remove this exemption, at the cost of a language-specific demo. Revisit if an assessor rejects this exemption |
| **Owner** | clusterfactory maintainers |
| **Review date** | 2027-03-01 |
