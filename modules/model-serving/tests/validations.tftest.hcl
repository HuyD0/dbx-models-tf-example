# Unit tests for the model-serving module's plan-time guardrails: variable
# validations and lifecycle preconditions. Run with mocked providers — no
# cloud credentials, no state:
#
#   cd modules/model-serving
#   terraform init -backend=false && terraform test
#
# Mock providers use the real provider schemas but fabricate computed
# values, so `command = plan` exercises every validation, precondition,
# and the YAML-driven defaults without any API call.

# azurerm validates role-assignment scopes as real ARM IDs at plan time, so
# the mocked Cognitive Services account must return an ARM-shaped id.
mock_provider "azurerm" {
  mock_data "azurerm_cognitive_account" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.CognitiveServices/accounts/aif-example"
      endpoint = "https://aif-example.openai.azure.com/"
    }
  }
}
mock_provider "azuread" {}
mock_provider "databricks" {}

variables {
  ai_foundry_name           = "aif-example"
  ai_foundry_resource_group = "rg-example"
}

# ── Happy path: YAML defaults produce the documented endpoint set ───────────

run "defaults_plan_succeeds" {
  command = plan

  assert {
    condition     = length(keys(databricks_model_serving.endpoints)) == 4
    error_message = "Expected the 4 default external endpoints from model_defaults.yaml."
  }

  # gateway_defaults from the YAML (60 endpoint QPM / 20 user QPM) must be
  # rendered on every endpoint when var.rate_limits is empty.
  assert {
    condition = (
      databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits[0].calls == 60
      && databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits[0].key == "endpoint"
      && databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits[1].calls == 20
      && databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits[1].key == "user"
    )
    error_message = "gateway_defaults.rate_limits from model_defaults.yaml were not applied as the default ai_gateway rate limits."
  }

  # Usage tracking is non-negotiable on every endpoint.
  assert {
    condition     = alltrue([for k, ep in databricks_model_serving.endpoints : ep.ai_gateway[0].usage_tracking_config[0].enabled])
    error_message = "usage_tracking_config must be enabled on every endpoint."
  }
}

# ── Workspace override beats the YAML defaults ──────────────────────────────

run "rate_limit_override_replaces_yaml_defaults" {
  command = plan

  variables {
    rate_limits = [
      { calls = 100, key = "endpoint" },
    ]
  }

  assert {
    condition = (
      length(databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits) == 1
      && databricks_model_serving.endpoints["azure-gpt-4o"].ai_gateway[0].rate_limits[0].calls == 100
    )
    error_message = "A non-empty var.rate_limits must fully replace the YAML gateway_defaults."
  }
}

# ── Rate limit validations ──────────────────────────────────────────────────

run "rejects_invalid_rate_limit_key" {
  command = plan

  variables {
    rate_limits = [
      { calls = 10, key = "banana" },
    ]
  }

  expect_failures = [var.rate_limits]
}

run "rejects_user_group_limit_without_principal" {
  command = plan

  variables {
    rate_limits = [
      { calls = 10, key = "user_group" },
    ]
  }

  expect_failures = [var.rate_limits]
}

run "rejects_more_than_five_user_group_limits" {
  command = plan

  variables {
    rate_limits = [
      { calls = 10, key = "user_group", principal = "g1" },
      { calls = 10, key = "user_group", principal = "g2" },
      { calls = 10, key = "user_group", principal = "g3" },
      { calls = 10, key = "user_group", principal = "g4" },
      { calls = 10, key = "user_group", principal = "g5" },
      { calls = 10, key = "user_group", principal = "g6" },
    ]
  }

  expect_failures = [var.rate_limits]
}

# ── Endpoint shape validations ──────────────────────────────────────────────

run "rejects_unknown_external_provider" {
  command = plan

  variables {
    additional_external_endpoints = {
      "bedrock-claude" = {
        model        = "gpt-4o" # allowlisted, so only the provider check fires
        task         = "llm/v1/chat"
        table_prefix = "bedrock_claude"
        provider     = "amazon-bedrock"
      }
    }
  }

  expect_failures = [var.additional_external_endpoints]
}

# ── Allowlist + provider-specific preconditions ─────────────────────────────

run "rejects_model_missing_from_allowlist" {
  command = plan

  variables {
    additional_external_endpoints = {
      "azure-gpt-99" = {
        model           = "gpt-99-ultra"
        deployment_name = "gpt-99-ultra"
        task            = "llm/v1/chat"
        table_prefix    = "azure_gpt99"
      }
    }
  }

  expect_failures = [databricks_model_serving.endpoints]
}

run "rejects_anthropic_endpoint_without_api_key_secret" {
  command = plan

  variables {
    additional_external_endpoints = {
      "anthropic-claude" = {
        model        = "gpt-4o" # allowlisted, so only the secret check fires
        task         = "llm/v1/chat"
        table_prefix = "anthropic_claude"
        provider     = "anthropic"
      }
    }
  }

  expect_failures = [databricks_model_serving.endpoints]
}

run "rejects_openai_endpoint_without_deployment_name" {
  command = plan

  variables {
    additional_external_endpoints = {
      "azure-gpt-4o-extra" = {
        model        = "gpt-4o"
        task         = "llm/v1/chat"
        table_prefix = "azure_gpt4o_extra"
      }
    }
  }

  expect_failures = [databricks_model_serving.endpoints]
}

