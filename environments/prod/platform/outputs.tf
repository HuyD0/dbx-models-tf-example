output "workspace_url" {
  value = module.stack.workspace_url
}

output "workspace_id" {
  value = module.stack.workspace_id
}

output "inference_catalog" {
  description = "Catalog name workload workspaces should write inference tables to."
  value       = var.inference_table_catalog
}

output "inference_schema" {
  description = "Schema name workload workspaces should write inference tables to."
  value       = var.inference_table_schema
}
