# module: workspace-stack

Composite module that provisions one complete Databricks workspace environment — networking, workspace, Unity Catalog, and (optionally) AI Gateway model serving — from a single `module` block.

This project is a **PoC/design for Databricks AI Gateway and Model Serving**, demonstrating how to front Azure AI Foundry-hosted models (GPT-4o, etc.) and Databricks Foundation Models through a single governed gateway, with Unity Catalog as the data/governance layer and Terraform as the repeatable deployment mechanism.

---

## What the module composes

In dependency order (`main.tf`):

1. **Resource group** — `azurerm_resource_group.this`, plus an optional Contributor role assignment for `contributor_group_object_id`.
2. **`module.networking`** — VNet-injection network: VNet, delegated public/private subnets, NSG associations.
3. **`module.workspace`** (`modules/databricks-workspace`) — the workspace itself plus its Unity Catalog Access Connector.
4. **Deployment-SP admin grant** — `data.databricks_service_principal.deployment_sp` looks up `deployment_sp_client_id` in the Databricks account (registered there by `environments/account`), and `databricks_mws_permission_assignment.deployment_sp_admin` grants it `ADMIN` on the new workspace, so the same SP can manage workspace-scoped resources (secret scopes, external locations, serving endpoints) atomically with workspace creation.
5. **`module.unity_catalog`** — metastore assignment, UC storage account + storage credential + external location, catalogs/schema for inference tables, and all group grants.
6. **`module.model_serving`** — created only when `enable_model_serving = true`. External AI Gateway endpoints, the optional fallback router, endpoint ACLs, the Foundry-auth SP + secret scope, and (when `model_serving_agent_waste_monitors` is set) scheduled SQL alerts for retry loops / error rates / blocked-model attempts / tool-error loops — see `docs/agent-spend-waste.md`.
7. **`terraform_data.ai_gateway_reconciler`** — out-of-band governance for the pre-provisioned `databricks-*` foundation endpoints (see below). Created only when `enable_model_serving = true` and `ai_gateway_reconcile_on_apply = true`.

---

## Workspace strategy

This repo instantiates the module twice:

- **`environments/dbx-dev`** — the serving hub: owns the `main` catalog (`create_main_catalog = true`, `inference_table_catalog = "main"`) and hosts the AI Gateway endpoints (`enable_model_serving = true`).
- **`environments/dbx-uat`** — a consumer workspace on the same metastore: `enable_model_serving = false` (no endpoints, no reconciler, `model_serving_endpoints` output is `[]`) and `create_main_catalog = false` — catalog names are metastore-global, so `main` stays with dbx-dev and uat owns its own `uat` catalog instead.

The module also supports a fuller hub/spoke split — a catalog-owning "platform" workspace granting write access to separate team workspaces via `inference_admin_groups` / `inference_writer_groups` — see the Unity Catalog section below.

---

## AI Gateway & Model Serving design

### External endpoints (Azure AI Foundry / Anthropic)

`module.model_serving` creates one `databricks_model_serving` resource per entry, each with an inline `ai_gateway {}` block:

```
Consumer → Databricks AI Gateway endpoint
               ↓  (AI Gateway layer)
               ├── rate limiting      (per endpoint, per user, per user group)
               ├── guardrails         (input/output safety, PII behavior — when configured)
               ├── usage tracking     (token/latency rows in system tables)
               └── inference tables   (full request/response logging to UC)
               ↓
         Azure AI Foundry (GPT-4o, GPT-5-mini, …) or Anthropic API
```

The endpoint catalog defaults come from `modules/model-serving/model_defaults.yaml`; override the whole set with `model_serving_external_endpoints` or merge extras on top with `model_serving_additional_external_endpoints`. Plan-time `lifecycle` preconditions reject any endpoint whose model is not in `allowed_external_models` in that YAML.

Azure OpenAI entries authenticate via Entra ID with a dedicated SP the module creates; Anthropic entries reference a pre-existing workspace secret (`api_key_secret = "<scope>/<key>"`). In both cases the endpoint config carries only `{{secrets/<scope>/<key>}}` **references** — no plaintext credentials in state or API responses.

