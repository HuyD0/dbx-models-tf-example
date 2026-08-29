output "metastore_id" {
  description = "Unity Catalog metastore ID — pass to each workspace environment as metastore_id"
  value       = databricks_metastore.this.id
}

output "group_display_names" {
  description = "Display names of all created account-level groups (generic + per-team)"
  value = concat(
    [for g in databricks_group.this : g.display_name],
    [for g in databricks_group.team : g.display_name],
  )
}

output "budget_policy_ids" {
  description = "Budget (serverless usage) policy IDs by budget_defaults.yaml key — pass one to a workspace environment as model_serving_budget_policy_id to tag that workspace's serving-endpoint spend"
  value       = { for k, p in databricks_budget_policy.this : k => p.policy_id }
}

output "budget_configuration_ids" {
  description = "Budget configuration IDs by budget_defaults.yaml key — import handle is '<account_id>|<budget_configuration_id>'"
  value       = { for k, b in databricks_budget.this : k => b.budget_configuration_id }
}
