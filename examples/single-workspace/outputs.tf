output "workspace_url" {
  description = "Databricks workspace URL."
  value       = module.stack.workspace_url
}

output "model_serving_endpoints" {
  description = "Names of the Terraform-managed model serving endpoints."
  value       = module.stack.model_serving_endpoints
}
