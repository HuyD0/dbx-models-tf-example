variable "subscription_id" {
  type = string
}

variable "databricks_account_id" {
  type      = string
  sensitive = true
}

variable "location" {
  type    = string
  default = "canadacentral"
}

variable "resource_group_name" {
  type    = string
  default = "rg-dbx-dev-platform"
}

variable "workspace_name" {
  type    = string
  default = "dbw-dev-platform"
}

variable "vnet_cidr" {
  type    = string
  default = "10.190.0.0/20"
}

variable "uc_storage_account_name" {
  type    = string
  default = "dbwdevplatformuc"
}

variable "metastore_id" {
  type = string
}

variable "inference_table_catalog" {
  description = "Centralized inference table catalog name. All workload workspaces (team-a, team-b, ...) write here."
  type        = string
  default     = "llmlogs"
}

variable "inference_table_schema" {
  type    = string
  default = "model_serving_logs"
}

variable "inference_admin_groups" {
  description = "Account-level groups granted ALL_PRIVILEGES on llmlogs catalog. Admin-only read access to inference logs."
  type        = list(string)
  default     = ["ad-dbx"]
}

variable "inference_writer_groups" {
  description = "Account-level groups whose members can write inference tables from OTHER workspaces. Should contain every team's deployer/serving group."
  type        = list(string)
  default     = []
}

variable "contributor_group_object_id" {
  type     = string
  default  = null
  nullable = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "deployment_sp_client_id" {
  description = "Azure client ID of the deployment service principal (sp-terraform-databricks). Granted ADMIN on this workspace at creation time."
  type        = string
}
