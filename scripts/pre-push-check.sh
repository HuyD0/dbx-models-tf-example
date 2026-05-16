#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Federated layout: `platform` env owns the central inference catalog (admin-only
# read); each team workspace owns its own governed endpoints and writes inference
# rows into the shared catalog, prefixed by `inference_table_prefix` for cost
# allocation. Plan order mirrors deploy order: platform must apply before any
# workload workspace.
ENVS=(
  account
  dev/platform
  dev/team-a
  dev/team-b
  prod/platform
  prod/team-a
  prod/team-b
)

# ── 1. Sanity-check prod workload tfvars don't point at dev AI Foundry ───────
echo "=== Checking prod workspaces' AI Foundry references ==="
for prod_env in prod/team-a prod/team-b; do
  tfvars="$REPO_ROOT/environments/$prod_env/terraform.tfvars"
  [[ -f "$tfvars" ]] || continue

  ai_name=$(grep -E '^\s*ai_foundry_name'           "$tfvars" | awk -F'"' '{print $2}')
  ai_rg=$(grep   -E '^\s*ai_foundry_resource_group' "$tfvars" | awk -F'"' '{print $2}')

  echo "  $prod_env"
  echo "    ai_foundry_name           = $ai_name"
  echo "    ai_foundry_resource_group = $ai_rg"

  if [[ "$ai_name" == *"-dev"* || "$ai_rg" == *"-dev"* ]]; then
    echo "    WARNING: $prod_env still references a dev AI Foundry resource."
    read -rp "    Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi
done
echo

# ── 1b. Sanity-check workload envs do NOT create the inference catalog ───────
echo "=== Checking inference catalog ownership ==="
for env in dev/team-a dev/team-b prod/team-a prod/team-b; do
  tfvars="$REPO_ROOT/environments/$env/terraform.tfvars"
  [[ -f "$tfvars" ]] || continue
  if grep -Eq '^\s*create_inference_catalog\s*=\s*true' "$tfvars"; then
    echo "  ERROR: $env sets create_inference_catalog=true."
    echo "         Only environments/{env}/platform should own the inference catalog."
    exit 1
  fi
done
echo "  OK — only platform envs own the inference catalog"
echo

# ── 2. terraform plan across all environments ─────────────────────────────────
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
