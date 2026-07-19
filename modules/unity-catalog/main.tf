terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = ">= 1.60, < 2.0"
      configuration_aliases = [databricks.accounts]
    }
  }
}

locals {
  # Storage account names: max 24 chars, lowercase alphanumeric only.
  workspace_slug          = lower(replace(replace(var.workspace_name, "-", ""), "_", ""))
  uc_storage_account_name = coalesce(var.uc_storage_account_name, substr("${local.workspace_slug}uc", 0, 24))

  # The inference-table catalog is created here only when it is *not* the
  # built-in `main` catalog (which we already manage above). This avoids a
  # duplicate-resource error when var.inference_table_catalog == "main".
  # Allow explicit override via var.create_inference_catalog so workload
  # workspaces can REFERENCE a catalog owned by another workspace (e.g. the
  # central `platform` env) without trying to recreate it.
  manage_inference_catalog = coalesce(
    var.create_inference_catalog,
    var.inference_table_catalog != "main",
  )
}

# --- ADLS Gen2 storage account for Unity Catalog ---

resource "azurerm_storage_account" "unity_catalog" {
  name                            = local.uc_storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  is_hns_enabled                  = true # required for ADLS Gen2 / UC
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "unity_catalog" {
  name                  = "unity-catalog"
  storage_account_id    = azurerm_storage_account.unity_catalog.id
  container_access_type = "private"
}

# --- RBAC: Access Connector → UC storage ---
# The Access Connector's system-assigned MSI must have these roles so Databricks
# can read/write UC-managed tables and checkpoints.

# Storage Blob Data Contributor is the only role Unity Catalog needs. The
# broader Storage Account Contributor (manage keys/network/config) has been
# removed to enforce least-privilege access for the Access Connector MSI.
resource "azurerm_role_assignment" "ac_uc_blob_contributor" {
  scope                = azurerm_storage_account.unity_catalog.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.access_connector_principal_id
}

# --- Unity Catalog Metastore Assignment ---
# The metastore is managed centrally in environments/account/ (one per region per account).
# Get the metastore_id by running: cd environments/account && terraform output metastore_id

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.accounts
  workspace_id = var.workspace_resource_id
  metastore_id = var.metastore_id
}

# --- Storage Credential ---
# Links the Access Connector MSI to Unity Catalog as an auth method for storage.

resource "databricks_storage_credential" "unity_catalog" {
  name = "${var.workspace_name}-ac-credential"
  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }
  owner      = var.owner_group
  comment    = "Managed by Terraform — Access Connector MSI for Unity Catalog"
  depends_on = [databricks_metastore_assignment.this]
}

# --- External Location (optional) ---
# Required before creating a catalog with a custom storage_root.
# Disable when the external location is managed separately (e.g. prod uses a shared one).

resource "databricks_external_location" "unity_catalog" {
  count           = var.create_external_location ? 1 : 0
  name            = "${var.workspace_name}-uc-storage"
  url             = format("abfss://%s@%s.dfs.core.windows.net", azurerm_storage_container.unity_catalog.name, azurerm_storage_account.unity_catalog.name)
  credential_name = databricks_storage_credential.unity_catalog.name
  owner           = var.owner_group
  comment         = "External location for Unity Catalog catalog storage — managed by Terraform"
  depends_on      = [azurerm_role_assignment.ac_uc_blob_contributor]
}

# --- Catalog ---

resource "databricks_catalog" "main" {
  count = var.create_main_catalog ? 1 : 0
  name  = "main"
  storage_root = format(
    "abfss://%s@%s.dfs.core.windows.net",
    azurerm_storage_container.unity_catalog.name,
    azurerm_storage_account.unity_catalog.name
  )
  owner      = var.owner_group
  comment    = "Managed by Terraform"
  properties = var.databricks_tags
  depends_on = [databricks_metastore_assignment.this, databricks_external_location.unity_catalog]
}

# --- Additional catalog for inference tables (only if not `main`) ---

resource "databricks_catalog" "inference" {
  count         = local.manage_inference_catalog ? 1 : 0
  name          = var.inference_table_catalog
  owner         = var.owner_group
  comment       = "Catalog for model serving inference tables — managed by Terraform"
  properties    = var.databricks_tags
  force_destroy = false
  storage_root = format(
    "abfss://%s@%s.dfs.core.windows.net/%s",
    azurerm_storage_container.unity_catalog.name,
    azurerm_storage_account.unity_catalog.name,
    var.inference_table_catalog
  )
  depends_on = [databricks_metastore_assignment.this, databricks_external_location.unity_catalog]
}

# --- Schema for inference table logs (used by model serving endpoints) ---
# Only created in workspaces that own the inference catalog. Other workspaces
# reference the schema by name through their model serving config.

resource "databricks_schema" "model_serving_logs" {
  count        = local.manage_inference_catalog || var.create_main_catalog ? 1 : 0
  catalog_name = local.manage_inference_catalog ? databricks_catalog.inference[0].name : databricks_catalog.main[0].name
  name         = var.inference_table_schema
  owner        = var.owner_group
  comment      = "Inference table logs for model serving endpoints — managed by Terraform"
  properties   = var.databricks_tags
}

# --- Workspace + Unity Catalog access for account-level groups ---
# `workspace_groups`          → workspace USER + scoped UC privileges (CREATE_CATALOG on metastore;
#                               USE_CATALOG/CREATE_SCHEMA/SELECT/MODIFY/CREATE_TABLE/CREATE_FUNCTION/
#                               CREATE_VIEW/EXECUTE/CREATE_VOLUME/READ_VOLUME/WRITE_VOLUME on catalogs).
#                               MANAGE and APPLY_TAG are reserved for the catalog owner (ad-dbx).
# `workspace_consumer_groups` → workspace USER only (for hub consumers — no UC writes)

