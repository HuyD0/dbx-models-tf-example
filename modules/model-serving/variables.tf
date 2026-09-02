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

variable "agent_waste_monitors" {
  description = "Opt-in scheduled Databricks SQL alerts (databricks_alert_v2) that surface silent agent waste: retry loops (error-loops), elevated per-endpoint failure share (error-rate), callers hammering deny-listed models (blocked-model-attempts) and, with payload_alerts_enabled, sessions that keep feeding tool-call errors back to the model (tool-error-loops). Queries are generated from the endpoint catalog and run against system.serving.endpoint_usage and the inference tables — see docs/agent-spend-waste.md. Null = nothing created. warehouse_id: SQL warehouse the alerts evaluate on. notify_emails: recipients. parent_path: workspace folder for the alerts. schedule_cron/timezone_id: Quartz schedule. Threshold fields are per alert. tool_error_pattern: RLIKE regex marking a tool-role message as an error. workspace_id: numeric workspace ID used to scope the system-table queries (workspace-stack fills it in)."
  type = object({
    warehouse_id                 = string
    notify_emails                = list(string)
    parent_path                  = optional(string, "/Shared/llm-gateway-monitors")
    schedule_cron                = optional(string, "0 0 * * * ?")
    timezone_id                  = optional(string, "UTC")
    error_loop_failed_calls      = optional(number, 10)
    error_rate_pct               = optional(number, 20)
    error_rate_min_calls         = optional(number, 20)
    blocked_model_attempts       = optional(number, 25)
    payload_alerts_enabled       = optional(bool, false)
    tool_error_turns_per_session = optional(number, 3)
    tool_error_pattern           = optional(string, "(?i)(error|exception|traceback|invalid|not found)")
    workspace_id                 = optional(string)
  })
  default  = null
  nullable = true

  validation {
    condition     = var.agent_waste_monitors == null || try(length(var.agent_waste_monitors.notify_emails) > 0, false)
    error_message = "agent_waste_monitors.notify_emails must list at least one recipient — an alert nobody receives is exactly the silent failure these monitors exist to prevent."
  }

  validation {
    condition     = var.agent_waste_monitors == null || try(alltrue([for e in var.agent_waste_monitors.notify_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))]), false)
    error_message = "agent_waste_monitors.notify_emails entries must be email addresses."
  }

  validation {
    condition     = var.agent_waste_monitors == null || try(length(var.agent_waste_monitors.warehouse_id) > 0, false)
    error_message = "agent_waste_monitors.warehouse_id must be the ID of an existing SQL warehouse (Compute → SQL warehouses → Connection details)."
  }

  validation {
    condition     = var.agent_waste_monitors == null || can(regex("^/", var.agent_waste_monitors.parent_path))
    error_message = "agent_waste_monitors.parent_path must be an absolute workspace path, e.g. /Shared/llm-gateway-monitors."
  }

  validation {
    condition     = var.agent_waste_monitors == null || try(length(split(" ", var.agent_waste_monitors.schedule_cron)) >= 6, false)
    error_message = "agent_waste_monitors.schedule_cron must be a Quartz cron expression with 6 or 7 fields, e.g. '0 0 * * * ?' (hourly)."
  }

  validation {
    condition     = var.agent_waste_monitors == null || try(alltrue([for v in [var.agent_waste_monitors.error_loop_failed_calls, var.agent_waste_monitors.error_rate_min_calls, var.agent_waste_monitors.blocked_model_attempts, var.agent_waste_monitors.tool_error_turns_per_session] : v >= 1]) && var.agent_waste_monitors.error_rate_pct > 0 && var.agent_waste_monitors.error_rate_pct <= 100, false)
    error_message = "agent_waste_monitors thresholds must be >= 1 (counts) and error_rate_pct must be within (0, 100]."
  }
}
