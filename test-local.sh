#!/usr/bin/env bash
set -euo pipefail

# Test ClusterFactory against local k3d cluster
# Usage: ./test-local.sh [mode]
# Modes: gitea-actions (default), jenkins, both

MODE="${1:-gitea-actions}"
NAMESPACE="cicd"
RELEASE="cf"
GITEA_PASS="testpass123"
JENKINS_PASS="testpass123"

echo "==> Testing ClusterFactory in mode: ${MODE}"

# Ensure dependencies are built and extracted
if [ ! -d "charts/gitea" ] || [ ! -d "charts/jenkins" ]; then
  echo "==> Building and extracting chart dependencies..."
  helm dependency build .
  cd charts
  tar -xzf gitea-*.tgz 2>/dev/null || true
  tar -xzf jenkins-*.tgz 2>/dev/null || true
  cd ..
fi

# Clean up any existing release
if helm list -n "${NAMESPACE}" 2>/dev/null | grep -q "^${RELEASE}"; then
  echo "==> Uninstalling existing release..."
  helm uninstall "${RELEASE}" -n "${NAMESPACE}"
  sleep 3
fi

# Set flags based on mode
case "${MODE}" in
  gitea-actions)
    FLAGS=(
      --set mode=gitea-actions
      --set jenkins.enabled=false
      --set gitea.gitea.config.actions.ENABLED=true
      --set giteaAdmin.password="${GITEA_PASS}"
    )
    ;;
  jenkins)
    FLAGS=(
      --set mode=jenkins
      --set jenkins.enabled=true
      --set gitea.gitea.config.actions.ENABLED=false
      --set giteaAdmin.password="${GITEA_PASS}"
      --set jenkinsAdmin.password="${JENKINS_PASS}"
    )
    ;;
  both)
    FLAGS=(
      --set mode=both
      --set jenkins.enabled=true
      --set gitea.gitea.config.actions.ENABLED=true
      --set giteaAdmin.password="${GITEA_PASS}"
      --set jenkinsAdmin.password="${JENKINS_PASS}"
    )
    ;;
  *)
    echo "ERROR: Unknown mode '${MODE}'. Use: gitea-actions, jenkins, or both"
    exit 1
    ;;
esac

# Install chart (without --wait, like CI does)
echo "==> Installing ClusterFactory..."
helm upgrade --install "${RELEASE}" . \
  -n "${NAMESPACE}" \
  --create-namespace \
  --timeout 15m \
  "${FLAGS[@]}"

# Wait for components
echo ""
echo "==> Waiting for Gitea deployment..."
kubectl -n "${NAMESPACE}" rollout status deployment/cf-gitea --timeout=5m

if [ "$MODE" = "jenkins" ] || [ "$MODE" = "both" ]; then
  echo "==> Waiting for Jenkins statefulset..."
  kubectl -n "${NAMESPACE}" rollout status statefulset/cf-jenkins --timeout=5m
fi

echo "==> Waiting for wire job to complete..."
kubectl -n "${NAMESPACE}" wait --for=condition=complete --timeout=10m job/cf-wire

# Check pod status
echo ""
echo "==> Pod status:"
kubectl -n "${NAMESPACE}" get pods,job

# Show wire result
echo ""
echo "==> Wire result:"
kubectl -n "${NAMESPACE}" get configmap cf-wire-result -o yaml | grep -A 10 "data:"

# Run helm tests
echo ""
echo "==> Running helm tests..."
helm test "${RELEASE}" -n "${NAMESPACE}" --timeout 5m

echo ""
echo "==> ✓ All tests passed for mode: ${MODE}"
