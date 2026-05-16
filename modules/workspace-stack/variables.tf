variable "team" {
  description = "Team identifier (e.g. 'team-a'). Used in tagging and for deriving the AD group name."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used in tagging."
  type        = string
}

variable "location" {
  type = string
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
  type = string
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

variable "metastore_id" {
  type = string
}

variable "uc_storage_account_name" {
  type     = string
  default  = null
  nullable = true
}

variable "inference_table_catalog" {
  type    = string
  default = "main"
}

variable "inference_table_schema" {
  type    = string
  default = "model_serving_logs"
}

variable "create_external_location" {
  type    = bool
  default = true
}

variable "contributor_group_object_id" {
  description = "Object ID of the Azure AD security group to grant Contributor on the resource group."
  type        = string
  default     = null
  nullable    = true
}

variable "create_main_catalog" {
  description = "Whether to create the 'main' Unity Catalog catalog. Set false for spoke workspaces sharing the hub's main catalog."
  type        = bool
  default     = true
}

variable "uc_owner_group" {
  description = "Display name of the Databricks account-level group to set as owner on all Unity Catalog objects. Defaults to ad-dbx."
  type        = string
  default     = "ad-dbx"
}

variable "workspace_groups" {
  description = "Account-level groups granted workspace USER + UC writes (ALL_PRIVILEGES on catalogs). For owners/operators of this workspace."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.workspace_groups : can(regex("^ad-dbx", g))])
    error_message = "All workspace_groups must be Databricks account-level group display names starting with 'ad-dbx'."
  }
}

variable "consumer_groups" {
  description = "Account-level groups granted (a) workspace USER access on this workspace and (b) CAN_QUERY on every model serving endpoint + EXECUTE on every foundation model. Use in an LLM hub to grant access to consumer teams."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.consumer_groups : can(regex("^ad-dbx", g))])
    error_message = "All consumer_groups must be Databricks account-level group display names starting with 'ad-dbx'."
  }
}

variable "reader_groups" {
  description = "Account-level groups granted workspace USER + read-only catalog access (SELECT). For BI tools."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.reader_groups : can(regex("^ad-dbx", g))])
    error_message = "All reader_groups must be Databricks account-level group display names starting with 'ad-dbx'."
  }
}

variable "ai_foundry_name" {
  type     = string
  default  = null
  nullable = true
}

variable "ai_foundry_resource_group" {
  type     = string
  default  = null
  nullable = true
}

variable "enable_model_serving" {
  description = "Whether this workspace owns model serving endpoints. Set to false for consumer workspaces that call a shared LLM hub."
  type        = bool
  default     = true
}

variable "openai_api_version" {
  type    = string
  default = "2024-12-01-preview"
}

variable "model_serving_fallback_enabled" {
  type    = bool
  default = false
}

variable "model_serving_endpoint_permissions_enabled" {
  description = "Manage endpoint-level ACLs. Set false on workspaces where the inference-endpoint ACL feature is not enabled by the account admin."
  type        = bool
  default     = true
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

variable "model_serving_additional_external_endpoints" {
  description = "Extra external (Azure OpenAI) endpoints merged on top of the active set. Use to add a model without replacing defaults."
  type = map(object({
    model           = string
    deployment_name = string
    task            = string
    table_prefix    = string
  }))
  default = {}
}

variable "model_serving_admin_groups" {
  description = "Account-level groups granted CAN_MANAGE on every model serving endpoint. Locks down endpoint creation/update/delete."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.model_serving_admin_groups : can(regex("^ad-dbx", g))])
    error_message = "All model_serving_admin_groups must be Databricks account-level group display names starting with 'ad-dbx'."
  }
}

variable "model_serving_guardrails" {
  description = "AI Gateway guardrails (input/output safety + PII behavior) applied to every endpoint."
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

# NOTE: governance of pre-provisioned `databricks-*` Foundation Model API
# endpoints (allowlist + blocklist) lives in modules/model-serving/model_defaults.yaml
# and is applied via scripts/apply-ai-gateway.sh. To change the policy, edit
# the YAML — there are no per-workspace Terraform variables for it.

variable "ai_gateway_reconcile_on_apply" {
  description = "Run scripts/apply-ai-gateway.sh in single-workspace mode after every `terraform apply` to re-assert rate limits + inference tables on pre-provisioned `databricks-*` endpoints. Requires `az`, `yq`, `jq`, and `curl` on PATH. Set false in CI environments that bake governance into a separate pipeline."
  type        = bool
  default     = true
}

variable "create_inference_catalog" {
  description = "Override for whether this workspace creates the inference catalog. Null = auto (create when inference_table_catalog != 'main'). Set to false in workload workspaces that share a centralized catalog owned by the 'platform' env."
  type        = bool
  default     = null
  nullable    = true
}

variable "inference_admin_groups" {
  description = "Account-level groups granted ALL_PRIVILEGES on the centralized inference catalog/schema. Only set this on the platform/catalog-owner workspace \u2014 governs admin read access."
  type        = list(string)
  default     = []
}

variable "inference_writer_groups" {
  description = "Account-level groups granted USE_CATALOG + USE_SCHEMA/MODIFY/CREATE_TABLE on the inference catalog so OTHER workspaces' model serving SPs (which are members of these groups) can write inference tables here. Read access is NOT granted."
  type        = list(string)
  default     = []
}

variable "inference_table_prefix" {
  description = "Per-workspace prefix prepended to every inference table name (e.g. 'team_a'). Null = use the `team` variable. Enables per-workspace/per-app cost allocation when several workspaces share one centralized inference catalog."
  type        = string
  default     = null
  nullable    = true
}

variable "deployment_sp_client_id" {
  description = "Azure client ID (application ID) of the deployment service principal (sp-terraform-databricks). Looked up via the accounts provider and granted ADMIN on this workspace at creation time."
  type        = string
}
