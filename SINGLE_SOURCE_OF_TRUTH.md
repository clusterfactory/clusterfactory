# Single Source of Truth: component versions and dependencies

For each opinionated service in clusterfactory (currently Gitea and Jenkins),
**one Python module** is the source of truth for:

- Service version (image tag)
- Required dependencies (plugins, extensions)
- Configuration the engine assumes is present

After v0.3, that module lives at:

```
engine/src/clusterfactory_engine/components/<service>.py
```

Anything else that mentions a version — Helm values, Zarf component image
list, Dockerfile base image — must agree with the component module, and
disagreements are resolved by editing the module first and reconciling
downstream.

## Why this pattern

Without it, version constants drift. Helm values say `1.23.6`, Zarf
bundles `1.23.5`, the Dockerfile pulls `1.24.0`, the Python component
expects API shapes from `1.22`. By the time someone notices, three teams
are debugging the same problem.

By contrast: when the constant lives in one place and everything else
references that place (or is generated from it), an upgrade is "edit one
file, run `make package`, run `make test-e2e`."

## Where the constants live today

### Jenkins

`engine/src/clusterfactory_engine/components/jenkins.py`:

```python
JENKINS_VERSION = "2.541.3-jdk21"
PLUGINS = [
    "plain-credentials",
    "credentials",
    "git",
    "workflow-aggregator",
    "workflow-job",
]
```

These flow downstream to:

| File | What it pins | How it stays consistent |
|------|--------------|-------------------------|
| `zarf.yaml` | `jenkins/jenkins:2.541.3-jdk21` image | Manual; covered by `test_zarf_package.py` drift checks |
| `values/jenkins.yaml` | chart `controller.image.tag` | Manual |
| `images/jenkins/Dockerfile` (if a custom image is built) | `FROM jenkins/jenkins:2.541.3-jdk21` and the plugin list | Manual |

### Gitea

`engine/src/clusterfactory_engine/components/gitea.py` carries the
expected version via the image tag it asserts against. The same pattern
applies to `zarf.yaml` and `values/gitea.yaml`.

## Upgrading

1. Edit the component module — bump `JENKINS_VERSION` (or equivalent).
2. Update `zarf.yaml` and `values/*.yaml` to match. Run unit tests:
   `make test-unit` — `test_zarf_package.py` will surface obvious
   inconsistencies.
3. Build and run e2e: `make package && make test-e2e`.
4. Tag and release.

## Future: generate downstream pins from the component module

Today step 2 is manual. The intended evolution is a Makefile target that
reads the constants from the Python module and writes the corresponding
lines into `zarf.yaml` and `values/*.yaml` — turning manual reconciliation
into a generated artifact. That's a v0.4 task; the contract for now is
"edit the module, sync the rest, let the unit tests catch you."

## Note

A previous version of this document referenced `factory/components/*.py`
as the SSOT location. That tree was the pre-Zarf scaffolding and was
removed during the v0.3 cleanup; see `refactor-to-zarf.md` for the move.
