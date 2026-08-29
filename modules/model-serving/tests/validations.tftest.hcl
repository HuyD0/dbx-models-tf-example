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
