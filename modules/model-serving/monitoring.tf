# ── Agent-waste monitors (scheduled Databricks SQL alerts) ──────────────────
# Silent tool failures and retry loops hide inside "usage growth": an agent
# whose tool call fails does not surface an error — it retries, burning
# tokens and wall-clock time until something gives. Databricks found ~$500K
# per year of such waste by asking a handful of questions of the gateway's
# per-call trace data (see docs/agent-spend-waste.md).
#
# This repo already records the raw signal for every governed endpoint —
# system.serving.endpoint_usage (status, tokens, requester, usage_context)
# and the full-payload inference tables — but nothing asked those
# questions. These alerts do, on a schedule, so the waste is a page rather
# than a line item:
#
#   error-loops             one requester repeatedly failing against one
#                           endpoint in the last hour (HTTP-level retry storm)
#   error-rate              per-endpoint non-200 share over the last hour
#   blocked-model-attempts  callers hammering a deny-listed databricks-*
#                           endpoint (every attempt is a 429 by design — a
#                           retrying agent never recovers on its own)
#   tool-error-loops        (opt-in: payload_alerts_enabled) sessions whose
#                           conversation keeps carrying `tool`-role messages
#                           that match an error signature — the exact
#                           pattern in the blog post. Reads the inference
#                           tables, which only exist once an endpoint has
#                           served traffic, so enable it after first use.
#
# Opt-in via var.agent_waste_monitors (null = nothing created). Thresholds,
# schedule and recipients live in that object; the SQL is generated from
# the same endpoint catalog the module already manages, so a new endpoint
# is covered on the next apply without touching this file.
#
# Prerequisites (not managed here): a SQL warehouse, and SELECT on
# system.serving.endpoint_usage / served_entities for the identity the
# alerts run as (the deployment SP, i.e. the creator).

