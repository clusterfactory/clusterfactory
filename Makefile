.PHONY: help clean lint local-registry plugins plugins-update plugins-image plugins-tag plugins-lock-check wire-engine-image wire-engine-tag package init-package deploy test

SHELL := /bin/bash
FLAVOR ?= upstream
VERSION := $(shell awk '/^  version:/ {print $$2; exit}' zarf.yaml)
PACKAGE := zarf-package-clusterfactory-amd64-$(VERSION)-$(FLAVOR).tar.zst
# Upstream Jenkins image from the flavor values (used only to run jenkins-plugin-cli)
# (the tag that follows `repository: jenkins/jenkins`; the file also pins the agent image)
JENKINS_IMAGE := $(shell awk '/repository: jenkins\/jenkins$$/{hit=1; next} hit && /tag:/{print "docker.io/jenkins/jenkins:" $$2; exit}' values/jenkins-$(FLAVOR)-values.yaml)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build artifacts
	rm -rf zarf-package-clusterfactory-*.tar.zst zarf-init-*.tar.zst zarf-sbom/ sboms/ build/

lint:  ## CI gate 1 locally: zarf dev lint, helm lint helper charts, yamllint
	zarf dev lint . -f $(FLAVOR) $(ZARF_TMPL)
	for c in charts/*/; do helm lint "$$c" --strict && helm template cf "$$c" >/dev/null; done
	yamllint --strict -c .yamllint .

# Plugin resolution is two-phase so the closure is reproducible:
#   plugins-update  resolve jenkins/plugins.txt (top-level pins) against the
#                   update centre -> jenkins/plugins.lock (full closure). Run on
#                   purpose; transitive versions move whenever upstream releases.
#   plugins         install exactly jenkins/plugins.lock -> jenkins/plugins/.
#                   This is what `make package` and CI use.
PLUGIN_CLI = docker run --rm -v "$(CURDIR)/jenkins:/j" $(JENKINS_IMAGE) jenkins-plugin-cli
define resolve_plugins
	rm -rf jenkins/plugins && mkdir -p jenkins/plugins && chmod 777 jenkins/plugins  # container runs as uid 1000
	set -o pipefail; $(PLUGIN_CLI) --plugin-file /j/$(1) --plugin-download-directory /j/plugins --list \
		| sed -n '/Resulting plugin list/,/^$$/p' | grep -E '^[a-z0-9_-]+ ' | sort > $(2)
	@test -s $(2) && ls jenkins/plugins/*.jpi >/dev/null || { echo "plugin resolution produced nothing"; exit 1; }
endef

plugins-update:  ## Re-resolve jenkins/plugins.txt into a new jenkins/plugins.lock (needs docker + internet)
	$(call resolve_plugins,plugins.txt,jenkins/plugins.lock)
	@echo "resolved $$(wc -l < jenkins/plugins.lock | tr -d ' ') plugins into jenkins/plugins.lock"

plugins:  ## Install exactly jenkins/plugins.lock into jenkins/plugins/ (needs docker + internet)
	@test -s jenkins/plugins.lock || { echo "jenkins/plugins.lock missing - run make plugins-update"; exit 1; }
	awk '{print $$1":"$$2}' jenkins/plugins.lock > jenkins/.plugins.lock.txt && chmod 644 jenkins/.plugins.lock.txt  # read by uid 1000 in the container
	$(call resolve_plugins,.plugins.lock.txt,jenkins/.plugins.lock.resolved)
	@rm -f jenkins/.plugins.lock.txt
	@echo "installed $$(ls jenkins/plugins/*.jpi | wc -l | tr -d ' ') plugins from jenkins/plugins.lock"

# Locally built images are pushed to a throwaway registry on the build
# machine and referenced from there. Zarf's "pull from the docker daemon"
# fallback tags/untags images by id while pulling and, with several images in
# flight, races itself ("reference does not exist") and removes the images
# afterwards. A registry is deterministic and works the same in CI.
LOCAL_REGISTRY ?= localhost:5001
# renovate: datasource=docker depName=registry
LOCAL_REGISTRY_IMAGE := docker.io/library/registry:3.0.0@sha256:5b12b22f21522fe69443079df04c0f3f42cb9977857f3c20404386652a6c6d8e
local-registry:  ## Start the throwaway build registry on $(LOCAL_REGISTRY) if it is not running
	@docker ps --format '{{.Names}}' | grep -qx cf-build-registry || \
		docker run -d --name cf-build-registry --restart unless-stopped -p 127.0.0.1:5001:5000 $(LOCAL_REGISTRY_IMAGE) >/dev/null
	@for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf http://$(LOCAL_REGISTRY)/v2/ >/dev/null && break; sleep 1; done
	@curl -sf http://$(LOCAL_REGISTRY)/v2/ >/dev/null || { echo "build registry not reachable at $(LOCAL_REGISTRY)"; exit 1; }

# Hash the actual .jpi payload (not just the lock): an empty or partial
# resolution must never reuse the tag of a good image.
PLUGINS_TAG := $(VERSION)-$(shell cat jenkins/plugins.lock jenkins/Dockerfile jenkins/plugins/*.jpi 2>/dev/null | shasum -a 256 | cut -c1-12)
PLUGINS_IMAGE := $(LOCAL_REGISTRY)/clusterfactory/jenkins-plugins:$(PLUGINS_TAG)
plugins-tag:  ## Print the content-addressed plugins image tag (consumed by zarf onCreate)
	@echo $(PLUGINS_TAG)

plugins-image:  ## Build the data-only plugins image from jenkins/plugins/ (local daemon only, never pushed)
	@ls jenkins/plugins/*.jpi >/dev/null 2>&1 || { echo "jenkins/plugins/ is empty - run make plugins"; exit 1; }
	$(MAKE) -s local-registry
	docker build --platform linux/amd64 -t $(PLUGINS_IMAGE) jenkins/
	docker push -q $(PLUGINS_IMAGE)
	@echo "built and pushed $(PLUGINS_IMAGE)"

WIRE_TAG := $(VERSION)-$(shell shasum -a 256 wire-engine/wire.py wire-engine/Dockerfile | shasum -a 256 | cut -c1-12)
WIRE_IMAGE := $(LOCAL_REGISTRY)/clusterfactory/wire-engine:$(WIRE_TAG)
ZARF_TMPL := --set PLUGINS_TAG=$(PLUGINS_TAG) --set WIRE_ENGINE_TAG=$(WIRE_TAG) --set LOCAL_REGISTRY=$(LOCAL_REGISTRY)
wire-engine-tag:  ## Print the content-addressed wire-engine image tag (consumed by zarf onCreate)
	@echo $(WIRE_TAG)

wire-engine-image:  ## Build the wire-engine image (local daemon only, never pushed)
	$(MAKE) -s local-registry
	docker build --platform linux/amd64 -t $(WIRE_IMAGE) wire-engine/
	docker push -q $(WIRE_IMAGE)
	@echo "built and pushed $(WIRE_IMAGE)"

plugins-lock-check:  ## Fail if installing plugins.lock does not reproduce plugins.lock exactly
	$(MAKE) plugins
	diff -u jenkins/plugins.lock jenkins/.plugins.lock.resolved
	@echo "plugins.lock is self-consistent"
	@for p in $$(grep -v '^#' jenkins/plugins.txt | grep -o '^[^:]*'); do grep -q "^$$p " jenkins/plugins.lock || { echo "$$p from plugins.txt missing in plugins.lock - run make plugins-update"; exit 1; }; done

# Signing (ADR 0004): set SIGNING_KEY (path or cosign key provider) and
# SIGNING_KEY_PASS to sign; CI does, from repository secrets. cosign.pub in
# the repo root is the matching public key; consumers deploy with --key.
SIGNING_KEY ?=
SIGNING_KEY_PASS ?=
ZARF_SIGN := $(if $(SIGNING_KEY),--signing-key $(SIGNING_KEY) --signing-key-pass "$(SIGNING_KEY_PASS)",)
package:  ## CI gate 2 locally: create the Zarf package for FLAVOR (default: upstream); OUT=dir
	zarf package create . -f $(FLAVOR) --confirm $(ZARF_TMPL) $(ZARF_SIGN) $(if $(OUT),-o $(OUT),) $(ZARF_CREATE_ARGS)

init-package:  ## The all-in-one init package (RKE2 + Zarf + the forge) for FLAVOR; OUT=dir (needs docker, skopeo, internet)
	FLAVOR=$(FLAVOR) ZARF_EXTRA="$(ZARF_TMPL)" SIGNING_KEY="$(SIGNING_KEY)" SIGNING_KEY_PASS="$(SIGNING_KEY_PASS)" \
		hack/build-init-package.sh $(if $(OUT),$(OUT),build)

package-signed:  ## Create and sign with ~/.clusterfactory/cosign.key (maintainers)
	$(MAKE) package SIGNING_KEY=$(HOME)/.clusterfactory/cosign.key SIGNING_KEY_PASS="$$(cat $(HOME)/.clusterfactory/cosign.password)"


deploy:  ## Deploy the package to the current kube context (verifies the signature)
	zarf package deploy $(PACKAGE) --confirm --key cosign.pub $(ZARF_DEPLOY_ARGS)

test:  ## Static checks on the wire engine (stdlib only: compile + import smoke)
	python3 -m py_compile wire-engine/wire.py
	@grep -nE '^(import|from) ' wire-engine/wire.py | grep -vE '^[0-9]+:(import|from) (base64|hashlib|http\.cookiejar|json|os|secrets|ssl|sys|time|urllib|xml|__future__)' \
		&& { echo "wire.py must stay stdlib-only"; exit 1; } || echo "wire.py is stdlib-only"

.DEFAULT_GOAL := help
