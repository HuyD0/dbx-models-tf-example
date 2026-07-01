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

Model-serving endpoint permissions (`CAN_QUERY`, `CAN_MANAGE`) are a fifth layer, wired through the `consumer_groups` / `admin_groups` variables on the `model-serving` module.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Azure Entra ID (AAD)                                                       │
│                                                                             │
│  SP: dbw-model-serving ──── Cognitive Services OpenAI User ──► AI Foundry  │
│  Access Connector MSI  ──── Storage Blob Data Contributor ──► UC storage   │
└─────────────────────────────────────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Databricks Account (account/main.tf)                                       │
│                                                                             │
│  Metastore ◄─── assigned to the dbx-dev workspace via unity-catalog module │
│                                                                             │
│  Groups:                                                                    │
│    ad-dbx          (owner / admin)                                          │
│    PowerBI_users   (BI readers)                                             │
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

Two Azure identities are created by the `model-serving` module and used across all endpoints.

### Service Principal: `dbw-model-serving`

Created in `modules/model-serving/main.tf`. Used to authenticate Databricks (running in Microsoft's control plane) against the customer's Azure OpenAI / AI Foundry deployment.

```
azuread_application.model_serving
  └── azuread_service_principal.model_serving
        ├── azuread_service_principal_password.model_serving   (client_secret)
        └── azurerm_role_assignment.databricks_oai_user
              role: Cognitive Services OpenAI User
              scope: AI Foundry cognitive account
```

This SP's `client_id` and `client_secret` are injected into every `external_model` served entity so that Databricks can forward user requests to `gpt-4o`, `gpt-5-mini`, `gpt-5.4`, and `text-embedding-ada-002`.

### Access Connector MSI

Created by the `databricks-workspace` module and used exclusively for Unity Catalog storage access. It never touches model-serving endpoints.

```
azurerm_databricks_access_connector.this
  └── azurerm_role_assignment  Storage Blob Data Contributor  → UC ADLS Gen2
  └── azurerm_role_assignment  Storage Account Contributor    → UC ADLS Gen2
```

---

## Layer 2 — Databricks Account Groups

Groups are created once in `environments/account/main.tf` and then referenced by name everywhere else. No group is created inside a workspace; all groups live at the account level.

```hcl
# environments/account/terraform.tfvars
groups = ["ad-dbx", "PowerBI_users"]
teams  = []            # no per-team groups — single workspace owns everything
```

| Group | Intended members | Role in the system |
|---|---|---|
| `ad-dbx` | Platform / infra engineers | Metastore owner, endpoint `CAN_MANAGE`, UC `ALL_PRIVILEGES` on `dbx-dev` |
| `PowerBI_users` | BI / reporting consumers | Read-only catalogs, no endpoint access |

Granting access to a new consumer group is a single change:
add the group name to `consumer_groups` (or `reader_groups`) in
`environments/dbx-dev/terraform.tfvars` → grants workspace membership and,
for `consumer_groups`, endpoint `CAN_QUERY`.

---

## Layer 3 — Workspace Membership

Managed by `databricks_mws_permission_assignment` inside `modules/unity-catalog/main.tf`. A group must be assigned to a workspace before any of its members can log in.

```hcl
# modules/unity-catalog/main.tf
locals {
  all_workspace_groups = workspace_groups + workspace_consumer_groups + workspace_reader_groups
}

resource "databricks_mws_permission_assignment" "workspace_access" {
  for_each     = toset(local.all_workspace_groups)
  permissions  = ["USER"]
}
```

The three input lists map to the three variable families in `workspace-stack`:

| `workspace-stack` variable | `unity-catalog` variable | Workspace role | UC access |
|---|---|---|---|
| `workspace_groups` | `workspace_groups` | USER | `ALL_PRIVILEGES` on catalogs |
| `consumer_groups` | `workspace_consumer_groups` | USER | none |
| `reader_groups` | `workspace_reader_groups` | USER | read-only catalogs |

### dbx-dev environment assignment

```
dbx-dev workspace
  workspace_groups = ["ad-dbx"]
  consumer_groups  = []
  → ad-dbx gets USER on dbx-dev workspace + ALL_PRIVILEGES on main catalog

Add BI/reporting groups to reader_groups, or additional consumer groups
to consumer_groups, in environments/dbx-dev/terraform.tfvars as needed.
```

---

## Layer 4 — Unity Catalog Privileges

Granted in `modules/unity-catalog/main.tf` using `databricks_grant` resources.

```
Metastore (shared, one per region)
  └── ad-dbx (via workspace_groups on dbx-dev)
        CREATE_CATALOG, CREATE_EXTERNAL_LOCATION, CREATE_STORAGE_CREDENTIAL

Catalog: main  (owned directly by dbx-dev, create_main_catalog = true)
  └── ad-dbx → ALL_PRIVILEGES (workspace_groups)

Schema: model_serving_logs  (inside the main catalog)
  └── created by unity-catalog module, owned by uc_owner_group (ad-dbx)
      inference_table_catalog = "main" — no separate inference catalog,
      no inference_writer_groups / inference_admin_groups needed since
      there's no cross-workspace writer.
```

### Read-only grant (reader groups)

```
PowerBI_users (if added to reader_groups)
  USE_CATALOG, USE_SCHEMA, SELECT, EXECUTE, READ_VOLUME
  on the main catalog
```

---

## Layer 5 — Model-Serving Endpoint Permissions

Endpoint-level access (`CAN_QUERY`, `CAN_MANAGE`) is controlled through variables on the `model-serving` module.

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

### Endpoint permission matrix (dbx-dev)

| Endpoint | `ad-dbx` | `PowerBI_users` |
|---|---|---|
| `azure-gpt-4o` | CAN_MANAGE | — |
| `azure-gpt-5-mini` | CAN_MANAGE | — |
| `azure-gpt-5-4` | CAN_MANAGE | — |
| `azure-text-embedding-ada-002` | CAN_MANAGE | — |
| `dbrx-claude-sonnet-4-6` | CAN_MANAGE | — |
| `azure-gpt-chat-fallback` (fallback router) | CAN_MANAGE | — |

Any group added to `consumer_groups` in
`environments/dbx-dev/terraform.tfvars` is automatically granted
`CAN_QUERY` on every endpoint above.

---

## End-to-End Access Flow

The diagram below walks a user through the full request path from login to
inference against the single `dbx-dev` workspace.

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
    │     • rate limits (60 calls/min per endpoint, 20/min per user)
    │     • guardrails (PII masking, safety filters, input/output)
    │     • writes payload to inference table (main.model_serving_logs.azure_gpt4o_payload)
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

There is no more team-onboarding flow — `dbx-dev` is the only workspace, so
granting access is a single change on its `terraform.tfvars`.

1. **Create the account-level group** (if it doesn't already exist) — add it
   to `groups` in `environments/account/terraform.tfvars` and apply.

2. **Grant workspace + endpoint access** — add the new group to
   `consumer_groups` (query-only) or `reader_groups` (read-only UC access)
   in `environments/dbx-dev/terraform.tfvars` and apply.

```hcl
# environments/dbx-dev/terraform.tfvars
consumer_groups = [
  "some-new-group",   # ← grants CAN_QUERY on every dbx-dev endpoint
]
```

That single change propagates through two resources:
- `databricks_mws_permission_assignment` (workspace USER)
- `databricks_permissions` on every endpoint (CAN_QUERY)

3. **Optional — UC write access**: if the group needs to write data (not
   just query models), add it to `workspace_groups` instead — this grants
   `ALL_PRIVILEGES` on the `main` catalog in addition to workspace access.

---

## How to Restrict Access (Rate Limits & Guardrails)

Rate limits and guardrails are set on the `dbx-dev` workspace in `terraform.tfvars` and apply to **all endpoints** in that workspace.

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

Per-group rate limits can be added by including a `principal` field on a limit entry — this maps to a Databricks group name.

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

**Tag requests with an app identifier** — have each app pass a custom header (e.g. `X-App-ID` or `X-Cost-Center`); the inference table captures request headers in `request_metadata`, making it queryable for chargeback reports.

```sql
SELECT
  request_metadata['x-app-id']      AS app_id,
  date_trunc('month', timestamp)     AS month,
  count(*)                           AS requests,
  sum(usage.completion_tokens)       AS tokens_out,
  sum(usage.prompt_tokens)           AS tokens_in
FROM main.model_serving_logs.azure_gpt4o_payload
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;
```

`system.serving.endpoint_usage` provides aggregated token counts per endpoint per principal if a lighter query is preferred.

**When a separate endpoint is justified** (not just for cost allocation):
- The app requires a different model or a fine-tuned variant
- The app needs different guardrails (e.g. no PII masking for an internal tool)
- Hard rate-limit isolation is required so one app cannot affect another's quota
- Compliance requires traffic from different consumers to never mix
