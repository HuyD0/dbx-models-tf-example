#!/usr/bin/env bash
# Usage: source scripts/dev-auth.sh
#
# Fetches SP credentials from Key Vault and exports them as env vars for the
# current shell session. Secrets are never written to disk.
#
# Prerequisites:
#   - az login (as yourself) with read access to the Key Vault
#   - bootstrap/main.tf has been applied (KV and secrets exist)

set -euo pipefail

KV_NAME="<YOUR_KV_NAME>"

echo "Fetching SP credentials from Key Vault '${KV_NAME}'..."

export ARM_CLIENT_ID
ARM_CLIENT_ID=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "terraform-sp-client-id" \
  --query value -o tsv)

export ARM_CLIENT_SECRET
ARM_CLIENT_SECRET=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "terraform-sp-secret" \
  --query value -o tsv)

export ARM_TENANT_ID="<YOUR_TENANT_ID>"
export ARM_SUBSCRIPTION_ID="<YOUR_SUBSCRIPTION_ID>"
export ARM_USE_OIDC="false"
export ARM_USE_AZUREAD="true"
export DATABRICKS_ACCOUNT_ID="<YOUR_DATABRICKS_ACCOUNT_ID>"

echo "Done. Authenticated as SP: ${ARM_CLIENT_ID}"
echo "Credentials live in this shell session only — unset on exit."
