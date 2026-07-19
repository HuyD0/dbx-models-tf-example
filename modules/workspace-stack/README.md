# module: workspace-stack

Composite module that provisions one complete Databricks workspace environment — workspace, Unity Catalog, and AI Gateway model serving endpoints — from a single `module` block.

This project is a **PoC/design for Databricks AI Gateway and Model Serving**, demonstrating how to front Azure AI Foundry-hosted models (GPT-4o, etc.) and Databricks Foundation Models through a single governed gateway, with Unity Catalog as the data/governance layer and Terraform as the repeatable deployment mechanism.

---

## Workspace strategy

This repo deploys a single workspace, `environments/dbx-dev`, that owns both
roles the module supports: it creates the `main` Unity Catalog catalog
(`create_main_catalog = true`) and hosts AI Gateway model serving endpoints
directly (`enable_model_serving = true`, the module default).

The module also supports splitting these roles across multiple workspaces —
e.g. a catalog-owning "platform" workspace (`enable_model_serving = false`,
`create_main_catalog = false`, `create_inference_catalog = true`) plus one or
more "team" workspaces that write inference rows into the platform's shared
catalog via `inference_writer_groups` — for deployments that need per-team
workspace isolation. This repo doesn't use that split; see
`inference_admin_groups` / `inference_writer_groups` below if you need it.

---

## AI Gateway & Model Serving design

Each team workspace creates two classes of endpoint via `module.model_serving`:

### External endpoints (Azure AI Foundry)
Back GPT-class models deployed in an Azure AI Foundry project. The module retrieves the endpoint URL and API key from the Foundry resource and registers them as `databricks_model_serving` external endpoints with the AI Gateway wrapper enabled.

```
Consumer → Databricks AI Gateway endpoint
               ↓  (AI Gateway layer)
               ├── rate limiting      (per call, per token, per principal)
               ├── guardrails         (input/output safety, PII redaction)
               ├── usage tracking     (writes token/latency rows)
               └── inference tables   (full request/response logging to UC)
               ↓
         Azure AI Foundry (GPT-4o, GPT-5-mini, …)
```

Defined via `model_serving_external_endpoints` (full override) or `model_serving_additional_external_endpoints` (merge on top of module defaults without replacing them).

### Foundation model endpoints (Databricks)
Wrap `system.ai.*` entities with rate limits applied at the workspace level. Controlled via `model_serving_foundation_endpoints` / `model_serving_additional_foundation_endpoints`.

**Important limitations vs external endpoints:**
- `ai_gateway { }` block is **not supported** — rate limits are applied as top-level `rate_limits { }` on the resource instead
- `inference_table_config` is **not supported** — use `system.serving.endpoint_usage` system tables for usage data
- Guardrails are **not supported** at the endpoint level

Access is granted via `databricks_grant` with `EXECUTE` privilege on the `system.ai.*` entity (not `databricks_permissions` like external endpoints).

### Foundation model blocklist
The `model_serving_disabled_foundation_models` variable documents which models are not approved, but **does not create Terraform-managed block resources** — Databricks reserves the `databricks-` name prefix, preventing shadow endpoint creation. To enforce a model allowlist:
1. Wrap only the approved models as named endpoints via `model_serving_foundation_endpoints` (already done by module defaults)
2. Restrict `EXECUTE` grants to those named entities only via `consumer_groups`
3. Optionally disable Foundation Model APIs entirely at the workspace level via admin settings

### Fallback routing
When `model_serving_fallback_enabled = true`, the AI Gateway will route to a secondary endpoint if the primary is unavailable or over rate limit. Useful for cross-region or foundation-model fallback.

---

## Endpoint access control

The module uses **two different permission mechanisms** depending on endpoint type:

| Endpoint type | Resource | Permission |
|---|---|---|
| External (Azure AI Foundry) | `databricks_permissions` | `CAN_QUERY` (consumers), `CAN_MANAGE` (admins) |
| Fallback router (`azure-gpt-chat-fallback`) | `databricks_permissions` | Same as external |
| Foundation model (`system.ai.*`) | `databricks_grant` | `EXECUTE` (consumers), `ALL_PRIVILEGES` (admins) |

Both are driven by the same `consumer_groups` and `model_serving_admin_groups` variables — the module resolves the appropriate resource type internally.

