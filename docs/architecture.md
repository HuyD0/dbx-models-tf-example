# Architecture

This project provisions a **federated** Azure Databricks AI gateway:

- Each team workspace owns its own governed model-serving endpoints
  (Azure AI Foundry external models + Databricks-hosted foundation models).
- A single, environment-scoped **`platform`** workspace owns the central
  Unity Catalog inference catalog (`llmlogs`). All team workspaces write
  inference rows there for one-stop logging, audit, and chargeback.
- Read access on `llmlogs` is **admin-only**. Team workspaces get the
  minimum grants needed to write (`USE_CATALOG`, `USE_SCHEMA`, `MODIFY`,
  `CREATE_TABLE` — never `SELECT`).
- Per-workspace cost allocation is enforced by `inference_table_prefix`,
  which prepends the team name to every inference table so rows from
  different workspaces never collide
  (`team_a_azure_gpt4o_*`, `team_b_azure_gpt4o_*`, …).

## High-level diagram

```
                ┌────────────────────────────────────────────────┐
                │              Consumers / Notebooks             │
                │   apps in team-a, team-b, … (ad-dbx-<team>)    │
                └───────────────────────┬────────────────────────┘
                                        │  OpenAI-compatible REST
                                        ▼
  ┌─────────────────────────┐    ┌─────────────────────────┐
  │  team-a workspace       │    │  team-b workspace       │
  │  (Premium, VNet 10.180) │    │  (Premium, VNet 10.181) │
  │                         │    │                         │
  │  Model Serving + AI GW  │    │  Model Serving + AI GW  │
  │  ─ azure-gpt-4o         │    │  ─ azure-gpt-4o         │
  │  ─ azure-gpt-5-mini     │    │  ─ azure-gpt-5-mini     │
  │  ─ databricks-claude…   │    │  ─ databricks-claude…   │
  │  ─ azure-gpt-chat-fallback (fb)  │    │  ─ azure-gpt-chat-fallback (fb)  │
  │                         │    │                         │
  │  disabled_foundation_   │    │  disabled_foundation_   │
  │    endpoints (rate=0)   │    │    endpoints (rate=0)   │
  └───────────┬─────────────┘    └─────────────┬───────────┘
              │ inference rows                  │ inference rows
              │ prefix: team_a_*                │ prefix: team_b_*
              └───────────────┬─────────────────┘
                              ▼
        ┌────────────────────────────────────────────────┐
        │        platform workspace (admin-only)         │
        │        Owns Unity Catalog `llmlogs`            │
        │                                                │
        │   llmlogs.model_serving_logs                   │
        │     • team_a_azure_gpt4o_payload               │
        │     • team_a_azure_gpt5mini_payload            │
        │     • team_b_azure_gpt4o_payload               │
        │     • team_b_azure_embeddings_payload          │
        │     • …                                        │
        │                                                │
        │   Admin group   : ad-dbx       ALL_PRIVILEGES  │
        │   Writer groups : ad-dbx-team-a, -team-b       │
        │                   USE_CATALOG + USE_SCHEMA +   │
        │                   MODIFY + CREATE_TABLE        │
        │                   (no SELECT — read is         │
        │                    reserved to admins)         │
        └────────────────────────────────────────────────┘
```

Per-workspace identity: each team workspace creates its own
`<workspace>-model-serving` SP (named via `var.name_prefix` in the
`model-serving` module) and grants it `Cognitive Services OpenAI User`
on the AI Foundry account. Each workspace's Access Connector MSI
authenticates to its own ADLS Gen2 container for UC.

Foundation-model governance: each workspace renders a
`databricks_model_serving.disabled_foundation_endpoints` for_each block
with `rate_limits { calls = 0 }`, so only the approved Claude 4.6/4.7
models are usable. The blocklist lives in `modules/model-serving` as
`local.default_disabled_foundation_models` and can be overridden per env
via `model_serving_disabled_foundation_models`.

Networking: every workspace lives in its own injected VNet with
public/private subnets, NSGs with Databricks delegations, and Secure
Cluster Connectivity (no public IP).

## Components

| Layer | Resource | Purpose |
|-------|----------|---------|
| Bootstrap | Storage Account + container | Remote Terraform state with blob versioning |
| Account | `databricks_metastore`, `databricks_group` | One metastore per region; account-level groups |
| Networking | VNet + 2 subnets + 2 NSGs | VNet injection, NSG delegations for Databricks |
| Workspace | `azurerm_databricks_workspace`, Access Connector | Premium workspace with infra encryption + MSI |
| Unity Catalog (platform) | ADLS Gen2 + `llmlogs` catalog + `model_serving_logs` schema + admin/writer grants | Central inference log catalog |
| Unity Catalog (team) | Metastore assignment + storage credential + external location + team catalog | Team data (no inference schema created here) |
| Model Serving (team) | External endpoints + foundation endpoints + disabled blocklist + optional fallback router | One AI gateway per workspace |
| Identity (team) | `azuread_application` + SP + role assignment | Databricks → Azure OpenAI auth (SP, not MSI) |

## Why a Service Principal for Azure OpenAI

The Access Connector's managed identity is used for **storage** (ADLS
Gen2), but external model endpoints execute inside Databricks'
control-plane infrastructure — not in this Azure subscription — so a
managed identity in this subscription cannot be used to authenticate to
Azure AI Foundry. Each team workspace creates a dedicated AAD
application + service principal (display name
`${var.name_prefix}-model-serving`, e.g. `dbw-dev-team-a-model-serving`)
and grants it the **Cognitive Services OpenAI User** role on the Foundry
account; its client secret is passed to the model-serving config via
`microsoft_entra_client_secret_plaintext`.

