#!/usr/bin/env bash
# scripts/cleanup-v03.sh — remove the legacy tree the zarf refactor orphaned.
#
# Run from the repo root. Idempotent: missing paths are skipped.
# Safe to commit the diff; nothing here is referenced by zarf.yaml, the wire
# Job, the engine code, or the canonical CI workflow (zarf-test.yaml).
#
# What this removes and why:
#   - factory/                      → superseded by engine/src/clusterfactory_engine/
#   - Dockerfile.wire               → root duplicate; engine/Dockerfile is canonical
#   - run-tests.py                  → hardcoded to factory/testing; Makefile target replaces it
#   - Chart.yaml, Chart.lock        → Zarf replaces Helm chart packaging
#   - charts/, templates/           → ditto; charts now come from upstream URLs in zarf.yaml
#   - hack/                         → bundle.sh / update-digests.sh; Zarf does this now
#   - docs/*.tgz, docs/index.yaml   → Helm repo artifacts; we don't publish a chart anymore
#   - .github/workflows/test.yaml   → legacy Helm CI; zarf-test.yaml is canonical
#   - 16 of 20 root .md files       → moved to docs/history/ (preserved, not lost)
#   - *.bak                         → leftover swap files
#   - values.yaml, values.schema.json → Helm-chart-era; engine reads platform.yaml,
#                                       and per-chart values live under values/
#   - cosign.pub                    → keep ONLY if you actually sign packages today;
#                                     remove from this script if so. Default keeps it.

set -euo pipefail

if [[ ! -f zarf.yaml ]]; then
  echo "error: run from repo root (zarf.yaml not found)" >&2
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"
remove() {
  if [[ ! -e "$1" ]]; then return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then echo "would remove: $1"; return 0; fi
  echo "removing: $1"
  rm -rf -- "$1"
}

# ---- 1. parallel Python tree ------------------------------------------------
remove factory
remove Dockerfile.wire
remove run-tests.py
remove requirements.txt   # repo-root one; engine/requirements.txt is canonical

# ---- 2. Helm chart era ------------------------------------------------------
remove Chart.yaml
remove Chart.lock
remove templates
remove charts
remove values.yaml
remove values.schema.json
remove hack

# ---- 3. published Helm repo artifacts (regeneratable; rebuilds from tags) ---
remove docs/index.yaml
for tgz in docs/clusterfactory-*.tgz docs/gitea-jenkins-*.tgz; do
  remove "$tgz"
done

# ---- 4. legacy CI workflow --------------------------------------------------
remove .github/workflows/test.yaml

# ---- 5. backup files --------------------------------------------------------
remove Makefile-v02.bak
remove README-v02.md.bak
remove platform-v02.yaml.bak

# ---- 6. doc drift: 20 root .md → 4 + history -------------------------------
mkdir -p docs/history
keep_root=(
  README.md
  SECURITY.md
  CONTRIBUTING.md
  CHANGELOG.md
  refactor-to-zarf.md
  SINGLE_SOURCE_OF_TRUTH.md  # kept; will be updated to reference engine/, not factory/
)
is_kept() {
  local f="$1"
  for k in "${keep_root[@]}"; do [[ "$f" == "$k" ]] && return 0; done
  return 1
}
shopt -s nullglob
for md in *.md; do
  if is_kept "$md"; then continue; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would move: $md → docs/history/$md"
  else
    echo "moving: $md → docs/history/$md"
    mv -- "$md" "docs/history/$md"
  fi
done
# refactor-to-clusterfactory-python-sdk.md, security-refactoring.md,
# deployment-modes-refactoring.md are historical refactor docs — same fate.
for md in refactor-to-clusterfactory-python-sdk.md \
          security-refactoring.md \
          deployment-modes-refactoring.md; do
  if [[ -f "$md" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "would move: $md → docs/history/$md"
    else
      mv -- "$md" "docs/history/$md"
    fi
  fi
done

echo
echo "done. review with: git status"
echo "if anything looks wrong: git checkout -- ."
