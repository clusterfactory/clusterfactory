.PHONY: help test test-unit test-integration test-all lint format build deploy-test clean

# Variables
WIRE_IMAGE ?= clusterfactory-wire:0.2.0
TEST_NAMESPACE ?= default
CLUSTER_NAME ?= clusterfactory-test

help: ## Show this help message
	@echo "ClusterFactory Development Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Testing
test-unit: ## Run unit tests
	python3 -m pytest factory/testing/layers/unit/ -v

test-integration: ## Run integration tests (requires live cluster)
	python3 -m pytest factory/testing/layers/integration/ -v -m integration

test-all: ## Run all test layers
	./run-tests.py all -v

test-watch: ## Run unit tests in watch mode
	python3 -m pytest factory/testing/layers/unit/ -v --looponfail

# Code Quality
lint: ## Run linters
	@echo "Running flake8..."
	-python3 -m flake8 factory/ --max-line-length=100 --ignore=E501,W503
	@echo "Running mypy..."
	-python3 -m mypy factory/ --ignore-missing-imports

format: ## Format code with black
	python3 -m black factory/ --line-length=100

# Docker
build: ## Build wire Docker image
	docker build -f Dockerfile.wire -t $(WIRE_IMAGE) .

build-push: build ## Build and push wire image
	docker push $(WIRE_IMAGE)

# Cluster Management
cluster-create: ## Create k3d test cluster
	k3d cluster create $(CLUSTER_NAME) \
		--agents 2 \
		--registry-create test-registry:5000

cluster-delete: ## Delete test cluster
	k3d cluster delete $(CLUSTER_NAME)

cluster-import-image: build ## Import wire image into cluster
	k3d image import $(WIRE_IMAGE) -c $(CLUSTER_NAME)

# Deployment
deploy-bash: ## Deploy with bash engine
	helm install test-bash . \
		--set wire.engine=bash \
		--wait --timeout=10m

deploy-python: build cluster-import-image ## Deploy with Python engine
	helm install test-python . \
		--set wire.engine=python \
		--set wire.image.python=$(WIRE_IMAGE) \
		--wait --timeout=10m

deploy-compare: ## Deploy both engines for comparison
	$(MAKE) deploy-bash
	kubectl create namespace python-test || true
	helm install test-python . \
		--namespace python-test \
		--set wire.engine=python \
		--set wire.image.python=$(WIRE_IMAGE) \
		--wait --timeout=10m

# Debugging
logs-bash: ## Show bash wire logs
	kubectl logs -l app.kubernetes.io/name=wire,wire.clusterfactory.io/engine=bash --tail=100

logs-python: ## Show Python wire logs
	kubectl logs -l app.kubernetes.io/name=wire,wire.clusterfactory.io/engine=python --tail=100

describe-wire: ## Describe wire job
	kubectl describe job -l app.kubernetes.io/name=wire

port-forward-gitea: ## Port forward Gitea (localhost:3000)
	kubectl port-forward svc/test-gitea-http 3000:3000

port-forward-jenkins: ## Port forward Jenkins (localhost:8080)
	kubectl port-forward svc/test-jenkins 8080:8080

# Helm
helm-template-bash: ## Render Helm templates (bash engine)
	helm template test . --set wire.engine=bash

helm-template-python: ## Render Helm templates (Python engine)
	helm template test . --set wire.engine=python

helm-lint: ## Lint Helm chart
	helm lint .

# Cleanup
clean: ## Clean up test artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	rm -rf *.egg-info

clean-all: clean ## Clean everything including deployments
	-helm uninstall test-bash
	-helm uninstall test-python -n python-test
	-kubectl delete namespace python-test

# Development Workflow
dev-setup: ## Set up development environment
	pip install -r requirements.txt
	pip install flake8 mypy black pytest-watch

dev-test: test-unit ## Quick development test (unit only)

dev-cycle: clean test-unit build ## Full development cycle

# Full Integration Test Cycle
full-test: cluster-create build cluster-import-image deploy-python test-integration ## Full integration test cycle
	@echo "✅ Full integration test cycle complete"

# CI Commands
ci-test: test-unit lint ## Run CI tests
	@echo "✅ CI tests passed"

ci-integration: cluster-create build cluster-import-image deploy-python test-integration cluster-delete ## CI integration test
	@echo "✅ CI integration tests passed"