locals {
  awm = var.agent_waste_monitors

  # Endpoints whose traffic should be judged on error rate / retry loops:
  # everything this module manages plus the governed foundation endpoints.
  # Deny-listed endpoints are excluded here (a 429 is their expected
  # response) and watched separately by blocked-model-attempts.
  monitored_endpoint_names = sort(concat(
    keys(local.endpoints),
    var.fallback_enabled ? ["azure-gpt-chat-fallback"] : [],
    keys(local.governed_foundation_endpoints),
  ))

  sql_monitored_endpoints = join(", ", [for n in local.monitored_endpoint_names : "'${n}'"])
  sql_blocked_endpoints   = join(", ", [for n in sort(tolist(local.disabled_foundation_models)) : "'${n}'"])

  # Endpoint names are not unique across workspaces in one account, so
  # scope to this workspace when the caller (workspace-stack) tells us
  # which one we are.
  sql_workspace_filter = try(local.awm.workspace_id, null) == null ? "" : "AND se.workspace_id = '${local.awm.workspace_id}'"

  # Chat payload tables — the only place tool-call content is visible.
  # Same naming rule as the inference_table_config blocks in main.tf and
  # the reconciler script: <catalog>.<schema>.<workspace_prefix><table_prefix>_payload
  chat_payload_tables = {
    for name, tbl in merge(
      { for name, e in local.endpoints : name => "${local.table_prefix}${e.table_prefix}" if e.task == "llm/v1/chat" },
      var.fallback_enabled ? { "azure-gpt-chat-fallback" = "${local.table_prefix}azure_gpt_chat_fallback" } : {},
      { for name, fe in local.governed_foundation_endpoints : name => "${local.table_prefix}${fe.table_prefix}" },
    ) : name => "${var.inference_table_catalog}.${var.inference_table_schema}.${tbl}_payload"
  }

  # One SELECT per payload table, UNION ALL'ed into a single stream of
  # conversation turns. session_id comes from the caller-supplied
  # usage_context (see docs/agent-spend-waste.md) and falls back to the
  # requester so unlabelled traffic is still grouped, just more coarsely.
  sql_payload_turns = join("\n  UNION ALL\n", [
    for name, tbl in local.chat_payload_tables : <<-SQL
      SELECT
        '${name}'                                                 AS endpoint_name,
        request_time,
        requester,
        COALESCE(request:usage_context.session_id, requester)     AS session_id,
        request:messages                                          AS messages_json,
        CAST(response:usage.total_tokens AS INT)                  AS total_tokens
      FROM ${tbl}
      WHERE request_time > current_timestamp() - INTERVAL 24 HOURS
    SQL
  ])

  agent_waste_alert_catalog = {
    "error-loops" = {
      summary   = "One caller repeatedly failing against one endpoint — the HTTP-level shape of an agent retry loop."
      threshold = try(local.awm.error_loop_failed_calls, 10)
      source    = "failed_calls"
      query     = <<-SQL
        -- Requesters with >= ${try(local.awm.error_loop_failed_calls, 10)} non-200 responses from a single
        -- endpoint in the last hour. A healthy client backs off; a broken
        -- agent loop does not.
        SELECT
          u.requester,
          se.endpoint_name,
          COUNT(*)                                                        AS failed_calls,
          concat_ws(',', sort_array(collect_set(u.status_code)))          AS status_codes,
          SUM(COALESCE(u.input_token_count, 0) + COALESCE(u.output_token_count, 0)) AS tokens_burned,
          MIN(u.request_time)                                             AS first_failure,
          MAX(u.request_time)                                             AS last_failure
        FROM system.serving.endpoint_usage u
        JOIN system.serving.served_entities se USING (served_entity_id)
        WHERE u.request_time > current_timestamp() - INTERVAL 1 HOUR
          AND u.status_code <> 200
          AND se.endpoint_name IN (${local.sql_monitored_endpoints})
          ${local.sql_workspace_filter}
        GROUP BY 1, 2
        HAVING COUNT(*) >= ${try(local.awm.error_loop_failed_calls, 10)}
        ORDER BY failed_calls DESC
      SQL
    }

    "error-rate" = {
      summary   = "Per-endpoint non-200 share over the last hour."
      threshold = try(local.awm.error_rate_pct, 20)
      source    = "error_pct"
      query     = <<-SQL
        -- Endpoints whose failure share crossed ${try(local.awm.error_rate_pct, 20)}% in the last hour
        -- (endpoints with fewer than ${try(local.awm.error_rate_min_calls, 20)} calls are ignored to avoid
        -- noise from a single failed smoke test).
        SELECT
          se.endpoint_name,
          COUNT(*)                                                    AS calls,
          SUM(CASE WHEN u.status_code <> 200 THEN 1 ELSE 0 END)       AS failed_calls,
          ROUND(100.0 * SUM(CASE WHEN u.status_code <> 200 THEN 1 ELSE 0 END) / COUNT(*), 1) AS error_pct
        FROM system.serving.endpoint_usage u
        JOIN system.serving.served_entities se USING (served_entity_id)
        WHERE u.request_time > current_timestamp() - INTERVAL 1 HOUR
          AND se.endpoint_name IN (${local.sql_monitored_endpoints})
          ${local.sql_workspace_filter}
        GROUP BY 1
        HAVING COUNT(*) >= ${try(local.awm.error_rate_min_calls, 20)}
        ORDER BY error_pct DESC
      SQL
    }

    "blocked-model-attempts" = {
      summary   = "Callers retrying against deny-listed databricks-* endpoints (always 429 — a retrying agent never recovers)."
      threshold = try(local.awm.blocked_model_attempts, 25)
      source    = "attempts"
      query     = <<-SQL
        -- Attempts against endpoints pinned at rate_limit = 0 by
        -- model_defaults.yaml (disabled_foundation_models) in the last 24h.
        -- Usage tracking stays on for those endpoints precisely so this is
        -- visible. Steady attempts from one principal = an agent or job
        -- configured for a non-approved model, silently failing.
        SELECT
          u.requester,
          se.endpoint_name,
          COUNT(*)            AS attempts,
          MIN(u.request_time) AS first_attempt,
          MAX(u.request_time) AS last_attempt
        FROM system.serving.endpoint_usage u
        JOIN system.serving.served_entities se USING (served_entity_id)
        WHERE u.request_time > current_timestamp() - INTERVAL 24 HOURS
          AND se.endpoint_name IN (${local.sql_blocked_endpoints})
          ${local.sql_workspace_filter}
        GROUP BY 1, 2
        ORDER BY attempts DESC
      SQL
    }

    "tool-error-loops" = {
      summary   = "Sessions whose conversation keeps carrying tool-call errors back to the model — silent tool failures the agent is retrying through."
      threshold = try(local.awm.tool_error_turns_per_session, 3)
      source    = "tool_error_turns"
      query     = <<-SQL
        -- Conversation turns (one row per gateway request) across every chat
        -- payload table, grouped by session. A turn "carries a tool error"
        -- when any tool-role message in the prompt matches the configured
        -- error signature — i.e. the model was shown a failed tool result
        -- and asked to continue. Sessions with >= ${try(local.awm.tool_error_turns_per_session, 3)} such turns
        -- in 24h are retry loops: fix the tool, not the prompt.
        WITH turns AS (
        ${local.sql_payload_turns}
        ),
        classified AS (
          SELECT
            *,
            exists(
              CAST(parse_json(messages_json) AS ARRAY<VARIANT>),
              m -> CAST(m:role AS STRING) = 'tool'
                   AND CAST(m:content AS STRING) RLIKE '${try(local.awm.tool_error_pattern, "(?i)(error|exception|traceback|invalid|not found)")}'
            ) AS has_tool_error
          FROM turns
        )
        SELECT
          session_id,
          requester,
          endpoint_name,
          COUNT(*)                                                  AS turns,
          SUM(CASE WHEN has_tool_error THEN 1 ELSE 0 END)           AS tool_error_turns,
          ROUND(100.0 * SUM(CASE WHEN has_tool_error THEN 1 ELSE 0 END) / COUNT(*), 1) AS tool_error_pct,
          SUM(CASE WHEN has_tool_error THEN COALESCE(total_tokens, 0) ELSE 0 END)     AS tokens_after_tool_errors,
          MIN(request_time)                                         AS first_turn,
          MAX(request_time)                                         AS last_turn
        FROM classified
        GROUP BY 1, 2, 3
        HAVING SUM(CASE WHEN has_tool_error THEN 1 ELSE 0 END) >= ${try(local.awm.tool_error_turns_per_session, 3)}
        ORDER BY tool_error_turns DESC
      SQL
    }
  }

  # Which of the catalog above to materialise:
  #   • nothing unless var.agent_waste_monitors is set,
  #   • blocked-model-attempts only if there is a deny-list to watch,
  #   • tool-error-loops only when explicitly enabled (needs the payload
  #     tables to exist) and there is at least one chat endpoint.
  agent_waste_alerts = local.awm == null ? {} : {
    for key, a in local.agent_waste_alert_catalog : key => a
    if(
      (key != "blocked-model-attempts" || length(local.disabled_foundation_models) > 0)
      && (key != "tool-error-loops" || (try(local.awm.payload_alerts_enabled, false) && length(local.chat_payload_tables) > 0))
    )
  }
}

