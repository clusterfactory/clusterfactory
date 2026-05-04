#!/usr/bin/env bash
# Quick check for ClusterFactory deployment status
# Usage: ./quick-check.sh [namespace]
#
# Fast iteration helper - shows immediate status without long waits

set -euo pipefail

NS="${1:-cicd}"

echo "==> Quick status check for namespace: ${NS}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "${NS}" >/dev/null 2>&1; then
  echo "❌ Namespace '${NS}' does not exist"
  exit 1
fi

echo "📦 Deployments:"
kubectl -n "${NS}" get deployments -o wide 2>/dev/null || echo "  (none)"
echo ""

echo "📦 StatefulSets:"
kubectl -n "${NS}" get statefulsets -o wide 2>/dev/null || echo "  (none)"
echo ""

echo "🔧 Jobs:"
kubectl -n "${NS}" get jobs -o wide 2>/dev/null || echo "  (none)"
echo ""

echo "🐳 Pods:"
kubectl -n "${NS}" get pods -o wide 2>/dev/null || echo "  (none)"
echo ""

# Check wire job status quickly
if kubectl -n "${NS}" get job cf-wire >/dev/null 2>&1; then
  echo "🔍 Wire Job Status:"
  WIRE_STATUS=$(kubectl -n "${NS}" get job cf-wire -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
  if [[ "$WIRE_STATUS" == "Complete" ]]; then
    echo "  ✅ Wire job completed"
    if kubectl -n "${NS}" get cm cf-wire-result >/dev/null 2>&1; then
      SHA=$(kubectl -n "${NS}" get cm cf-wire-result -o jsonpath='{.data.structural_sha}' 2>/dev/null || echo "")
      if [[ -n "$SHA" ]]; then
        echo "  📝 Structural SHA: ${SHA}"
      fi
    fi
  elif [[ "$WIRE_STATUS" == "Failed" ]]; then
    echo "  ❌ Wire job failed"
    echo "  📋 Logs:"
    kubectl -n "${NS}" logs job/cf-wire --tail=30 2>/dev/null || echo "  (no logs)"
  else
    echo "  ⏳ Wire job still running (${WIRE_STATUS})"
  fi
  echo ""
fi

# Check for common issues
echo "⚠️  Quick issue scan:"
FAILING_PODS=$(kubectl -n "${NS}" get pods --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2 || echo "")
if [[ -n "$FAILING_PODS" ]]; then
  echo "  ❌ Found failing/pending pods:"
  echo "$FAILING_PODS" | awk '{print "     " $0}'
  echo ""
  echo "  💡 Tip: Check logs with: kubectl -n ${NS} logs <pod-name>"
else
  echo "  ✅ All pods running or completed"
fi
echo ""

echo "💡 Quick commands:"
echo "  Check wire logs:    kubectl -n ${NS} logs job/cf-wire"
echo "  Delete everything:  helm uninstall cf -n ${NS} && kubectl delete ns ${NS}"
echo "  Nuke cluster:       k3d cluster delete test && k3d cluster create test --wait"
echo "  Watch pods:         watch -n1 kubectl -n ${NS} get pods"
