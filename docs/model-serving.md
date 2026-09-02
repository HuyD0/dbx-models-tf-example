# Model Serving

This is the heart of the project. The
[`modules/model-serving`](../modules/model-serving) module turns the
`dbx-dev` workspace into a self-contained OpenAI-compatible gateway in
front of:

- **Azure AI Foundry** deployments (GPT-4o, GPT-5-mini, GPT-5.4,
  text-embedding-ada-002), reached via `provider = "openai"` external models.
- **Databricks-hosted foundation models** (Claude Sonnet 4.6, Opus 4.6,
  Opus 4.7 today; add Llama / Mistral / GTE the same way) — the
  pre-provisioned pay-per-token `databricks-*` endpoints serving
  `system.ai.*` entities, governed in place rather than created by
  Terraform.
- **An optional fallback endpoint** (`azure-gpt-chat-fallback`) that serves
  the primary and secondary Foundry deployments on one endpoint, so
  failed requests are silently retried against the secondary model.
- **A blocklist for non-approved foundation models**: every endpoint listed
  in `disabled_foundation_models` is pinned at `rate_limits: calls = 0`
  by `scripts/apply-ai-gateway.sh` (Terraform cannot manage the reserved
  `databricks-*` endpoints). Note this is a **deny-list, and it fails
  open**: a newly released `databricks-*` endpoint is callable until
  someone adds it to the YAML.

Every endpoint has the AI gateway turned on with **usage tracking**,
**rate limits**, and **inference tables** — set inline by Terraform on the
endpoints it manages, and PUT by the reconciler script onto the governed
foundation endpoints. Inference tables land in the `main` Unity Catalog
catalog that `dbx-dev` owns (`inference_table_catalog = "main"`), under
the `model_serving_logs` schema. Table names carry a workspace prefix:
`workspace-stack` passes `coalesce(var.inference_table_prefix, var.team)`
to the module, so in `dbx-dev` (team `dbx-dev`) every table starts with
`dbx_dev_`.

---

## 1. Endpoint catalog

Defaults and the approved-model allowlists are managed in a single YAML
file that ships with the module:

```
modules/model-serving/model_defaults.yaml
```

The file has six top-level sections:

| Section | Purpose |
|---|---|
| `allowed_external_models` | Approved external model names (Azure OpenAI or other providers). Terraform will refuse to plan any external endpoint whose `model` is not listed here (a `lifecycle { precondition }`). |
| `allowed_foundation_entities` | Approved `system.ai.*` entity names. **Documentation/audit only** — nothing reads this list to enforce anything. |
| `external_endpoints` | Default external endpoints created when `var.external_endpoints = null`. Optional `provider` (`openai` default / `anthropic`) and `api_key_secret` fields per entry. |
| `foundation_endpoints` | Pre-provisioned `databricks-*` endpoints governed in place by `scripts/apply-ai-gateway.sh` (rate limits + inference tables); each entry carries its `table_prefix`. |
| `disabled_foundation_models` | Pre-provisioned `databricks-*` endpoint names blocked at rate_limit = 0 by the same script. |
| `gateway_defaults` | Default AI Gateway policy — endpoint/user rate limits (QPM/TPM), optional per-group limits, optional guardrails — applied by Terraform to external endpoints and by the script to foundation endpoints. |

The YAML is validated on every commit and PR by a `check-jsonschema`
pre-commit hook and the CI validate job — both use
`modules/model-serving/model_defaults.schema.json`. Override the external
endpoint set per environment with the `model_serving_external_endpoints`
and `model_serving_additional_external_endpoints` variables; foundation
governance is YAML-only.

### External (Azure AI Foundry)

| Endpoint name | Model | Task | Inference table prefix |
|---|---|---|---|
| `azure-gpt-4o` | `gpt-4o` | `llm/v1/chat` | `azure_gpt4o` |
| `azure-gpt-5-mini` | `gpt-5-mini` | `llm/v1/chat` | `azure_gpt5mini` |
| `azure-gpt-5-4` | `gpt-5.4` | `llm/v1/chat` | `azure_gpt54` |
| `azure-text-embedding-ada-002` | `text-embedding-ada-002` | `llm/v1/embeddings` | `azure_embeddings` |

