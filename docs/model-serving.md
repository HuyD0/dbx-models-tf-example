# Model Serving

This is the heart of the project. The
[`modules/model-serving`](../modules/model-serving) module turns the
`dbx-dev` workspace into a self-contained OpenAI-compatible gateway in
front of:

- **Azure AI Foundry** deployments (GPT-4o, GPT-5-mini, GPT-5.4,
  text-embedding-ada-002), reached via `provider = "openai"` external models.
- **Databricks-hosted foundation models** (Claude Sonnet 4.6, Opus 4.6,
  Opus 4.7 today; add Llama / Mistral / GTE the same way), reached via
  `system.ai.*` served entities.
- **An optional fallback router** (`azure-gpt-chat-fallback`) that fronts the
  external endpoints so 5xx responses are silently retried against a
  secondary model.
- **A disabled-foundation-endpoints block** that pins every non-approved
  foundation model at `rate_limits { calls = 0 }`, so only the
  blessed Claude versions are reachable from the workspace.

Every endpoint has the AI gateway turned on with **usage tracking**,
**rate limits**, and (for external endpoints) **inference tables**.
Inference tables land directly in the `main` Unity Catalog catalog that
`dbx-dev` owns (`inference_table_catalog = "main"`), under the
`model_serving_logs` schema. `inference_table_prefix` still exists as a
mechanism on the module — e.g. for allocating cost by application within
this single workspace — but there's no longer a per-team prefix need
since there's only one workspace.

---

## 1. Endpoint catalog

Defaults and the approved-model allowlists are managed in a single YAML
file that ships with the module:

```
modules/model-serving/model_defaults.yaml
```

The file has four top-level sections:

| Section | Purpose |
|---|---|
| `allowed_external_models` | Approved Azure OpenAI model names. Terraform will refuse to plan any external endpoint whose `model` is not listed here. |
| `allowed_foundation_entities` | Approved `system.ai.*` entity names. Same enforcement for foundation endpoints. |
| `external_endpoints` | Default Azure OpenAI endpoints created when `var.external_endpoints = null`. |
| `foundation_endpoints` | Default Databricks Foundation Model endpoints when `var.foundation_endpoints = null`. |
| `disabled_foundation_models` | Foundation model names blocked at rate_limit = 0. |

The YAML is validated on every commit and PR by a `check-jsonschema`
pre-commit hook and a dedicated `schema-check` CI job — both use
`modules/model-serving/model_defaults.schema.json`. Override defaults
per environment with the `model_serving_external_endpoints` and
`model_serving_foundation_endpoints` variables.

### External (Azure AI Foundry)

| Endpoint name | Model | Task | Inference table prefix |
|---|---|---|---|
| `azure-gpt-4o` | `gpt-4o` | `llm/v1/chat` | `azure_gpt4o` |
| `azure-gpt-5-mini` | `gpt-5-mini` | `llm/v1/chat` | `azure_gpt5mini` |
| `azure-gpt-5-4` | `gpt-5.4` | `llm/v1/chat` | `azure_gpt54` |
| `azure-text-embedding-ada-002` | `text-embedding-ada-002` | `llm/v1/embeddings` | `azure_embeddings` |

Each external endpoint is a single-served-entity `databricks_model_serving`
with `external_model.provider = "openai"` and `openai_api_type = "azuread"`.
Authentication uses the dedicated SP `dbw-model-serving` and the
`Cognitive Services OpenAI User` role on the Foundry account — see
[architecture.md](architecture.md) for why a managed identity can't be used.

### Foundation (Databricks-hosted)

| Endpoint name | Entity | Notes |
|---|---|---|
| `databricks-claude-sonnet-4-6` | `system.ai.claude_sonnet_4_6` v1 | Pay-per-token, no SP, no secret |
| `databricks-claude-opus-4-6`   | `system.ai.claude_opus_4_6`   v1 | Pay-per-token, no SP, no secret |
| `databricks-claude-opus-4-7`   | `system.ai.claude_opus_4_7`   v1 | Pay-per-token, no SP, no secret |

