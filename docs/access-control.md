# Model Access Control

This document explains how access to Databricks model-serving endpoints is structured, how it is granted through Terraform, and how each layer relates to the underlying workspaces and Unity Catalog.

---

## Overview

Access is enforced at **four independent layers**, each managed by a different provider:

| Layer | Provider | What it controls |
|---|---|---|
| 1. Azure RBAC | `azurerm` / `azuread` | SP credentials for calling Azure OpenAI; MSI rights over ADLS Gen2 |
| 2. Databricks account groups | `databricks` (account) | Logical identities that are shared across all workspaces |
| 3. Workspace membership | `databricks` (account) | Which groups can log into which workspace |
| 4. Unity Catalog grants | `databricks` (workspace) | What catalog/schema/table data a group can read or write |

Model-serving endpoint permissions (`CAN_QUERY`, `CAN_MANAGE`) are a fifth layer, wired through the `consumer_groups` / `admin_groups` variables on the `model-serving` module. This fifth layer applies **only to Terraform-managed endpoints** — the pre-provisioned `databricks-*` foundation endpoints carry no Terraform ACLs and are governed by gateway rate limits instead (see [Layer 5](#layer-5--model-serving-endpoint-permissions)).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Azure Entra ID (AAD)                                                       │
│                                                                             │
│  SP: dbx-dev-model-serving ── Cognitive Services OpenAI User ──► AI Foundry│
│  Access Connector MSI  ──── Storage Blob Data Contributor ──► UC storage   │
└─────────────────────────────────────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Databricks Account (account/main.tf)                                       │
│                                                                             │
│  Metastore ◄─── assigned to each workspace via the unity-catalog module    │
│                                                                             │
│  Groups:                                                                    │
│    ad-dbx          (owner / admin)                                          │
│    ad-dbx-<team>   (per-team groups, minted from the `teams` variable)      │
└─────────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  dbx-dev workspace    │
                    │                       │
                    │  Model Serving        │
                    │  Endpoints            │
                    │                       │
                    │  UC: main catalog     │
                    │   (owned directly,    │
                    │    incl.              │
                    │    model_serving_logs │
                    │    schema)            │
                    └───────────────────────┘
```

---

## Layer 1 — Azure RBAC

Two Azure identities are used across all endpoints: a service principal created by the `model-serving` module and the Access Connector MSI created by the `databricks-workspace` module.

### Service Principal: `dbx-dev-model-serving`

Created in `modules/model-serving/main.tf` with display name `${name_prefix}-model-serving`; `workspace-stack` passes the workspace name as `name_prefix`, so in `dbx-dev` the SP is `dbx-dev-model-serving`. Used to authenticate Databricks (running in Microsoft's control plane) against the customer's Azure OpenAI / AI Foundry deployment.

```
azuread_application.model_serving
  └── azuread_service_principal.model_serving
        ├── azuread_service_principal_password.model_serving   (client_secret)
        └── azurerm_role_assignment.databricks_oai_user
              role: Cognitive Services OpenAI User
              scope: AI Foundry cognitive account
```

This SP's `client_id` is injected inline into every `external_model` served entity so that Databricks can forward user requests to `gpt-4o`, `gpt-5-mini`, `gpt-5.4`, and `text-embedding-ada-002`. The `client_secret` is **never** passed plaintext: it is stored in a Databricks secret scope (`databricks_secret_scope.model_serving`) and consumed by endpoint config as a secret *reference* — `{{secrets/<scope>/sp-client-secret}}`.

### Access Connector MSI

Created by the `databricks-workspace` module and used exclusively for Unity Catalog storage access. It never touches model-serving endpoints. Its single role assignment lives in `modules/unity-catalog/main.tf`:

```
azurerm_databricks_access_connector.this
  └── azurerm_role_assignment  Storage Blob Data Contributor  → UC ADLS Gen2
```

Storage Blob Data Contributor is the only role Unity Catalog needs; the broader Storage Account Contributor role was deliberately removed for least privilege.

---

## Layer 2 — Databricks Account Groups

Groups are created once in `environments/account/main.tf` and then referenced by name everywhere else. No group is created inside a workspace; all groups live at the account level. The `groups` variable creates groups verbatim; the `teams` variable mints one `ad-dbx-<team>` group per entry.

```hcl
# environments/account/terraform.tfvars  (gitignored — illustrative values)
groups = ["ad-dbx"]
teams  = []            # each entry would create an account group "ad-dbx-<team>"
```

| Group | Intended members | Role in the system |
|---|---|---|
| `ad-dbx` | Platform / infra engineers | Metastore + catalog **owner**; endpoint `CAN_MANAGE` when listed in `model_serving_admin_groups`; scoped UC write privileges when listed in `workspace_groups` |
| `ad-dbx-<team>` | Consumer / BI teams | Workspace USER + endpoint `CAN_QUERY` (`consumer_groups`) or read-only catalog access (`reader_groups`) |

> **Naming constraint:** the `workspace_groups`, `consumer_groups`, `reader_groups`, and `model_serving_admin_groups` variables on `workspace-stack` all carry a validation requiring group names to start with `ad-dbx`. An account group with any other name can exist, but cannot be wired into workspace access through these variables.

Granting access to a new consumer group is a single change:
add the group name to `consumer_groups` in
`environments/dbx-dev/terraform.tfvars` → grants workspace membership plus
endpoint `CAN_QUERY` on the Terraform-managed endpoints.

---

## Layer 3 — Workspace Membership

Managed by `databricks_mws_permission_assignment` inside `modules/unity-catalog/main.tf`. A group must be assigned to a workspace before any of its members can log in.

```hcl
# modules/unity-catalog/main.tf
locals {
  all_workspace_groups = toset(concat(
    var.workspace_groups, var.workspace_consumer_groups, var.workspace_reader_groups,
  ))
}

resource "databricks_mws_permission_assignment" "workspace_access" {
  for_each     = local.all_workspace_groups
  provider     = databricks.accounts
  workspace_id = var.workspace_resource_id
  principal_id = data.databricks_group.workspace_groups[each.value].id
  permissions  = ["USER"]
}
```

The three input lists map to the three variable families in `workspace-stack`:

| `workspace-stack` variable | `unity-catalog` variable | Workspace role | UC access |
|---|---|---|---|
| `workspace_groups` | `workspace_groups` | USER | scoped write privileges on catalogs (no `MANAGE` / `APPLY_TAG`) |
| `consumer_groups` | `workspace_consumer_groups` | USER | none |
| `reader_groups` | `workspace_reader_groups` | USER | read-only catalogs |

### dbx-dev environment assignment

```
dbx-dev workspace
  workspace_groups = ["ad-dbx"]
  consumer_groups  = []
  → ad-dbx gets USER on dbx-dev workspace + scoped write privileges on the
    main catalog (it also OWNS the catalog via uc_owner_group)

Add additional consumer groups to consumer_groups in
environments/dbx-dev/terraform.tfvars as needed. reader_groups exists on
workspace-stack but is not currently exposed by the dbx-dev root — plumb it
through environments/dbx-dev/{variables,main}.tf before using it.
```

---

## Layer 4 — Unity Catalog Privileges

Granted in `modules/unity-catalog/main.tf` using `databricks_grant` resources. The privilege lists are deliberately scoped — `ALL_PRIVILEGES` is never granted on the `main` catalog; full control comes only from **ownership** (`uc_owner_group`, default `ad-dbx`).

```
Metastore (shared, one per region, owned by ad-dbx)
  └── workspace_groups (e.g. ad-dbx on dbx-dev)
        CREATE_CATALOG only
        (CREATE_EXTERNAL_LOCATION / CREATE_STORAGE_CREDENTIAL are platform-only:
         reserved to the metastore owner and the storage-credential resource
         managed by this module)

Catalog: main  (owned directly by dbx-dev, create_main_catalog = true,
                owner = uc_owner_group → ad-dbx)
  └── workspace_groups → scoped write privileges:
        USE_CATALOG, CREATE_SCHEMA, USE_SCHEMA, SELECT, MODIFY,
        CREATE_TABLE, CREATE_FUNCTION, CREATE_VIEW, EXECUTE,
        CREATE_VOLUME, READ_VOLUME, WRITE_VOLUME
      (MANAGE and APPLY_TAG are reserved for the catalog owner)

Schema: model_serving_logs  (inside the main catalog)
  └── created by unity-catalog module, owned by uc_owner_group (ad-dbx)
      inference_table_catalog = "main" — no separate inference catalog,
      no inference_writer_groups / inference_admin_groups needed since
      there's no cross-workspace writer.
```

### Read-only grant (reader groups)

```
ad-dbx-<team> (if added to reader_groups)
  USE_CATALOG, USE_SCHEMA, SELECT, EXECUTE, READ_VOLUME
  on the main catalog
```

---

## Layer 5 — Model-Serving Endpoint Permissions

Endpoint-level access (`CAN_QUERY`, `CAN_MANAGE`) is controlled through variables on the `model-serving` module. It applies to the **Terraform-managed** endpoints only, and only when `model_serving_endpoint_permissions_enabled = true` (the default — set it `false` where the inference-endpoint ACL feature is unavailable).

```
workspace-stack variables           model-serving variables
─────────────────────────────────   ─────────────────────────────────
consumer_groups          ──────────► consumer_groups   → CAN_QUERY
model_serving_admin_groups ────────► admin_groups       → CAN_MANAGE
```

These variables flow from `terraform.tfvars` → `workspace-stack` → `model-serving`:

```
environments/dbx-dev/terraform.tfvars
  consumer_groups            = []
  model_serving_admin_groups = ["ad-dbx"]
       │
       ▼
modules/workspace-stack/main.tf
  module "model_serving" {
    consumer_groups = var.consumer_groups        # → CAN_QUERY
    admin_groups    = var.model_serving_admin_groups  # → CAN_MANAGE
  }
       │
       ▼
modules/model-serving/main.tf
  (databricks_permissions resources render one per endpoint)
```

All ACL entries for an endpoint live in a single `databricks_permissions` resource (the provider treats it as authoritative), and a group listed in both `consumer_groups` and `admin_groups` gets `CAN_MANAGE`. (The module also accepts a single `write_access_group` folded into the `CAN_QUERY` set — a convenience input not plumbed through `workspace-stack`.)

### Endpoint permission matrix (dbx-dev, with `model_serving_admin_groups = ["ad-dbx"]`)

| Endpoint | `ad-dbx` | groups in `consumer_groups` |
|---|---|---|
| `azure-gpt-4o` | CAN_MANAGE | CAN_QUERY |
| `azure-gpt-5-mini` | CAN_MANAGE | CAN_QUERY |
| `azure-gpt-5-4` | CAN_MANAGE | CAN_QUERY |
| `azure-text-embedding-ada-002` | CAN_MANAGE | CAN_QUERY |
| `azure-gpt-chat-fallback` (only when `model_serving_fallback_enabled = true`) | CAN_MANAGE | CAN_QUERY |

Any group added to `consumer_groups` in
`environments/dbx-dev/terraform.tfvars` is automatically granted
`CAN_QUERY` on every endpoint above.

### Pre-provisioned `databricks-*` foundation endpoints

The pay-per-token Foundation Model endpoints (`databricks-claude-sonnet-4-6`, `databricks-claude-opus-4-6`, `databricks-claude-opus-4-7`, plus every other `databricks-*` endpoint Databricks ships) exist automatically in every workspace. The name prefix is reserved — the Terraform provider rejects CREATE/UPDATE on them — so **no `databricks_permissions` ACLs are managed for them**: any workspace user can reach them, and governance is by AI-gateway rate limit only.

That governance is applied **out-of-band** by `scripts/apply-ai-gateway.sh` (a `PUT /api/2.0/serving-endpoints/{name}/ai-gateway` per endpoint), re-run by `terraform apply` whenever its triggers change (YAML hash, workspace URL, table settings) via `terraform_data.ai_gateway_reconciler` in `modules/workspace-stack/main.tf`. Reading `modules/model-serving/model_defaults.yaml`:

- `foundation_endpoints` → get the `gateway_defaults` rate limits + inference tables;
- `disabled_foundation_models` → get `rate_limit = 0`, so every call returns HTTP 429.

> ⚠ **The deny-list is fail-open.** A newly released `databricks-*` endpoint is fully callable until someone adds it to `disabled_foundation_models` and an apply re-runs the reconciler. `allowed_foundation_entities` in the same YAML (also exported as a module output) is audit documentation, **not** an enforced allowlist.

---

## End-to-End Access Flow

The diagram below walks a user through the full request path from login to
inference against the `dbx-dev` workspace (the only one with
`enable_model_serving = true` — `dbx-uat` runs workspace + UC only).

```
User
    │
    │  1. Authenticates via Entra ID
    ▼
account group: ad-dbx
    │
    │  2. databricks_mws_permission_assignment → USER on dbx-dev workspace
    ▼
dbx-dev workspace (login granted)
    │
    │  3. databricks_permissions → CAN_QUERY on model-serving endpoints
    ▼
Model-serving endpoint (e.g. azure-gpt-4o)
    │
    │  4. AI gateway enforces:
    │     • rate limits (gateway_defaults: 60 calls/min per endpoint, 20/min per user)
    │     • guardrails — OFF by default; the shipped gateway_defaults has no
    │       guardrails section (enable via the YAML or model_serving_guardrails)
    │     • writes payload to inference table
    │       (main.model_serving_logs.dbx_dev_azure_gpt4o_payload)
    ▼
SP: dbx-dev-model-serving
    │
    │  5. azurerm_role_assignment → Cognitive Services OpenAI User
    ▼
Azure AI Foundry (gpt-4o deployment)
    │
    │  6. Response returned through gateway → user
    ▼
User receives answer
```

---

## How to Grant Access to a New Consumer Group

There is no team-onboarding flow — `dbx-dev` is the only workspace serving
models, so granting access is a single change on its `terraform.tfvars`.

1. **Create the account-level group** (if it doesn't already exist) — add it
   to `groups` (or, for the `ad-dbx-<team>` convention, to `teams`) in
   `environments/account/terraform.tfvars` and apply. Remember the
   workspace-side lists validate that names start with `ad-dbx`.

2. **Grant workspace + endpoint access** — add the new group to
   `consumer_groups` in `environments/dbx-dev/terraform.tfvars` and apply.
   (Read-only UC access via `reader_groups` exists on `workspace-stack`, but
   the dbx-dev root does not expose it yet — plumb the variable through first.)

```hcl
# environments/dbx-dev/terraform.tfvars
consumer_groups = [
  "ad-dbx-some-team",   # ← grants CAN_QUERY on every Terraform-managed endpoint
]
```

That single change propagates through two resources:
- `databricks_mws_permission_assignment` (workspace USER)
- `databricks_permissions` on every Terraform-managed endpoint (CAN_QUERY)

3. **Optional — UC write access**: if the group needs to write data (not
   just query models), add it to `workspace_groups` instead — this grants
   the scoped write-privilege set on the `main` catalog
   (USE_CATALOG … WRITE_VOLUME, but not MANAGE/APPLY_TAG) plus
   `CREATE_CATALOG` on the metastore, in addition to workspace access.

---

## How to Restrict Access (Rate Limits & Guardrails)

Rate limits and guardrails are set on the `dbx-dev` workspace in `terraform.tfvars` and apply to every **Terraform-managed** endpoint in that workspace. Empty/null values fall back to `gateway_defaults` in `modules/model-serving/model_defaults.yaml` (shipped defaults: 60 calls/min per endpoint, 20/min per user, no guardrails).

```hcl
# environments/dbx-dev/terraform.tfvars
model_serving_rate_limits = [
  { calls = 60, key = "endpoint", renewal_period = "minute" },   # total per endpoint
  { calls = 20, key = "user",     renewal_period = "minute" },   # per-user throttle
]

model_serving_guardrails = {
  input  = { safety = true, pii_behavior = "MASK" }
  output = { safety = true, pii_behavior = "MASK" }
}
```

Per-group rate limits can be added with `key = "user_group"` plus a `principal` (a Databricks group display name) on a limit entry — at most 5 `user_group` entries of 20 limits total.

Note: these workspace-level overrides do **not** reach the pre-provisioned `databricks-*` foundation endpoints — the reconciler always applies the YAML `gateway_defaults` to those, so change the YAML to change their policy.

---

## Endpoint Ownership

```
                Databricks Account
                       │
                       ▼
                dbx-dev workspace
                (enable_model_serving = true,
                 create_main_catalog  = true)
                       │
                       │ owns endpoints + main catalog
                       │ (incl. model_serving_logs schema)
                       ▼
                 unified metastore
             (shared, account level)
```

`dbx-dev` owns everything directly — the model-serving endpoints and the
`main` catalog they write inference rows into. There is no separate
platform/team split and no cross-workspace writer grants.

---

## Cost Allocation by Application

The inference tables and per-user rate limits already provide the data needed for per-app cost chargebacks — no separate endpoint per app is required.

**Tag requests with an app identifier** — have each app pass a
`usage_context` map in the request body (the mechanism documented in
[model-serving.md §2.2](model-serving.md)); it lands in
`system.serving.endpoint_usage.usage_context` and in the inference
table's `request` column, making it queryable for chargeback reports.

```sql
SELECT
  request:usage_context.app_id              AS app_id,
  date_trunc('month', request_time)         AS month,
  count(*)                                  AS requests,
  sum(response:usage.completion_tokens)     AS tokens_out,
  sum(response:usage.prompt_tokens)         AS tokens_in
FROM main.model_serving_logs.dbx_dev_azure_gpt4o_payload
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;
```

`system.serving.endpoint_usage` provides the same split with lighter
queries (`usage_context['app_id']`, `input_token_count`,
`output_token_count`) if full payloads aren't needed.

**When a separate endpoint is justified** (not just for cost allocation):
- The app requires a different model or a fine-tuned variant
- The app needs different guardrails (e.g. no PII masking for an internal tool)
- Hard rate-limit isolation is required so one app cannot affect another's quota
- Compliance requires traffic from different consumers to never mix