> **`endpoint_permissions_enabled`** — if the Databricks account has not enabled the inference endpoint ACL feature, `databricks_permissions` calls will fail with `ACLs for inference-endpoint are disabled`. Set `model_serving_endpoint_permissions_enabled = false` to skip ACL management; only workspace admins will be able to call the endpoints until the feature is enabled.

---

## Unity Catalog design

### Inference catalog ownership
`environments/dbx-dev` owns the `main` catalog directly (`create_main_catalog = true`, `inference_table_catalog = "main"`). Its model serving endpoints write inference tables into `main.model_serving_logs.<prefix>_<model>` — no separate catalog or cross-workspace writer grants are needed since there's only one workspace.

```
dbx-dev workspace
  └── Unity Catalog: main (owned here)
        └── schema: model_serving_logs
              ├── dbx_dev_gpt4o_payload
              └── dbx_dev_llama3_payload
```

The `inference_writer_groups` / `inference_admin_groups` variables exist for the multi-workspace split described above (a catalog-owning "platform" workspace granting write access to separate "team" workspaces) — this repo's single workspace doesn't need them.

---

## Usage

**Single workspace owning its own catalog + AI Gateway endpoints** (this repo's `environments/dbx-dev`):

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

  # Owns the `main` catalog directly — no separate platform workspace
  inference_table_catalog = "main"
  inference_table_schema  = "model_serving_logs"
  create_main_catalog     = true

  # Azure AI Foundry backed endpoints
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

---

## Inputs

### Identity

| Variable | Type | Default | Description |
|---|---|---|---|
| `team` | `string` | — | Team identifier (e.g. `team-a`). Used in tagging and as the default inference table prefix. |
| `environment` | `string` | — | Environment name (`dev`, `prod`). |
| `resource_group_name` | `string` | — | Azure resource group to create. |
| `workspace_name` | `string` | — | Databricks workspace name. |
| `tags` | `map(string)` | `{}` | Extra Azure tags merged with `environment`, `team`, `managed_by`. |
| `contributor_group_object_id` | `string` | `null` | AAD group granted **Contributor** on the resource group. |

### Unity Catalog

| Variable | Type | Default | Description |
|---|---|---|---|
| `metastore_id` | `string` | — | ID of the account-level Unity Catalog metastore to attach. |
| `uc_storage_account_name` | `string` | `null` | Storage account for the workspace's UC external location. |
| `create_external_location` | `bool` | `true` | Whether to create a UC external location backed by the storage account. |
| `create_main_catalog` | `bool` | `true` | Set `false` for workspaces that don't own a `main` catalog (e.g. `platform`). |
| `uc_owner_group` | `string` | `"ad-dbx"` | Account-level group set as owner on all UC objects. |
| `inference_table_catalog` | `string` | `"main"` | Catalog where inference tables are written. |
| `inference_table_schema` | `string` | `"model_serving_logs"` | Schema where inference tables are written. |
| `inference_table_prefix` | `string` | `null` | Per-workspace prefix for inference table names. Defaults to `team`. |
| `create_inference_catalog` | `bool` | `null` | Override auto-detection. Null = create when `inference_table_catalog` ≠ `"main"`. |
| `inference_admin_groups` | `list(string)` | `[]` | Groups granted `ALL_PRIVILEGES` on the inference catalog. Set on the catalog-owner workspace only. |
| `inference_writer_groups` | `list(string)` | `[]` | Groups granted write access so other workspaces' model serving can write here. |

### Access groups

| Variable | Type | Default | Description |
|---|---|---|---|
| `workspace_groups` | `list(string)` | `[]` | Groups granted workspace `USER` + `ALL_PRIVILEGES` on catalogs (owners/operators). |
| `consumer_groups` | `list(string)` | `[]` | Groups granted workspace `USER` + `CAN_QUERY` on endpoints + `EXECUTE` on foundation models. |
| `reader_groups` | `list(string)` | `[]` | Groups granted workspace `USER` + read-only catalog access (`SELECT`). |

### Model serving / AI Gateway

| Variable | Type | Default | Description |
|---|---|---|---|
| `enable_model_serving` | `bool` | `true` | Set `false` for consumer workspaces that call the shared hub. |
| `ai_foundry_name` | `string` | `null` | Azure AI Foundry resource name (required when serving external models). |
| `ai_foundry_resource_group` | `string` | `null` | Resource group of the AI Foundry resource. |
| `openai_api_version` | `string` | `"2024-12-01-preview"` | Azure OpenAI API version passed to external endpoints. |
| `model_serving_external_endpoints` | `map(object)` | `null` | External model endpoints backed by Azure AI Foundry. Each entry: `model`, `deployment_name`, `task`, `table_prefix`. |
| `model_serving_foundation_models_enabled` | `bool` | `true` | Enable Databricks-hosted foundation model endpoints. |
| `model_serving_foundation_endpoints` | `map(object)` | `null` | Override foundation model endpoint definitions (`entity_name`, `entity_version`). |
| `model_serving_fallback_enabled` | `bool` | `false` | Enable fallback routing across endpoints. |
| `model_serving_rate_limits` | `list(object)` | `[]` | Per-endpoint rate limits. Each entry: `calls`, `key`, `renewal_period`, `tokens`, `principal`. |
| `model_serving_admin_groups` | `list(string)` | `[]` | Groups granted `CAN_MANAGE` on every external endpoint + `ALL_PRIVILEGES` on foundation entities. |
| `model_serving_guardrails` | `object` | `null` | AI Gateway input/output guardrails (`safety`, `pii_behavior`). Applied to external endpoints only — not supported for foundation endpoints. |
| `model_serving_disabled_foundation_models` | `list(string)` | `null` | Documents the approved-model blocklist. No Terraform resources are created from this list — access is enforced via named endpoints + `EXECUTE` grants only. |
| `model_serving_additional_external_endpoints` | `map(object)` | `{}` | Extra external (Azure OpenAI) endpoints merged on top of the active set. Use to add a model without replacing defaults. Each entry: `model`, `deployment_name`, `task`, `table_prefix`. |
| `model_serving_additional_foundation_endpoints` | `map(object)` | `{}` | Extra foundation model endpoints merged on top of the active set. Use to add a model without replacing defaults. Each entry: `entity_name`, `entity_version`. |
| `model_serving_endpoint_permissions_enabled` | `bool` | `true` | Set `false` if the account has not enabled the inference endpoint ACL feature. Disables `databricks_permissions` resources to avoid plan failures. |

---

## Outputs

| Output | Description |
|---|---|
| `workspace_id` | Databricks workspace numeric ID. |
| `workspace_url` | Workspace URL (`https://<host>.azuredatabricks.net`). |
| `workspace_resource_id` | Azure resource ID of the workspace. |
| `resource_group_name` | Name of the created resource group. |
| `access_connector_id` | Resource ID of the Databricks Access Connector (used for UC external locations). |
| `uc_storage_account_name` | Storage account backing the UC external location. |
| `metastore_id` | ID of the attached metastore. |
| `inference_catalog_name` | Resolved catalog name for inference tables. |
| `model_serving_endpoints` | List of model serving endpoint names (`[]` when `enable_model_serving = false`). |

---

## Provider requirements

Both Databricks provider aliases must be passed explicitly. `azurerm` is inherited automatically.

| Alias | Purpose |
|---|---|
| `databricks` (default) | Workspace-scoped: catalogs, schemas, grants, model serving endpoints. |
| `databricks.accounts` | Account-scoped: metastore assignment, group entitlements. |

See [docs/architecture.md](../../docs/architecture.md) for how each environment wires these.

---

## Notes

- **Secrets** — never inline API keys. Reference Foundry keys via `{{secrets/<scope>/<key>}}` in endpoint configs; scopes are managed outside this module via Azure Key Vault + Databricks secret scope.
- **Inference tables** — `module.model_serving` enables `inference_table_config` on external endpoints automatically. Table name: `<catalog>.<schema>.<prefix>_<model>`. Foundation model endpoints do **not** support inference tables — query `system.serving.endpoint_usage` instead.
- **UC grants** — `workspace_groups` get write access, `consumer_groups` get `CAN_QUERY`/`EXECUTE` only, `reader_groups` get `SELECT` only. Always use group principals, not user principals.
- **Model blocklist** — `model_serving_disabled_foundation_models` is a documentation/planning aid. The enforced allowlist is the set of named foundation endpoints created by the module — only those get `EXECUTE` grants.
