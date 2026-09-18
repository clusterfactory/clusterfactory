# wire-engine/ — post-deploy wiring Job

`wire.py` converges the cross-service wiring (Gitea org/repo/Jenkinsfile →
integration user + token → Jenkins credential → Jenkins pipeline job). It
is stdlib-only Python, every step is check-then-act, and it prints one
`[status] step` line per step (`ok`, `created`, `updated`, `skipped`,
`failed`). A second run against a converged cluster prints only `ok`.

It runs as the Job templated by `charts/settings` (ADR 0002); wiring
logic never lives in Helm. The Gitea token it mints is stored in the
Secret `cf-wire-gitea-token` and reused on re-runs because Gitea tokens
cannot be read back.

Local dry run against a port-forwarded cluster is not supported on
purpose - it needs the in-cluster ServiceAccount for the Secret. Use
`kubectl logs -n clusterfactory -l app.kubernetes.io/name=cf-wire-engine`.
