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