Each external endpoint is a single-served-entity `databricks_model_serving`
with `external_model.provider = "openai"` and `openai_api_type = "azuread"`.
Authentication uses the dedicated SP `<name_prefix>-model-serving`
(`dbx-dev-model-serving` in dev — workspace-stack passes the workspace
name as `name_prefix`) and the
`Cognitive Services OpenAI User` role on the Foundry account — see
[architecture.md](architecture.md) for why a managed identity can't be used.

### Foundation (Databricks-hosted)

| Endpoint name | Entity | Notes |
|---|---|---|
| `databricks-claude-sonnet-4-6` | `system.ai.databricks-claude-sonnet-4-6` | Pay-per-token, no SP, no secret |
| `databricks-claude-opus-4-6`   | `system.ai.databricks-claude-opus-4-6`   | Pay-per-token, no SP, no secret |
| `databricks-claude-opus-4-7`   | `system.ai.databricks-claude-opus-4-7`   | Pay-per-token, no SP, no secret |

These endpoints exist automatically in every workspace and cannot be
created, updated, or deleted by Terraform (reserved name prefix), so the
reconciler script applies the governance instead: usage tracking, the
`gateway_defaults` rate limits, **and inference tables** —
`inference_table_config { enabled: true }` with the per-endpoint
`table_prefix` from the YAML. Payloads for the approved Claude endpoints
land in the same `main.model_serving_logs` schema as the external ones.

### Disabled foundation endpoints (blocklist)

The pre-provisioned `databricks-*` endpoints cannot be created, updated,
or deleted by Terraform (reserved name prefix), so blocking happens
out-of-band: `scripts/apply-ai-gateway.sh` PUTs an AI-gateway config with
`rate_limits: [{ calls: 0, key: "endpoint" }]` on every endpoint listed in
`disabled_foundation_models`, so calls are rejected with HTTP 429 at the
gateway (usage tracking stays on, so attempts are still audited). This is
the supported way to **prevent users from invoking the long tail of
Databricks foundation models** that this platform has not approved.

Two honest caveats about this mechanism:

- **It is fail-open.** Blocking is a deny-list, and
  `allowed_foundation_entities` is audit documentation, not an enforced
  allowlist. When Databricks rolls out a new `databricks-*` endpoint it is
  fully callable until someone notices and adds it to
  `disabled_foundation_models`.
- **Drift between applies is not caught.** The script attempts every
  endpoint and any failed PUT fails the script — and therefore
  `terraform apply` — so a green apply does mean every block landed. But
  the reconciler re-runs only when one of its triggers changes (the YAML
  hash, workspace URL, or table prefix/catalog/schema) or when run
  manually — a no-op apply does not re-run it, so an out-of-band UI
  change stays in effect until then. Schedule the script via a CI
  cron or Databricks Job for continuous re-assertion.

The blocklist lives in `modules/model-serving/model_defaults.yaml` and
includes the older Claude variants (sonnet-4-5, haiku-4-5, opus-4-5,
opus-4-1, sonnet-4) plus the GPT-OSS, Qwen, Llama 3.x/4, Gemma 3, and
embedding (GTE/BGE/Qwen3) models. There is no per-environment override —
edit the YAML; the reconciler re-runs automatically on the next
`terraform apply` (`terraform_data.ai_gateway_reconciler` in
`modules/workspace-stack/main.tf` triggers on the YAML hash; disable with
`ai_gateway_reconcile_on_apply = false`).

### Fallback endpoint (optional)

When `model_serving_fallback_enabled = true` (the module variable is
`fallback_enabled`), the module additionally creates
`azure-gpt-chat-fallback`, a 2-served-entity endpoint:

```text
azure-gpt-chat-fallback
├── served_entity: gpt-4o-primary       traffic 100%   ──► Foundry deployment gpt-4o
└── served_entity: gpt-5-mini-fallback  traffic   0%   ──► Foundry deployment gpt-5-mini
```

`fallback_config.enabled = true` makes the gateway re-issue any 429/5xx
response against the next entity automatically. Steady-state traffic still
follows `traffic_config` (100/0), so the fallback is invisible to callers
when the primary is healthy. See §5 for the full picture.

### Adding an endpoint

