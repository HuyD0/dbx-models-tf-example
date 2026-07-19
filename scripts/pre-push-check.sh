#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Single-workspace layout: `dbx-dev` owns both the `main` catalog and its own
# governed model serving endpoints directly. Plan order mirrors deploy order:
# account must apply before the workspace.
ENVS=(
  account
  dbx-dev
  dbx-uat
)

# ── Auth precheck ─────────────────────────────────────────────────────────────
# The account/dbx-dev Databricks providers use auth_type = "azure-client-secret",
# which reads the SP creds from ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID.
# Without them, `terraform plan` fails with a cryptic
# "azure-client-secret auth: not configured" error. Fail fast with guidance.
missing=()
for v in ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: service-principal auth not configured — missing: ${missing[*]}" >&2
  echo "       Run this in the SAME shell first (use 'source', not './'):" >&2
  echo "         az login" >&2
  echo "         source scripts/dev-auth.sh" >&2
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: 'az' is not logged in — run 'az login' (needed to read Key Vault)." >&2
  exit 1
fi

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
