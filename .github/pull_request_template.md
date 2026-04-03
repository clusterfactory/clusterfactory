## What does this PR do?

<!-- One paragraph. What changed and why. -->

## Type of change

- [ ] Bug fix
- [ ] New feature / enhancement
- [ ] Documentation
- [ ] Refactor (no behaviour change)
- [ ] CI / tooling

## Checklist

- [ ] `helm lint . --strict` passes locally
- [ ] `helm template cf . | kubectl apply --dry-run=client -f -` passes locally
- [ ] Tested with `helm upgrade --install` against a real cluster (Docker Desktop / kind / k3d)
- [ ] If touching `wire-job.yaml` — wire job completes and all resources are created
- [ ] If touching `runner-daemonset.yaml` — runner registers and shows online in Gitea
- [ ] If adding a new template — corresponding `helm test` job added in `templates/tests/`
- [ ] `values.yaml` updated if new configuration options added
- [ ] `README.md` updated if user-facing behaviour changed
- [ ] `CHANGELOG.md` entry added under `## Unreleased`

## How to test this PR

<!-- Exact commands a reviewer can run to verify the change. -->
<!-- Minimum: the helm install command and what to check afterwards. -->

## Related issues

<!-- Closes #123 -->