> **Always add to the allowlist first.** Terraform enforces `lifecycle
> { precondition }` on the external endpoint loop — any `model` not in
> `allowed_external_models` causes a hard plan failure with a
> descriptive error message. For foundation endpoints there is no
> equivalent enforcement: `allowed_foundation_entities` is audit
> documentation only; what the reconciler actually reads is
> `foundation_endpoints` (govern) and `disabled_foundation_models`
> (block).

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

**Step 2b — or add only for one environment** via `model_serving_additional_external_endpoints` in `terraform.tfvars`:

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

External endpoints for other providers (e.g. Anthropic direct) follow the
same pattern with two extra fields — the API key is a secret *reference*
(`{{secrets/<scope>/<key>}}`) to a pre-existing workspace secret, so the
key value never enters Terraform state:

```yaml
external_endpoints:
  anthropic-claude-sonnet:
    model: claude-sonnet-4-5        # ← must be in allowed_external_models
    provider: anthropic
    api_key_secret: llm-provider-keys/anthropic-api-key
    task: llm/v1/chat
    table_prefix: anthropic_claude_sonnet
```

Foundation (governed via the reconciler, not Terraform — endpoint names
exactly as returned by `GET /api/2.0/serving-endpoints`):

```yaml
# model_defaults.yaml
foundation_endpoints:
  databricks-llama-3-70b:
    table_prefix: databricks_llama_3_70b

# keep the audit record accurate (not enforced):
allowed_foundation_entities:
  - system.ai.databricks-claude-sonnet-4-6
  - system.ai.databricks-llama-3-70b
```

(and remove the endpoint from `disabled_foundation_models` if present).

---

## 2. AI gateway configuration

Every endpoint the module manages gets the same `ai_gateway { … }` block
(and the reconciler PUTs the equivalent JSON onto the governed foundation
endpoints):

```hcl
ai_gateway {
  usage_tracking_config { enabled = true }

  dynamic "guardrails"  { for_each = ... }  # only when guardrails are configured

  dynamic "rate_limits" { for_each = local.effective_rate_limits ... }

  inference_table_config {
    enabled           = true
    catalog_name      = var.inference_table_catalog
    schema_name       = var.inference_table_schema
    table_name_prefix = "${local.table_prefix}${each.value.table_prefix}"
  }

  fallback_config { enabled = true } # only on the fallback endpoint
}
```

### 2.1 Usage tracking (`usage_tracking_config`)

Always on. Writes one row per request to `system.serving.endpoint_usage`
with: request time, workspace, status code, input/output token counts, the
calling principal (`requester`), an optional caller-supplied
`usage_context` map, and the `served_entity_id`. The table does **not**
carry endpoint or entity names — join `system.serving.served_entities` on
`served_entity_id` for those (see §3.2). This is the canonical source for
cost attribution and SLO dashboards because it covers **every** endpoint —
external, foundation, and fallback.

### 2.2 Inference tables (`inference_table_config`)

Set inline by Terraform on every endpoint it manages (external + the
fallback endpoint), and PUT by `scripts/apply-ai-gateway.sh` onto the
governed foundation endpoints — so payloads **are** captured for the
approved `databricks-*` Claude endpoints too. Each table holds the full
request/response payload (messages, completions, tool calls) plus status
code and latency:

```
<inference_table_catalog>.<inference_table_schema>.<workspace_prefix><table_prefix>_payload
```

Defaults in this repo: `main.model_serving_logs.<workspace_prefix><table_prefix>_payload`,
where `<workspace_prefix>` comes from `var.inference_table_prefix`
(workspace-stack passes `coalesce(var.inference_table_prefix, var.team)`,
so `dbx_dev_` in dev) and `<table_prefix>` is the endpoint's entry in
`model_defaults.yaml`. Example:
`main.model_serving_logs.dbx_dev_azure_gpt4o_payload`.

The `main` catalog and its `model_serving_logs` schema are owned directly
by the `dbx-dev` workspace (`create_main_catalog = true`), so there are no
cross-workspace writer grants to manage — `workspace_groups` on `dbx-dev`
already get a scoped write grant on the catalog (`USE_CATALOG`, `SELECT`,
`MODIFY`, `CREATE_TABLE`, … — everything except `MANAGE`/`APPLY_TAG`,
which stay with the owner group). Tables can take a few minutes to
materialise after an endpoint is first created, and once a table exists
the prefix can't be changed without dropping it first (see the header of
`scripts/apply-ai-gateway.sh`).

#### Per-application cost allocation