### Fallback routing

`model_serving_fallback_enabled = true` adds one extra endpoint, `azure-gpt-chat-fallback`, with **two served entities on the same endpoint** (gpt-4o primary at 100% traffic, gpt-5-mini fallback) and the AI Gateway's `fallback_config` retrying on 5xx. It is built this way because Databricks forbids chaining one external-model endpoint to another ("Requests to external models from Databricks model serving are not permitted").

### Pre-provisioned foundation endpoints (`databricks-*`) — the reconciler

The `databricks-` endpoint name prefix is reserved: the Terraform provider rejects CREATE and UPDATE for these endpoints, which exist automatically in every workspace. They are therefore governed **out-of-band**:

- `terraform_data.ai_gateway_reconciler` runs `scripts/apply-ai-gateway.sh --single-workspace` whenever one of its `triggers_replace` values changes (YAML hash, workspace URL, table prefix/catalog/schema) — a no-op apply does not re-run it — passing `WORKSPACE_URL`, `TABLE_PREFIX`, `TABLE_CATALOG`, `TABLE_SCHEMA`, and `YAML_PATH` as environment variables.
- The script reads `modules/model-serving/model_defaults.yaml` (the same file `module.model_serving` reads) and issues `PUT /api/2.0/serving-endpoints/{name}/ai-gateway` per endpoint:
  - `foundation_endpoints` → usage tracking, the `gateway_defaults` rate limits (and guardrails, when the YAML defines them), and inference-table logging into the workspace's catalog/schema/prefix;
  - `disabled_foundation_models` → `rate_limits: [{calls: 0}]`, so every request gets HTTP 429 immediately while usage tracking still records the attempt.