# Folder the alerts live in — created explicitly so they land somewhere
# humans can find them rather than in the deployment SP's home directory.
resource "databricks_directory" "agent_waste_monitors" {
  count = local.awm == null ? 0 : 1
  path  = local.awm.parent_path
}

resource "databricks_alert_v2" "agent_waste" {
  for_each = local.agent_waste_alerts

  display_name   = "${var.name_prefix}-llm-${each.key}"
  custom_summary = each.value.summary
  custom_description = join(" ", [
    each.value.summary,
    "Generated by modules/model-serving/monitoring.tf from model_defaults.yaml;",
    "investigation queries and the fix checklist are in docs/agent-spend-waste.md.",
  ])
  parent_path  = databricks_directory.agent_waste_monitors[0].path
  warehouse_id = local.awm.warehouse_id
  query_text   = each.value.query

  schedule = {
    quartz_cron_schedule = local.awm.schedule_cron
    timezone_id          = local.awm.timezone_id
    pause_status         = "UNPAUSED"
  }

  evaluation = {
    comparison_operator = "GREATER_THAN_OR_EQUAL"
    # Every query already filters to offenders and returns one row per
    # offender; alert when the worst one crosses the threshold, stay OK
    # when the query returns nothing.
    source = {
      name        = each.value.source
      aggregation = "MAX"
    }
    threshold = {
      value = {
        double_value = each.value.threshold
      }
    }
    empty_result_state = "OK"

    notification = {
      notify_on_ok  = false
      subscriptions = [for e in local.awm.notify_emails : { user_email = e }]
    }
  }
}
