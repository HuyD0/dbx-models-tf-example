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
  description = "Rate limit rules for the AI gateway, overriding gateway_defaults.rate_limits in model_defaults.yaml. Each entry defines how many calls (and optionally tokens) are allowed per key within a renewal period. Empty = use the YAML defaults."
  type = list(object({
    calls          = number
    key            = optional(string, "endpoint")
    renewal_period = optional(string, "minute")
    tokens         = optional(number)
    principal      = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.rate_limits : contains(["user", "user_group", "service_principal", "endpoint"], r.key)])
    error_message = "rate_limits key must be one of: user, user_group, service_principal, endpoint."
  }

  validation {
    condition     = alltrue([for r in var.rate_limits : r.principal != null if contains(["user_group", "service_principal"], r.key)])
    error_message = "rate_limits entries with key = user_group or service_principal must set principal (group display name / SP application ID)."
  }

  validation {
    condition     = length(var.rate_limits) <= 20 && length([for r in var.rate_limits : r if r.key == "user_group"]) <= 5
    error_message = "Databricks allows at most 20 rate limits per endpoint, of which at most 5 may be user_group-scoped."
  }
}

variable "budget_policy_id" {
  description = "Databricks budget policy (serverless usage policy) ID attached to every serving endpoint for cost attribution — its custom tags are stamped onto system.billing.usage records. From: cd environments/account && terraform output budget_policy_ids. Null = no policy. NOTE: Databricks does not currently apply usage policies to endpoints serving external models — tag-filtered budgets remain the guaranteed attribution path for those; this attachment covers foundation/custom endpoints and is forward-looking for external ones."
  type        = string
  default     = null
  nullable    = true
}

variable "external_endpoints" {
  description = "External model serving endpoints. Set to null to use the built-in defaults defined in model_defaults.yaml. provider defaults to openai (Azure AI Foundry via Entra ID); anthropic entries require api_key_secret ('<scope>/<key>' Databricks secret path)."
  type = map(object({
    model           = string
    deployment_name = optional(string)
    task            = string
    table_prefix    = string
    provider        = optional(string, "openai")
    api_key_secret  = optional(string)
  }))
  default  = null
  nullable = true

  validation {
    condition     = var.external_endpoints == null ? true : alltrue([for e in var.external_endpoints : contains(["openai", "anthropic"], e.provider)])
    error_message = "external_endpoints provider must be openai or anthropic."
  }
}

variable "additional_external_endpoints" {
  description = "Extra external endpoints to merge on top of the active set (defaults or var.external_endpoints). Use this to add a new model without replacing the whole list. Same shape as external_endpoints."
  type = map(object({
    model           = string
    deployment_name = optional(string)
    task            = string
    table_prefix    = string
    provider        = optional(string, "openai")
    api_key_secret  = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for e in var.additional_external_endpoints : contains(["openai", "anthropic"], e.provider)])
    error_message = "additional_external_endpoints provider must be openai or anthropic."
  }
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
  description = "AI Gateway guardrails applied to every endpoint, overriding gateway_defaults.guardrails in model_defaults.yaml. Set input/output safety + PII behavior. Default null = use the YAML defaults (no guardrails unless the YAML enables them)."
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
