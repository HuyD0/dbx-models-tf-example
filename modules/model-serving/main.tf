terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0, < 4.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.126.0, < 2.0"
    }
  }
}

locals {
  model_defaults = yamldecode(file("${path.module}/model_defaults.yaml"))

  default_external_endpoints = local.model_defaults.external_endpoints

  # Approved allowlists — precondition blocks on each resource enforce these.
  # Foundation entities live in the YAML for documentation/audit; the
  # apply-ai-gateway.sh script reads the same YAML to govern the
  # pre-provisioned `databricks-*` endpoints (see comment block below).
  allowed_external_models     = toset(local.model_defaults.allowed_external_models)
  allowed_foundation_entities = toset(local.model_defaults.allowed_foundation_entities)

  # Normalize endpoint entries so YAML-sourced maps (which omit optional
  # keys) and typed variables share one shape. provider defaults to openai.
  endpoints = {
    for name, e in merge(
      var.external_endpoints != null ? var.external_endpoints : local.default_external_endpoints,
      var.additional_external_endpoints,
      ) : name => {
      model           = e.model
      deployment_name = try(e.deployment_name, null)
      task            = e.task
      table_prefix    = e.table_prefix
      provider        = coalesce(try(e.provider, null), "openai")
      api_key_secret  = try(e.api_key_secret, null)
    }
  }

  # ── Default AI Gateway policy (model_defaults.yaml → gateway_defaults) ──────
  # Workspace-level variables override the YAML; empty/null variables fall
  # back to these centrally-governed defaults.
  gateway_defaults = local.model_defaults.gateway_defaults

  default_rate_limits = concat(
    [{
      calls          = local.gateway_defaults.rate_limits.endpoint_qpm
      key            = "endpoint"
      renewal_period = "minute"
      tokens         = try(local.gateway_defaults.rate_limits.endpoint_tpm, null)
      principal      = null
    }],
    [{
      calls          = local.gateway_defaults.rate_limits.user_qpm
      key            = "user"
      renewal_period = "minute"
      tokens         = null
      principal      = null
    }],
    [for g in try(local.gateway_defaults.rate_limits.user_group_limits, []) : {
      calls          = g.qpm
      key            = "user_group"
      renewal_period = "minute"
      tokens         = try(g.tpm, null)
      principal      = g.group
    }],
  )

  effective_rate_limits = length(var.rate_limits) > 0 ? var.rate_limits : local.default_rate_limits

  yaml_guardrails = try(local.model_defaults.gateway_defaults.guardrails, null)
  default_guardrails = local.yaml_guardrails == null ? null : {
    input = {
      safety       = try(local.yaml_guardrails.input_safety, false)
      pii_behavior = try(local.yaml_guardrails.input_pii_behavior, null)
    }
    output = {
      safety       = try(local.yaml_guardrails.output_safety, false)
      pii_behavior = try(local.yaml_guardrails.output_pii_behavior, null)
    }
  }

  effective_guardrails = var.guardrails != null ? var.guardrails : local.default_guardrails

  # Foundation Model API governance is fully YAML-driven. Surface the lists
  # to ops scripts and outputs only.
  governed_foundation_endpoints = local.model_defaults.foundation_endpoints
  disabled_foundation_models    = toset(local.model_defaults.disabled_foundation_models)

  # Sanitize the workspace prefix to alphanumerics + underscores so it's a
  # valid Unity Catalog table-name component.
  table_prefix = var.inference_table_prefix == "" ? "" : "${replace(lower(var.inference_table_prefix), "/[^a-z0-9]/", "_")}_"
}

data "azurerm_cognitive_account" "aif" {
  name                = var.ai_foundry_name
  resource_group_name = var.ai_foundry_resource_group
}

# SP dedicated to Databricks model serving → AI Foundry auth.
# A managed identity cannot be used here because external model endpoints
# run inside Databricks' own infrastructure, not in this Azure subscription.
resource "azuread_application" "model_serving" {
  display_name = "${var.name_prefix}-model-serving"
}

