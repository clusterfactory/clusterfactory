#!/bin/sh
# summary.sh — Phase 4 (hook weight 20): print access summary after full install
# Reads credentials from OpenBao so nothing sensitive is hardcoded in logs.

set -e
apk add -q jq

HOST="${CONTROL_PLANE_HOST:-localhost}"
NS="${NS:-platform}"
RELEASE_NAME="${RELEASE_NAME:-platform}"

# ── Read credentials from OpenBao ───────────────────────────────────────────
_bao() {
  curl -sf "${OPENBAO_ADDR}/v1/secret/data/$1" \
    -H "X-Vault-Token: ${OPENBAO_TOKEN}" | jq -r ".data.data.$2 // \"(not found)\""
}

HARBOR_PASS=$(_bao harbor password)
ARGOCD_PASS=$(_bao argocd password)
HEADLAMP_TOKEN=$(_bao headlamp token)

# ── Print summary ────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                  platform — access summary                      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  ACCESS POINTS"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-10s %-20s %s\n" "Cockpit"  "(terminal)"   "http://${HOST}:4000"
printf "  %-10s %-20s %s\n" "Headlamp" "(cluster UI)"  "http://${HOST}:4466"
printf "  %-10s %-20s %s\n" "Gitea"    "(git)"         "http://${HOST}:30080"
printf "  %-10s %-20s %s\n" "ArgoCD"   "(gitops)"      "http://${HOST}:8080"
printf "  %-10s %-20s %s\n" "Harbor"   "(registry)"    "http://${HOST}:30002"
printf "  %-10s %-20s %s\n" "OpenBao"  "(secrets)"     "http://${HOST}:30820"
echo ""
echo "  CREDENTIALS"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-10s admin / %s\n" "Gitea"   "${GITEA_PASSWORD}"
printf "  %-10s admin / %s\n" "ArgoCD"  "${ARGOCD_PASS}"
printf "  %-10s admin / %s\n" "Harbor"  "${HARBOR_PASS}"
printf "  %-10s token: %s\n"  "OpenBao" "${OPENBAO_TOKEN}  (dev mode — not persistent)"
echo ""
echo "  HEADLAMP TOKEN  →  paste at http://${HOST}:4466"
echo "  ────────────────────────────────────────────────────────────────"
echo "  ${HEADLAMP_TOKEN}"
echo ""
echo "  All credentials in OpenBao (token: ${OPENBAO_TOKEN}):"
printf "    bao kv get -address=http://%s:30820 secret/%s\n" "${HOST}" "harbor"
printf "    bao kv get -address=http://%s:30820 secret/%s\n" "${HOST}" "argocd"
printf "    bao kv get -address=http://%s:30820 secret/%s\n" "${HOST}" "headlamp"
echo ""
echo "  Regenerate headlamp token (expires in 1y):"
echo "    kubectl create token headlamp-admin -n kube-system --duration=8760h"
echo ""
