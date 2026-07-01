#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Single-workspace layout: `dbx-dev` owns both the `main` catalog and its own
# governed model serving endpoints directly. Plan order mirrors deploy order:
# account must apply before the workspace.
ENVS=(
  account
  dbx-dev
)

# ── terraform plan across all environments ────────────────────────────────────
FAILED=()

for env in "${ENVS[@]}"; do
  dir="$REPO_ROOT/environments/$env"
  echo "=== plan: $env ==="
  pushd "$dir" > /dev/null

  # init quietly; surface only on failure
  if ! terraform init -input=false -reconfigure -no-color \
        > /tmp/tfinit-"${env//\//-}".log 2>&1; then
    echo "  init failed — see /tmp/tfinit-${env//\//-}.log"
    FAILED+=("$env")
    popd > /dev/null
    echo
    continue
  fi

  terraform plan \
    -input=false \
    -no-color \
    -out=tfplan 2>&1 | tee /tmp/tfplan-"${env//\//-}".log | \
    grep -E "^Plan:|^No changes|Error:" || true

  if grep -q "^Error:" /tmp/tfplan-"${env//\//-}".log 2>/dev/null; then
    FAILED+=("$env")
  fi

  popd > /dev/null
  echo
done

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED environments:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  exit 1
else
  echo "All plans passed. Safe to push."
fi
