variable "workspace_name" {
  description = "Name of the Databricks workspace (used to derive resource names)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy Unity Catalog storage resources into"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all Azure resources"
  type        = map(string)
  default     = {}
}

variable "databricks_tags" {
  description = "Key/value tags applied to Databricks Unity Catalog objects (catalogs, schemas) that support tagging. Surfaced as `properties` on the underlying resources."
  type        = map(string)
  default     = {}
}

variable "uc_storage_account_name" {
  description = "Storage account name for Unity Catalog ADLS Gen2 (globally unique, 3-24 lowercase alphanumeric). Leave null to auto-derive from workspace_name."
  type        = string
  default     = null
  nullable    = true
}

variable "inference_table_catalog" {
  description = "Unity Catalog catalog name for inference tables"
  type        = string
  default     = "main"
}

variable "create_inference_catalog" {
  description = "Override for whether THIS workspace creates the inference catalog. Null = auto (create when inference_table_catalog != 'main'). Set to false in workspaces that should reference an inference catalog owned by another workspace (e.g. the 'platform' env) so they don't try to recreate or take ownership of it."
  type        = bool
  default     = null
  nullable    = true
}

variable "create_main_catalog" {
  description = "Whether to create the 'main' catalog. Set to false for spoke workspaces that share the hub's main catalog."
  type        = bool
  default     = true
}

variable "inference_table_schema" {
  description = "Unity Catalog schema name for inference tables"
  type        = string
  default     = "model_serving_logs"
}

variable "access_connector_id" {
  description = "Resource ID of the Databricks Access Connector"
  type        = string
}

variable "access_connector_principal_id" {
  description = "Principal ID of the Access Connector managed identity (for RBAC assignments)"
  type        = string
}

variable "workspace_resource_id" {
  description = "Numeric Databricks workspace ID for metastore assignment"
  type        = string
}

variable "metastore_id" {
  description = "Unity Catalog metastore ID — managed in environments/account/ and passed in per workspace"
  type        = string
}

variable "create_external_location" {
  description = "Whether to create a Databricks external location resource. Set to false if the external location is managed separately."
  type        = bool
  default     = true
}

variable "workspace_groups" {
  description = "Account-level groups granted workspace USER access AND scoped Unity Catalog privileges (CREATE_CATALOG on metastore; USE_CATALOG/CREATE_SCHEMA/SELECT/MODIFY/CREATE_TABLE/CREATE_FUNCTION/CREATE_VIEW/EXECUTE/CREATE_VOLUME/READ_VOLUME/WRITE_VOLUME on owned catalogs). MANAGE and APPLY_TAG are reserved for the catalog owner (ad-dbx)."
  type        = list(string)
  default     = []
}

variable "workspace_consumer_groups" {
  description = "Account-level groups granted workspace USER access ONLY (no UC writes, no catalog reads). For consumer teams that call shared endpoints from this workspace (e.g. LLM hub)."
  type        = list(string)
  default     = []
}

variable "workspace_reader_groups" {
  description = "Account-level groups granted workspace USER + read-only catalog access (USE_CATALOG, USE_SCHEMA, SELECT) on all catalogs managed here. For BI tools like Power BI."
  type        = list(string)
  default     = []
}

variable "owner_group" {
  description = "Display name of the Databricks account-level group to set as owner on all Unity Catalog objects (catalogs, schemas, storage credentials, external locations)."
  type        = string
  default     = "ad-dbx"
}

variable "inference_admin_groups" {
  description = "Account-level groups granted ALL_PRIVILEGES on the inference catalog AND its schema. Use this for admin-only visibility into centralized inference logs."
  type        = list(string)
  default     = []
}

variable "inference_writer_groups" {
  description = "Account-level groups (typically the team groups that own workload workspaces) granted USE_CATALOG on the inference catalog + USE_SCHEMA/MODIFY/CREATE_TABLE on its schema. Required for cross-workspace model serving endpoints to write inference tables into a centrally-owned catalog. Read access is NOT granted \u2014 use inference_admin_groups for that."
  type        = list(string)
  default     = []
}
