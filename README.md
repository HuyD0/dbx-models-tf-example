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
| [`docs/budgets.md`](docs/budgets.md) | Cost governance — account-level budgets (LLM spend alerts + optional usage blocking) and budget/serverless-usage policies for chargeback |
| [`docs/architecture.md`](docs/architecture.md) | Component diagram, request flow, why an SP is used for Azure OpenAI |
| [`docs/nist-alignment.md`](docs/nist-alignment.md) | NIST AI RMF + SP 800-53 control mapping with gaps |

## Repository structure

```
bootstrap/                 # One-time remote state backend provisioning
environments/
  account/                 # Account-level: metastore, account groups, deployment SP, budgets + budget policies
    budget_defaults.yaml       # Budgets + budget (usage) policies — cost governance source of truth
    budget_defaults.schema.json # JSON Schema — validated by pre-commit and CI
  dbx-dev/                 # Dev workspace — owns `main` catalog + model serving
  dbx-uat/                 # UAT workspace — owns `uat` catalog, no model serving
modules/
  networking/              # VNet, subnets, NSGs (VNet injection)
  databricks-workspace/    # Workspace + Access Connector
  unity-catalog/           # Storage, metastore assignment, catalog, schema, grants
  model-serving/           # AI gateway: external + foundation endpoints, fallback router
    model_defaults.yaml        # Approved model allowlists + endpoint catalog + gateway_defaults policy
    model_defaults.schema.json # JSON Schema — validated by pre-commit and CI
  workspace-stack/         # Composes networking + workspace + UC + model-serving
examples/
  single-workspace/        # Compile-checked usage example (terraform validate in CI)
docs/                      # Architecture, AI gateway, budgets, NIST mapping, operations
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

Defined once in `gateway_defaults` in
`modules/model-serving/model_defaults.yaml` and applied to every endpoint
in the workspace — Terraform-managed external endpoints and (via the
reconciler script) the pre-provisioned `databricks-*` foundation
endpoints share the same policy:

| Scope | Limit |
|---|---|
| `endpoint` | 60 calls / minute |
| `user` | 20 calls / minute |

The YAML also supports endpoint token limits (`endpoint_tpm`), per-group
limits (`user_group_limits`, max 5), and default guardrails (safety +
PII behavior). Override per workspace via `model_serving_rate_limits` /
`model_serving_guardrails` in `environments/dbx-dev/terraform.tfvars`.

### Cost governance (budgets + budget policies)

`environments/account/budget_defaults.yaml` declares:

- **Budgets** — monthly USD spend monitors with email alerts. The
  `UNITY_AI_GATEWAY`-scoped budget tracks LLM spend (external models AND
  the pay-per-token `databricks-*` endpoints) near-real-time and can
  optionally **block further AI Gateway usage** past a threshold.
- **Budget policies** (serverless usage policies) — custom tags stamped
  onto `system.billing.usage` for chargeback, attachable to serving
  endpoints via `model_serving_budget_policy_id`, with group grants
  managed in Terraform.

See [`docs/budgets.md`](docs/budgets.md) for the YAML shape, the
policy-ID handoff between environments, and import runbooks.

### Access control — `consumer_groups`

Any Databricks account-level group listed in `consumer_groups` on the
`dbx-dev` workspace is automatically granted:

- workspace **USER** access (`databricks_mws_permission_assignment`)
- **`CAN_QUERY`** on every **Terraform-managed** serving endpoint — the
  external endpoints and the fallback router — via one
  `databricks_permissions` resource per endpoint. Groups listed in
  `model_serving_admin_groups` get **`CAN_MANAGE`** instead.

Add a new consumer group by appending to the list and re-applying.

The pre-provisioned `databricks-*` foundation endpoints are **not**
covered by these ACLs — Terraform cannot manage endpoints under the
reserved prefix, so access to them is constrained only by the rate
limits the reconciler applies (`calls = 0` for blocked models), not by
per-group grants.

### Deploying a workspace

```bash
cd environments/dbx-dev        # or environments/dbx-uat
cp ../../terraform.tfvars.example terraform.tfvars
# add subscription_id, databricks_account_id, metastore_id,
# deployment_sp_client_id — and set ai_foundry_name for serving workspaces
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
- **Networking** — VNet (default `10.192.0.0/20` in dev, `10.193.0.0/20` in
  uat) with public/private subnets, NSGs with
  Databricks delegations, optional Secure Cluster Connectivity (no public IP)
- **Databricks workspace** — Premium SKU, infrastructure encryption, Access
  Connector with system-assigned MSI for Unity Catalog