resource "azuread_service_principal" "model_serving" {
  client_id = azuread_application.model_serving.client_id
}

resource "azuread_service_principal_password" "model_serving" {
  service_principal_id = azuread_service_principal.model_serving.id
}

# ── Databricks secret scope — stores the model serving SP credential ─────────
# Using a native Databricks secret scope keeps the credential out of endpoint
# API responses and Databricks audit logs. The value is stored sensitive in
# Terraform state, which is encrypted at rest by the Azure Storage backend.
# For state-level zero-knowledge protection, migrate to an AKV-backed scope
# (keyvault_metadata) and grant the Databricks workspace MSI GET on the vault.
resource "databricks_secret_scope" "model_serving" {
  name = "${var.name_prefix}-model-serving-scope"
}

resource "databricks_secret" "sp_client_secret" {
  scope        = databricks_secret_scope.model_serving.name
  key          = "sp-client-secret"
  string_value = azuread_service_principal_password.model_serving.value
}

resource "azurerm_role_assignment" "databricks_oai_user" {
  scope                = data.azurerm_cognitive_account.aif.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azuread_service_principal.model_serving.object_id
}

resource "databricks_model_serving" "endpoints" {
  for_each = local.endpoints

  name = each.key

  # Serverless usage policy for cost attribution. In-place update; null = no
  # policy. Not applied by the platform to external-model endpoints today —
  # see var.budget_policy_id.
  budget_policy_id = var.budget_policy_id

  dynamic "tags" {
    for_each = var.databricks_tags
    content {
      key   = tags.key
      value = tags.value
    }
  }

  # Never remove the whole ai_gateway block from an existing endpoint —
  # disable features field-by-field (enabled = false) instead. The provider
  # panics on updates that drop the block entirely.
  ai_gateway {
    usage_tracking_config {
      enabled = true
    }

    dynamic "guardrails" {
      for_each = local.effective_guardrails == null ? [] : [local.effective_guardrails]
      content {
        dynamic "input" {
          for_each = guardrails.value.input == null ? [] : [guardrails.value.input]
          content {
            safety = input.value.safety
            dynamic "pii" {
              for_each = input.value.pii_behavior == null ? [] : [input.value.pii_behavior]
              content {
                behavior = pii.value
              }
            }
          }
        }
        dynamic "output" {
          for_each = guardrails.value.output == null ? [] : [guardrails.value.output]
          content {
            safety = output.value.safety
            dynamic "pii" {
              for_each = output.value.pii_behavior == null ? [] : [output.value.pii_behavior]
              content {
                behavior = pii.value
              }
            }
          }
        }
      }
    }

    dynamic "rate_limits" {
      for_each = local.effective_rate_limits
      content {
        calls          = rate_limits.value.calls
        key            = rate_limits.value.key
        renewal_period = rate_limits.value.renewal_period
        tokens         = rate_limits.value.tokens
        principal      = rate_limits.value.principal
      }
    }

    inference_table_config {
      enabled           = true
      table_name_prefix = "${local.table_prefix}${each.value.table_prefix}"
      catalog_name      = var.inference_table_catalog
      schema_name       = var.inference_table_schema
    }
  }

  config {
    served_entities {
      name = each.key
      external_model {
        name     = each.value.model
        provider = each.value.provider
        task     = each.value.task

        dynamic "openai_config" {
          for_each = each.value.provider == "openai" ? [1] : []
          content {
            openai_api_type               = "azuread"
            openai_api_base               = data.azurerm_cognitive_account.aif.endpoint
            openai_api_version            = var.openai_api_version
            openai_deployment_name        = each.value.deployment_name
            microsoft_entra_tenant_id     = azuread_service_principal.model_serving.application_tenant_id
            microsoft_entra_client_id     = azuread_application.model_serving.client_id
            microsoft_entra_client_secret = "{{secrets/${databricks_secret_scope.model_serving.name}/sp-client-secret}}"
          }
        }

        # Anthropic API key is a secret REFERENCE to a pre-existing workspace
        # secret — the key value never enters Terraform state or API responses.
        dynamic "anthropic_config" {
          for_each = each.value.provider == "anthropic" ? [1] : []
          content {
            anthropic_api_key = "{{secrets/${each.value.api_key_secret}}}"
          }
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.databricks_oai_user]

  lifecycle {
    precondition {
      condition     = contains(local.allowed_external_models, each.value.model)
      error_message = "External endpoint '${each.key}' uses model '${each.value.model}' which is not in allowed_external_models in model_defaults.yaml. Add it to the allowlist before deploying."
    }

    precondition {
      condition     = each.value.provider != "openai" || each.value.deployment_name != null
      error_message = "External endpoint '${each.key}' uses provider 'openai' and must set deployment_name (the Azure OpenAI deployment to target)."
    }

    precondition {
      condition     = each.value.provider != "anthropic" || can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", each.value.api_key_secret))
      error_message = "External endpoint '${each.key}' uses provider 'anthropic' and must set api_key_secret to a '<scope>/<key>' Databricks secret path."
    }
  }
}

# ── Fallback routing endpoint (gpt-4o → gpt-5-mini on 5xx) ──────────────────
# Both Azure OpenAI deployments are configured as direct external_model served
# entities on the SAME endpoint. The AI gateway's fallback_config rotates
# between them on 5xx. This avoids the Databricks restriction:
#   "Requests to external models from Databricks model serving are not permitted"
# which blocks chaining one external endpoint to another via
# provider="databricks-model-serving".

resource "databricks_model_serving" "gpt_chat_fallback" {
  count = var.fallback_enabled ? 1 : 0
  name  = "azure-gpt-chat-fallback"

  budget_policy_id = var.budget_policy_id

  dynamic "tags" {
    for_each = var.databricks_tags
    content {
      key   = tags.key
      value = tags.value
    }
  }

  ai_gateway {
    fallback_config {
      enabled = true
    }

    usage_tracking_config {
      enabled = true
    }

    dynamic "guardrails" {
      for_each = local.effective_guardrails == null ? [] : [local.effective_guardrails]
      content {
        dynamic "input" {
          for_each = guardrails.value.input == null ? [] : [guardrails.value.input]
          content {
            safety = input.value.safety
            dynamic "pii" {
              for_each = input.value.pii_behavior == null ? [] : [input.value.pii_behavior]
              content {
                behavior = pii.value
              }
            }
          }
        }
        dynamic "output" {
          for_each = guardrails.value.output == null ? [] : [guardrails.value.output]
          content {
            safety = output.value.safety
            dynamic "pii" {
              for_each = output.value.pii_behavior == null ? [] : [output.value.pii_behavior]
              content {
                behavior = pii.value
              }
            }
          }
        }
      }
    }

    dynamic "rate_limits" {
      for_each = local.effective_rate_limits
      content {
        calls          = rate_limits.value.calls
        key            = rate_limits.value.key
        renewal_period = rate_limits.value.renewal_period
        tokens         = rate_limits.value.tokens
        principal      = rate_limits.value.principal
      }
    }

    inference_table_config {
      enabled           = true
      table_name_prefix = "${local.table_prefix}azure_gpt_chat_fallback"
      catalog_name      = var.inference_table_catalog
      schema_name       = var.inference_table_schema
    }
  }

  config {
    # Primary: gpt-4o — receives 100% of traffic.
    served_entities {
      name = "gpt-4o-primary"
      external_model {
        name     = "gpt-4o"
        provider = "openai"
        task     = "llm/v1/chat"
        openai_config {
          openai_api_type               = "azuread"
          openai_api_base               = data.azurerm_cognitive_account.aif.endpoint
          openai_api_version            = var.openai_api_version
          openai_deployment_name        = "gpt-4o"
          microsoft_entra_tenant_id     = azuread_service_principal.model_serving.application_tenant_id
          microsoft_entra_client_id     = azuread_application.model_serving.client_id
          microsoft_entra_client_secret = "{{secrets/${databricks_secret_scope.model_serving.name}/sp-client-secret}}"
        }
      }
    }

    # Fallback: gpt-5-mini — auto-invoked on 5xx from the primary.
    served_entities {
      name = "gpt-5-mini-fallback"
      external_model {
        name     = "gpt-5-mini"
        provider = "openai"
        task     = "llm/v1/chat"
        openai_config {
          openai_api_type               = "azuread"
          openai_api_base               = data.azurerm_cognitive_account.aif.endpoint
          openai_api_version            = var.openai_api_version
          openai_deployment_name        = "gpt-5-mini"
          microsoft_entra_tenant_id     = azuread_service_principal.model_serving.application_tenant_id
          microsoft_entra_client_id     = azuread_application.model_serving.client_id
          microsoft_entra_client_secret = "{{secrets/${databricks_secret_scope.model_serving.name}/sp-client-secret}}"
        }
      }
    }

    traffic_config {
      routes {
        served_model_name  = "gpt-4o-primary"
        traffic_percentage = 100
      }
      routes {
        served_model_name  = "gpt-5-mini-fallback"
        traffic_percentage = 0
      }
    }
  }

  depends_on = [azurerm_role_assignment.databricks_oai_user]
}

# ── Databricks Foundation Model API endpoints (pre-provisioned) ─────────────
# The `databricks-*` endpoint name prefix is reserved by Databricks: the
# provider rejects CREATE and UPDATE for any name with that prefix. These
# endpoints exist in every workspace automatically and cannot be deleted.
#
# Governance is therefore applied OUT-OF-BAND by scripts/apply-ai-gateway.sh,
# which reads modules/model-serving/model_defaults.yaml (the same file this
# module reads) and PUTs `/api/2.0/serving-endpoints/{name}/ai-gateway`:
#
#   • foundation_endpoints       → rate limits + inference table logging
#   • disabled_foundation_models → rate_limit = 0 (HTTP 429 on every call)
#
# A `terraform_data.ai_gateway_reconciler` resource in workspace-stack/main.tf
# invokes the script on every `terraform apply` (triggered on YAML hash +
# workspace URL), so the desired state is re-asserted whenever Terraform
# runs. For continuous drift correction between applies, schedule the same
# script via a CI cron or a Databricks Job.

# ── Group permissions on all endpoints ──────────────────────────────────────
# All ACL entries for a given endpoint must live in a single
# databricks_permissions resource — the provider treats it as authoritative
# and multiple resources on the same endpoint will overwrite each other.
locals {
  all_consumer_groups = toset(compact(concat(
    var.write_access_group != null ? [var.write_access_group] : [],
    var.consumer_groups,
  )))

  # Per-endpoint access_control list: every consumer gets CAN_QUERY,
  # every admin gets CAN_MANAGE. Admins win if a group is in both lists.
  endpoint_access_controls = concat(
    [for g in sort(tolist(local.all_consumer_groups)) : {
      group_name       = g
      permission_level = "CAN_QUERY"
    } if !contains(var.admin_groups, g)],
    [for g in sort(var.admin_groups) : {
      group_name       = g
      permission_level = "CAN_MANAGE"
    }],
  )

  endpoints_needing_permissions = length(local.endpoint_access_controls) > 0 ? keys(local.endpoints) : []
}

resource "databricks_permissions" "endpoints" {
  for_each            = var.endpoint_permissions_enabled ? toset(local.endpoints_needing_permissions) : toset([])
  serving_endpoint_id = databricks_model_serving.endpoints[each.key].serving_endpoint_id

  dynamic "access_control" {
    for_each = local.endpoint_access_controls
    content {
      group_name       = access_control.value.group_name
      permission_level = access_control.value.permission_level
    }
  }
}

resource "databricks_permissions" "gpt_chat_fallback" {
  count               = var.endpoint_permissions_enabled && var.fallback_enabled && length(local.endpoint_access_controls) > 0 ? 1 : 0
  serving_endpoint_id = databricks_model_serving.gpt_chat_fallback[0].serving_endpoint_id

  dynamic "access_control" {
    for_each = local.endpoint_access_controls
    content {
      group_name       = access_control.value.group_name
      permission_level = access_control.value.permission_level
    }
  }
}
