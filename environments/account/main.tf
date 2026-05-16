# --- Unity Catalog Metastore ---
# One metastore per region per Databricks account is allowed.
# If one already exists, import it before applying:
#   terraform import databricks_metastore.this <metastore-uuid>

resource "databricks_metastore" "this" {
  name          = var.metastore_name
  region        = var.location
  owner         = "ad-dbx"
  force_destroy = false
}

# --- Account-level groups ---
# Groups created here are visible to all workspaces in the account.
# To grant a group access to a specific workspace, use
# databricks_mws_permission_assignment in the workspace's environment (dev/ or prod/).

resource "databricks_group" "this" {
  for_each     = toset(var.groups)
  display_name = each.value
}

resource "databricks_group" "team" {
  for_each     = toset(var.teams)
  display_name = "ad-dbx-${each.value}"
}

# --- Deployment SP ---
# Ensures sp-terraform-databricks exists in the account SCIM so workspace-stack
# can look it up via data source and grant it ADMIN when each workspace is
# created. The per-workspace ADMIN grant is managed in modules/workspace-stack.

resource "databricks_service_principal" "deployment_sp" {
  application_id = var.deployment_sp_client_id
  display_name   = "sp-terraform-databricks"
  active         = true
}

# NOTE: The deployment SP (var.deployment_sp_client_id) must be a member of
# the "ad-dbx" Azure AD group so it inherits ownership of all Unity Catalog
# objects (metastore, external locations, catalogs, schemas) without needing
# per-object MANAGE grants.  This cannot be managed here because the SP lacks
# MS Graph GroupMember.ReadWrite.All.  Run the bootstrap step once:
#
#   SP_OID=$(az ad sp show --id <deployment_sp_client_id> --query id -o tsv)
#   az ad group member add --group "ad-dbx" --member-id "$SP_OID"
