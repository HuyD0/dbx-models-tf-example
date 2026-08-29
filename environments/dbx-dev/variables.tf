variable "team" {
  description = "Team identifier for this workspace."
  type        = string
  default     = "dbx-dev"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group that will hold all Databricks resources."
  type        = string
  default     = "rg-databricks-dbx-dev"
}

variable "workspace_name" {
  description = "Azure Databricks workspace name."
  type        = string
  default     = "dbx-dev"
}

variable "sku" {
  description = "Databricks workspace SKU (standard, premium, or trial). Premium is required for endpoint ACLs."
  type        = string
  default     = "premium"
}

variable "tags" {
  description = "Azure resource tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "vnet_cidr" {
  description = "Address space for the VNet-injection network (public and private subnets are carved from it)."
  type        = string
  default     = "10.192.0.0/20"
}

variable "managed_resource_group_name" {
  description = "Override for the Databricks-managed resource group name. Null = provider default."
  type        = string
  default     = null
  nullable    = true
}

variable "no_public_ip" {
  description = "Enable Secure Cluster Connectivity (no public IPs on cluster nodes)."
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Allow access to the workspace UI/API from public networks."
  type        = bool
  default     = true
}

variable "infrastructure_encryption_enabled" {
  description = "Enable a second layer of encryption on the DBFS root storage."
  type        = bool
  default     = true
}

variable "ai_foundry_name" {
  description = "Name of the Azure AI Foundry (Cognitive Services) account serving external models."
  type        = string
  default     = "aif-huy-dev"
}

variable "ai_foundry_resource_group" {
  description = "Resource group containing the Azure AI Foundry account."
  type        = string
  default     = "rg-aifoundry-dev"
}

variable "openai_api_version" {
  description = "Azure OpenAI API version targeted by external model endpoints."
  type        = string
  default     = "2024-12-01-preview"
}

variable "inference_table_catalog" {
  description = "Unity Catalog catalog receiving model-serving inference tables."
  type        = string
  default     = "main"
}

variable "inference_table_schema" {
  description = "Unity Catalog schema receiving model-serving inference tables."
  type        = string
  default     = "model_serving_logs"
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
  description = "External model serving endpoints. Override to add or remove deployments without editing the module. provider defaults to openai (Azure AI Foundry); anthropic entries require api_key_secret."
  type = map(object({
    model           = string
    deployment_name = optional(string)
    task            = string
    table_prefix    = string
    provider        = optional(string, "openai")
    api_key_secret  = optional(string)
  }))
  default = null
}

variable "model_serving_additional_external_endpoints" {
  description = "Extra external endpoints merged on top of the module defaults. Use to add a model without replacing the full list."
  type = map(object({
    model           = string
    deployment_name = optional(string)
    task            = string
    table_prefix    = string
    provider        = optional(string, "openai")
    api_key_secret  = optional(string)
  }))
  default = {}
}

variable "model_serving_budget_policy_id" {
  description = "Databricks budget policy (serverless usage policy) ID attached to every model serving endpoint for cost attribution — from: cd environments/account && terraform output budget_policy_ids. Null = no policy."
  type        = string
  default     = null
  nullable    = true
}

variable "model_serving_guardrails" {
  description = "AI Gateway guardrails override (input/output safety + PII behavior). Null = use gateway_defaults.guardrails from model_defaults.yaml."
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

variable "model_serving_endpoint_permissions_enabled" {
  description = "Manage endpoint-level ACLs (CAN_QUERY / CAN_MANAGE). Set false on workspaces where the inference-endpoint ACL feature is not enabled by the account admin."
  type        = bool
  default     = true
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
  description = "Whether to create the 'main' Unity Catalog catalog."
  type        = bool
  default     = true
}

variable "enable_model_serving" {
  description = "Whether this workspace owns model serving endpoints."
  type        = bool
  default     = true
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

variable "databricks_auth_type" {
  description = <<-EOT
    Databricks provider auth strategy. Defaults to `azure-client-secret`, which
    reads ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID as exported by
    scripts/dev-auth.sh. CI sets this to `github-oidc-azure` so the workflow
    authenticates via the GitHub Actions OIDC token (ACTIONS_ID_TOKEN_REQUEST_*)
    and needs no client secret.
  EOT
  type        = string
  default     = "azure-client-secret"

  validation {
    condition     = contains(["azure-client-secret", "github-oidc-azure", "azure-cli"], var.databricks_auth_type)
    error_message = "databricks_auth_type must be one of: azure-client-secret, github-oidc-azure, azure-cli."
  }
}
