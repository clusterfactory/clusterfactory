.PHONY: help clean lint plugins plugins-image plugins-tag plugins-lock-check wire-engine-image wire-engine-tag package deploy test

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
	zarf dev lint . -f $(FLAVOR) $(ZARF_TMPL)
	for c in charts/*/; do helm lint "$$c" --strict && helm template cf "$$c" >/dev/null; done
	yamllint --strict -c .yamllint .

plugins:  ## Resolve jenkins/plugins.txt into jenkins/plugins/ (needs docker + internet) and refresh plugins.lock
	rm -rf jenkins/plugins && mkdir -p jenkins/plugins
	docker run --rm -v "$(CURDIR)/jenkins:/j" $(JENKINS_IMAGE) \
		jenkins-plugin-cli --plugin-file /j/plugins.txt --plugin-download-directory /j/plugins --list \
		| sed -n '/Resulting plugin list/,/^$$/p' | grep -E '^[a-z0-9_-]+ ' | sort > jenkins/plugins.lock
	@echo "resolved $$(wc -l < jenkins/plugins.lock | tr -d ' ') plugins into jenkins/plugins/"

# Locally built images get content-addressed tags: a kubelet caches by tag
# (IfNotPresent), so re-using "0.4.0" for new content silently runs old bits.
PLUGINS_TAG := $(VERSION)-$(shell shasum -a 256 jenkins/plugins.lock jenkins/Dockerfile | shasum -a 256 | cut -c1-12)
PLUGINS_IMAGE := ghcr.io/clusterfactory/jenkins-plugins:$(PLUGINS_TAG)
plugins-tag:  ## Print the content-addressed plugins image tag (consumed by zarf onCreate)
	@echo $(PLUGINS_TAG)

plugins-image:  ## Build the data-only plugins image from jenkins/plugins/ (local daemon only, never pushed)
	test -d jenkins/plugins || $(MAKE) plugins
	docker build --platform linux/amd64 -t $(PLUGINS_IMAGE) jenkins/
	@echo "built $(PLUGINS_IMAGE)"

WIRE_TAG := $(VERSION)-$(shell shasum -a 256 wire-engine/wire.py wire-engine/Dockerfile | shasum -a 256 | cut -c1-12)
WIRE_IMAGE := ghcr.io/clusterfactory/wire-engine:$(WIRE_TAG)
ZARF_TMPL := --set PLUGINS_TAG=$(PLUGINS_TAG) --set WIRE_ENGINE_TAG=$(WIRE_TAG)
wire-engine-tag:  ## Print the content-addressed wire-engine image tag (consumed by zarf onCreate)
	@echo $(WIRE_TAG)

wire-engine-image:  ## Build the wire-engine image (local daemon only, never pushed)
	docker build --platform linux/amd64 -t $(WIRE_IMAGE) wire-engine/
	@echo "built $(WIRE_IMAGE)"

plugins-lock-check:  ## Fail if plugins.lock is stale relative to plugins.txt
	cp jenkins/plugins.lock /tmp/plugins.lock.before
	$(MAKE) plugins
	diff -u /tmp/plugins.lock.before jenkins/plugins.lock

package:  ## CI gate 2 locally: create the Zarf package for FLAVOR (default: upstream); OUT=dir
	zarf package create . -f $(FLAVOR) --confirm $(ZARF_TMPL) $(if $(OUT),-o $(OUT),) $(ZARF_CREATE_ARGS)


deploy:  ## Deploy the package to the current kube context
	zarf package deploy $(PACKAGE) --confirm

test:  ## Static checks on the wire engine (stdlib only: compile + import smoke)
	python3 -m py_compile wire-engine/wire.py
	@grep -nE '^(import|from) ' wire-engine/wire.py | grep -vE '^[0-9]+:(import|from) (base64|hashlib|http\.cookiejar|json|os|secrets|ssl|sys|time|urllib|xml|__future__)' \
		&& { echo "wire.py must stay stdlib-only"; exit 1; } || echo "wire.py is stdlib-only"

.DEFAULT_GOAL := help
