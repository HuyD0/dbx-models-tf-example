# Architecture

This project provisions Azure Databricks workspaces sharing a single Unity
Catalog metastore. The primary workspace, `dbx-dev`, is configured as a
centralised **AI gateway** in front of both Databricks-hosted foundation
models (e.g. Claude) and Azure AI Foundry-hosted models (e.g. GPT-4o,
GPT-5-mini). All inference traffic flows through Databricks Model Serving so
that usage, prompts, and completions can be tracked in Unity Catalog
inference tables. `dbx-dev` owns the `main` catalog directly — there is no
platform/team split and no cross-workspace catalog sharing.

A second workspace, `dbx-uat`, provides a UAT tier: same metastore, its own
catalog named `uat`, and no model-serving endpoints
(`enable_model_serving = false`). Because catalog names are metastore-global,
only one workspace can own `main` — each additional workspace owns a
distinctly-named catalog of its own. The diagram below describes `dbx-dev`;
`dbx-uat` is the same stack minus the model-serving layer.

## High-level diagram

```
                ┌────────────────────────────────────────────────┐
                │              Consumers / Notebooks             │
                │     (apps, jobs, users in AD group `ad-dbx`)   │
                └───────────────────────┬────────────────────────┘
                                        │  OpenAI-compatible REST
                                        ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │              dbx-dev Databricks Workspace (Premium SKU)         │
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
   │   │  Unity Catalog — main catalog (owned directly by dbx-dev)│   │
   │   │   main catalog ─► model_serving_logs schema             │   │
   │   │     • azure_gpt4o_payload                               │   │
   │   │     • azure_gpt5mini_payload                            │   │
   │   │     • azure_embeddings_payload                          │   │
   │   │   system.serving.endpoint_usage  (foundation models)    │   │
   │   └────────────────────────────────────────────────────────┘    │
   └────────────────────────┬────────────────────────────────────────┘
                            │ ABFSS via Access Connector MSI
                            ▼
              ┌─────────────────────────────┐
              │  ADLS Gen2 (HNS, GRS, TLS) │
              │  unity-catalog container    │
              └─────────────────────────────┘

   Networking: workspace lives in an injected VNet (10.192.0.0/20) with
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
| Unity Catalog | ADLS Gen2 + metastore assignment + storage credential + external location + `main` catalog + `model_serving_logs` schema | UC governance for tables and inference logs, owned directly by dbx-dev |
| Model Serving | External endpoints + foundation endpoints + optional fallback router | Single AI gateway surface |
| Identity | `azuread_application` + SP + role assignment | Databricks → Azure OpenAI auth (SP, not MSI) |

Foundation-model governance: the workspace renders a
`databricks_model_serving.disabled_foundation_endpoints` for_each block with
`rate_limits { calls = 0 }`, so only the approved Claude models are usable.
The blocklist lives in `modules/model-serving` as
`local.default_disabled_foundation_models` and can be overridden via
`model_serving_disabled_foundation_models`.

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
- `environments/dbx-dev/` owns the dev workspace, its Unity Catalog
  assignment, and its model-serving endpoints. It consumes the metastore
  created in `account/` via `var.metastore_id`.
- `environments/dbx-uat/` owns the UAT workspace and its `uat` catalog. It
  consumes the same metastore and has no model-serving layer. It is
  independent of `dbx-dev` — neither env reads the other's state.

**Region note**: `environments/account`'s metastore is in `canadacentral`,
but both workspace envs deploy in `eastus2` — a
deliberate cross-region metastore assignment. The Azure AI Foundry accounts
backing this workspace's model-serving endpoints are in East US 2, and model
calls (frequent, latency-sensitive HTTP round-trips to Foundry) are prioritized
over metastore calls (control-plane operations, less latency-sensitive) for
same-region placement. Databricks supports attaching a workspace to a
metastore in a different region; only the metastore itself is one-per-region.

Each environment uses a separate state file key in the same backend container
— `databricks/dbx-dev/`, `databricks/dbx-uat/`, and the account key. See each
env's `providers.tf`.

## Deploy order

```
bootstrap  →  account  →  dbx-dev
                      └→  dbx-uat
```

The two workspace envs both depend on `account` but not on each other, so
they can apply in either order (or concurrently).

This order is enforced by `scripts/redeploy.sh` and asserted by
`scripts/pre-push-check.sh`.
