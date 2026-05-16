variable "ai_foundry_name" {
  description = "Name of the Azure AI Foundry (Cognitive Services) account"
  type        = string
}

variable "ai_foundry_resource_group" {
  description = "Resource group containing the Azure AI Foundry account"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for workspace-scoped Azure AD app registration backing the model serving SP. Should be unique per workspace to avoid Entra display-name collisions across workspaces that share this module."
  type        = string
  default     = "dbw"
}

variable "inference_table_prefix" {
  description = "Workspace identifier prepended to every inference table name (e.g. 'team_a'). Required when multiple workspaces write to the same centralized inference_table_catalog/schema so tables don't collide. Empty = no prefix (single-workspace catalog)."
  type        = string
  default     = ""
}

variable "openai_api_version" {
  description = "Azure OpenAI API version to target from Databricks model serving endpoints"
  type        = string
  default     = "2024-12-01-preview"
}

variable "inference_table_catalog" {
  description = "Unity Catalog catalog name where inference tables will be written"
  type        = string
  default     = "main"
}

variable "inference_table_schema" {
  description = "Unity Catalog schema name where inference tables will be written"
  type        = string
  default     = "model_serving_logs"
}

variable "fallback_enabled" {
  description = "Enable AI gateway traffic fallback. When a served entity returns error codes (e.g. 500), the request is automatically retried against other served entities in the endpoint in round-robin order."
  type        = bool
  default     = false
}

variable "endpoint_permissions_enabled" {
  description = "Manage endpoint-level ACLs (CAN_QUERY / CAN_MANAGE) for the serving endpoints. Set to false for workspaces where the inference-endpoint ACL feature is not enabled by the account admin (you will see 'ACLs for inference-endpoint are disabled or not available in this tier' errors otherwise). When false, only workspace admins can call the endpoints."
  type        = bool
  default     = true
}

variable "rate_limits" {
  description = "Rate limit rules for the AI gateway. Each entry defines how many calls (and optionally tokens) are allowed per key within a renewal period."
  type = list(object({
    calls          = number
    key            = optional(string, "endpoint")
    renewal_period = optional(string, "minute")
    tokens         = optional(number)
    principal      = optional(string)
  }))
  default = []
}

variable "external_endpoints" {
  description = "External (Azure OpenAI) model serving endpoints. Set to null to use the built-in defaults defined in the module."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default  = null
  nullable = true
}

variable "additional_external_endpoints" {
  description = "Extra external (Azure OpenAI) endpoints to merge on top of the active set (defaults or var.external_endpoints). Use this to add a new model without replacing the whole list."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = {}
}

variable "write_access_group" {
  description = "Display name of a single group to grant CAN_QUERY on all endpoints. Convenience for single-workspace use; hub deployments should use consumer_groups instead."
  type        = string
  default     = null
  nullable    = true
}

variable "consumer_groups" {
  description = "List of group display names granted CAN_QUERY on all model serving endpoints. Use this when sharing endpoints across multiple workspace consumers (e.g. an LLM hub)."
  type        = list(string)
  default     = []
}

variable "databricks_tags" {
  description = "Key/value tags applied to every Databricks model serving endpoint managed by this module."
  type        = map(string)
  default     = {}
}

variable "admin_groups" {
  description = "Account-level group display names that get CAN_MANAGE on every model serving endpoint. Locks down who can create/update/delete endpoints."
  type        = list(string)
  default     = []
}

variable "guardrails" {
  description = "AI Gateway guardrails applied to every endpoint. Set input/output safety + PII behavior. Default null = no guardrails."
  type = object({
    input = optional(object({
      safety       = optional(bool, false)
      pii_behavior = optional(string) # "BLOCK" | "MASK" | "NONE"
    }))
    output = optional(object({
      safety       = optional(bool, false)
      pii_behavior = optional(string)
    }))
  })
  default  = null
  nullable = true
}

# NOTE: governance of pre-provisioned `databricks-*` Foundation Model API
# endpoints (allowlist + blocklist) lives in modules/model-serving/model_defaults.yaml
# and is applied via scripts/apply-ai-gateway.sh, not via Terraform variables.
# Edit the YAML to change the policy; the workspace-stack terraform_data
# reconciler re-asserts the desired state on every `terraform apply`.