Foundation endpoints carry usage tracking and rate limits but **do not
support `inference_table_config`** — payloads are not captured. Use the
`system.serving.*` system tables for these (see §3.2 below).

### Disabled foundation endpoints (blocklist)

The module additionally renders a `databricks_model_serving.disabled_
foundation_endpoints` for_each over a blocklist of model names. Each
entry creates an endpoint configured to point at the model but with
`rate_limits { calls = 0 }`, so calls are rejected at the gateway. This
is the supported way to **prevent users from invoking the long tail of
Databricks foundation models** that this platform has not approved.

Defaults live in the `disabled_foundation_models` list in
`modules/model-serving/model_defaults.yaml` and include
the older Claude variants (sonnet-4-5, haiku-4-5, opus-4-5, opus-4-1,
sonnet-4), the GPT-OSS, Qwen3, Llama 4, Gemma 3, and embedding models.
Override per env via `model_serving_disabled_foundation_models` (a
full list — passing `[]` re-enables everything; passing `null` keeps
the module default from the YAML).

### Fallback router (optional)

When `model_serving_fallback_enabled = true`, the module additionally
creates `azure-gpt-chat-fallback`, a 2-served-entity endpoint:

```text
azure-gpt-chat-fallback
├── served_entity: gpt-4o-primary       traffic 100%   ──► azure-gpt-4o
└── served_entity: gpt-5-mini-fallback  traffic   0%   ──► azure-gpt-5-mini
```

`fallback_config.enabled = true` makes the gateway re-issue any 5xx
response against the next entity automatically. Steady-state traffic still
follows `traffic_config` (100/0), so the fallback is invisible to callers
when the primary is healthy. See §5 for the full picture.

### Adding an endpoint

> **Always add to the allowlist first.** Terraform enforces `lifecycle
> { precondition }` on both resource loops — any `model` or
> `entity_name` not in `allowed_external_models` /
> `allowed_foundation_entities` causes a hard plan failure with a
> descriptive error message.

**Step 1 — update the YAML allowlist** (`modules/model-serving/model_defaults.yaml`):

```yaml
# extend the approved list
allowed_external_models:
  - gpt-4o
  - gpt-4-turbo   # ← add before referencing it anywhere
```

**Step 2a — add to the module defaults** (new model for every workspace):

```yaml
external_endpoints:
  azure-gpt-4-turbo:
    model: gpt-4-turbo
    deployment_name: gpt-4-turbo
    task: llm/v1/chat
    table_prefix: azure_gpt4turbo
```

**Step 2b — or add only for one environment** via `additional_external_endpoints` in `terraform.tfvars`:

```hcl
model_serving_additional_external_endpoints = {
  "azure-gpt-4-turbo" = {
    model           = "gpt-4-turbo"
    deployment_name = "gpt-4-turbo"
    task            = "llm/v1/chat"
    table_prefix    = "azure_gpt4turbo"
  }
}
```

The deployment with `deployment_name` must exist in the Foundry account
named by `var.ai_foundry_name`. Same SP, same RBAC, same gateway settings.

Foundation (same two-step pattern):

```yaml
# model_defaults.yaml
allowed_foundation_entities:
  - system.ai.claude_sonnet_4_6
  - system.ai.llama_3_70b   # ← add first

foundation_endpoints:
  databricks-llama-3-70b:
    entity_name: system.ai.llama_3_70b
    entity_version: "1"
```

Or per-environment only via `model_serving_additional_foundation_endpoints` in `terraform.tfvars`.

---

## 2. AI gateway configuration

Every endpoint declared by the module gets the same `ai_gateway { … }`
block:

```hcl
ai_gateway {
  usage_tracking_config { enabled = true }

  dynamic "rate_limits" { for_each = var.rate_limits ... }

  inference_table_config {           # external endpoints only
    enabled           = true
    catalog_name      = var.inference_table_catalog
    schema_name       = var.inference_table_schema
    table_name_prefix = each.value.table_prefix
  }

  fallback_config { enabled = true } # only on the fallback router
}
```

### 2.1 Usage tracking (`usage_tracking_config`)