# ── Agent-waste monitors (monitoring.tf) ────────────────────────────────────

run "agent_waste_monitors_off_by_default" {
  command = plan

  assert {
    condition     = length(databricks_alert_v2.agent_waste) == 0 && length(databricks_directory.agent_waste_monitors) == 0
    error_message = "No alerts or folder may be created while var.agent_waste_monitors is null."
  }
}

run "agent_waste_monitors_generate_usage_alerts" {
  command = plan

  variables {
    agent_waste_monitors = {
      warehouse_id  = "abc123def456"
      notify_emails = ["mlops-team@example.com"]
      workspace_id  = "1234567890"
    }
  }

  # Payload alert stays off unless explicitly enabled; the three
  # system-table alerts are always generated (a deny-list exists in the YAML).
  assert {
    condition     = join(",", keys(databricks_alert_v2.agent_waste)) == "blocked-model-attempts,error-loops,error-rate"
    error_message = "Expected exactly the error-loops, error-rate and blocked-model-attempts alerts by default."
  }

  # The SQL is generated from the endpoint catalog and scoped to the workspace.
  assert {
    condition = (
      strcontains(databricks_alert_v2.agent_waste["error-loops"].query_text, "'azure-gpt-4o'")
      && strcontains(databricks_alert_v2.agent_waste["error-loops"].query_text, "'databricks-claude-sonnet-4-6'")
      && strcontains(databricks_alert_v2.agent_waste["error-loops"].query_text, "se.workspace_id = '1234567890'")
    )
    error_message = "error-loops SQL must cover managed + governed endpoints and carry the workspace filter."
  }

  # Deny-listed endpoints are watched by blocked-model-attempts only —
  # their 429s must not pollute the error-loop / error-rate signals.
  assert {
    condition = (
      strcontains(databricks_alert_v2.agent_waste["blocked-model-attempts"].query_text, "'databricks-claude-haiku-4-5'")
      && !strcontains(databricks_alert_v2.agent_waste["error-loops"].query_text, "'databricks-claude-haiku-4-5'")
      && !strcontains(databricks_alert_v2.agent_waste["error-rate"].query_text, "'databricks-claude-haiku-4-5'")
    )
    error_message = "Blocked endpoints must appear only in the blocked-model-attempts query."
  }

  assert {
    condition = (
      databricks_alert_v2.agent_waste["error-loops"].evaluation.source.name == "failed_calls"
      && databricks_alert_v2.agent_waste["error-loops"].evaluation.threshold.value.double_value == 10
      && databricks_alert_v2.agent_waste["error-rate"].evaluation.threshold.value.double_value == 20
      && databricks_alert_v2.agent_waste["error-loops"].warehouse_id == "abc123def456"
    )
    error_message = "Alert evaluation must use the documented default thresholds and the supplied warehouse."
  }
}

run "agent_waste_payload_alert_covers_every_chat_table" {
  command = plan

  variables {
    inference_table_prefix = "team-a"
    fallback_enabled       = true
    agent_waste_monitors = {
      warehouse_id                 = "abc123def456"
      notify_emails                = ["mlops-team@example.com"]
      payload_alerts_enabled       = true
      tool_error_turns_per_session = 5
    }
  }

  assert {
    condition     = contains(keys(databricks_alert_v2.agent_waste), "tool-error-loops")
    error_message = "payload_alerts_enabled = true must create the tool-error-loops alert."
  }

  # Every chat endpoint's payload table — external, fallback and governed
  # foundation — is in the UNION; the embeddings table is not.
  assert {
    condition = (
      strcontains(databricks_alert_v2.agent_waste["tool-error-loops"].query_text, "main.model_serving_logs.team_a_azure_gpt4o_payload")
      && strcontains(databricks_alert_v2.agent_waste["tool-error-loops"].query_text, "main.model_serving_logs.team_a_azure_gpt_chat_fallback_payload")
      && strcontains(databricks_alert_v2.agent_waste["tool-error-loops"].query_text, "main.model_serving_logs.team_a_databricks_claude_sonnet_4_6_payload")
      && !strcontains(databricks_alert_v2.agent_waste["tool-error-loops"].query_text, "team_a_azure_embeddings_payload")
    )
    error_message = "tool-error-loops SQL must union every chat payload table (with the sanitized workspace prefix) and skip embeddings."
  }

  assert {
    condition     = databricks_alert_v2.agent_waste["tool-error-loops"].evaluation.threshold.value.double_value == 5
    error_message = "tool_error_turns_per_session must drive the tool-error-loops threshold."
  }
}

run "rejects_agent_waste_monitors_without_recipients" {
  command = plan

  variables {
    agent_waste_monitors = {
      warehouse_id  = "abc123def456"
      notify_emails = []
    }
  }

  expect_failures = [var.agent_waste_monitors]
}

run "rejects_agent_waste_monitors_with_bad_cron" {
  command = plan

  variables {
    agent_waste_monitors = {
      warehouse_id  = "abc123def456"
      notify_emails = ["mlops-team@example.com"]
      schedule_cron = "0 * * * *" # 5-field crontab syntax, not Quartz
    }
  }

  expect_failures = [var.agent_waste_monitors]
}
