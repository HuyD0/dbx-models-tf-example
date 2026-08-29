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
                │  (apps, jobs, users in `ad-dbx-*` AD groups)   │
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
   │   │  External endpoints              Foundation endpoints  │    │
   │   │  (databricks_model_serving)      (pre-provisioned,     │    │
   │   │  ─ azure-gpt-4o                   governed out-of-band)│    │
   │   │  ─ azure-gpt-5-mini              ─ databricks-claude-  │    │
   │   │  ─ azure-gpt-5-4                   sonnet-4-6          │    │
   │   │  ─ azure-text-embedding-ada-002  ─ databricks-claude-  │    │
   │   │  ─ azure-gpt-chat-fallback         opus-4-6 / opus-4-7 │    │
   │   │    (fallback router, optional)                         │    │
   │   └────────────┬───────────────────────────┬───────────────┘    │
   │                │ AAD SP                    │ system.ai.*        │
   │                ▼                           ▼                    │
   │     ┌───────────────────┐       ┌───────────────────────┐       │
   │     │  Azure AI Foundry │       │  Databricks Foundation│       │
   │     │  (Cognitive Svcs) │       │   Model APIs (Claude) │       │
   │     └───────────────────┘       └───────────────────────┘       │
   │                                                                 │
   │   ┌────────────────────────────────────────────────────────┐    │
   │   │  Unity Catalog — main catalog (owned by dbx-dev)       │    │
   │   │   main.model_serving_logs schema:                      │    │
   │   │     • dbx_dev_<endpoint>_payload inference tables      │    │
   │   │       (external and foundation endpoints alike)        │    │
   │   │   system.serving.endpoint_usage (all endpoints)        │    │
   │   └────────────────────────────────────────────────────────┘    │
   └────────────────────────┬────────────────────────────────────────┘
                            │ ABFSS via Access Connector MSI
                            ▼
              ┌─────────────────────────────┐
              │  ADLS Gen2 (HNS, GRS, TLS)  │
              │  unity-catalog container    │
              └─────────────────────────────┘

   Networking: workspace lives in an injected VNet (10.192.0.0/20 for
   dbx-dev, 10.193.0.0/20 for dbx-uat) — two subnets delegated to
   Microsoft.Databricks/workspaces sharing one NSG, with Secure Cluster
   Connectivity (no public IP) on by default.
```

## Components

| Layer | Resource | Purpose |
|-------|----------|---------|
| Bootstrap | Storage Account + `tfstate` container; deployment SP + Key Vault | Remote Terraform state with blob versioning; SP secret kept in AKV |
| Account | `databricks_metastore`, `databricks_group`, `databricks_service_principal`, `databricks_budget` + `databricks_budget_policy` | One metastore per region; account-level groups; deployment-SP registration; cost budgets and serverless usage policies |
| Networking | VNet + 2 delegated subnets + shared NSG | VNet injection, subnet delegations to `Microsoft.Databricks/workspaces` |
| Workspace | `azurerm_databricks_workspace`, Access Connector | Premium workspace with infra encryption + MSI |
| Unity Catalog | ADLS Gen2 + metastore assignment + storage credential + external location + `main` catalog + `model_serving_logs` schema | UC governance for tables and inference logs, owned directly by dbx-dev |
| Model Serving | `databricks_model_serving` external endpoints + optional fallback router; out-of-band governance of pre-provisioned `databricks-*` endpoints | Single AI gateway surface |
| Identity | `azuread_application` + SP + role assignment + Databricks secret scope | Databricks → Azure OpenAI auth (SP, not MSI) |

Foundation-model governance: the pre-provisioned `databricks-*` Foundation
Model API endpoints cannot be managed with `databricks_model_serving` — that
name prefix is reserved by Databricks and the provider rejects CREATE and
UPDATE on it. Governance is applied **out-of-band** instead:
`terraform_data.ai_gateway_reconciler` in `modules/workspace-stack/main.tf`
invokes `scripts/apply-ai-gateway.sh` on applies where its triggers changed (YAML hash, workspace URL, table settings)
(re-triggered when the YAML hash or workspace URL changes; opt out via
`ai_gateway_reconcile_on_apply`). The script reads
`modules/model-serving/model_defaults.yaml` and PUTs
`/api/2.0/serving-endpoints/{name}/ai-gateway` per endpoint: each
`foundation_endpoints` entry gets the default rate limits plus inference
tables, and each `disabled_foundation_models` entry gets a rate limit of
0 calls/minute, so every request returns HTTP 429. Two honest caveats: the
blocklist is **fail-open** — a newly released `databricks-*` endpoint is
fully callable until someone adds it to `disabled_foundation_models` — and
`allowed_foundation_entities` in the same YAML is audit documentation
(surfaced as a module output for ops tooling), not an enforced allowlist. Plan-time allowlist enforcement exists only for
external endpoints, via a lifecycle precondition against
`allowed_external_models`.

## Why a Service Principal for Azure OpenAI

The Access Connector's managed identity is used for **storage** (ADLS Gen2),
but external model endpoints execute inside Databricks' control-plane
infrastructure — not in this Azure subscription — so a managed identity in
this subscription cannot be used to authenticate to Azure AI Foundry. A
dedicated AAD application + service principal is created (display name
`<name_prefix>-model-serving`; workspace-stack passes the workspace name as
the prefix, so `dbx-dev-model-serving` here) and granted the **Cognitive
Services OpenAI User** role on the Foundry account. Its client secret is
written to a Databricks secret scope (`<name_prefix>-model-serving-scope`)
and the endpoint config consumes it as a secret *reference* —
`{{secrets/<scope>/sp-client-secret}}` — so the plaintext value never
appears in endpoint definitions or API responses. (It does live, marked
sensitive, in Terraform state via `databricks_secret`.)

## State and environments

- `bootstrap/` provisions the remote state Storage Account (one-time).
- `environments/account/` holds account-level resources (metastore, groups,
  deployment-SP registration, budgets + budget policies).
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

Each environment uses a separate state file key in the same backend
container — `databricks/account/terraform.tfstate`,
`databricks/dbx-dev/terraform.tfstate`, and
`databricks/dbx-uat/terraform.tfstate`. See each env's `providers.tf`.

## Deploy order

```
bootstrap  →  account  →  dbx-dev
                      └→  dbx-uat
```

The two workspace envs both depend on `account` but not on each other, so
they can apply in either order (or concurrently).

`scripts/redeploy.sh` automates the `bootstrap → account → dbx-dev` leg in
that order (it does not deploy `dbx-uat`); `scripts/pre-push-check.sh` runs
`terraform plan` across `account`, `dbx-dev`, and `dbx-uat` in the same
sequence but applies nothing.
