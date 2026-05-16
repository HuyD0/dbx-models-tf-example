variable "databricks_account_id" {
  description = "Databricks account ID (UUID)"
  type        = string
  sensitive   = true
}

variable "deployment_sp_client_id" {
  description = "Client ID of the deployment SP (sp-terraform-databricks). Granted ADMIN on all workspaces."
  type        = string
}

variable "location" {
  description = "Azure region for the Unity Catalog metastore"
  type        = string
  default     = "canadacentral"
}

variable "metastore_name" {
  description = "Name of the Unity Catalog metastore (one per region per account)"
  type        = string
  default     = "main"
}

variable "groups" {
  description = "Account-level group display names to create (visible across all workspaces)"
  type        = list(string)
  default     = []
}

variable "teams" {
  description = "Team identifiers. For each team, an 'ad-dbx-<team>' group is created at the account level."
  type        = list(string)
  default     = []
}

