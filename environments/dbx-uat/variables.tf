variable "team" {
  description = "Team identifier for this workspace."
  type        = string
  default     = "dbx-uat"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "resource_group_name" {
  type = string
}

variable "workspace_name" {
  type = string
}

variable "sku" {
  type    = string
  default = "premium"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vnet_cidr" {
  type    = string
  default = "10.193.0.0/20"
}

variable "managed_resource_group_name" {
  type     = string
  default  = null
  nullable = true
}

variable "no_public_ip" {
  type    = bool
  default = true
}

variable "public_network_access_enabled" {
  type    = bool
  default = true
}

variable "infrastructure_encryption_enabled" {
  type    = bool
  default = true
}

variable "ai_foundry_name" {
  description = "Azure AI Foundry account backing model serving. Unused while enable_model_serving = false."
  type        = string
  default     = null
  nullable    = true
}

variable "ai_foundry_resource_group" {
  description = "Resource group of the AI Foundry account. Unused while enable_model_serving = false."
  type        = string
  default     = null
  nullable    = true
}

variable "openai_api_version" {
  type    = string
  default = "2024-12-01-preview"
}

variable "inference_table_catalog" {
  description = "Catalog owning inference tables. `uat` here -- `main` is owned by the dbx-dev workspace on the shared metastore."
  type        = string
  default     = "uat"
}

variable "inference_table_schema" {
  type    = string
  default = "model_serving_logs"
}

variable "databricks_account_id" {
  description = "Databricks account ID (UUID) for the accounts-level provider"
  type        = string
  sensitive   = true
}

variable "metastore_id" {
  description = "Unity Catalog metastore ID — from: cd environments/account && terraform output metastore_id"
  type        = string
}

variable "uc_storage_account_name" {
  description = "Storage account name for Unity Catalog metastore ADLS Gen2 (globally unique, 3-24 lowercase alphanumeric). Leave null to auto-derive from workspace_name."
  type        = string
  default     = null
  nullable    = true
}

variable "subscription_id" {
  description = "Azure subscription ID — used to scope the azurerm provider."
  type        = string
}

variable "model_serving_fallback_enabled" {
  description = "Enable AI gateway traffic fallback for model serving endpoints."
  type        = bool
  default     = false
}

variable "model_serving_rate_limits" {
  description = "Rate limit rules for model serving AI gateway."
  type = list(object({
    calls          = number
    key            = optional(string, "endpoint")
    renewal_period = optional(string, "minute")
    tokens         = optional(number)
    principal      = optional(string)
  }))
  default = []
}

variable "model_serving_external_endpoints" {
  description = "External (Azure OpenAI) model serving endpoints. Override to add or remove deployments without editing the module."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = null
}

variable "model_serving_additional_external_endpoints" {
  description = "Extra external (Azure OpenAI) endpoints merged on top of the module defaults. Use to add a model without replacing the full list."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = {}
}

variable "workspace_groups" {
  description = "Account-level groups granted workspace USER + UC ALL_PRIVILEGES."
  type        = list(string)
  default     = []
}

variable "consumer_groups" {
  description = "Account-level groups granted workspace USER + endpoint CAN_QUERY (read-only consumers)."
  type        = list(string)
  default     = []
}

variable "create_main_catalog" {
  description = "Whether to create the 'main' Unity Catalog catalog. False here -- dbx-dev owns `main` on the shared metastore and catalog names are metastore-global."
  type        = bool
  default     = false
}

variable "create_inference_catalog" {
  description = "Whether this workspace creates its own inference catalog. Null = auto (create when inference_table_catalog != 'main')."
  type        = bool
  default     = null
  nullable    = true
}

variable "enable_model_serving" {
  description = "Whether this workspace owns model serving endpoints."
  type        = bool
  default     = false
}

variable "contributor_group_object_id" {
  description = "Object ID of the Azure AD security group to grant Contributor on the resource group."
  type        = string
  default     = null
  nullable    = true
}

variable "model_serving_admin_groups" {
  description = "Account-level groups granted CAN_MANAGE on every model serving endpoint."
  type        = list(string)
  default     = []
}

variable "deployment_sp_client_id" {
  description = "Azure client ID of the deployment service principal (sp-terraform-databricks). Granted ADMIN on this workspace at creation time."
  type        = string
}
