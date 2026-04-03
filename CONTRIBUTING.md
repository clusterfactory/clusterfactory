# Contributing to clusterfactory

Thanks for your interest. This document covers how to develop, test, and submit
changes.

## Before you open a PR

- Check open issues and PRs to avoid duplicating work.
- For significant changes, open an issue first to discuss the approach.
- Bug fixes and documentation improvements can go straight to a PR.

## Local development setup

You need:
- Docker Desktop (or equivalent) with Kubernetes enabled
- `helm` >= 3.x
- `kubectl` configured against a local cluster

```bash
git clone https://github.com/clusterfactory/clusterfactory.git
cd clusterfactory
helm dependency build .
```

## Running the chart locally

```bash
helm upgrade --install cf . \
  --namespace cicd \
  --create-namespace \
  --atomic \
  --timeout 10m
```

Access the services:
```bash
kubectl port-forward -n cicd svc/cf-gitea-http 3000:3000 &
kubectl port-forward -n cicd svc/cf-jenkins 8080:8080 &
```

Jenkins password:
```bash
kubectl get secret cf-jenkins -n cicd \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d && echo
```

## Running tests

```bash
helm test cf --namespace cicd --timeout 5m --logs
```

Tests assert that the wire job completed correctly: Gitea org, repo, and files
exist; Jenkins job and credentials exist. All tests must pass before a PR is merged.

## Linting

```bash
helm lint . --strict
helm template cf . --namespace cicd | kubectl apply --dry-run=client -f -
```

## Making changes

### wire-job.yaml

The wire job is the most sensitive file in the chart. Changes here affect the
install experience for everyone. If you change the wire job:
- Test an install from scratch (not an upgrade from an existing release)
- Test an upgrade from the previous version
- Confirm `helm test` passes after both

### templates/tests/

Every new resource created by the wire job should have a corresponding assertion
in `templates/tests/`. Tests use the same alpine image and curl pattern as the
wire job — see existing test files for the pattern.

### values.yaml

- New configuration options must have a comment explaining what they do
- Defaults must work out of the box on Docker Desktop with no --set flags
- Do not add options that require the user to know cluster internals (storage class
  names, node selectors, etc.) without a sensible default or clear documentation

### Chart.yaml

Bump the chart `version` field for any change that affects rendered templates or
values. Use semver: patch for bug fixes, minor for new features, major for breaking
changes.

## Changelog

Add an entry under `## Unreleased` in `CHANGELOG.md` for every PR. Follow the
format already in the file (Added / Changed / Fixed / Removed). The release
maintainer promotes Unreleased to a versioned section on release.

## CI

Every PR runs:
1. `helm lint --strict`
2. `helm template` dry-run
3. Full install against k3d
4. `helm test`

All four must pass. If CI fails on your PR, check the Actions tab for logs. The
most common failure is the wire job timing out — check the wire job logs step in
the CI output.

## Commit messages

No strict convention required, but:
- First line: short imperative summary (`fix wire job timeout on slow clusters`)
- Keep it under 72 characters
- Reference the issue if applicable (`fixes #42`)

## Code of conduct

Be direct, be constructive, assume good faith. Low-effort or abusive interactions
will be closed without comment.
