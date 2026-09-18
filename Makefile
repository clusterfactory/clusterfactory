.PHONY: help clean lint plugins plugins-image plugins-lock-check package deploy test

FLAVOR ?= upstream
VERSION := $(shell awk '/^  version:/ {print $$2; exit}' zarf.yaml)
PACKAGE := zarf-package-clusterfactory-amd64-$(VERSION)-$(FLAVOR).tar.zst
# Upstream Jenkins image from the flavor values (used only to run jenkins-plugin-cli)
JENKINS_IMAGE := $(shell awk '/repository: jenkins\/jenkins/{r=$$2} /^    tag:/{t=$$2} END{print "docker.io/" r ":" t}' values/jenkins-$(FLAVOR)-values.yaml)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build artifacts
	rm -rf zarf-package-clusterfactory-*.tar.zst zarf-sbom/ sboms/ build/

lint:  ## CI gate 1 locally: zarf dev lint, helm lint helper charts, yamllint
	zarf dev lint . -f $(FLAVOR)
	for c in charts/*/; do helm lint "$$c" --strict && helm template cf "$$c" >/dev/null; done
	yamllint --strict -c .yamllint .

plugins:  ## Resolve jenkins/plugins.txt into jenkins/plugins/ (needs docker + internet) and refresh plugins.lock
	rm -rf jenkins/plugins && mkdir -p jenkins/plugins
	docker run --rm -v "$(CURDIR)/jenkins:/j" $(JENKINS_IMAGE) \
		jenkins-plugin-cli --plugin-file /j/plugins.txt --plugin-download-directory /j/plugins --list \
		| sed -n '/Resulting plugin list/,/^$$/p' | grep -E '^[a-z0-9_-]+ ' | sort > jenkins/plugins.lock
	@echo "resolved $$(wc -l < jenkins/plugins.lock | tr -d ' ') plugins into jenkins/plugins/"

PLUGINS_IMAGE := ghcr.io/clusterfactory/jenkins-plugins:$(VERSION)
plugins-image:  ## Build the data-only plugins image from jenkins/plugins/ (local daemon only, never pushed)
	test -d jenkins/plugins || $(MAKE) plugins
	docker build --platform linux/amd64 -t $(PLUGINS_IMAGE) jenkins/
	@echo "built $(PLUGINS_IMAGE)"

plugins-lock-check:  ## Fail if plugins.lock is stale relative to plugins.txt
	cp jenkins/plugins.lock /tmp/plugins.lock.before
	$(MAKE) plugins
	diff -u /tmp/plugins.lock.before jenkins/plugins.lock

package:  ## CI gate 2 locally: create the Zarf package for FLAVOR (default: upstream)
	zarf package create . -f $(FLAVOR) --confirm

deploy:  ## Deploy the package to the current kube context
	zarf package deploy $(PACKAGE) --confirm

test:  ## Run wire-engine unit tests (legacy engine/ until step 5)
	cd engine && pytest tests/

.DEFAULT_GOAL := help
