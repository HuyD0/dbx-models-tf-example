# terraform-databricks

> ⚠️ **Demo project — not for production use at OTPP.**
> This repo exists to demonstrate model governance concepts (allowlists,
> inference table logging, zero-rate-limit blocking, NIST control alignment)
> on Azure Databricks. It is not intended to be deployed into OTPP environments
> as-is. Review security, networking, and compliance requirements before
> adapting any part of this for production use.

> **Note:** This repo uses the **old `databricks_model_serving` pattern** with
> `ai_gateway {}` blocks embedded inline — not the newer standalone Databricks
> AI Gateway product. Rate limits, guardrails, inference tables, and fallback
> routing are all configured via the embedded `ai_gateway {}` block inside each
> `databricks_model_serving` resource.

Terraform for an Azure Databricks workspace that centralises inference in front
of both Databricks-hosted foundation models (e.g. Claude) and Azure AI
Foundry-hosted models (e.g. GPT-4o, GPT-5-mini), using the `databricks_model_serving`
resource with inline `ai_gateway` configuration.

All inference traffic flows through these endpoints with:

- **Usage tracking** — every request is recorded in `system.serving.endpoint_usage`
- **Inference tables** — full prompt/completion payloads written to Unity Catalog (`main.model_serving_logs`)
- **Model blocking** — non-approved foundation models are disabled by setting `rate_limits { calls = 0 }`, causing the API to return HTTP 429 on every attempt
- **Rate limits** — per-endpoint and per-user call limits enforced at the gateway layer
- **Fallback routing** — optional automatic retry across a secondary model on 5xx

Together these give a single audit and control plane suitable for NIST-aligned governance of AI usage.

## Why this exists

The deployment supports three goals:

1. **Centralise inference** so every model call (Azure OpenAI, Databricks
   foundation models, future BYO models) flows through one governed
   endpoint surface.
2. **Track usage and content** for cost attribution, abuse detection, and
   offline evaluation — via Unity Catalog inference tables and
   `system.serving.endpoint_usage`.
3. **Align with NIST AI RMF and SP 800-53** by enforcing least-privilege
   identity, network isolation, audit logging, and configuration baselines
   in code — including model-level access control (zero rate limits to
   block non-approved models), mandatory usage tracking, and inference
   table logging for auditability. See
   [`docs/nist-alignment.md`](docs/nist-alignment.md) for the control
   mapping.

## Documentation

| Doc | What's in it |
|---|---|
| [`docs/model-serving.md`](docs/model-serving.md) | **Primary doc** — endpoint catalog, inline `ai_gateway` config (usage tracking, inference tables, rate limits), logging & usage SQL, fallback routing in depth, identity & secret rotation |
| [`docs/architecture.md`](docs/architecture.md) | Component diagram, request flow, why an SP is used for Azure OpenAI |
| [`docs/nist-alignment.md`](docs/nist-alignment.md) | NIST AI RMF + SP 800-53 control mapping with gaps |

## Repository structure

```
bootstrap/                 # One-time remote state backend provisioning
environments/
  account/                 # Account-level: metastore, AAD groups
  dbx-dev/                 # Dev workspace — owns `main` catalog + model serving
  dbx-uat/                 # UAT workspace — owns `uat` catalog, no model serving
modules/
  networking/              # VNet, subnets, NSGs (VNet injection)
  databricks-workspace/    # Workspace + Access Connector
  unity-catalog/           # Storage, metastore assignment, catalog, schema, grants
  model-serving/           # AI gateway: external + foundation endpoints, fallback router
    model_defaults.yaml        # Approved model allowlists + default endpoint catalog
    model_defaults.schema.json # JSON Schema — validated by pre-commit and CI
  workspace-stack/         # Composes networking + workspace + UC + model-serving
docs/                      # Architecture, AI gateway, NIST mapping, operations
```

## Workspace strategy

Two workspaces share one Unity Catalog metastore, each owning its own
catalog. Catalog names are metastore-global, so exactly one workspace may
own `main`.

| Env | Catalog | `create_main_catalog` | Model serving |
|---|---|---|---|
| `dbx-dev` | `main` | `true` | `true` — owns all endpoints |
| `dbx-uat` | `uat` | `false` | `false` |

