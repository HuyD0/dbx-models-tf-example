# Finding wasted agent spend (silent tool failures and retry loops)

Databricks' engineering blog described how they found roughly **$500K a
year of wasted tokens** (about $1.2M once engineer wait time is counted)
in one hour, without adding any instrumentation: seven bugs in internal
MCP tool servers were making tools crash on inputs the model reasonably
sent (a JSON array where the tool wanted a comma-separated string, for
example), and instead of surfacing an error the agents **retried — on
average a dozen times per incident**. Nothing paged, because every
individual LLM call succeeded. The waste was hiding inside "usage
growth".

Source: [How we eliminated $1M/year in wasted AI agent spend in one hour](https://www.databricks.com/blog/how-we-eliminated-1-million-year-wasted-ai-agent-spend-one-hour).

Two lessons carry over directly to this gateway:

1. **The signal already exists.** Per-call gateway traces (tool name,
   arguments, error, tokens, latency, session id) were enough. The work
   was asking the right questions of a table that was already there.
2. **Fix the tool, not the prompt.** Their design principle: tools built
   for agents should *adapt to the way LLMs naturally call them* — coerce
   a list into the string the tool wanted, default omitted parameters,
   absorb unexpected arguments — rather than crashing and hoping the
   model reads a traceback.

This page maps that method onto what this repo deploys, gives the SQL to
ask the same questions of our tables, and describes the scheduled alerts
(`agent_waste_monitors`) that keep asking them.

---

## 1. What they had vs. what this gateway records

| In the blog post | Here | Notes |
|---|---|---|
| Unity Gateway OpenTelemetry trace per MCP tool call | **Not equivalent.** This repo uses the older inline `ai_gateway {}` pattern; tools run inside the caller's agent, not through the gateway. | The gateway sees a tool call's *result* only when the agent sends it back as the next prompt. That is enough to detect a loop, not to trace the tool itself — see §5 for MLflow Tracing. |
| Token counts, latency, status per call | `system.serving.endpoint_usage` (`status_code`, `input_token_count`, `output_token_count`, `requester`, `usage_context`) and the inference tables' `execution_duration_ms` | Covers every endpoint: external, fallback, governed foundation, **and blocked** (attempts against `disabled_foundation_models` are still recorded). |
| Tool name, arguments, error text | Inference table `request` column: `tool_calls` on assistant messages, `role: "tool"` messages carrying the tool's output | `main.model_serving_logs.<workspace_prefix><table_prefix>_payload` — see [model-serving.md §2.2](model-serving.md#22-inference-tables-inference_table_config). |
| Session id linking calls | **Only if callers send it.** `usage_context.session_id` in the request body → `endpoint_usage.usage_context` and the payload `request` column | The single most important thing to fix first — see §2. Without it, "repeat rate" and "turns to recover" collapse to per-requester aggregates. |
| Genie One over the trace table | A Genie space over the same three tables | See §4. |
| Fixes in the MCP servers | Owners of the tool / MCP servers your agents use | Checklist in §3. |
| Continuous monitoring | `agent_waste_monitors` scheduled SQL alerts | See §4. |

---

## 2. Step 0 — make sessions visible (`usage_context`)

Every request through the gateway may carry a free-form `usage_context`
map. Nothing in the platform fills it in for you, and without it the
retry analysis below cannot tell "one agent looping twelve times" from
"twelve users each calling once". Standardise it in every agent:

```json
{
  "messages": [...],
  "usage_context": {
    "session_id": "b6f2…",          // one per conversation / agent run
    "app_id":     "billing-bot",    // chargeback key (see access-control.md)
    "agent":      "triage-v3",      // which agent build made the call
    "turn":       "7"               // optional: the agent's own step counter
  }
}
```

With the OpenAI SDK pointed at the gateway (see
[model-serving.md §4](model-serving.md#4-calling-an-endpoint)):

```python
client.chat.completions.create(
    model="azure-gpt-chat-fallback",
    messages=messages,
    extra_body={"usage_context": {"session_id": session_id, "app_id": "billing-bot", "agent": "triage-v3"}},
)
```

It lands in `system.serving.endpoint_usage.usage_context` (a map) and in
the raw `request` JSON of the inference table (`request:usage_context.session_id`).
The queries below use `COALESCE(request:usage_context.session_id, requester)`
so unlabelled traffic still groups — just coarsely, by principal.

---

## 3. Step 1 — ask the questions

All queries assume the `dbx-dev` defaults: catalog `main`, schema
`model_serving_logs`, workspace prefix `dbx_dev_`. The payload tables
hold the raw request/response JSON as strings; the `:` operator extracts
JSON paths and `parse_json(...)` turns the `messages` array into a
`VARIANT` you can explode (needs a SQL warehouse on a current channel).

### 3.1 Where do failures cluster? (every endpoint, no payload needed)

```sql
-- Non-200 share per endpoint and principal, last 24h. A single principal
-- with hundreds of failures against one endpoint is a loop, not load.
SELECT
  se.endpoint_name,
  u.requester,
  COUNT(*)                                                  AS calls,
  SUM(CASE WHEN u.status_code <> 200 THEN 1 ELSE 0 END)     AS failed_calls,
  ROUND(100.0 * SUM(CASE WHEN u.status_code <> 200 THEN 1 ELSE 0 END) / COUNT(*), 1) AS error_pct,
  concat_ws(',', sort_array(collect_set(u.status_code)))    AS status_codes
FROM system.serving.endpoint_usage u
JOIN system.serving.served_entities se USING (served_entity_id)
WHERE u.request_time > current_timestamp() - INTERVAL 24 HOURS
GROUP BY 1, 2
HAVING SUM(CASE WHEN u.status_code <> 200 THEN 1 ELSE 0 END) >= 10
ORDER BY failed_calls DESC;
```

A steady stream of `429` from one principal against a `databricks-*`
endpoint on the deny-list is the cheapest find of all: an agent or job
configured for a model this platform blocks, failing forever and
retrying forever.

### 3.2 Which tool errors recur, and how often does a session hit the same one twice?

This is the blog's core table. Tool results appear as `role: "tool"`
messages inside `request:messages`. Because an agent re-sends the whole
conversation on every turn, the same tool result appears in every later
request of that session — dedupe on `tool_call_id`.

```sql
WITH turns AS (
  SELECT
    request_time,
    requester,
    COALESCE(request:usage_context.session_id, requester)      AS session_id,
    CAST(parse_json(request:messages) AS ARRAY<VARIANT>)       AS messages
  FROM main.model_serving_logs.dbx_dev_azure_gpt_chat_fallback_payload
  WHERE request_time > current_timestamp() - INTERVAL 7 DAYS
),
tool_results AS (
  SELECT DISTINCT
    t.session_id,
    t.requester,
    CAST(m:tool_call_id AS STRING)                             AS tool_call_id,
    CAST(m:content AS STRING)                                  AS content
  FROM turns t
  LATERAL VIEW explode(t.messages) AS m
  WHERE CAST(m:role AS STRING) = 'tool'
    AND CAST(m:content AS STRING) RLIKE '(?i)(error|exception|traceback|invalid|not found)'
),
signatures AS (
  -- First line of the error with digits collapsed, so
  -- "KeyError: 'fields' (row 137)" and "(row 22)" count as one bug.
  SELECT
    *,
    regexp_replace(split_part(content, '\n', 1), '[0-9]+', '#') AS signature
  FROM tool_results
),
per_session AS (
  SELECT signature, session_id, requester, COUNT(*) AS hits
  FROM signatures
  GROUP BY 1, 2, 3
)
SELECT
  signature,
  SUM(hits)                                                    AS occurrences,
  COUNT(*)                                                     AS sessions,
  ROUND(100.0 * SUM(CASE WHEN hits >= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS repeat_rate_pct,
  ROUND(AVG(hits), 1)                                          AS avg_hits_per_session,
  COUNT(DISTINCT requester)                                    AS principals
FROM per_session
GROUP BY 1
ORDER BY occurrences DESC
LIMIT 20;
```

`repeat_rate_pct` is the blog's "repeat rate" (sessions that hit the same
error more than once — i.e. the agent retried instead of recovering).
`avg_hits_per_session` approximates their "turns to recover". Run the
same query against each chat payload table, or `UNION ALL` them as the
`tool-error-loops` alert does.

To see *what the model sent* that broke the tool, pull the matching
assistant `tool_calls` — this is the input for the fix in §3:

```sql
WITH turns AS (
  SELECT
    COALESCE(request:usage_context.session_id, requester)      AS session_id,
    CAST(parse_json(request:messages) AS ARRAY<VARIANT>)       AS messages
  FROM main.model_serving_logs.dbx_dev_azure_gpt_chat_fallback_payload
  WHERE request_time > current_timestamp() - INTERVAL 7 DAYS
),
calls AS (
  SELECT DISTINCT
    t.session_id,
    CAST(c:id AS STRING)                                       AS tool_call_id,
    CAST(c:function.name AS STRING)                            AS tool_name,
    CAST(c:function.arguments AS STRING)                       AS arguments
  FROM turns t
  LATERAL VIEW explode(t.messages) AS m
  LATERAL VIEW explode(CAST(m:tool_calls AS ARRAY<VARIANT>)) AS c
  WHERE CAST(m:role AS STRING) = 'assistant' AND m:tool_calls IS NOT NULL
),
results AS (
  SELECT DISTINCT
    t.session_id,
    CAST(m:tool_call_id AS STRING)                             AS tool_call_id,
    CAST(m:content AS STRING)                                  AS content
  FROM turns t
  LATERAL VIEW explode(t.messages) AS m
  WHERE CAST(m:role AS STRING) = 'tool'
    AND CAST(m:content AS STRING) RLIKE '(?i)(error|exception|traceback|invalid|not found)'
)
SELECT
  c.tool_name,
  regexp_replace(split_part(r.content, '\n', 1), '[0-9]+', '#') AS signature,
  COUNT(*)                                                     AS failures,
  any_value(c.arguments)                                       AS example_arguments,
  any_value(r.content)                                         AS example_error
FROM calls c
JOIN results r USING (session_id, tool_call_id)
GROUP BY 1, 2
ORDER BY failures DESC
LIMIT 20;
```

`example_arguments` is usually the whole story — in the blog it was
`"fields": ["key", "summary", "status"]` sent to a tool that did
`fields.split(",")`.

### 3.3 What is it costing?

Tokens spent on turns that carry a tool error are tokens spent
recovering from a tool bug. Price the tokens with your own contract
rates; the values below are placeholders.

```sql
WITH prices(endpoint_name, usd_per_1k_input, usd_per_1k_output) AS (
  VALUES
    ('azure-gpt-chat-fallback',    0.0025, 0.0100),   -- placeholder rates
    ('azure-gpt-4o',               0.0025, 0.0100),
    ('azure-gpt-5-mini',           0.0003, 0.0012),
    ('databricks-claude-sonnet-4-6', 0.0030, 0.0150)
),
turns AS (
  SELECT
    'azure-gpt-chat-fallback'                                  AS endpoint_name,
    request_time,
    COALESCE(request:usage_context.session_id, requester)      AS session_id,
    CAST(response:usage.prompt_tokens     AS INT)              AS prompt_tokens,
    CAST(response:usage.completion_tokens AS INT)              AS completion_tokens,
    execution_duration_ms,
    exists(
      CAST(parse_json(request:messages) AS ARRAY<VARIANT>),
      m -> CAST(m:role AS STRING) = 'tool'
           AND CAST(m:content AS STRING) RLIKE '(?i)(error|exception|traceback|invalid|not found)'
    )                                                          AS carries_tool_error
  FROM main.model_serving_logs.dbx_dev_azure_gpt_chat_fallback_payload
  WHERE request_time > current_timestamp() - INTERVAL 30 DAYS
  -- UNION ALL the other chat payload tables here
)
SELECT
  t.endpoint_name,
  SUM(CASE WHEN carries_tool_error THEN 1 ELSE 0 END)          AS turns_after_tool_errors,
  COUNT(*)                                                     AS turns,
  ROUND(SUM(CASE WHEN carries_tool_error
        THEN prompt_tokens * p.usd_per_1k_input / 1000 + completion_tokens * p.usd_per_1k_output / 1000
        ELSE 0 END), 2)                                        AS usd_30d_on_tool_errors,
  ROUND(SUM(CASE WHEN carries_tool_error
        THEN prompt_tokens * p.usd_per_1k_input / 1000 + completion_tokens * p.usd_per_1k_output / 1000
        ELSE 0 END) * 365 / 30, 0)                             AS usd_annualised,
  ROUND(SUM(CASE WHEN carries_tool_error THEN execution_duration_ms ELSE 0 END) / 3600000.0, 1) AS model_hours_waiting
FROM turns t
JOIN prices p USING (endpoint_name)
GROUP BY 1;
```

`model_hours_waiting` only counts time inside the model call. The blog's
much larger "12,000 engineering hours" figure was people waiting on
agents that were waiting on retries — multiply by however many humans
sit behind your agents.

---

## 4. Step 2 — fix the tools

The blog's fixes took about an hour once the offending arguments were
known, because they did not try to make the model behave — they made the
tools tolerant. Apply the same checklist to every tool / MCP server your
agents call:

- **Coerce, don't crash.** Accept a JSON array *or* a comma-separated
  string for list parameters. Accept a number *or* a numeric string.
  Trim whitespace. The model infers types from JSON conventions, not from
  your docstring.
- **Default what is omitted.** A missing optional field is the common
  case, not an error.
- **Ignore what you don't know.** Drop unexpected arguments rather than
  rejecting the call.
- **Never leak a traceback.** Return a short, structured error the model
  can act on: what was wrong, what a valid call looks like. A `KeyError:
  'fields'` teaches the model nothing, so it tries the same call again.
- **Make retries cheap or impossible.** Idempotent tools; if a call
  cannot succeed (bad id, no permission), say so in a way that ends the
  loop.
- **Regression-test with the real arguments** from §3.2's
  `example_arguments` — they are the inputs the model actually produces.

Then re-run §3.2 a week later; the signature should be gone.

---

## 5. Step 3 — keep the loop running

### 5.1 Scheduled alerts (`agent_waste_monitors`)

The module can create Databricks SQL alerts (`databricks_alert_v2`) that
run the questions above on a schedule. Nothing is created until the
variable is set:

```hcl
# environments/dbx-dev/terraform.tfvars
model_serving_agent_waste_monitors = {
  warehouse_id  = "1234567890abcdef"          # Compute → SQL warehouses → Connection details
  notify_emails = ["mlops-team@example.com"]

  # Optional — defaults shown
  parent_path                  = "/Shared/llm-gateway-monitors"
  schedule_cron                = "0 0 * * * ?"   # hourly, Quartz syntax
  timezone_id                  = "UTC"
  error_loop_failed_calls      = 10   # per requester × endpoint, last hour
  error_rate_pct               = 20   # per endpoint, last hour …
  error_rate_min_calls         = 20   # … ignoring endpoints below this volume
  blocked_model_attempts       = 25   # attempts on deny-listed endpoints, last 24h
  payload_alerts_enabled       = false
  tool_error_turns_per_session = 3    # turns carrying a tool error, per session, last 24h
  tool_error_pattern           = "(?i)(error|exception|traceback|invalid|not found)"
}
```

| Alert (`<workspace>-llm-…`) | Reads | Fires when | Created |
|---|---|---|---|
| `error-loops` | `system.serving.endpoint_usage` | one requester has ≥ `error_loop_failed_calls` non-200 responses from one endpoint in the last hour | always |
| `error-rate` | `system.serving.endpoint_usage` | an endpoint with ≥ `error_rate_min_calls` calls in the last hour has ≥ `error_rate_pct` % non-200 | always |
| `blocked-model-attempts` | `system.serving.endpoint_usage` | ≥ `blocked_model_attempts` calls hit any `disabled_foundation_models` endpoint in 24h | when the deny-list is non-empty |
| `tool-error-loops` | every chat payload table (`UNION ALL`) | a session has ≥ `tool_error_turns_per_session` turns whose prompt carries a tool-role message matching `tool_error_pattern`, in 24h | `payload_alerts_enabled = true` |

Design notes:

- The SQL is generated from the same endpoint catalog the module
  manages (`model_defaults.yaml` + overrides), so adding an endpoint
  extends the alerts on the next apply. Deny-listed endpoints are
  excluded from `error-loops` / `error-rate` (a 429 is their intended
  response) and watched only by `blocked-model-attempts`.
- Queries are scoped to this workspace's numeric ID (`workspace-stack`
  fills it in) because endpoint names are not unique across workspaces
  in one account.
- Each query returns one row per offender; the alert triggers on the
  `MAX` of the metric column and is `OK` on an empty result, so the
  alert's own result view is the drill-down list.
- **`tool-error-loops` is opt-in** because inference tables only
  materialise a few minutes after an endpoint first serves traffic; an
  alert over a table that does not exist yet fails every evaluation.
  Enable it once `SHOW TABLES IN main.model_serving_logs` lists the
  `_payload` tables.
- Alerts run as their creator (the deployment SP). That identity needs
  `SELECT` on `system.serving.endpoint_usage` and
  `system.serving.served_entities` (granted by a metastore admin via
  `GRANT SELECT ON SCHEMA system.serving TO …`) and read access to the
  payload tables (it owns them in `dbx-dev`).
- Tune thresholds after a week of data: `error_loop_failed_calls`
  should sit well above your busiest legitimate client's failure count
  in a bad hour; `tool_error_pattern` should be narrowed to the
  signatures §3.2 actually shows you.

### 5.2 Ask in plain English (Genie)

The blog's analysis was done by asking Genie questions rather than
writing SQL. Create a Genie space over `system.serving.endpoint_usage`,
`system.serving.served_entities`, and the `main.model_serving_logs`
payload tables, and seed it with the queries above as example SQL so
"which tool errors happened most this week and how many sessions hit
them twice?" resolves correctly. Genie spaces are created in the UI
today; the tables it needs are all Terraform-managed here.

### 5.3 Brakes already in place

Detection is not the only control. Two brakes in this repo bound how
much a runaway loop can cost before anyone reads an alert:

- **Per-user rate limits** — `gateway_defaults.rate_limits.user_qpm`
  (20/min by default) caps how fast any one principal can retry. Add a
  `tokens` cap (`endpoint_tpm`, or `tokens` on a per-user rule in
  `model_serving_rate_limits`) to bound token burn as well as call
  count. See [model-serving.md §2.3](model-serving.md#23-rate-limits-rate_limits).
- **AI Gateway budgets** — the `UNITY_AI_GATEWAY` budget in
  `environments/account/budget_defaults.yaml` alerts near-real-time on
  LLM spend and can `block_usage` past a threshold. See
  [budgets.md](budgets.md).

### 5.4 Tracing the tools themselves (beyond the gateway)

Everything above infers tool failures from what the agent echoes back
to the model. To see the tool call directly — arguments, duration, the
exception before any retry — instrument the agent with **MLflow Tracing**
(`mlflow.openai.autolog()` / `@mlflow.trace` around tool functions) and
log traces to an MLflow experiment backed by Unity Catalog. That yields
the per-tool span table the blog worked from, and it joins to the
payload tables on `databricks_request_id` when the agent forwards it.
Agent-side instrumentation is out of scope for this Terraform repo; the
gateway-side analysis here works without it.

---

## 6. Limits

- The gateway records tool *results* only when the agent sends them back
  as context. A tool that fails and is never retried is invisible here
  (and also costs nothing).
- Session grouping is only as good as `usage_context.session_id`
  adoption (§2). Unlabelled traffic is grouped per principal.
- Inference tables lag a few minutes and are not created until first
  traffic; `system.serving.endpoint_usage` can lag up to an hour.
- `parse_json` / `VARIANT` need a SQL warehouse on a current release;
  the `error-loops`, `error-rate` and `blocked-model-attempts` alerts do
  not use them.
- Price tables in §3.3 are placeholders. For actual spend use
  `system.billing.usage` with the budget-policy tags described in
  [budgets.md](budgets.md).
- Provisioned-throughput endpoints are not part of this repo and are not
  covered.
