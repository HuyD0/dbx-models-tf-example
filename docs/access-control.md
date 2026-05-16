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
│  Metastore ◄─── assigned to each workspace via unity-catalog module        │
│                                                                             │
│  Groups:                                                                    │
│    ad-dbx          (platform / admin)                                       │
│    ad-dbx-team-a   (team-a users)                                          │
│    PowerBI_users   (BI readers)                                             │
└─────────────────────────────────────────────────────────────────────────────┘
        │                               │
        ▼                               ▼
┌───────────────────┐         ┌───────────────────┐
│  team-a           │         │  team-b            │
│  workspace        │         │  workspace         │
│                   │         │                    │
│  Model Serving    │         │  Model Serving     │
│  Endpoints        │         │  Endpoints         │
│                   │         │                    │
│  UC: main         │         │  UC: main          │
│  catalog          │         │  catalog           │
└────────┬──────────┘         └────────┬───────────┘
         │ inference rows              │ inference rows
         │ prefix: team_a_*            │ prefix: team_b_*
         └──────────────┬─────────────┘
                        ▼
          ┌─────────────────────┐
          │  platform workspace │
          │  UC: llmlogs        │
          │  catalog (shared)   │
          └─────────────────────┘
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
teams  = ["team-a"]            # produces group "ad-dbx-team-a"
```

| Group | Intended members | Role in the system |
|---|---|---|
| `ad-dbx` | Platform / infra engineers | Metastore owner, endpoint `CAN_MANAGE`, UC `ALL_PRIVILEGES` |
| `ad-dbx-team-a` | Team-A data scientists | team-a and team-b workspace access + endpoint `CAN_QUERY` |
| `PowerBI_users` | BI / reporting consumers | Read-only catalogs, no endpoint access |

Adding a new team requires two changes:
1. Add the team name to `teams` in `environments/account/terraform.tfvars` → creates the `ad-dbx-<team>` group.
2. Add the group name to `consumer_groups` in the target hub's `terraform.tfvars` → grants workspace membership and `CAN_QUERY`.

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

### Dev environment assignments

```
team-a workspace
  workspace_groups = ["ad-dbx-team-a"]
  consumer_groups  = ["ad-dbx"]
  → ad-dbx-team-a gets USER on team-a workspace
  → ad-dbx gets USER on team-a workspace

team-b workspace
  workspace_groups = ["ad-dbx-team-b"]
  consumer_groups  = ["ad-dbx", "ad-dbx-team-a"]
  → ad-dbx-team-b gets USER on team-b workspace
  → ad-dbx + ad-dbx-team-a get USER on team-b workspace (consumers)
```

---

## Layer 4 — Unity Catalog Privileges

Granted in `modules/unity-catalog/main.tf` using `databricks_grant` resources.

```
Metastore (shared, one per region)
  ├── ad-dbx-team-a (via workspace_groups on team-a)
  │     CREATE_CATALOG, CREATE_EXTERNAL_LOCATION, CREATE_STORAGE_CREDENTIAL
  │
  └── ad-dbx-team-b (via workspace_groups on team-b)
        CREATE_CATALOG, CREATE_EXTERNAL_LOCATION, CREATE_STORAGE_CREDENTIAL

Catalog: llmlogs  (platform inference logs — owned by platform workspace)
  └── ad-dbx  → ALL_PRIVILEGES  (inference_admin_groups on platform)

  inference_writer_groups on platform:
    ad-dbx-team-a, ad-dbx-team-b  → USE_CATALOG + USE_SCHEMA + MODIFY + CREATE_TABLE
    (write only — no SELECT; read is reserved to admins)

Catalog: main  (per-workspace, created per team)
  └── ad-dbx-team-a/team-b → ALL_PRIVILEGES (workspace_groups)

Schema: model_serving_logs  (inside llmlogs catalog)
  └── created by unity-catalog module, owned by uc_owner_group (ad-dbx)
```

### Read-only grant (reader groups)

```
PowerBI_users (if added to reader_groups)
  USE_CATALOG, USE_SCHEMA, SELECT, EXECUTE, READ_VOLUME
  on both the main catalog and the inference catalog
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
environments/dev/team-a/terraform.tfvars
  consumer_groups            = ["ad-dbx", "ad-dbx-team-b"]
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