## State and environments

- `bootstrap/` provisions the remote state Storage Account (one-time).
- `environments/account/` holds account-level resources (metastore and
  account-level AAD groups). Apply before any workspace env.
- `environments/<env>/platform/` provisions the central `llmlogs`
  catalog and the workspace it lives in. Admin-only read; declares
  writer groups via `inference_writer_groups`. Apply before any team
  workspace in that env.
- `environments/<env>/<team>/` provisions a team workspace, its own UC
  storage, and its own model-serving endpoints. Each team sets
  `inference_table_catalog = "llmlogs"`, `create_inference_catalog = false`,
  and its `inference_table_prefix` is auto-derived from `var.team`.

Each environment uses a separate state file key in the same backend
container — see `environments/<env>/<name>/providers.tf`.

## Deploy order

```
bootstrap  →  account  →  dev/platform   →  dev/team-a,  dev/team-b  (parallel)
                       →  prod/platform  →  prod/team-a, prod/team-b (parallel)
```

This order is enforced by `scripts/redeploy.sh` and asserted by
`scripts/pre-push-check.sh` (which refuses if any workload env sets
`create_inference_catalog = true`).
# Architecture

This project provisions an Azure Databricks workspace configured as a centralised
**AI gateway** in front of both Databricks-hosted foundation models (e.g. Claude)
and Azure AI Foundry-hosted models (e.g. GPT-4o, GPT-5-mini). All inference
traffic flows through Databricks Model Serving so that usage, prompts, and
completions can be tracked in Unity Catalog inference tables.

## High-level diagram

```
                ┌────────────────────────────────────────────────┐
                │              Consumers / Notebooks             │
                │     (apps, jobs, users in AD group `ad-dbx`)   │
                └───────────────────────┬────────────────────────┘
                                        │  OpenAI-compatible REST
                                        ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │                Databricks Workspace (Premium SKU)               │
   │   ┌────────────────────────────────────────────────────────┐    │
   │   │              Model Serving + AI Gateway                │    │
   │   │  • usage_tracking_config       • rate_limits           │    │
   │   │  • inference_table_config      • fallback_config       │    │
   │   │                                                        │    │
   │   │  External endpoints                Foundation endpoints│    │
   │   │  ─ azure-gpt-4o                    ─ databricks-claude │    │
   │   │  ─ azure-gpt-5-mini                  -sonnet-4-6       │    │
   │   │  ─ azure-text-embedding-ada-002                        │    │
   │   │  ─ azure-gpt-chat-fallback (fallback router, optional)          │    │
   │   └────────────┬───────────────────────────┬───────────────┘    │
   │                │ AAD SP                    │ system.ai.*        │
   │                ▼                           ▼                    │
   │     ┌───────────────────┐       ┌───────────────────────┐       │
   │     │  Azure AI Foundry │       │  Databricks Foundation│       │
   │     │  (Cognitive Svcs) │       │   Model APIs (Claude) │       │
   │     └───────────────────┘       └───────────────────────┘       │
   │                                                                 │
   │   ┌────────────────────────────────────────────────────────┐    │
   │   │           Unity Catalog (one metastore / region)       │    │
   │   │   main catalog ─► model_serving_logs schema            │    │
   │   │     • azure_gpt4o_payload                              │    │
   │   │     • azure_gpt5mini_payload                           │    │
   │   │     • azure_embeddings_payload                         │    │
   │   │   system.serving.endpoint_usage  (foundation models)   │    │
   │   └────────────────────────────────────────────────────────┘    │
   └────────────────────────┬────────────────────────────────────────┘
                            │ ABFSS via Access Connector MSI
                            ▼
              ┌─────────────────────────────┐
              │  ADLS Gen2 (HNS, GRS, TLS) │
              │  unity-catalog container    │
              └─────────────────────────────┘

   Networking: workspace lives in an injected VNet (10.179.0.0/20) with
   public/private subnets, NSGs with Databricks delegations, optional
   Secure Cluster Connectivity (no public IP).
```

## Components

| Layer | Resource | Purpose |
|-------|----------|---------|
| Bootstrap | Storage Account + container | Remote Terraform state with blob versioning |
| Account | `databricks_metastore`, `databricks_group` | One metastore per region; account-level groups |
| Networking | VNet + 2 subnets + 2 NSGs | VNet injection, NSG delegations for Databricks |
| Workspace | `azurerm_databricks_workspace`, Access Connector | Premium workspace with infra encryption + MSI |
| Unity Catalog | ADLS Gen2 + metastore assignment + storage credential + external location + catalog + schema | UC governance for tables and inference logs |
| Model Serving | External endpoints + foundation endpoints + optional fallback router | Single AI gateway surface |
| Identity | `azuread_application` + SP + role assignment | Databricks → Azure OpenAI auth (SP, not MSI) |

## Why a Service Principal for Azure OpenAI

The Access Connector's managed identity is used for **storage** (ADLS Gen2),
but external model endpoints execute inside Databricks' control-plane
infrastructure — not in this Azure subscription — so a managed identity in
this subscription cannot be used to authenticate to Azure AI Foundry. A
dedicated AAD application + service principal is created and granted the
**Cognitive Services OpenAI User** role on the Foundry account; its client
secret is passed to the model serving config via
`microsoft_entra_client_secret_plaintext`.

## State and environments

- `bootstrap/` provisions the remote state Storage Account (one-time).
- `environments/account/` holds account-level resources (metastore, groups).
  Run before any workspace environment.
- `environments/dev/` and `environments/prod/` each own a workspace and its
  Unity Catalog assignment. They consume the metastore created in `account/`
  via `var.metastore_id`.

Each environment uses a separate state file key in the same backend container.
