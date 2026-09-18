.PHONY: help clean lint package deploy test

FLAVOR ?= upstream
VERSION := $(shell awk '/^  version:/ {print $$2; exit}' zarf.yaml)
PACKAGE := zarf-package-clusterfactory-amd64-$(VERSION)-$(FLAVOR).tar.zst

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build artifacts
	rm -rf zarf-package-clusterfactory-*.tar.zst zarf-sbom/ sboms/ build/

lint:  ## CI gate 1 locally: zarf dev lint, helm lint helper charts, yamllint
	zarf dev lint . -f $(FLAVOR)
	for c in charts/*/; do helm lint "$$c" --strict && helm template cf "$$c" >/dev/null; done
	yamllint --strict -c .yamllint .

package:  ## CI gate 2 locally: create the Zarf package for FLAVOR (default: upstream)
	zarf package create . -f $(FLAVOR) --confirm

deploy:  ## Deploy the package to the current kube context
	zarf package deploy $(PACKAGE) --confirm

test:  ## Run wire-engine unit tests (legacy engine/ until step 5)
	cd engine && pytest tests/

.DEFAULT_GOAL := help
