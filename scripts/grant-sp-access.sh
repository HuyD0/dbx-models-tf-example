#!/usr/bin/env bash
# grant-sp-access.sh
#
# Grants the Terraform service principal the permissions that cannot be
# managed by Terraform itself (bootstrap chicken-and-egg):
#
#   1. AAD directory role: Application Administrator
#      → Allows the SP to create azuread_application + azuread_service_principal
#        resources in the model-serving module (dbw-model-serving SP).
#
#   2. Databricks account admin
#      → Allows the SP to create metastore, groups, and metastore assignments
#        in environments/account/ and workspace-scoped admin operations.
#
# Prerequisites:
#   - az login (as yourself — must already be AAD Global Admin or Privileged
#     Role Administrator to grant directory roles)
#   - cd bootstrap && terraform apply  (SP must already exist)
#   - jq installed (brew install jq)
#
# Usage:
#   bash scripts/grant-sp-access.sh

set -euo pipefail

SUBSCRIPTION_ID="<YOUR_SUBSCRIPTION_ID>"
DATABRICKS_ACCOUNT_ID="<YOUR_DATABRICKS_ACCOUNT_ID>"
KV_NAME="<YOUR_KV_NAME>"
SP_DISPLAY_NAME="sp-terraform-databricks"

# ── 1. Resolve SP identities ──────────────────────────────────────────────────

echo "▶ Fetching SP app ID from Key Vault '${KV_NAME}'..."
SP_APP_ID=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "terraform-sp-client-id" \
  --query value -o tsv)

echo "▶ Resolving SP object ID from AAD..."
SP_OBJECT_ID=$(az ad sp show --id "${SP_APP_ID}" --query id -o tsv)

echo "  SP app ID:    ${SP_APP_ID}"
echo "  SP object ID: ${SP_OBJECT_ID}"

# ── 2. AAD: Application Administrator directory role ─────────────────────────
# This role lets the SP create and manage app registrations + service principals
# (required for the azuread_application.model_serving resource in modules/model-serving).

echo ""
echo "▶ Granting AAD 'Application Administrator' directory role..."

# Activate the role if not already instantiated in this tenant
ROLE_TEMPLATE_ID="9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3" # Application Administrator

# Check if role is already active
ROLE_ID=$(az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/directoryRoles?\$filter=roleTemplateId+eq+'${ROLE_TEMPLATE_ID}'" \
  --query "value[0].id" -o tsv 2>/dev/null || echo "")

if [[ -z "${ROLE_ID}" ]]; then
  echo "  Activating 'Application Administrator' role in tenant..."
  ROLE_ID=$(az rest \
    --method POST \
    --url "https://graph.microsoft.com/v1.0/directoryRoles" \
    --body "{\"roleTemplateId\": \"${ROLE_TEMPLATE_ID}\"}" \
    --query id -o tsv)
fi

echo "  Role ID: ${ROLE_ID}"

# Check if SP is already a member
EXISTING=$(az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/directoryRoles/${ROLE_ID}/members" \
  --query "value[?id=='${SP_OBJECT_ID}'].id" -o tsv 2>/dev/null || echo "")

if [[ -n "${EXISTING}" ]]; then
  echo "  SP is already an Application Administrator — skipping."
else
  az rest \
    --method POST \
    --url "https://graph.microsoft.com/v1.0/directoryRoles/${ROLE_ID}/members/\$ref" \
    --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/directoryObjects/${SP_OBJECT_ID}\"}" \
    2>&1 | grep -v "already exist" || true
  echo "  ✓ Application Administrator role granted."
fi

# ── 3. Databricks: account admin ─────────────────────────────────────────────
# Uses the Databricks accounts SCIM API with a token minted from your az login
# session (resource ID is the Databricks Azure AD app).

echo ""
echo "▶ Adding SP as Databricks account admin..."

DBX_TOKEN=$(az account get-access-token \
  --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" \
  --query accessToken -o tsv)

DBX_API="https://accounts.azuredatabricks.net/api/2.0/accounts/${DATABRICKS_ACCOUNT_ID}"

# Check if SP is already registered as a service principal in the account
EXISTING_SP=$(curl -sf \
  "${DBX_API}/servicePrincipals?filter=applicationId+eq+${SP_APP_ID}" \
  -H "Authorization: Bearer ${DBX_TOKEN}" \
  | jq -r '.Resources[0].id // empty')

if [[ -z "${EXISTING_SP}" ]]; then
  echo "  Registering SP in Databricks account..."
  DBX_SP_ID=$(curl -sf \
    -X POST "${DBX_API}/servicePrincipals" \
    -H "Authorization: Bearer ${DBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"schemas\": [\"urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal\"],
      \"applicationId\": \"${SP_APP_ID}\",
      \"displayName\": \"${SP_DISPLAY_NAME}\",
      \"roles\": [{\"value\": \"account_admin\"}]
    }" | jq -r '.id')
  echo "  ✓ SP registered with account_admin role. Databricks SP ID: ${DBX_SP_ID}"
else
  echo "  SP already registered (Databricks SP ID: ${EXISTING_SP}). Ensuring account_admin role..."
  curl -sf \
    -X PATCH "${DBX_API}/servicePrincipals/${EXISTING_SP}" \
    -H "Authorization: Bearer ${DBX_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"schemas\": [\"urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal\"],
      \"roles\": [{\"value\": \"account_admin\"}]
    }" > /dev/null
  echo "  ✓ account_admin role confirmed."
fi

# ── 4. Summary ────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo "Done. SP '${SP_DISPLAY_NAME}' (${SP_APP_ID}) now has:"
echo ""
echo "  Azure RBAC (managed by bootstrap/main.tf terraform apply):"
echo "    • Contributor               → subscription"
echo "    • User Access Administrator → subscription"
echo "    • Storage Blob Data Contributor → state storage account"
echo "    • Key Vault Secrets User    → <YOUR_KV_NAME>"
echo ""
echo "  AAD directory role (just granted):"
echo "    • Application Administrator → tenant"
echo ""
echo "  Databricks (just granted):"
echo "    • account_admin             → account ${DATABRICKS_ACCOUNT_ID}"
echo ""
echo "Next: source .env && cd environments/account && terraform apply"
echo "════════════════════════════════════════════════════════"
