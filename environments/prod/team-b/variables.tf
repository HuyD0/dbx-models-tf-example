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
  default = "rg-dbx-llm-hub"
}

variable "workspace_name" {
  type    = string
  default = "dbw-llm-hub"
}

variable "vnet_cidr" {
  type    = string
  default = "10.200.0.0/20"
}

variable "uc_storage_account_name" {
  type    = string
  default = "dbwllmhubuc"
}

variable "metastore_id" {
  type = string
}

variable "ai_foundry_name" {
  type = string
}

variable "ai_foundry_resource_group" {
  type = string
}

variable "openai_api_version" {
  type    = string
  default = "2024-12-01-preview"
}

variable "inference_table_catalog" {
  description = "Catalog for centralized model serving inference tables"
  type        = string
  default     = "llmlogs"
}

variable "inference_table_schema" {
  type    = string
  default = "model_serving_logs"
}

variable "model_serving_fallback_enabled" {
  type    = bool
  default = true
}

variable "model_serving_endpoint_permissions_enabled" {
  type    = bool
  default = true
}

variable "model_serving_rate_limits" {
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
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = null
}

variable "model_serving_admin_groups" {
  description = "Groups granted CAN_MANAGE on every model serving endpoint."
  type        = list(string)
  default     = []
}

variable "model_serving_guardrails" {
  description = "AI Gateway guardrails (input/output safety + PII behavior)."
  type = object({
    input = optional(object({
      safety       = optional(bool, false)
      pii_behavior = optional(string)
    }))
    output = optional(object({
      safety       = optional(bool, false)
      pii_behavior = optional(string)
    }))
  })
  default  = null
  nullable = true
}

variable "contributor_group_object_id" {
  description = "Object ID of the Azure AD security group to grant Contributor on the resource group."
  type        = string
  default     = null
  nullable    = true
}

variable "consumer_groups" {
  description = "Account-level group display names that get CAN_QUERY on every endpoint and EXECUTE on every foundation model. Add a new team's group here to grant access."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "workspace_groups" {
  description = "Account-level groups granted workspace USER + UC ALL_PRIVILEGES on team-b's own catalog. Members are also the writer principals for inference tables when applying terraform."
  type        = list(string)
  default     = []
}

variable "create_main_catalog" {
  description = "Whether to create a workspace-local 'main' catalog. Set false to use a shared catalog."
  type        = bool
  default     = false
}

variable "deployment_sp_client_id" {
  description = "Azure client ID of the deployment service principal (sp-terraform-databricks). Granted ADMIN on this workspace at creation time."
  type        = string
}