- **Unity Catalog** — ADLS Gen2 (HNS, GRS, TLS 1.2), metastore assignment,
  storage credential, external location, `main` catalog, and a
  `model_serving_logs` schema; Access Connector MSI granted
  `Storage Blob Data Contributor` only (the broader
  `Storage Account Contributor` role was removed for least privilege)
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
- [pre-commit](https://pre-commit.com/) for local validation (fmt, validate,
  tflint, trivy, governance-YAML schema checks, secret scanning — hooks
  install their own dependencies)
- `az`, `yq`, `jq`, and `curl` on PATH — required by
  `scripts/apply-ai-gateway.sh`, which runs on every apply of a
  serving-enabled workspace
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
# add subscription_id, databricks_account_id, metastore_id,
# deployment_sp_client_id — and set ai_foundry_name for serving workspaces
terraform init
terraform plan -out=tfplan -var="metastore_id=$METASTORE_ID"
terraform apply tfplan
```

The Databricks provider's `host` is derived from the workspace module
output, so a single `terraform apply` provisions the workspace, Unity
Catalog, and model serving end-to-end — no two-step deploy required.

Account and subscription identifiers are supplied via environment
variables in CI rather than committed tfvars (`databricks_account_id` is
additionally marked `sensitive`):

```bash
export TF_VAR_databricks_account_id=...
export TF_VAR_subscription_id=...
export TF_VAR_metastore_id=...
export TF_VAR_deployment_sp_client_id=...
```

## Adding or changing models

The active model catalog and guardrails live in one file:

```
modules/model-serving/model_defaults.yaml
```

The file has six sections: `allowed_external_models`,
`allowed_foundation_entities`, `external_endpoints`,
`foundation_endpoints`, `disabled_foundation_models`, and
`gateway_defaults` (the default rate limits + guardrails).

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
2. **`disabled_foundation_models`** lists the other known `databricks-*`
   endpoints, which are locked down (rate limit set to **0 calls/min**, so
   the API returns HTTP 429 on every attempt).
3. **`scripts/apply-ai-gateway.sh`** is the reconciler. It reads the YAML
   and `PUT`s the desired AI-gateway config on each endpoint via
   `PUT /api/2.0/serving-endpoints/{name}/ai-gateway`. The script runs
   automatically on every `terraform apply` via the
   `terraform_data.ai_gateway_reconciler` resource in
   `modules/workspace-stack/main.tf` (disable with the workspace-stack
   variable `ai_gateway_reconcile_on_apply`), which is keyed on the YAML
   file hash + workspace URL + table prefix/catalog/schema — so any
   change to the YAML triggers a re-reconcile on the next apply.

**This deny-list is fail-open.** `disabled_foundation_models` is a
blocklist, not an allowlist: when Databricks rolls out a new
pre-provisioned `databricks-*` endpoint, it is fully callable until
someone adds it to the YAML and the reconciler re-runs — and the
reconciler only re-asserts the YAML's state on `terraform apply` (or a
manual run); it does not discover new endpoints or catch drift between
applies. `allowed_foundation_entities` in the same YAML is **audit
documentation, not enforcement**: it is surfaced as the model-serving
module's `allowed_foundation_entities` output for ops tooling, but no
resource or script enforces it as an allowlist. Review the blocklist
whenever Databricks announces new pay-per-token models. (Within a run,
enforcement failures are not silent: every endpoint is attempted, and
any failed `PUT` fails the script — and therefore the apply.)

To run the reconciler manually (e.g. after an out-of-band UI change):

```bash
scripts/apply-ai-gateway.sh                 # all serving-enabled workspaces (currently just dbx-dev)
scripts/apply-ai-gateway.sh dbx-dev         # a single env
scripts/apply-ai-gateway.sh --dry-run dbx-dev # print payloads only
```

The YAML is validated by:
- `check-jsonschema` pre-commit hooks (against
  `modules/model-serving/model_defaults.schema.json` and
  `environments/account/budget_defaults.schema.json`)
- a schema-validation step at the start of the CI `validate` job, which
  runs before `terraform fmt` / `terraform validate`

See [`docs/model-serving.md § Adding an endpoint`](docs/model-serving.md)
for the step-by-step workflow.

## Variables (workspace environments)

Each workspace environment (`dbx-dev`, `dbx-uat`) declares its own copy of
these variables; where defaults differ per environment both are shown as
dev / uat.

| Name | Description | Default |
|------|-------------|---------|
| `team` | Team identifier — becomes tags and the default inference-table prefix | `dbx-dev` / `dbx-uat` |
| `location` | Azure region | `eastus2` |
| `resource_group_name` | Resource group name | `rg-databricks-dbx-dev` / `rg-databricks-dbx-uat` |
| `workspace_name` | Databricks workspace name | `dbx-dev` / `dbx-uat` |
| `sku` | Workspace SKU (`standard`, `premium`, `trial`) | `premium` |
| `tags` | Resource tags applied to all resources | `{}` |
| `vnet_cidr` | VNet address space for VNet injection | `10.192.0.0/20` / `10.193.0.0/20` |
| `managed_resource_group_name` | Override the Databricks-managed RG name (null = auto) | `null` |
| `no_public_ip` | Enable Secure Cluster Connectivity | `true` |
| `public_network_access_enabled` | Allow public network access | `true` |
| `infrastructure_encryption_enabled` | Secondary encryption layer on DBFS | `true` |
| `ai_foundry_name` | Azure AI Foundry account name | `aif-huy-dev` / `null` |
| `ai_foundry_resource_group` | Resource group of the AI Foundry account | `rg-aifoundry-dev` / `null` |
| `openai_api_version` | Azure OpenAI API version | `2024-12-01-preview` |
| `inference_table_catalog` | UC catalog for inference tables | `main` / `uat` |
| `inference_table_schema` | UC schema for inference tables | `model_serving_logs` |
| `create_main_catalog` | Create the `main` UC catalog (exactly one workspace may own it) | `true` / `false` |
| `enable_model_serving` | Whether this workspace owns model serving endpoints | `true` / `false` |
| `workspace_groups` | Account-level groups granted workspace USER + scoped write privileges on the owned catalogs | `[]` |
| `consumer_groups` | Account-level groups granted workspace USER + endpoint `CAN_QUERY` | `[]` |
| `model_serving_admin_groups` | Account-level groups granted `CAN_MANAGE` on every managed endpoint | `[]` |
| `model_serving_fallback_enabled` | Enable AI gateway traffic fallback | `false` |
| `model_serving_rate_limits` | Rate limit rules applied to every endpoint (`[]` = use `gateway_defaults` from `model_defaults.yaml`) | `[]` |
| `model_serving_guardrails` | AI Gateway guardrails override (`null` = use `gateway_defaults`) | `null` |
| `model_serving_budget_policy_id` | Budget (serverless usage) policy attached to every endpoint — from `environments/account` outputs | `null` |
| `model_serving_endpoint_permissions_enabled` | Manage endpoint ACLs (set `false` where the inference-endpoint ACL feature is unavailable) | `true` |
| `model_serving_external_endpoints` | Full override of the external endpoint catalog (`null` = load from `model_defaults.yaml`) | `null` |
| `model_serving_additional_external_endpoints` | Extra external endpoints merged on top of the active set | `{}` |
| `contributor_group_object_id` | AAD group object ID granted Contributor on the resource group | `null` |
| `databricks_account_id` | Databricks account UUID (sensitive) | — |
| `subscription_id` | Azure subscription ID | — |
| `metastore_id` | UC metastore UUID from `environments/account/` | — |
| `deployment_sp_client_id` | Client ID of the deployment SP (`sp-terraform-databricks`), granted workspace ADMIN at creation | — |
| `databricks_auth_type` | Databricks provider auth: `azure-client-secret`, `github-oidc-azure` (CI), or `azure-cli` | `azure-client-secret` |
| `uc_storage_account_name` | UC storage account name (auto-derived if null) | `null` |
| `create_inference_catalog` | (uat only) Override auto-creation of the inference catalog | `null` |

The workspace-stack module additionally exposes
`ai_gateway_reconcile_on_apply` (default `true`) to toggle the
foundation-endpoint reconciler run on apply; the environment roots use
the default rather than exposing it as a root variable.

See [`docs/model-serving.md`](docs/model-serving.md) for examples of
overriding endpoint maps, tuning rate limits, and operating the fallback
router.

## Outputs (workspace environments)

| Name | Description |
|------|-------------|
| `workspace_url` | Databricks workspace URL |
| `workspace_id` | Azure resource ID of the workspace |
| `workspace_resource_id` | Numeric Databricks workspace ID |
| `access_connector_id` | Access Connector resource ID (for Unity Catalog) |
| `uc_storage_account_name` | Storage account backing Unity Catalog |
| `metastore_id` | UC metastore ID assigned to this workspace |
| `inference_catalog_name` | Catalog receiving model-serving inference tables |
| `model_serving_endpoints` | Names of the Terraform-managed serving endpoints (empty when serving is disabled) |
