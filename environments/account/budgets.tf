# ── Cost governance: budgets + budget (serverless usage) policies ───────────
# Driven entirely by budget_defaults.yaml (schema-validated in CI) — the
# account-scope analogue of modules/model-serving/model_defaults.yaml. Edit
# the YAML to change thresholds, recipients, tags, or policy grants; never
# duplicate these values in tfvars.
#
# All resources here require the account-level provider (this environment's
# default provider) and an account-admin identity. databricks_budget is
# Public Preview.
#
# To adopt a budget or policy created out-of-band in the UI:
#   terraform import 'databricks_budget.this["<key>"]' "<account_id>|<budget_configuration_id>"
#   terraform import 'databricks_budget_policy.this["<key>"]' "<policy_id>"

locals {
  budget_defaults = yamldecode(file("${path.module}/budget_defaults.yaml"))

  budgets         = local.budget_defaults.budgets
  budget_policies = local.budget_defaults.budget_policies
}

# Monthly USD list-price monitors. resource_type UNITY_AI_GATEWAY scopes a
# budget to LLM spend (external models + pay-per-token foundation models,
# near-real-time, supports BLOCK_USAGE); ALL_RESOURCES covers everything
# with up to 24h alert lag.
resource "databricks_budget" "this" {
  for_each = local.budgets

  display_name  = each.value.display_name
  resource_type = "BUDGET_RESOURCE_TYPE_${try(each.value.resource_type, "ALL_RESOURCES")}"

  dynamic "filter" {
    for_each = length(try(each.value.filter.workspaces, [])) + length(try(each.value.filter.tags, {})) > 0 ? [try(each.value.filter, {})] : []
    content {
      dynamic "workspace_id" {
        for_each = length(try(filter.value.workspaces, [])) > 0 ? [1] : []
        content {
          operator = "IN"
          values   = [for w in filter.value.workspaces : var.workspace_ids[w]]
        }
      }

      dynamic "tags" {
        for_each = try(filter.value.tags, {})
        content {
          key = tags.key
          value {
            operator = "IN"
            values   = tags.value
          }
        }
      }
    }
  }

  dynamic "alert_configurations" {
    for_each = each.value.alerts
    content {
      # The only values the API accepts today — budgets are monthly,
      # cumulative, USD list price.
      time_period        = "MONTH"
      trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
      quantity_type      = "LIST_PRICE_DOLLARS_USD"
      quantity_threshold = alert_configurations.value.threshold_usd

      dynamic "action_configurations" {
        for_each = try(alert_configurations.value.emails, [])
        content {
          action_type = "EMAIL_NOTIFICATION"
          target      = action_configurations.value
        }
      }

      # BLOCK_USAGE must omit target; only valid on AI Gateway budgets.
      dynamic "action_configurations" {
        for_each = try(alert_configurations.value.block_usage, false) ? [1] : []
        content {
          action_type = "BLOCK_USAGE"
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for w in try(each.value.filter.workspaces, []) : contains(keys(var.workspace_ids), w)])
      error_message = "Budget '${each.key}' filters on a workspace name missing from var.workspace_ids. Add the workspace's numeric ID (terraform output workspace_resource_id in its environment) to the workspace_ids map."
    }

    precondition {
      condition     = length(distinct([for a in each.value.alerts : a.threshold_usd])) == length(each.value.alerts)
      error_message = "Budget '${each.key}' has duplicate alert thresholds — Databricks requires each of the (max 4) alerts on a budget to use a unique quantity_threshold."
    }
  }
}

# Budget policies ("serverless usage policies"): their custom tags are
# stamped onto system.billing.usage records of any serverless resource the
# policy is attached to — the chargeback key for model serving endpoints
# (attached via each workspace env's model_serving_budget_policy_id).
resource "databricks_budget_policy" "this" {
  for_each = local.budget_policies

  policy_name = each.value.policy_name

  # Plugin-framework list attribute (note `=`, unlike legacy blocks).
  custom_tags = [
    for k, v in each.value.custom_tags : { key = k, value = v }
  ]

  binding_workspace_ids = (
    length(try(each.value.bind_workspaces, [])) > 0
    ? [for w in each.value.bind_workspaces : var.workspace_ids[w]]
    : null # null = usable account-wide
  )

  lifecycle {
    precondition {
      condition     = alltrue([for w in try(each.value.bind_workspaces, []) : contains(keys(var.workspace_ids), w)])
      error_message = "Budget policy '${each.key}' binds a workspace name missing from var.workspace_ids. Add the workspace's numeric ID (terraform output workspace_resource_id in its environment) to the workspace_ids map."
    }
  }
}

# Who may use/manage each policy. AUTHORITATIVE per rule set: this resource
# owns ALL grants on the policy and overwrites any made in the UI — import
# existing rule sets before first apply if grants were added manually.
# databricks_permissions does not support budget policies; this rule-set
# resource is the only Terraform mechanism.
#
# The deployment SP is always a manager: without use/manager rights on the
# policy, workspace applies that set budget_policy_id on an endpoint are
# rejected by the API.
resource "databricks_access_control_rule_set" "budget_policy" {
  for_each = local.budget_policies

  name = "accounts/${var.databricks_account_id}/budgetPolicies/${databricks_budget_policy.this[each.key].policy_id}/ruleSets/default"

  dynamic "grant_rules" {
    for_each = length(try(each.value.user_groups, [])) > 0 ? [1] : []
    content {
      principals = [for g in each.value.user_groups : "groups/${g}"]
      role       = "roles/budgetPolicy.user"
    }
  }

  grant_rules {
    principals = concat(
      [for g in try(each.value.manager_groups, []) : "groups/${g}"],
      ["servicePrincipals/${var.deployment_sp_client_id}"],
    )
    role = "roles/budgetPolicy.manager"
  }
}
