.PHONY: help clean wire-image package deploy test

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build artifacts
	rm -rf clusterfactory-ci-*.tar.zst
	rm -rf zarf-sbom/

wire-image:  ## Build and load wire engine image into k3d
	docker build -t ghcr.io/clusterfactory/clusterfactory-wire:0.3.0 engine/
	k3d image import ghcr.io/clusterfactory/clusterfactory-wire:0.3.0 -c cf-test || true

package:  ## Create Zarf package
	zarf package create . --confirm

deploy:  ## Deploy package to k8s (requires GITEA_ADMIN_PASSWORD env var)
	@test -n "$(GITEA_ADMIN_PASSWORD)" || (echo "ERROR: GITEA_ADMIN_PASSWORD not set" && exit 1)
	zarf package deploy clusterfactory-ci-0.3.0-amd64.tar.zst \
		--confirm \
		--set GITEA_ADMIN_PASSWORD=$(GITEA_ADMIN_PASSWORD)

test:  ## Run tests
	cd engine && pytest tests/

lint:  ## Lint Python code
	cd engine && pylint src/clusterfactory_engine/

.DEFAULT_GOAL := help
