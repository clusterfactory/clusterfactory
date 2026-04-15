#!/bin/bash
# Quick install script for Docker Desktop
# This script installs clusterfactory on Docker Desktop with optimized settings

set -e

NAMESPACE="${NAMESPACE:-cicd}"
RELEASE="${RELEASE:-cf}"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ClusterFactory - Docker Desktop Installation                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installing to namespace: ${NAMESPACE}"
echo "Release name: ${RELEASE}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ helm not found. Please install helm first."
    exit 1
fi

# Check if Docker Desktop Kubernetes is running
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Kubernetes cluster not accessible."
    echo "   Make sure Docker Desktop Kubernetes is enabled."
    exit 1
fi

echo "✅ Prerequisites checked"
echo ""

# Build dependencies
echo "📦 Building chart dependencies..."
helm dependency build

echo ""
echo "🚀 Installing ClusterFactory..."
helm install "${RELEASE}" . \
  -f values-docker-desktop.yaml \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 5m

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Installation Complete!                                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "🎉 ClusterFactory is now running in Docker Desktop!"
echo ""
echo "📊 Check status:"
echo "   kubectl get pods -n ${NAMESPACE}"
echo ""
echo "🌐 Access services (after port-forward):"
echo "   Gitea:   http://localhost:3000"
echo "   Jenkins: http://localhost:8080"
echo ""
echo "🔌 Port forwarding commands:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-gitea-http 3000:3000"
echo "   kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-jenkins 8080:8080"
echo ""
echo "📝 Default credentials:"
echo "   Gitea:   gitea / r8sA8CPHD9!bt6d"
echo "   Jenkins: admin / (run: kubectl get secret -n ${NAMESPACE} ${RELEASE}-jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)"
echo ""
echo "ℹ️  Note: Gitea Actions runner is disabled on Docker Desktop"
echo "   Use Jenkins for CI/CD pipelines instead"
echo ""
