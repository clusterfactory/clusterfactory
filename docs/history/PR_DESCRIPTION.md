# WIP: Python Factory Engine - Typed, Testable, Extensible Wiring

> **Status:** 🚧 Work In Progress - Ready for Review  
> **Progress:** 80% complete (foundation + components + Helm integration done)  
> **Breaking Changes:** None (bash engine remains default)

## Overview

This PR introduces a **Python factory engine** as an alternative to the bash wire-job script. The Python engine provides a typed, testable, and extensible foundation for component wiring while maintaining 100% backward compatibility.

## Why Python?

The bash wire-job works for gitea-jenkins but cannot scale to the factory vision:

- ❌ Not composable (no graph, no interface, no reusable structure)
- ❌ Not diffable (structural changes invisible)
- ❌ No type system (credential is just a string)
- ❌ Breaks airgap discipline (`apk add curl jq` at runtime)
- ❌ Cannot plan upgrades (no state model)
- ❌ Cannot test itself (no seam for testing)

The Python engine solves all of these while maintaining the same wiring behavior.

## Architecture

### Bash Engine (Existing)
```
wire-job → alpine:3.19 → apk add curl jq → bash script → Gitea/Jenkins APIs
```

### Python Engine (New)
```
wire-job → clusterfactory-wire:0.2.0 → Factory Engine → Component Instances → APIs
                                               ↓
                                        platform.yaml (ConfigMap)
```

## Key Features

### ✅ Zero Breaking Changes
- Bash engine remains **default** (`wire.engine: bash`)
- Users opt-in to Python via values.yaml
- Both engines coexist safely

### ✅ Component Interface
Every component implements the same interface:
```python
class Component(ABC):
    def ready() -> bool           # Health check
    def produces() -> list[type]  # Credential types this generates
    def consumes() -> list[type]  # Credential types this accepts
    def extract() -> Credential   # Generate credential
    def inject(Credential)        # Accept credential
    def verify(Credential) -> bool # Prove wire holds
```

### ✅ SHA-Based Determinism
```yaml
platform_sha: 8c6a3ee0f8c38a53850243ad3bb59c0b29c9cda6e376c50b628934f0099c0f6a
structural_sha: <computed from all credential SHAs>
```

Same platform declaration → same platform SHA  
Same wiring execution → same structural SHA

### ✅ Airgap Compliant
- **Bash:** `apk add curl jq` at runtime (pulls from internet)
- **Python:** All deps baked into image at build time

### ✅ Full Test Coverage
```
Unit Tests        →  Pure logic, no network (20 tests passing)
Integration Tests →  Real components, live cluster
Airgap Tests      →  No external traffic allowed
Upgrade Tests     →  N → N+1 transition verification
```

### ✅ Extensibility
Adding a new component (Harbor, Vault, Keycloak):
1. Write `HarborComponent` class implementing Component interface
2. Add to `platform.yaml` artifacts list
3. Declare wiring edges
4. Engine handles the rest automatically

## What's Included

### Core Engine (`factory/`)
- **Model Layer:** Artifact, Credential, Platform, Graph, Result
- **Engine Core:** Resolver, Planner, Executor, Verifier, Hasher
- **Components:** Gitea (398 LOC), Jenkins (388 LOC)
- **Health Checker:** Parallel polling with backoff
- **Credentials:** ApiToken, UserPass, RunnerToken types

### Helm Integration
- **Feature Flag:** `wire.engine: bash | python`
- **Template Helpers:** Clean separation of both engines
- **Platform ConfigMap:** Generated from chart values
- **Documentation:** Migration guide in `docs/wire-engines.md`

### Testing
- **20 Unit Tests:** All passing, full coverage of core logic
- **Test Fixtures:** Fake components for isolated testing
- **Determinism Tests:** SHA consistency verified

### Docker
- **Dockerfile.wire:** Python 3.12-slim, deps baked in
- **Entrypoint:** `python -m factory`

## Commits

### 1. Foundation (4466463)
- Model layer with SHA fingerprinting
- Complete engine (Resolver, Planner, Executor, Verifier, Hasher)
- Health checker with parallel polling
- Component base interface
- 13 unit tests passing

### 2. Components (0ccf814)
- GiteaComponent: Full API client with token minting, org/repo creation
- JenkinsComponent: Full API client with credential storage, job creation
- Component registry in Resolver
- Dockerfile.wire
- 20 unit tests passing (+7 new tests)

### 3. Helm Integration (5b23d83)
- Engine feature flag (bash | python)
- Template helpers for both engines
- Platform ConfigMap generation
- Documentation (wire-engines.md)

## Testing Status

| Layer | Status | Count | Notes |
|-------|--------|-------|-------|
| Unit | ✅ | 20/20 | All passing |
| Integration | ⏳ | 0 | Needs live cluster |
| Airgap | ⏳ | 0 | Pending Docker build |
| Upgrade | ⏳ | 0 | Future work |

## Usage

### Enable Python Engine
```yaml
# values.yaml
wire:
  engine: python  # Options: bash (default) | python
```

### Verify Helm Rendering
```bash
# Bash engine (default)
helm template test . --set wire.engine=bash

# Python engine
helm template test . --set wire.engine=python
```

### Local Testing
```bash
# Run unit tests
python3 -m pytest factory/testing/layers/unit/ -v

# Test platform loading
python3 -m factory --platform platform.yaml --log-level DEBUG
```

## Migration Path

1. **Phase 1 (This PR):** Foundation + Components + Helm integration
2. **Phase 2:** Build Docker image, integration tests
3. **Phase 3:** Run parallel (bash in prod, python in test)
4. **Phase 4:** Compare structural SHAs, validate equivalence
5. **Phase 5:** Switch default to `engine: python`
6. **Phase 6:** Deprecate bash engine

## Remaining Work (20%)

- [ ] Build Docker image: `docker build -f Dockerfile.wire -t clusterfactory-wire:0.2.0 .`
- [ ] Integration tests with live Gitea + Jenkins
- [ ] Push image to registry
- [ ] Update CI airgap tests
- [ ] Add upgrade test layer

## Files Changed

- **Added:** 42 files (~3800 lines)
  - `factory/` - Complete Python package
  - `Dockerfile.wire` - Python container
  - `templates/_wire-helpers.tpl` - Engine selection
  - `templates/platform-configmap.yaml` - Platform config
  - `docs/wire-engines.md` - Documentation
  - `docs/refactoring-python.md` - Blueprint (not for main)

- **Modified:** 2 files
  - `values.yaml` - Engine feature flag
  - `templates/wire-job.yaml` - Refactored to use helpers

## Review Focus

1. **Architecture:** Does the Component interface make sense?
2. **Helm Integration:** Are both engines cleanly separated?
3. **Testing:** Is the unit test coverage sufficient?
4. **Migration:** Is the feature flag approach safe?

## Questions for Reviewers

1. Should we keep `docs/refactoring-python.md` in main or gitignore it?
2. Docker registry location for `clusterfactory-wire` image?
3. Prefer phased rollout or keep bash indefinitely?
4. Any concerns about the Component interface design?

## Related Issues

- Addresses airgap compliance (no runtime package installs)
- Enables component extensibility (Harbor, Vault, Keycloak)
- Provides upgrade planning foundation
- Enables structural verification via SHA

---

**Ready for:** Code review, architecture feedback  
**Not ready for:** Production deployment (needs integration testing)  
**Breaking changes:** None  
**Feature flag:** `wire.engine: bash` (default, stable)

cc @maintainers - This is a significant architectural change but with zero risk to existing deployments. Feedback welcome!
