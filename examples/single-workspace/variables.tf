variable "subscription_id" {
  description = "Azure subscription ID hosting the workspace."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID (UUID) for the accounts-level provider."
  type        = string
  sensitive   = true
}

variable "metastore_id" {
  description = "Unity Catalog metastore UUID — from: cd environments/account && terraform output metastore_id."
  type        = string
}

variable "deployment_sp_client_id" {
  description = "Client ID of the deployment service principal registered in the Databricks account."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group that will hold all Databricks resources."
  type        = string
  default     = "rg-databricks-example"
}

variable "workspace_name" {
  description = "Azure Databricks workspace name."
  type        = string
  default     = "dbx-example"
}