locals {
  all_workspace_groups = toset(concat(var.workspace_groups, var.workspace_consumer_groups, var.workspace_reader_groups))
  uc_write_groups      = toset(var.workspace_groups)
  uc_read_groups       = toset(var.workspace_reader_groups)
}

data "databricks_group" "workspace_groups" {
  for_each     = local.all_workspace_groups
  provider     = databricks.accounts
  display_name = each.value
}

resource "databricks_mws_permission_assignment" "workspace_access" {
  for_each     = local.all_workspace_groups
  provider     = databricks.accounts
  workspace_id = var.workspace_resource_id
  principal_id = data.databricks_group.workspace_groups[each.value].id
  permissions  = ["USER"]
}

resource "databricks_grant" "metastore" {
  for_each  = local.uc_write_groups
  metastore = var.metastore_id
  principal = each.value
  # Least privilege: team groups may create catalogs in their own workspace.
  # CREATE_EXTERNAL_LOCATION and CREATE_STORAGE_CREDENTIAL are platform-only;
  # those are controlled by the metastore owner (ad-dbx) and the storage-credential
  # resource in this module.
  privileges = ["CREATE_CATALOG"]
  depends_on = [databricks_mws_permission_assignment.workspace_access]
}

resource "databricks_grant" "main_catalog" {
  for_each  = var.create_main_catalog ? local.uc_write_groups : toset([])
  catalog   = databricks_catalog.main[0].name
  principal = each.value
  # Explicit scoped privileges — excludes MANAGE (modify others' grants) and
  # APPLY_TAG (governance metadata admin), which are reserved for the catalog owner.
  privileges = [
    "USE_CATALOG", "CREATE_SCHEMA", "USE_SCHEMA",
    "SELECT", "MODIFY", "CREATE_TABLE", "CREATE_FUNCTION",
    "CREATE_VIEW", "EXECUTE", "CREATE_VOLUME",
    "READ_VOLUME", "WRITE_VOLUME",
  ]
  depends_on = [databricks_catalog.main, databricks_mws_permission_assignment.workspace_access]
}

resource "databricks_grant" "inference_catalog" {
  for_each  = local.manage_inference_catalog ? local.uc_write_groups : toset([])
  catalog   = databricks_catalog.inference[0].name
  principal = each.value
  # Same scoped set as main_catalog — no MANAGE or APPLY_TAG.
  # In practice this fires only when the workspace owns the inference catalog
  # AND workspace_groups is non-empty; the platform env sets workspace_groups=[]
  # so inference_catalog_admin is the effective admin grant.
  privileges = [
    "USE_CATALOG", "CREATE_SCHEMA", "USE_SCHEMA",
    "SELECT", "MODIFY", "CREATE_TABLE", "CREATE_FUNCTION",
    "CREATE_VIEW", "EXECUTE", "CREATE_VOLUME",
    "READ_VOLUME", "WRITE_VOLUME",
  ]
  depends_on = [databricks_catalog.inference, databricks_mws_permission_assignment.workspace_access]
}

# Read-only catalog grants for BI/reader groups
resource "databricks_grant" "main_catalog_read" {
  for_each   = var.create_main_catalog ? local.uc_read_groups : toset([])
  catalog    = databricks_catalog.main[0].name
  principal  = each.value
  privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "EXECUTE", "READ_VOLUME"]
  depends_on = [databricks_catalog.main, databricks_mws_permission_assignment.workspace_access]
}

resource "databricks_grant" "inference_catalog_read" {
  for_each   = local.manage_inference_catalog ? local.uc_read_groups : toset([])
  catalog    = databricks_catalog.inference[0].name
  principal  = each.value
  privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "EXECUTE", "READ_VOLUME"]
  depends_on = [databricks_catalog.inference, databricks_mws_permission_assignment.workspace_access]
}

# --- Admin-only ALL_PRIVILEGES on the centralized inference catalog ---
# Use this on the workspace that OWNS the catalog (e.g. the `platform` env)
# to lock log read access to admins. Workload workspaces that only write get
# privileges via inference_writer_groups (no read).

resource "databricks_grant" "inference_catalog_admin" {
  for_each   = local.manage_inference_catalog ? toset(var.inference_admin_groups) : toset([])
  catalog    = databricks_catalog.inference[0].name
  principal  = each.value
  privileges = ["ALL_PRIVILEGES"]
  depends_on = [databricks_catalog.inference]
}

# --- Cross-workspace writer grants ---
# USE_CATALOG on the catalog + USE_SCHEMA / MODIFY / CREATE_TABLE on the schema
# so model serving endpoints in OTHER workspaces (whose serving SP is a member
# of one of these groups) can write inference tables into this centralized
# catalog. No SELECT is granted \u2014 read access is admin-only.

resource "databricks_grant" "inference_catalog_writer" {
  for_each   = local.manage_inference_catalog ? toset(var.inference_writer_groups) : toset([])
  catalog    = databricks_catalog.inference[0].name
  principal  = each.value
  privileges = ["USE_CATALOG"]
  depends_on = [databricks_catalog.inference]
}

resource "databricks_grant" "inference_schema_writer" {
  for_each   = (local.manage_inference_catalog || var.create_main_catalog) ? toset(var.inference_writer_groups) : toset([])
  schema     = "${databricks_schema.model_serving_logs[0].catalog_name}.${databricks_schema.model_serving_logs[0].name}"
  principal  = each.value
  privileges = ["USE_SCHEMA", "MODIFY", "CREATE_TABLE"]
  depends_on = [databricks_schema.model_serving_logs]
}
