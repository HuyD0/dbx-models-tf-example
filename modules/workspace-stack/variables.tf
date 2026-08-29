variable "team" {
  description = "Team identifier (e.g. 'team-a'). Used in tagging and for deriving the AD group name."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used in tagging."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group that will hold all Databricks resources."
  type        = string
}

variable "workspace_name" {
  description = "Azure Databricks workspace name."
  type        = string
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

variable "metastore_id" {
  description = "Unity Catalog metastore UUID from environments/account (terraform output metastore_id)."
  type        = string
}

variable "uc_storage_account_name" {
  description = "Storage account name for the UC ADLS Gen2 account (globally unique, 3-24 lowercase alphanumeric). Null = derived from workspace_name."
  type        = string
  default     = null
  nullable    = true
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

variable "create_external_location" {
  description = "Create the external location backing catalog storage. Disable when it is managed elsewhere."
  type        = bool
  default     = true
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
  description = "Account-level groups granted workspace USER + scoped UC write privileges on catalogs (USE/CREATE/SELECT/MODIFY etc. — MANAGE and APPLY_TAG stay with the owner group). For owners/operators of this workspace."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.workspace_groups : can(regex("^ad-dbx", g))])
    error_message = "All workspace_groups must be Databricks account-level group display names starting with 'ad-dbx'."
  }
}

variable "consumer_groups" {
  description = "Account-level groups granted (a) workspace USER access on this workspace and (b) CAN_QUERY on every Terraform-managed model serving endpoint. Use in an LLM hub to grant access to consumer teams. Pre-provisioned databricks-* foundation endpoints are governed by gateway rate limits, not per-group ACLs."
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
  description = "Name of the Azure AI Foundry (Cognitive Services) account serving external models."
  type        = string
  default     = null
  nullable    = true
}

variable "ai_foundry_resource_group" {
  description = "Resource group containing the Azure AI Foundry account."
  type        = string
  default     = null
  nullable    = true
}

variable "enable_model_serving" {
  description = "Whether this workspace owns model serving endpoints. Set to false for consumer workspaces that call a shared LLM hub."
  type        = bool
  default     = true
}

variable "openai_api_version" {
  description = "Azure OpenAI API version targeted by external model endpoints."
  type        = string
  default     = "2024-12-01-preview"
}

variable "model_serving_fallback_enabled" {
  description = "Enable the AI-gateway fallback endpoint (azure-gpt-chat-fallback)."
  type        = bool
  default     = false
}

variable "model_serving_endpoint_permissions_enabled" {
  description = "Manage endpoint-level ACLs. Set false on workspaces where the inference-endpoint ACL feature is not enabled by the account admin."
  type        = bool
  default     = true
}

variable "model_serving_rate_limits" {
  description = "AI Gateway rate limit rules applied to every endpoint. Empty = use gateway_defaults from model_defaults.yaml."
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
  description = "Full override of the external endpoint catalog. Null = load defaults from model_defaults.yaml."
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
  description = "Extra external endpoints merged on top of the active set. Use to add a model without replacing defaults. provider defaults to openai (Azure AI Foundry); anthropic entries require api_key_secret ('<scope>/<key>')."
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
  description = "Databricks budget policy (serverless usage policy) ID attached to every model serving endpoint for cost attribution. From: cd environments/account && terraform output budget_policy_ids. Null = no policy."
  type        = string
  default     = null
  nullable    = true
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
  description = "Run scripts/apply-ai-gateway.sh in single-workspace mode during `terraform apply` whenever its triggers change (YAML hash, workspace URL, table settings) to re-assert rate limits + inference tables on pre-provisioned `databricks-*` endpoints. Requires `az`, `yq`, `jq`, and `curl` on PATH. Set false in CI environments that bake governance into a separate pipeline."
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