`dbx-dev` owns the `main` catalog and deploys the model-serving endpoints.
Inference tables attach directly to the `main` catalog's
`model_serving_logs` schema — no cross-workspace writer grants to manage.

`dbx-uat` is a workspace + networking + Unity Catalog tier only. It assigns
to the same metastore and owns a catalog named `uat` (via
`inference_table_catalog = "uat"`, which auto-creates the catalog since it
isn't `main`) with its own `model_serving_logs` schema. Serving can be
enabled later by flipping `enable_model_serving` and supplying
`ai_foundry_name` / `ai_foundry_resource_group`.

Endpoint configuration is **centrally governed**: `dbx-dev` reads
`modules/model-serving/model_defaults.yaml` as the single source of truth
for approved model allowlists, the default endpoint catalog, and the
foundation-model blocklist. A change to that file propagates on the next
`terraform apply`. Overrides can be layered on top via
`model_serving_additional_external_endpoints` and
`model_serving_rate_limits` in `environments/dbx-dev/terraform.tfvars`, but
it cannot reference a model outside the centrally-approved allowlist —
Terraform enforces this with a `lifecycle { precondition }` that fails the
plan before any API call is made.

### Endpoint ownership toggle

The `workspace-stack` module exposes a single boolean:

```hcl
enable_model_serving = true   # dbx-dev — deploys databricks_model_serving endpoints
enable_model_serving = false  # dbx-uat — workspace + UC only, no endpoints
```

### What the dbx-dev workspace deploys

| Resource | Details |
|---|---|
| Databricks workspace | Premium SKU, VNet-injected |
| Unity Catalog | `main` catalog, owned directly, with a `model_serving_logs` schema for inference tables |
| AAD application + SP | `<workspace-name>-model-serving` — granted **Cognitive Services OpenAI User** on the AI Foundry account |
| External endpoints | `azure-gpt-4o`, `azure-gpt-5-mini`, `azure-gpt-5-4`, `azure-text-embedding-ada-002` (from `model_defaults.yaml`) — managed by Terraform |
| Foundation endpoints | `databricks-claude-sonnet-4-6`, `databricks-claude-opus-4-6`, `databricks-claude-opus-4-7` (from `model_defaults.yaml`) — **pre-provisioned by Databricks**, governed out-of-band by `scripts/apply-ai-gateway.sh` (see [Foundation Model governance](#foundation-model-governance)) |
| Fallback router | `azure-gpt-chat-fallback` — retries gpt-4o → gpt-5-mini on 5xx (when `model_serving_fallback_enabled = true`) |

### Rate limits (defaults)

Applied to every endpoint in the workspace:

| Scope | Limit |
|---|---|
| `endpoint` | 60 calls / minute |
| `user` | 20 calls / minute |

Override via `model_serving_rate_limits` in `environments/dbx-dev/terraform.tfvars`.

### Access control — `consumer_groups`

Any Databricks account-level group listed in `consumer_groups` on the
`dbx-dev` workspace is automatically granted:

- **`CAN_QUERY`** on every model serving endpoint
- **`EXECUTE`** on every foundation model served entity

Add a new consumer group by appending to the list and re-applying.

### Deploying a workspace

```bash
cd environments/dbx-dev        # or environments/dbx-uat
cp ../../terraform.tfvars.example terraform.tfvars
# fill in subscription_id, databricks_account_id, metastore_id, ai_foundry_name
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Account must apply before either workspace — both reference the metastore
that `environments/account/` creates. The two workspace envs are
independent of each other and can apply in any order.

## What this deploys

- **Remote state backend** — Azure Storage Account with blob versioning (`bootstrap/`)
- **Resource group** — dedicated RG for all Databricks resources
- **Networking** — VNet (10.179.0.0/20) with public/private subnets, NSGs with
  Databricks delegations, optional Secure Cluster Connectivity (no public IP)
- **Databricks workspace** — Premium SKU, infrastructure encryption, Access
  Connector with system-assigned MSI for Unity Catalog
- **Unity Catalog** — ADLS Gen2 (HNS, GRS, TLS 1.2), metastore assignment,
  storage credential, external location, `main` catalog, and a
  `model_serving_logs` schema; Access Connector MSI granted
  `Storage Blob Data Contributor` and `Storage Account Contributor`
- **Model Serving** (uses `databricks_model_serving` with inline `ai_gateway {}` blocks — the older embedded pattern, not the standalone Databricks AI Gateway product) —
  - External endpoints to Azure AI Foundry: `azure-gpt-4o`,
    `azure-gpt-5-mini`, `azure-gpt-5-4`, `azure-text-embedding-ada-002`
  - Foundation endpoints to Databricks-hosted Claude (`databricks-claude-*`)
    are **pre-provisioned by Databricks** under a reserved name prefix; the
    Terraform provider cannot create or update them. Their AI-gateway
    config (rate limits + inference tables for approved models;
    `calls = 0` for everything on the blocklist) is reconciled by
    `scripts/apply-ai-gateway.sh`, which is also invoked automatically on
    every `terraform apply` by a `terraform_data.ai_gateway_reconciler`
    resource keyed on the YAML hash. See [Foundation Model governance](#foundation-model-governance).
  - Optional fallback router (`azure-gpt-chat-fallback`) auto-retrying 5xx across
    primary/secondary served entities
  - All endpoints have usage tracking on; governed endpoints additionally
    write full prompt/completion payloads to Unity Catalog inference tables
  - **Approved-model allowlists** enforced via `lifecycle { precondition }`
    on external endpoints — any model or entity not in `model_defaults.yaml`
    fails the plan before any API call is made
- **Identity** — dedicated AAD application + service principal with the
  **Cognitive Services OpenAI User** role on the Foundry account (managed
  identity cannot be used because external model endpoints execute inside
  Databricks' control plane, not in this Azure subscription)

See [`docs/architecture.md`](docs/architecture.md) for the request flow.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.9
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) authenticated (`az login`)
- [pre-commit](https://pre-commit.com/) with `pip install check-jsonschema yamllint` for local validation
- An existing Azure AI Foundry (Cognitive Services) account with the
  desired model deployments
- A Databricks account ID (UUID) with admin access

## Quick start

```bash
# 1. One-time: provision the remote state backend
cd bootstrap
terraform init
terraform apply -var="storage_account_name=<globally-unique-name>"

# 2. One-time per Databricks account: create the metastore + groups
cd ../environments/account
terraform init
terraform apply
METASTORE_ID=$(terraform output -raw metastore_id)

# 3. Deploy the workspaces (account must apply first; order between them
#    does not matter)
cd ../environments/dbx-dev
cp ../../terraform.tfvars.example terraform.tfvars
# fill in subscription_id, databricks_account_id, metastore_id, ai_foundry_name
terraform init
terraform plan -out=tfplan -var="metastore_id=$METASTORE_ID"
terraform apply tfplan
```

The Databricks provider's `host` is derived from the workspace module
output, so a single `terraform apply` provisions the workspace, Unity
Catalog, and model serving end-to-end — no two-step deploy required.

Sensitive variables (`databricks_account_id`, `subscription_id`) should be
supplied via environment variables in CI:

```bash
export TF_VAR_databricks_account_id=...
export TF_VAR_subscription_id=...
```

## Adding or changing models

The active model catalog and guardrails live in one file:

```
modules/model-serving/model_defaults.yaml
```

The file has five sections: `allowed_external_models`,
`allowed_foundation_entities`, `external_endpoints`,
`foundation_endpoints`, and `disabled_foundation_models`.

**Rule: add the model to the allowlist before adding it as an endpoint.**
Terraform enforces this with `lifecycle { precondition }` on external
endpoints — a plan that references a model not in the allowlist fails
immediately with a descriptive error, before any API call is made.

### Foundation Model governance

Databricks pre-provisions every `databricks-*` foundation endpoint and
reserves the name prefix, so Terraform can't manage them directly. The
repo handles them through three layers, all driven by
`modules/model-serving/model_defaults.yaml`:

1. **`foundation_endpoints`** in the YAML lists the approved endpoints and
   the inference-table prefix for each.
2. **`disabled_foundation_models`** lists every other `databricks-*`
   endpoint that must be locked down (rate limit set to **0 calls/min**, so
   the API returns HTTP 429 on every attempt).
3. **`scripts/apply-ai-gateway.sh`** is the reconciler. It reads the YAML
   and `PUT`s the desired AI-gateway config on each endpoint via the
   Databricks REST API. The script runs automatically on every
   `terraform apply` via the `terraform_data.ai_gateway_reconciler`
   resource, which is keyed on the YAML file hash + workspace URL +
   table prefix/catalog/schema — so any change to the YAML triggers a
   re-reconcile on the next apply.

To run the reconciler manually (e.g. after an out-of-band UI change):

```bash
scripts/apply-ai-gateway.sh                 # all serving-enabled workspaces (currently just dbx-dev)
scripts/apply-ai-gateway.sh dbx-dev         # a single env
scripts/apply-ai-gateway.sh --dry-run dbx-dev # print payloads only
```

The YAML is validated by:
- `check-jsonschema` pre-commit hook (runs on every commit, uses
  `modules/model-serving/model_defaults.schema.json`)
- `yamllint` pre-commit hook (style and structure)
- A dedicated `schema-check` CI job that runs before `terraform validate`

See [`docs/model-serving.md § Adding an endpoint`](docs/model-serving.md)
for the step-by-step workflow.

## Variables (workspace environments)

| Name | Description | Default |
|------|-------------|---------|
| `location` | Azure region | `eastus2` |
| `resource_group_name` | Resource group name | — |
| `workspace_name` | Databricks workspace name | — |
| `sku` | Workspace SKU (`standard`, `premium`, `trial`) | `premium` |
| `tags` | Resource tags applied to all resources | `{}` |
| `vnet_cidr` | VNet address space for VNet injection | `10.192.0.0/20` |
| `managed_resource_group_name` | Override the Databricks-managed RG name (null = auto) | `null` |
| `no_public_ip` | Enable Secure Cluster Connectivity | `true` |
| `public_network_access_enabled` | Allow public network access | `true` |
| `infrastructure_encryption_enabled` | Secondary encryption layer on DBFS | `true` |
| `ai_foundry_name` | Azure AI Foundry account name | — |
| `ai_foundry_resource_group` | Resource group of the AI Foundry account | — |
| `openai_api_version` | Azure OpenAI API version | `2024-12-01-preview` |
| `inference_table_catalog` | UC catalog for inference tables | `main` |
| `inference_table_schema` | UC schema for inference tables | `model_serving_logs` |
| `model_serving_fallback_enabled` | Enable AI gateway traffic fallback | `false` |
| `model_serving_rate_limits` | Rate limit rules applied to every endpoint | `[]` |
| `model_serving_external_endpoints` | Full override of the Azure OpenAI endpoint catalog (`null` = load from `model_defaults.yaml`) | `null` |
| `model_serving_additional_external_endpoints` | Extra external endpoints merged on top of the active set | `{}` |
| `ai_gateway_reconcile_on_apply` | Run `scripts/apply-ai-gateway.sh` on every `terraform apply` to enforce YAML-driven rate limits + inference tables on pre-provisioned `databricks-*` endpoints | `true` |
| `databricks_account_id` | Databricks account UUID (sensitive) | — |
| `subscription_id` | Azure subscription ID | — |
| `metastore_id` | UC metastore UUID from `environments/account/` | — |
| `uc_storage_account_name` | UC storage account name (auto-derived if null) | `null` |
| `metastore_force_destroy` | Allow destroy of a non-empty metastore (keep `false` in prod) | `false` |
| `write_access_group` | AD/Databricks group granted write access on UC | `null` |

See [`docs/model-serving.md`](docs/model-serving.md) for examples of
overriding endpoint maps, tuning rate limits, and operating the fallback
router.

## Outputs

| Name | Description |
|------|-------------|
| `workspace_url` | Databricks workspace URL |
| `workspace_id` | Azure resource ID of the workspace |
| `workspace_resource_id` | Numeric Databricks workspace ID |
| `managed_resource_group_id` | Managed resource group created by Databricks |
| `access_connector_id` | Access Connector resource ID (for Unity Catalog) |
| `access_connector_principal_id` | Access Connector managed identity principal ID |