Always on. Writes one row per request to `system.serving.endpoint_usage`
with: timestamp, workspace, endpoint name, served entity name, status
code, latency, prompt/completion tokens, and the calling principal
(workspace user, SP, or `<unknown>` for cluster-scoped PATs). This is the
canonical source for cost attribution and SLO dashboards because it covers
**every** endpoint — external, foundation, and fallback router.

### 2.2 Inference tables (`inference_table_config`)

External endpoints only. Writes the **full request/response payload**
(prompt, completion, tools, headers) plus token usage, status code, and
latency to:

```
<inference_table_catalog>.<inference_table_schema>.<workspace_prefix><table_prefix>_payload
```

Defaults in this repo: `main.model_serving_logs.<prefix>_payload`, where
`<prefix>` is the endpoint's `table_prefix` from `model_defaults.yaml`
(optionally combined with `var.inference_table_prefix` if set). Example:
`main.model_serving_logs.azure_gpt4o_payload`.

The `main` catalog and its `model_serving_logs` schema are owned directly
by the `dbx-dev` workspace (`create_main_catalog = true`), so there are no
cross-workspace writer grants to manage — `workspace_groups` on `dbx-dev`
already get `ALL_PRIVILEGES` on the catalog, including `SELECT`. Tables can
take a few minutes to materialise after an endpoint is first created.

> Foundation endpoints do **not** support inference tables. To capture
> Claude prompts/completions, route them through the fallback router or
> add an MLflow tracing layer on the caller side.

#### Per-application cost allocation