### Endpoint permission matrix (team-a dev)

| Endpoint | `ad-dbx` | `ad-dbx-team-a` | `PowerBI_users` |
|---|---|---|---|
| `azure-gpt-4o` | CAN_MANAGE | CAN_QUERY | — |
| `azure-gpt-5-mini` | CAN_MANAGE | CAN_QUERY | — |
| `azure-gpt-5-4` | CAN_MANAGE | CAN_QUERY | — |
| `azure-text-embedding-ada-002` | CAN_MANAGE | CAN_QUERY | — |
| `dbrx-claude-sonnet-4-6` | CAN_MANAGE | CAN_QUERY | — |
| `azure-gpt-chat-fallback` (fallback router) | CAN_MANAGE | CAN_QUERY | — |

---

## End-to-End Access Flow

The diagram below walks a team-a user through the full request path from login to inference.

```
Team-A user
    │
    │  1. Authenticates via Entra ID
    ▼
account group: ad-dbx-team-a
    │
    │  2. databricks_mws_permission_assignment → USER on team-a workspace
    ▼
team-a workspace (login granted)
    │
    │  3. databricks_permissions → CAN_QUERY on model-serving endpoints
    ▼
Model-serving endpoint (e.g. azure-gpt-4o)
    │
    │  4. AI gateway enforces:
    │     • rate limits (60 calls/min per endpoint, 20/min per user)
    │     • guardrails (PII masking, safety filters, input/output)
    │     • writes payload to inference table (llmlogs.model_serving_logs.team_a_azure_gpt4o_payload)
    ▼
SP: <workspace>-model-serving
    │
    │  5. azurerm_role_assignment → Cognitive Services OpenAI User
    ▼
Azure AI Foundry (gpt-4o deployment)
    │
    │  6. Response returned through gateway → user
    ▼
Team-A user receives answer
```

---

## How to Grant Access to a New Team

1. **Create the account-level group** — add the team name to `teams` in `environments/account/terraform.tfvars` and apply.

2. **Grant workspace + endpoint access** — add the new group to `consumer_groups` in the hub's `terraform.tfvars` and apply.

```hcl
# environments/dev/team-a/terraform.tfvars
consumer_groups = [
  "ad-dbx",
  "ad-dbx-team-b",   # ← grant team-b CAN_QUERY on team-a endpoints
]
```

That single change propagates through three resources:
- `databricks_mws_permission_assignment` (workspace USER)
- `databricks_permissions` on every endpoint (CAN_QUERY)

3. **Optional — UC write access**: if the team needs to write data (not just query models), add them to `workspace_groups` in their own workspace's `terraform.tfvars` and set `create_main_catalog = true`.

---

## How to Restrict Access (Rate Limits & Guardrails)

Rate limits and guardrails are set per team workspace in `terraform.tfvars` and apply to **all endpoints** in that workspace.

```hcl
# environments/dev/team-a/terraform.tfvars
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

## Per-Team Endpoint Ownership

```
                Databricks Account
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
    platform ws    team-a ws    team-b ws
    (model_serving (model_serving (model_serving
     =false)        =true)         =true)
          │            │            │
          │ owns        │ owns        │ owns
          │ llmlogs     │ endpoints   │ endpoints
          │ catalog     │ + writes    │ + writes
          │             │ inference   │ inference
          │             │ rows        │ rows
          └─────────────┴────────────┘
                   unified metastore
               (shared, account level)
```

- **platform**: owns the centralised `llmlogs` inference catalog. No endpoints. Admin-only read.
- **team-a / team-b**: each team deploys its own governed, rate-limited, guarded endpoints. Teams share the same inference catalog for consolidated audit and cost attribution.

Adding a new team deploys a new `environments/{env}/team-{x}/` stack without touching any other workspace.

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
FROM llmlogs.model_serving_logs.azure_gpt4o_payload
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;
```

`system.serving.endpoint_usage` provides aggregated token counts per endpoint per principal if a lighter query is preferred.

**When a separate endpoint is justified** (not just for cost allocation):
- The app requires a different model or a fine-tuned variant
- The app needs different guardrails (e.g. no PII masking for an internal tool)
- Hard rate-limit isolation is required so one app cannot affect another's quota
- Compliance requires traffic from different consumers to never mix