With a single serving workspace there's no need to break costs down by
team/workspace — the whole fleet already shares the `dbx_dev_` prefix in
one `main.model_serving_logs` schema. To allocate cost per **application**,
have each app pass a `usage_context` map in the request body (e.g.
`{"usage_context": {"app_id": "billing-bot"}}`): it lands in the
`usage_context` column of `system.serving.endpoint_usage`, and the raw
request body — `usage_context` included — is also captured in the
inference table's `request` column. `inference_table_prefix` still exists
as a mechanism on the module if per-app *table* separation is ever wanted
instead. See [access-control.md](access-control.md#cost-allocation-by-application)
for the chargeback angle.

### 2.3 Rate limits (`rate_limits`)

Defaults come from `gateway_defaults.rate_limits` in
`model_defaults.yaml` (endpoint QPM/TPM, per-user QPM, optional per-group
limits) — the same values `scripts/apply-ai-gateway.sh` applies to the
foundation endpoints, so the whole fleet shares one centrally-governed
policy. A workspace can override them with the
`model_serving_rate_limits` variable — but note the override reaches only
the Terraform-managed endpoints; the reconciler always applies the YAML
defaults to the foundation endpoints. The module renders one
`rate_limits` block per rule on every endpoint:

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
| `key` | no | `endpoint` | `user`, `user_group`, `service_principal`, or `endpoint` |
| `renewal_period` | no | `minute` | `minute` is currently the only supported value |
| `principal` | no | `null` | Required for `user_group` / `service_principal` keys (group display name / SP application ID) |

Databricks allows at most 20 rate limits per endpoint, of which at most 5
may be `user_group`-scoped; when both `calls` and `tokens` are set, the
more restrictive gate wins. The module's variable validations enforce the
key values, the `principal` requirement, and both count limits at plan
time.

Per-user limits require the caller to authenticate as a Databricks
identity. Calls made with a generic workspace PAT all collapse into the
same `endpoint` bucket.

### 2.4 Fallback (`fallback_config`)

Only set on `azure-gpt-chat-fallback`. With `enabled = true` the gateway:

1. Sends the request to the entity selected by `traffic_config` (the
   primary, by weight 100).
2. If the upstream returns a 429 or 5xx, retries against the next served
   entity in declaration order (the fallback) transparently to the caller.
3. Records each attempt in `system.serving.endpoint_usage` under its own
   `served_entity_id`, so retries are observable.

Fallback does not retry on other 4xx errors, so input validation errors
surface immediately.

---

## 3. Logging & usage queries

### 3.1 Inference tables (full payloads)

Column names below follow the AI Gateway-enabled inference table schema
for serving endpoints (`request_time`, `execution_duration_ms`, …); tables
created under the older auto-capture schema name some columns differently.

```sql
-- Last 50 GPT-4o requests with latency, tokens, and the rendered prompt
SELECT
  request_time,
  status_code,
  execution_duration_ms,
  request:messages         AS prompt,
  response:choices         AS completion,
  response:usage.prompt_tokens     AS prompt_tokens,
  response:usage.completion_tokens AS completion_tokens
FROM main.model_serving_logs.dbx_dev_azure_gpt4o_payload
ORDER BY request_time DESC
LIMIT 50;
```

```sql
-- 24h spend per principal on the GPT-4o endpoint
SELECT
  requester,
  SUM(response:usage.prompt_tokens)     AS prompt_tokens,
  SUM(response:usage.completion_tokens) AS completion_tokens
FROM main.model_serving_logs.dbx_dev_azure_gpt4o_payload
WHERE request_time > current_timestamp() - INTERVAL 24 HOURS
GROUP BY 1
ORDER BY prompt_tokens + completion_tokens DESC;
```

### 3.2 `system.serving.endpoint_usage` (every endpoint)

Covers the whole fleet and is the authoritative source for SLOs. Rows are
keyed by `served_entity_id` — join `system.serving.served_entities` to get
endpoint and entity names.

```sql
-- Error rate per endpoint over the last hour
SELECT
  se.endpoint_name,
  u.status_code,
  COUNT(*) AS calls
FROM system.serving.endpoint_usage u
JOIN system.serving.served_entities se USING (served_entity_id)
WHERE u.request_time > current_timestamp() - INTERVAL 1 HOURS
GROUP BY 1, 2
ORDER BY 1, 2;
```

(Latency is not in `endpoint_usage` — use the inference tables'
`execution_duration_ms` for that.)

```sql
-- Fallback effectiveness: how often did the secondary entity get hit?
SELECT
  se.served_entity_name,
  COUNT(*) AS calls
FROM system.serving.endpoint_usage u
JOIN system.serving.served_entities se USING (served_entity_id)
WHERE se.endpoint_name = 'azure-gpt-chat-fallback'
  AND u.request_time > current_timestamp() - INTERVAL 24 HOURS
GROUP BY 1;
```

```sql
-- Token spend per endpoint over the last 7 days (foundation + external)
SELECT
  se.endpoint_name,
  SUM(u.input_token_count)  AS input_tokens,
  SUM(u.output_token_count) AS output_tokens
FROM system.serving.endpoint_usage u
JOIN system.serving.served_entities se USING (served_entity_id)
WHERE u.request_time > current_timestamp() - INTERVAL 7 DAYS
GROUP BY 1
ORDER BY input_tokens + output_tokens DESC;
```

### 3.3 Suggested dashboards

In Databricks SQL, build:

- **Cost & usage** — token totals per endpoint per day from
  `system.serving.endpoint_usage` joined to `served_entities`.
- **Reliability** — 5xx rate per endpoint, plus fallback hit rate on
  `azure-gpt-chat-fallback`.
- **Top consumers** — per-principal (`requester`) token spend from
  inference tables.
- **Prompt audit** — `WHERE response:choices LIKE '%refused%'` or content-
  safety flags from a downstream classifier.

Wire alerts (Databricks SQL Alerts or Lakehouse Monitoring) on the same
queries to catch budget breaches and elevated error rates.

### 3.4 Agent-waste alerts (retry loops, silent tool failures)

The module can generate the reliability alerts for you: set
`model_serving_agent_waste_monitors` (a SQL warehouse ID + recipients)
and it creates scheduled `databricks_alert_v2` resources — per-requester
error loops, per-endpoint error rate, attempts against deny-listed
`databricks-*` endpoints and, opt-in, sessions whose prompts keep carrying
tool-call errors (the pattern behind Databricks' "$1M/year of wasted agent
spend" write-up). The SQL is generated from the endpoint catalog and the
inference-table names above, so it tracks this file's configuration. The
analysis queries, the `usage_context.session_id` convention they depend
on, and the tool-fix checklist are in
[agent-spend-waste.md](agent-spend-waste.md).

---

## 4. Calling an endpoint

All endpoints (external, foundation, fallback) share the same
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

> Point your applications at the **fallback endpoint** (`azure-gpt-chat-fallback`)
> rather than the underlying `azure-gpt-4o` directly so they get retry
> behaviour for free.

---

## 5. Fallback routing in depth

The fallback is **one endpoint**, not a router in front of others:
`databricks_model_serving.gpt_chat_fallback` in
[`modules/model-serving/main.tf`](../modules/model-serving/main.tf),
created when `fallback_enabled = true`.

1. **Two served entities, one endpoint** — `gpt-4o-primary` and
   `gpt-5-mini-fallback` are both declared as direct `external_model`
   served entities with `provider = "openai"`, each pointing at its own
   Foundry deployment (`gpt-4o` / `gpt-5-mini`) and authenticating with
   the same SP client-secret reference
   (`{{secrets/<name_prefix>-model-serving-scope/sp-client-secret}}`) as
   the standalone external endpoints. No extra credential is minted.
2. **Baseline routing** — `traffic_config` weights the primary at 100%
   and the fallback at 0%, so the secondary is idle while the primary is
   healthy.
3. **Retry behaviour** — `ai_gateway { fallback_config { enabled = true } }`
   makes the gateway retry a 429/5xx from the primary against the
   next-listed entity automatically.
4. **Observability** — both legs of a fallback show up as separate rows in
   `system.serving.endpoint_usage` (join `served_entities` for the
   `served_entity_name`), and the endpoint has its own inference table
   (`…azure_gpt_chat_fallback_payload`).

### Why not a chaining router?

The obvious alternative — a router endpoint whose served entities point at
the sibling `azure-gpt-4o` / `azure-gpt-5-mini` endpoints via
`provider = "databricks-model-serving"` and a workspace token — is
rejected by the platform: *"Requests to external models from Databricks
model serving are not permitted"* (see the comment above
`gpt_chat_fallback` in the module). Declaring both Foundry deployments as
served entities on the **same** endpoint sidesteps the restriction
entirely, and means there is no PAT, no extra secret scope, and nothing
new to rotate.

---

## 6. Identity & secrets summary

| Identity / secret | Used by | Rotation |
|---|---|---|
| `azuread_application.model_serving` + `azuread_service_principal_password.model_serving` | External + fallback endpoints authenticate to Azure AI Foundry (Entra client credentials) | `terraform apply -replace='module.stack.module.model_serving[0].azuread_service_principal_password.model_serving'` |
| `databricks_secret.sp_client_secret` in scope `<name_prefix>-model-serving-scope` | Endpoints consume the SP password via the `{{secrets/…/sp-client-secret}}` reference — the value never appears in endpoint configs or API responses | Updated automatically when the SP password is replaced |
| Access Connector MSI (in `modules/databricks-workspace`) | Unity Catalog → ADLS Gen2 | Azure-managed |

The SP password is the only long-lived secret the module manages. It lives
in Terraform state (and, as a copy, in the workspace secret scope) — keep
the state backend private (the `bootstrap/`-created storage account has
blob versioning enabled and the roots access it with
`use_azuread_auth = true`). Anthropic-style provider keys are never
Terraform-managed at all: `api_key_secret` is a reference to a
pre-existing workspace secret.

---

## 7. Variables reference (model-serving module)

From [`modules/model-serving/variables.tf`](../modules/model-serving/variables.tf).
The workspace-stack wrapper exposes most of these with a
`model_serving_` prefix (e.g. `model_serving_rate_limits`).

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `ai_foundry_name` | string | — | Foundry (Cognitive Services) account exposing the OpenAI deployments |
| `ai_foundry_resource_group` | string | — | RG of the Foundry account |
| `name_prefix` | string | `dbw` | Prefix for the model-serving SP app registration and secret scope (workspace-stack passes the workspace name, e.g. `dbx-dev`) |
| `openai_api_version` | string | `2024-12-01-preview` | API version on every external endpoint |
| `inference_table_catalog` | string | `main` | UC catalog for payload tables |
| `inference_table_schema` | string | `model_serving_logs` | UC schema for payload tables |
| `inference_table_prefix` | string | `""` | Workspace prefix on every table name (workspace-stack passes `coalesce(inference_table_prefix, team)`) |
| `external_endpoints` | map(object) | `null` (uses `model_defaults.yaml`) | Override the external endpoint catalog; `null` loads defaults from YAML |
| `additional_external_endpoints` | map(object) | `{}` | Merge extra external endpoints on top of the active set without replacing it |
| `fallback_enabled` | bool | `false` | Provision the `azure-gpt-chat-fallback` endpoint |
| `rate_limits` | list(object) | `[]` (uses `gateway_defaults`) | Override the YAML rate-limit policy on every managed endpoint |
| `guardrails` | object | `null` (uses `gateway_defaults`) | Override the YAML guardrails (input/output safety + PII behavior) |
| `endpoint_permissions_enabled` | bool | `true` | Manage endpoint ACLs (CAN_QUERY / CAN_MANAGE); set false where the ACL feature is unavailable |
| `write_access_group` | string | `null` | Single group granted CAN_QUERY (single-workspace convenience) |
| `consumer_groups` | list(string) | `[]` | Groups granted CAN_QUERY on all managed endpoints |
| `admin_groups` | list(string) | `[]` | Groups granted CAN_MANAGE on every managed endpoint |
| `budget_policy_id` | string | `null` | Serverless budget policy attached to endpoints for cost attribution |
| `databricks_tags` | map(string) | `{}` | Tags stamped on every managed endpoint |
| `agent_waste_monitors` | object | `null` | Scheduled SQL alerts for retry loops / error rates / blocked-model attempts / tool-error loops (`monitoring.tf`); see [agent-spend-waste.md](agent-spend-waste.md) |

There are **no** foundation-model variables (`foundation_endpoints`,
`disabled_foundation_models`, …): that governance is YAML-only, applied by
the reconciler script, and surfaced read-only through the module outputs
`governed_foundation_endpoints` and `disabled_foundation_models`.