With a single workspace there's no more need to break costs down by
team/workspace prefix — the multi-team example that used to live here
(`table_name LIKE 'team_a_%' / 'team_b_%'`) no longer applies. Since all
requests already land in the same `main.model_serving_logs` schema, the
straightforward way to allocate cost within `dbx-dev` is per-application,
by having apps pass an `X-App-ID` header — it lands in `request_metadata`
(see [access-control.md](access-control.md#cost-allocation-by-application)
for the query). `inference_table_prefix` still exists as a mechanism on the
module if per-app table separation is ever wanted instead of a header-based
split.

### 2.3 Rate limits (`rate_limits`)

Configured globally via the `model_serving_rate_limits` variable; the
module renders one `rate_limits` block per rule on every endpoint:

```hcl
model_serving_rate_limits = [
  # Per-user guard against runaway notebooks
  { calls = 60,   tokens = 50000,   key = "user",     renewal_period = "minute" },
  # Endpoint-wide ceiling to protect the Foundry quota
  { calls = 5000, tokens = 2000000, key = "endpoint", renewal_period = "minute" },
]
```

Rule fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `calls` | yes | — | Max requests per `renewal_period` |
| `tokens` | no | `null` | Optional token budget per `renewal_period` |
| `key` | no | `endpoint` | `user`, `endpoint`, or `principal` |
| `renewal_period` | no | `minute` | `minute` is currently the only supported value |
| `principal` | no | `null` | Pin a rule to a specific user/SP |

Per-user limits require the caller to authenticate as a Databricks
identity. Calls made with a generic workspace PAT all collapse into the
same `endpoint` bucket.

### 2.4 Fallback (`fallback_config`)

Only set on `azure-gpt-chat-fallback`. With `enabled = true` the gateway:

1. Sends the request to the entity selected by `traffic_config` (the
   primary, by weight 100).
2. If the upstream returns a 5xx, retries against the next served entity
   in declaration order (the fallback) without changing the response to
   the caller beyond a `Retry-After`-style header.
3. Still records the original failure in `system.serving.endpoint_usage`
   so retries are observable.

Fallback does not retry on 4xx, so input validation errors surface
immediately.

---

## 3. Logging & usage queries

### 3.1 Inference tables (full payloads, external endpoints)

```sql
-- Last 50 GPT-4o requests with latency, tokens, and the rendered prompt
SELECT
  request_time,
  status_code,
  execution_time_ms,
  request:messages         AS prompt,
  response:choices         AS completion,
  response:usage.prompt_tokens     AS prompt_tokens,
  response:usage.completion_tokens AS completion_tokens
FROM main.model_serving_logs.azure_gpt4o_payload
ORDER BY request_time DESC
LIMIT 50;
```

```sql
-- 24h spend per principal across every external chat endpoint
SELECT
  request_metadata['user-id'] AS principal,
  endpoint_name,
  SUM(response:usage.prompt_tokens)     AS prompt_tokens,
  SUM(response:usage.completion_tokens) AS completion_tokens
FROM main.model_serving_logs.azure_gpt4o_payload
WHERE request_time > current_timestamp() - INTERVAL 24 HOURS
GROUP BY 1, 2
ORDER BY prompt_tokens + completion_tokens DESC;
```

### 3.2 `system.serving.endpoint_usage` (every endpoint)

This is the only usage source for foundation endpoints, and the
authoritative source for SLOs everywhere else.

```sql
-- Error rate per endpoint over the last hour
SELECT
  endpoint_name,
  status_code,
  COUNT(*) AS calls,
  AVG(execution_time_ms) AS avg_latency_ms
FROM system.serving.endpoint_usage
WHERE request_time > current_timestamp() - INTERVAL 1 HOURS
GROUP BY 1, 2
ORDER BY 1, 2;
```

```sql
-- Fallback effectiveness: how often did the secondary entity get hit?
SELECT
  served_entity_name,
  COUNT(*) AS calls
FROM system.serving.endpoint_usage
WHERE endpoint_name = 'azure-gpt-chat-fallback'
  AND request_time > current_timestamp() - INTERVAL 24 HOURS
GROUP BY 1;
```

```sql
-- Token spend including foundation models (Claude has no inference table)
SELECT
  endpoint_name,
  SUM(input_token_count)  AS input_tokens,
  SUM(output_token_count) AS output_tokens
FROM system.serving.endpoint_usage
WHERE request_time > current_timestamp() - INTERVAL 7 DAYS
GROUP BY 1
ORDER BY input_tokens + output_tokens DESC;
```

### 3.3 Suggested dashboards

In Databricks SQL, build:

- **Cost & usage** — token totals per endpoint per day from
  `system.serving.endpoint_usage`.
- **Reliability** — 5xx rate per endpoint, plus fallback hit rate on
  `azure-gpt-chat-fallback`.
- **Top consumers** — per-principal token spend from inference tables.
- **Prompt audit** — `WHERE response:choices LIKE '%refused%'` or content-
  safety flags from a downstream classifier.

Wire alerts (Databricks SQL Alerts or Lakehouse Monitoring) on the same
queries to catch budget breaches and elevated error rates.

---

## 4. Calling an endpoint

All endpoints (external, foundation, fallback router) share the same
OpenAI-compatible surface:

```text
POST https://<workspace-host>/serving-endpoints/<endpoint-name>/invocations
Authorization: Bearer <DATABRICKS_TOKEN>
```

`<endpoint-name>` is the key from the relevant map (e.g. `azure-gpt-4o`,
`databricks-claude-sonnet-4-6`, `azure-gpt-chat-fallback`). For chat endpoints the
body is OpenAI-format:

```bash
curl -X POST \
  -H "Authorization: Bearer $DATABRICKS_TOKEN" \
  -H "Content-Type: application/json" \
  https://adb-xxx.azuredatabricks.net/serving-endpoints/azure-gpt-chat-fallback/invocations \
  -d '{
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 64
      }'
```

OpenAI Python SDK pointed at the gateway:

```python
from openai import OpenAI
client = OpenAI(
    base_url=f"{WORKSPACE_URL}/serving-endpoints",
    api_key=DATABRICKS_TOKEN,
)
client.chat.completions.create(
    model="azure-gpt-chat-fallback",   # or azure-gpt-4o, databricks-claude-sonnet-4-6
    messages=[{"role": "user", "content": "Hello"}],
)
```

> Point your applications at the **fallback router** (`azure-gpt-chat-fallback`)
> rather than the underlying `azure-gpt-4o` directly so they get retry
> behaviour for free.

---

## 5. Fallback routing in depth

The fallback endpoint is two `databricks_model_serving` resources
collaborating:

1. **Internal auth** — when `var.fallback_enabled = true`, the module
   provisions a `databricks_secret_scope` (`model-serving-internal`)
   containing a `databricks_token` with `lifetime_seconds = 7776000`
   (90 days). This PAT lets the fallback router call the underlying
   external endpoints over the workspace's own REST API.
2. **The router endpoint** — `azure-gpt-chat-fallback` declares two served
   entities, both with `provider = "databricks-model-serving"` (not
   `openai`) and a `databricks_model_serving_config` block pointing at
   `var.workspace_host` with `databricks_api_token = "{{secrets/model-serving-internal/pat}}"`.
3. **Behaviour** —
   - `traffic_config` weights determine baseline routing
     (100% to primary, 0% to fallback).
   - `fallback_config.enabled` triggers an automatic retry against the
     next-listed entity on 5xx.
   - Both legs of a fallback show up as separate rows in
     `system.serving.endpoint_usage` keyed by `served_entity_name`.

### Why not fall back directly to Foundry?

The fallback router uses `provider = "databricks-model-serving"` so that
Databricks can chain across multiple served entities; that requires the
target to be another model-serving endpoint, not a raw Foundry deployment.
Wrapping every Foundry deployment as its own external endpoint (which the
module already does) makes any of them eligible as a fallback target.

### Operating the fallback PAT

The PAT expires in 90 days. To rotate without downtime:

```bash
terraform apply -replace='module.model_serving.databricks_token.model_serving_chaining[0]'
```

The secret value updates atomically and the served entities pick up the
new token via the secret reference on next request — no endpoint redeploy
needed. Schedule this on a cron (CI cron, Azure DevOps schedule, etc.) to
satisfy NIST IA-5.

---

## 6. Identity & secrets summary

| Identity / secret | Used by | Rotation |
|---|---|---|
| `azuread_application.model_serving` + `azuread_service_principal_password.model_serving` | External endpoints to authenticate to Azure AI Foundry | `terraform apply -replace='module.model_serving.azuread_service_principal_password.model_serving'` |
| `databricks_token.model_serving_chaining` | Fallback router to call sibling endpoints | 90-day TTL; rotate as above |
| Access Connector MSI (in workspace module) | Unity Catalog → ADLS Gen2 | Azure-managed |

The SP password and the chaining PAT are the only long-lived secrets in
the system. Both live in Terraform state — keep the state backend
private (the `bootstrap/` storage account uses `use_azuread_auth` and
versioning).

---

## 7. Variables reference (model-serving module)

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `ai_foundry_name` | string | — | Foundry account exposing the `*OpenAI*` deployments |
| `ai_foundry_resource_group` | string | — | RG of the Foundry account |
| `openai_api_version` | string | `2024-12-01-preview` | API version on every external endpoint |
| `inference_table_catalog` | string | `main` | UC catalog for payload tables |
| `inference_table_schema` | string | `model_serving_logs` | UC schema for payload tables |
| `external_endpoints` | map(object) | `null` (uses `model_defaults.yaml`) | Override the Azure OpenAI endpoint catalog; `null` loads defaults from YAML |
| `additional_external_endpoints` | map(object) | `{}` | Merge extra external endpoints on top of the active set without replacing it |
| `foundation_models_enabled` | bool | `true` | Toggle the foundation block off entirely |
| `foundation_endpoints` | map(object) | `null` (uses `model_defaults.yaml`) | Override the foundation endpoint catalog; `null` loads defaults from YAML |
| `additional_foundation_endpoints` | map(object) | `{}` | Merge extra foundation endpoints on top of the active set without replacing it |
| `disabled_foundation_models` | list(string) | `null` (uses `model_defaults.yaml`) | Blocklist of foundation model names pinned at rate_limit = 0; `null` loads defaults from YAML |
| `rate_limits` | list(object) | `[]` | Applied identically to every endpoint |
| `fallback_enabled` | bool | `false` | Provision the `azure-gpt-chat-fallback` router + chaining PAT |
| `workspace_host` | string | `null` | Required when `fallback_enabled = true`; used in the chaining config |
