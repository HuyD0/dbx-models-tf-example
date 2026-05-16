variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group to deploy Databricks resources into"
  type        = string
}

variable "workspace_name" {
  description = "Name of the Azure Databricks workspace"
  type        = string
}

variable "sku" {
  description = "Databricks workspace SKU: standard | premium | trial"
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium", "trial"], var.sku)
    error_message = "SKU must be one of: standard, premium, trial."
  }
}

variable "tags" {
  description = "Tags to apply to all Azure resources"
  type        = map(string)
  default     = {}
}

variable "vnet_cidr" {
  description = "Address space for the VNet used for VNet injection"
  type        = string
  default     = "10.180.0.0/20"
}

variable "managed_resource_group_name" {
  description = "Override the name of the Databricks-managed resource group. Null = auto-name."
  type        = string
  default     = null
  nullable    = true
}

variable "no_public_ip" {
  description = "Enable Secure Cluster Connectivity (no public IP on clusters)"
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Allow public network access to the workspace."
  type        = bool
  default     = false
}

variable "infrastructure_encryption_enabled" {
  description = "Enable secondary layer of encryption on DBFS root."
  type        = bool
  default     = true
}

variable "ai_foundry_name" {
  description = "Name of the Azure AI Foundry (Cognitive Services) account"
  type        = string
}

variable "ai_foundry_resource_group" {
  description = "Resource group containing the Azure AI Foundry account"
  type        = string
}

variable "openai_api_version" {
  description = "Azure OpenAI API version"
  type        = string
  default     = "2024-12-01-preview"
}

variable "inference_table_catalog" {
  description = "Unity Catalog catalog for inference tables"
  type        = string
  default     = "main"
}

variable "inference_table_schema" {
  description = "Unity Catalog schema for inference tables"
  type        = string
  default     = "model_serving_logs"
}

variable "databricks_account_id" {
  description = "Databricks account ID (UUID) for the accounts-level provider"
  type        = string
  sensitive   = true
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "metastore_id" {
  description = "Unity Catalog metastore ID (output of environments/account)"
  type        = string
}

variable "uc_storage_account_name" {
  description = "Storage account name for Unity Catalog ADLS Gen2 (3-24 lowercase alphanumeric). Null = auto-derive."
  type        = string
  default     = null
  nullable    = true
}

variable "model_serving_fallback_enabled" {
  description = "Enable AI gateway traffic fallback for model serving endpoints."
  type        = bool
  default     = false
}

variable "model_serving_endpoint_permissions_enabled" {
  description = "Manage databricks_permissions on serving endpoints. Disable if the workspace tier does not expose inference-endpoint ACLs."
  type        = bool
  default     = true
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
  description = "External (Azure OpenAI) model serving endpoints. Null = use module defaults."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = null
}

variable "contributor_group_object_id" {
  description = "Object ID of the Azure AD security group to grant Contributor on the resource group."
  type        = string
  default     = null
  nullable    = true
}

variable "consumer_groups" {
  description = "Account-level groups granted CAN_QUERY on every model serving endpoint."
  type        = list(string)
  default     = []
}

variable "model_serving_admin_groups" {
  description = "Account-level groups granted CAN_MANAGE on every model serving endpoint."
  type        = list(string)
  default     = []
}

variable "model_serving_guardrails" {
  description = "AI gateway guardrail configuration applied to every model serving endpoint."
  type = object({
    input = optional(object({
      safety       = optional(bool)
      pii_behavior = optional(string)
    }))
    output = optional(object({
      safety       = optional(bool)
      pii_behavior = optional(string)
    }))
  })
  default  = null
  nullable = true
}

variable "workspace_groups" {
  description = "Account-level groups granted workspace USER access and scoped Unity Catalog privileges on this workspace's catalogs."
  type        = list(string)
  default     = []
}

variable "ai_gateway_reconcile_on_apply" {
  description = "Run scripts/apply-ai-gateway.sh in single-workspace mode after every `terraform apply` to re-assert rate limits + inference tables on pre-provisioned `databricks-*` endpoints. Requires `az`, `yq`, `jq`, `curl` on PATH."
  type        = bool
  default     = true
}

variable "deployment_sp_client_id" {
  description = "Azure client ID of the deployment service principal (sp-terraform-databricks). Granted ADMIN on this workspace at creation time."
  type        = string
}