- `triggers_replace` re-runs the provisioner whenever the YAML changes (md5 hash via the `model_defaults_yaml_hash` output), the workspace URL changes, or the table prefix/catalog/schema change.
- **Failure contract**: every endpoint is attempted (one bad endpoint doesn't block the rest), but any failed PUT makes the script — and therefore `terraform apply` — exit non-zero, so governance drift is never silently swallowed.
- **Requirements**: `az`, `yq`, `jq`, and `curl` on PATH; the `az` login identity must be able to manage serving endpoints in the workspace (the deployment SP's `ADMIN` grant covers this). Set `ai_gateway_reconcile_on_apply = false` in CI environments that run governance as a separate pipeline.
- Out-of-band drift **between** applies (someone editing via the UI) is not caught — schedule the same script via a CI cron or a Databricks Job for continuous reconciliation.

There are **no per-workspace Terraform variables** for the foundation-model policy: to change the allowlist, blocklist, or default gateway policy, edit `model_defaults.yaml`.

### Blocking non-approved foundation models

Blocking is a **deny-list, and it is fail-open**: when Databricks rolls out a new pre-provisioned `databricks-*` endpoint, it is fully callable until someone adds it to `disabled_foundation_models` and an apply (or a scheduled run) re-executes the reconciler. `allowed_foundation_entities` in the same YAML is audit documentation — surfaced as a `module.model_serving` output for ops tooling — **not** an enforced allowlist. Only the external-model allowlist (`allowed_external_models`) is enforced, via plan-time preconditions on the Terraform-managed endpoints. Review the deny-list whenever Databricks announces new pay-per-token models.

---

## Endpoint access control

| Endpoint type | Mechanism |
|---|---|
| Terraform-managed external endpoints (incl. `azure-gpt-chat-fallback`) | `databricks_permissions` — `CAN_QUERY` for `consumer_groups`, `CAN_MANAGE` for `model_serving_admin_groups`. One authoritative resource per endpoint (multiple resources on the same endpoint overwrite each other). |
| Pre-provisioned `databricks-*` foundation endpoints | **No per-group ACLs from this module.** Governance is the AI Gateway rate limits (per endpoint / per user / per user group) applied by the reconciler — rate-limit-gated, not ACL-gated. |

> **`model_serving_endpoint_permissions_enabled`** — if the account has not enabled the inference endpoint ACL feature, `databricks_permissions` calls fail with `ACLs for inference-endpoint are disabled`. Set this to `false` to skip ACL management; only workspace admins can call the endpoints until the feature is enabled.

---

## Unity Catalog design

`module.unity_catalog` assigns the account metastore, creates the UC storage account (Access Connector MSI gets **Storage Blob Data Contributor** only), a storage credential, an optional external location, and the catalogs/schema for inference tables. All UC objects are owned by `uc_owner_group`.

Group grants (all groups are account-level, `ad-dbx*` — enforced by variable validations):

- `workspace_groups` — workspace `USER`, `CREATE_CATALOG` on the metastore, and a scoped write set on the catalogs (`USE_CATALOG`/`CREATE_SCHEMA`/`SELECT`/`MODIFY`/`CREATE_TABLE`/… — `MANAGE` and `APPLY_TAG` stay with the owner group).
- `consumer_groups` — workspace `USER` plus `CAN_QUERY` on the serving endpoints (above); no UC write access.
- `reader_groups` — workspace `USER` plus read-only catalog access (`USE_CATALOG`, `USE_SCHEMA`, `SELECT`, `EXECUTE`, `READ_VOLUME`).

Inference tables land in `inference_table_catalog`.`inference_table_schema`, table names prefixed by `inference_table_prefix` (default: `team`). When the catalog is not `main`, the module creates it (override with `create_inference_catalog`). For a hub/spoke split, the catalog-owning workspace sets `inference_admin_groups` (`ALL_PRIVILEGES`, admin-only read) and `inference_writer_groups` (`USE_CATALOG` + schema-level `USE_SCHEMA`/`MODIFY`/`CREATE_TABLE`, **no read**) so other workspaces' serving SPs can write their logs here.

---

## Usage

**Serving hub owning its own catalog + AI Gateway endpoints** (this repo's `environments/dbx-dev`):

```hcl
module "stack" {
  source = "../../modules/workspace-stack"

  team        = "dbx-dev"
  environment = "dev"
  location    = var.location

  resource_group_name = var.resource_group_name
  workspace_name      = var.workspace_name
  vnet_cidr           = var.vnet_cidr
  metastore_id        = var.metastore_id

  # Deployment SP (registered in the account by environments/account) —
  # granted ADMIN on this workspace at creation time.
  deployment_sp_client_id = var.deployment_sp_client_id

  # Owns the `main` catalog directly — inference tables land here.
  inference_table_catalog = "main"
  inference_table_schema  = "model_serving_logs"
  create_main_catalog     = true

  # Azure AI Foundry backing the external endpoints
  ai_foundry_name           = var.ai_foundry_name
  ai_foundry_resource_group = var.ai_foundry_resource_group

  model_serving_rate_limits = [{
    calls          = 100
    renewal_period = "minute"
    key            = "user"
  }]

  model_serving_guardrails = {
    input  = { safety = true, pii_behavior = "BLOCK" }
    output = { safety = true }
  }

  workspace_groups           = ["ad-dbx"]
  model_serving_admin_groups = ["ad-dbx"]

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}
```

For a consumer workspace (this repo's `environments/dbx-uat`), additionally set `enable_model_serving = false` and `create_main_catalog = false`, and point `inference_table_catalog` at a workspace-local catalog name.

---

## Provider requirements

Both Databricks provider aliases must be passed explicitly (`configuration_aliases` in `main.tf`). `azurerm` is inherited automatically. The module declares version **floors** (`>= x, < next-major`); the environment roots own the tighter `~>` pins.

| Alias | Purpose |
|---|---|
| `databricks` (default) | Workspace-scoped: catalogs, schemas, grants, secret scope, model serving endpoints. |
| `databricks.accounts` | Account-scoped: deployment-SP lookup, workspace permission assignments, metastore assignment, group lookups. |

See [docs/architecture.md](../../docs/architecture.md) for how each environment wires these.

---

## Notes

- **Secrets** — never inline API keys. Endpoint configs carry only `{{secrets/<scope>/<key>}}` references: `module.model_serving` creates a `<workspace_name>-model-serving-scope` scope for the Foundry SP credential, and Anthropic entries reference a pre-existing workspace secret via `api_key_secret`.
- **Inference tables** — enabled on every Terraform-managed endpoint *and* (via the reconciler) on every governed `databricks-*` foundation endpoint. Table name prefix: `<inference_table_prefix>_<endpoint table_prefix>`. Once a prefix is set and the UC table exists, changing it requires dropping the table first.
- **UC grants** — always use group principals, not user principals; `workspace_groups`, `consumer_groups`, `reader_groups`, and `model_serving_admin_groups` validate for account-level `ad-dbx*` display names.
- **Model governance** — `modules/model-serving/model_defaults.yaml` is the single source of truth: external-model allowlist (plan-time enforced), foundation-endpoint governance and deny-list (reconciler-enforced, fail-open for new endpoints), and default gateway policy. No governance lists live in tfvars or per-workspace variables.

Interface tables below are generated by
[terraform-docs](https://terraform-docs.io) (`pre-commit run terraform_docs`).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9, < 2.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.0, < 5.0 |
| <a name="requirement_databricks"></a> [databricks](#requirement\_databricks) | >= 1.126.0, < 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.0, < 5.0 |
| <a name="provider_databricks.accounts"></a> [databricks.accounts](#provider\_databricks.accounts) | >= 1.126.0, < 2.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_model_serving"></a> [model\_serving](#module\_model\_serving) | ../model-serving | n/a |
| <a name="module_networking"></a> [networking](#module\_networking) | ../networking | n/a |
| <a name="module_unity_catalog"></a> [unity\_catalog](#module\_unity\_catalog) | ../unity-catalog | n/a |
| <a name="module_workspace"></a> [workspace](#module\_workspace) | ../databricks-workspace | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_resource_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [databricks_mws_permission_assignment.deployment_sp_admin](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/mws_permission_assignment) | resource |
| [terraform_data.ai_gateway_reconciler](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [databricks_service_principal.deployment_sp](https://registry.terraform.io/providers/databricks/databricks/latest/docs/data-sources/service_principal) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ai_foundry_name"></a> [ai\_foundry\_name](#input\_ai\_foundry\_name) | Name of the Azure AI Foundry (Cognitive Services) account serving external models. | `string` | `null` | no |
| <a name="input_ai_foundry_resource_group"></a> [ai\_foundry\_resource\_group](#input\_ai\_foundry\_resource\_group) | Resource group containing the Azure AI Foundry account. | `string` | `null` | no |
| <a name="input_ai_gateway_reconcile_on_apply"></a> [ai\_gateway\_reconcile\_on\_apply](#input\_ai\_gateway\_reconcile\_on\_apply) | Run scripts/apply-ai-gateway.sh in single-workspace mode during `terraform apply` whenever its triggers change (YAML hash, workspace URL, table settings) to re-assert rate limits + inference tables on pre-provisioned `databricks-*` endpoints. Requires `az`, `yq`, `jq`, and `curl` on PATH. Set false in CI environments that bake governance into a separate pipeline. | `bool` | `true` | no |
| <a name="input_consumer_groups"></a> [consumer\_groups](#input\_consumer\_groups) | Account-level groups granted (a) workspace USER access on this workspace and (b) CAN\_QUERY on every Terraform-managed model serving endpoint. Use in an LLM hub to grant access to consumer teams. Pre-provisioned databricks-* foundation endpoints are governed by gateway rate limits, not per-group ACLs. | `list(string)` | `[]` | no |
| <a name="input_contributor_group_object_id"></a> [contributor\_group\_object\_id](#input\_contributor\_group\_object\_id) | Object ID of the Azure AD security group to grant Contributor on the resource group. | `string` | `null` | no |
| <a name="input_create_external_location"></a> [create\_external\_location](#input\_create\_external\_location) | Create the external location backing catalog storage. Disable when it is managed elsewhere. | `bool` | `true` | no |
| <a name="input_create_inference_catalog"></a> [create\_inference\_catalog](#input\_create\_inference\_catalog) | Override for whether this workspace creates the inference catalog. Null = auto (create when inference\_table\_catalog != 'main'). Set to false in workload workspaces that share a centralized catalog owned by the 'platform' env. | `bool` | `null` | no |
| <a name="input_create_main_catalog"></a> [create\_main\_catalog](#input\_create\_main\_catalog) | Whether to create the 'main' Unity Catalog catalog. Set false for spoke workspaces sharing the hub's main catalog. | `bool` | `true` | no |
| <a name="input_deployment_sp_client_id"></a> [deployment\_sp\_client\_id](#input\_deployment\_sp\_client\_id) | Azure client ID (application ID) of the deployment service principal (sp-terraform-databricks). Looked up via the accounts provider and granted ADMIN on this workspace at creation time. | `string` | n/a | yes |
| <a name="input_enable_model_serving"></a> [enable\_model\_serving](#input\_enable\_model\_serving) | Whether this workspace owns model serving endpoints. Set to false for consumer workspaces that call a shared LLM hub. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (dev, staging, prod). Used in tagging. | `string` | n/a | yes |
| <a name="input_inference_admin_groups"></a> [inference\_admin\_groups](#input\_inference\_admin\_groups) | Account-level groups granted ALL\_PRIVILEGES on the centralized inference catalog/schema. Only set this on the platform/catalog-owner workspace — governs admin read access. | `list(string)` | `[]` | no |
| <a name="input_inference_table_catalog"></a> [inference\_table\_catalog](#input\_inference\_table\_catalog) | Unity Catalog catalog receiving model-serving inference tables. | `string` | `"main"` | no |
| <a name="input_inference_table_prefix"></a> [inference\_table\_prefix](#input\_inference\_table\_prefix) | Per-workspace prefix prepended to every inference table name (e.g. 'team\_a'). Null = use the `team` variable. Enables per-workspace/per-app cost allocation when several workspaces share one centralized inference catalog. | `string` | `null` | no |
| <a name="input_inference_table_schema"></a> [inference\_table\_schema](#input\_inference\_table\_schema) | Unity Catalog schema receiving model-serving inference tables. | `string` | `"model_serving_logs"` | no |
| <a name="input_inference_writer_groups"></a> [inference\_writer\_groups](#input\_inference\_writer\_groups) | Account-level groups granted USE\_CATALOG + USE\_SCHEMA/MODIFY/CREATE\_TABLE on the inference catalog so OTHER workspaces' model serving SPs (which are members of these groups) can write inference tables here. Read access is NOT granted. | `list(string)` | `[]` | no |
| <a name="input_infrastructure_encryption_enabled"></a> [infrastructure\_encryption\_enabled](#input\_infrastructure\_encryption\_enabled) | Enable a second layer of encryption on the DBFS root storage. | `bool` | `true` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for all resources. | `string` | n/a | yes |
| <a name="input_managed_resource_group_name"></a> [managed\_resource\_group\_name](#input\_managed\_resource\_group\_name) | Override for the Databricks-managed resource group name. Null = provider default. | `string` | `null` | no |
| <a name="input_metastore_id"></a> [metastore\_id](#input\_metastore\_id) | Unity Catalog metastore UUID from environments/account (terraform output metastore\_id). | `string` | n/a | yes |
| <a name="input_model_serving_additional_external_endpoints"></a> [model\_serving\_additional\_external\_endpoints](#input\_model\_serving\_additional\_external\_endpoints) | Extra external endpoints merged on top of the active set. Use to add a model without replacing defaults. provider defaults to openai (Azure AI Foundry); anthropic entries require api\_key\_secret ('<scope>/<key>'). | <pre>map(object({<br/>    model           = string<br/>    deployment_name = optional(string)<br/>    task            = string<br/>    table_prefix    = string<br/>    provider        = optional(string, "openai")<br/>    api_key_secret  = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_model_serving_admin_groups"></a> [model\_serving\_admin\_groups](#input\_model\_serving\_admin\_groups) | Account-level groups granted CAN\_MANAGE on every model serving endpoint. Locks down endpoint creation/update/delete. | `list(string)` | `[]` | no |
| <a name="input_model_serving_agent_waste_monitors"></a> [model\_serving\_agent\_waste\_monitors](#input\_model\_serving\_agent\_waste\_monitors) | Opt-in scheduled SQL alerts for silent agent waste (retry loops, error rates, blocked-model hammering, tool-error loops) on this workspace's endpoints — see docs/agent-spend-waste.md. Null = none. Requires a SQL warehouse ID and at least one recipient; the workspace ID used to scope the queries is filled in automatically. | <pre>object({<br/>    warehouse_id                 = string<br/>    notify_emails                = list(string)<br/>    parent_path                  = optional(string, "/Shared/llm-gateway-monitors")<br/>    schedule_cron                = optional(string, "0 0 * * * ?")<br/>    timezone_id                  = optional(string, "UTC")<br/>    error_loop_failed_calls      = optional(number, 10)<br/>    error_rate_pct               = optional(number, 20)<br/>    error_rate_min_calls         = optional(number, 20)<br/>    blocked_model_attempts       = optional(number, 25)<br/>    payload_alerts_enabled       = optional(bool, false)<br/>    tool_error_turns_per_session = optional(number, 3)<br/>    tool_error_pattern           = optional(string, "(?i)(error|exception|traceback|invalid|not found)")<br/>  })</pre> | `null` | no |
| <a name="input_model_serving_budget_policy_id"></a> [model\_serving\_budget\_policy\_id](#input\_model\_serving\_budget\_policy\_id) | Databricks budget policy (serverless usage policy) ID attached to every model serving endpoint for cost attribution. From: cd environments/account && terraform output budget\_policy\_ids. Null = no policy. | `string` | `null` | no |
| <a name="input_model_serving_endpoint_permissions_enabled"></a> [model\_serving\_endpoint\_permissions\_enabled](#input\_model\_serving\_endpoint\_permissions\_enabled) | Manage endpoint-level ACLs. Set false on workspaces where the inference-endpoint ACL feature is not enabled by the account admin. | `bool` | `true` | no |
| <a name="input_model_serving_external_endpoints"></a> [model\_serving\_external\_endpoints](#input\_model\_serving\_external\_endpoints) | Full override of the external endpoint catalog. Null = load defaults from model\_defaults.yaml. | <pre>map(object({<br/>    model           = string<br/>    deployment_name = optional(string)<br/>    task            = string<br/>    table_prefix    = string<br/>    provider        = optional(string, "openai")<br/>    api_key_secret  = optional(string)<br/>  }))</pre> | `null` | no |
| <a name="input_model_serving_fallback_enabled"></a> [model\_serving\_fallback\_enabled](#input\_model\_serving\_fallback\_enabled) | Enable the AI-gateway fallback endpoint (azure-gpt-chat-fallback). | `bool` | `false` | no |
| <a name="input_model_serving_guardrails"></a> [model\_serving\_guardrails](#input\_model\_serving\_guardrails) | AI Gateway guardrails (input/output safety + PII behavior) applied to every endpoint. | <pre>object({<br/>    input = optional(object({<br/>      safety       = optional(bool, false)<br/>      pii_behavior = optional(string)<br/>    }))<br/>    output = optional(object({<br/>      safety       = optional(bool, false)<br/>      pii_behavior = optional(string)<br/>    }))<br/>  })</pre> | `null` | no |
| <a name="input_model_serving_rate_limits"></a> [model\_serving\_rate\_limits](#input\_model\_serving\_rate\_limits) | AI Gateway rate limit rules applied to every endpoint. Empty = use gateway\_defaults from model\_defaults.yaml. | <pre>list(object({<br/>    calls          = number<br/>    key            = optional(string, "endpoint")<br/>    renewal_period = optional(string, "minute")<br/>    tokens         = optional(number)<br/>    principal      = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_no_public_ip"></a> [no\_public\_ip](#input\_no\_public\_ip) | Enable Secure Cluster Connectivity (no public IPs on cluster nodes). | `bool` | `true` | no |
| <a name="input_openai_api_version"></a> [openai\_api\_version](#input\_openai\_api\_version) | Azure OpenAI API version targeted by external model endpoints. | `string` | `"2024-12-01-preview"` | no |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Allow access to the workspace UI/API from public networks. | `bool` | `true` | no |
| <a name="input_reader_groups"></a> [reader\_groups](#input\_reader\_groups) | Account-level groups granted workspace USER + read-only catalog access (SELECT). For BI tools. | `list(string)` | `[]` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group that will hold all Databricks resources. | `string` | n/a | yes |
| <a name="input_sku"></a> [sku](#input\_sku) | Databricks workspace SKU (standard, premium, or trial). Premium is required for endpoint ACLs. | `string` | `"premium"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Azure resource tags applied to every taggable resource. | `map(string)` | `{}` | no |
| <a name="input_team"></a> [team](#input\_team) | Team identifier (e.g. 'team-a'). Used in tagging and for deriving the AD group name. | `string` | n/a | yes |
| <a name="input_uc_owner_group"></a> [uc\_owner\_group](#input\_uc\_owner\_group) | Display name of the Databricks account-level group to set as owner on all Unity Catalog objects. Defaults to ad-dbx. | `string` | `"ad-dbx"` | no |
| <a name="input_uc_storage_account_name"></a> [uc\_storage\_account\_name](#input\_uc\_storage\_account\_name) | Storage account name for the UC ADLS Gen2 account (globally unique, 3-24 lowercase alphanumeric). Null = derived from workspace\_name. | `string` | `null` | no |
| <a name="input_vnet_cidr"></a> [vnet\_cidr](#input\_vnet\_cidr) | Address space for the VNet-injection network (public and private subnets are carved from it). | `string` | n/a | yes |
| <a name="input_workspace_groups"></a> [workspace\_groups](#input\_workspace\_groups) | Account-level groups granted workspace USER + scoped UC write privileges on catalogs (USE/CREATE/SELECT/MODIFY etc. — MANAGE and APPLY\_TAG stay with the owner group). For owners/operators of this workspace. | `list(string)` | `[]` | no |
| <a name="input_workspace_name"></a> [workspace\_name](#input\_workspace\_name) | Azure Databricks workspace name. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_access_connector_id"></a> [access\_connector\_id](#output\_access\_connector\_id) | Azure resource ID of the Access Connector used by Unity Catalog. |
| <a name="output_agent_waste_alert_names"></a> [agent\_waste\_alert\_names](#output\_agent\_waste\_alert\_names) | Display names of the scheduled agent-waste SQL alerts (empty when serving or monitors are disabled). See docs/agent-spend-waste.md. |
| <a name="output_inference_catalog_name"></a> [inference\_catalog\_name](#output\_inference\_catalog\_name) | Catalog receiving inference tables (null when this workspace does not own one). |
| <a name="output_metastore_id"></a> [metastore\_id](#output\_metastore\_id) | Unity Catalog metastore ID assigned to this workspace. |
| <a name="output_model_serving_endpoints"></a> [model\_serving\_endpoints](#output\_model\_serving\_endpoints) | Names of the Terraform-managed model serving endpoints (empty when serving is disabled). |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the resource group holding all workspace resources. |
| <a name="output_uc_storage_account_name"></a> [uc\_storage\_account\_name](#output\_uc\_storage\_account\_name) | Name of the Unity Catalog ADLS Gen2 storage account. |
| <a name="output_workspace_id"></a> [workspace\_id](#output\_workspace\_id) | Azure resource ID of the Databricks workspace. |
| <a name="output_workspace_resource_id"></a> [workspace\_resource\_id](#output\_workspace\_resource\_id) | Numeric Databricks workspace ID (used by the accounts API and the account env's workspace\_ids map). |
| <a name="output_workspace_url"></a> [workspace\_url](#output\_workspace\_url) | Databricks workspace URL (https://adb-....azuredatabricks.net). |
<!-- END_TF_DOCS -->
