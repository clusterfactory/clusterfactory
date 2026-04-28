.PHONY: help clean wire-image package deploy test test-unit test-e2e lint install-dev

# ── versions, single source of truth ────────────────────────────────────────
WIRE_IMAGE      ?= ghcr.io/clusterfactory/clusterfactory-wire
WIRE_VERSION    ?= 0.3.0
ZARF_PACKAGE    ?= zarf-package-clusterfactory-ci-amd64-$(WIRE_VERSION).tar.zst
K3D_CLUSTER     ?= cf-test
PYTEST_FLAGS    ?= -ra

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── dev setup ───────────────────────────────────────────────────────────────
install-dev:  ## Install engine + dev deps (editable)
	cd engine && python -m pip install -e ".[dev]"

# ── build ───────────────────────────────────────────────────────────────────
wire-image:  ## Build the wire engine image and (best-effort) load into k3d
	docker build -t $(WIRE_IMAGE):$(WIRE_VERSION) engine/
	@k3d image import $(WIRE_IMAGE):$(WIRE_VERSION) -c $(K3D_CLUSTER) 2>/dev/null || \
		echo "(k3d cluster '$(K3D_CLUSTER)' not present — skipping import)"

package: wire-image  ## Create the Zarf package (signed if cosign.pub + key exist)
	zarf package create . --confirm

# ── deploy ──────────────────────────────────────────────────────────────────
deploy:  ## Deploy package; requires GITEA_ADMIN_PASSWORD env var
	@test -n "$(GITEA_ADMIN_PASSWORD)" || \
		(echo "ERROR: GITEA_ADMIN_PASSWORD not set" && exit 1)
	zarf package deploy $(ZARF_PACKAGE) \
		--confirm \
		--set GITEA_ADMIN_PASSWORD=$(GITEA_ADMIN_PASSWORD)

# ── test ────────────────────────────────────────────────────────────────────
test: test-unit  ## Run all tests (unit; e2e is opt-in)

test-unit:  ## Unit tests against the engine package (no cluster needed)
	cd engine && python -m pytest tests/unit/ $(PYTEST_FLAGS)

test-e2e:  ## End-to-end airgap install test (requires k3d, zarf, cosign)
	bash engine/tests/integration/test_airgap_install.sh

lint:  ## Lint the engine package
	cd engine && python -m pylint src/clusterfactory_engine/ \
		--disable=missing-docstring,too-few-public-methods

# ── clean ───────────────────────────────────────────────────────────────────
clean:  ## Remove build artifacts
	rm -f zarf-package-clusterfactory-ci-*.tar.zst
	rm -rf zarf-sbom/
	rm -rf engine/.pytest_cache engine/**/__pycache__
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

.DEFAULT_GOAL := help
