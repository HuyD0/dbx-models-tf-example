#!/usr/bin/env bash
# Usage: source scripts/dev-auth.sh
#
# Fetches SP credentials from Key Vault and exports them as env vars for the
# current shell session. Secrets are never written to disk.
#
# Prerequisites:
#   - az login (as yourself) with read access to the Key Vault
#   - bootstrap/main.tf has been applied (KV and secrets exist)
#
# NOTE: this script is meant to be *sourced*, so it deliberately does NOT use
# `set -euo pipefail` — those options would leak into the caller's interactive
# shell, breaking the prompt (`RPROMPT: parameter not set`) and closing the
# terminal on the next non-zero command. Errors are checked explicitly instead.

KV_NAME="kv-tfsp-ea936670"

# `return` when sourced, `exit` when executed directly.
_fail() { echo "ERROR: $*" >&2; return 1 2>/dev/null || exit 1; }

echo "Fetching SP credentials from Key Vault '${KV_NAME}'..."

if ! ARM_CLIENT_ID=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "terraform-sp-client-id" \
  --query value -o tsv); then
  _fail "could not read terraform-sp-client-id from ${KV_NAME} — run 'az login' first."
fi
export ARM_CLIENT_ID

if ! ARM_CLIENT_SECRET=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "terraform-sp-secret" \
  --query value -o tsv); then
  _fail "could not read terraform-sp-secret from ${KV_NAME} — run 'az login' first."
fi
export ARM_CLIENT_SECRET

export ARM_TENANT_ID="7f6a2cf9-5e4e-46ae-95d4-74016c1df1a6"
export ARM_SUBSCRIPTION_ID="ea936670-dda1-4884-8467-49c225bf3e83"
export ARM_USE_OIDC="false"
export ARM_USE_AZUREAD="true"
export DATABRICKS_ACCOUNT_ID="617a10e3-e106-4d01-bc34-524981fc9683"

echo "Done. Authenticated as SP: ${ARM_CLIENT_ID}"
echo "Credentials live in this shell session only — unset on exit."
