output "workspace_url" {
  description = "Databricks workspace URL"
  value       = module.stack.workspace_url
}

output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace"
  value       = module.stack.workspace_id
}

output "workspace_resource_id" {
  description = "Numeric Databricks workspace ID"
  value       = module.stack.workspace_resource_id
}

output "access_connector_id" {
  description = "Resource ID of the Databricks Access Connector"
  value       = module.stack.access_connector_id
}

output "uc_storage_account_name" {
  description = "Storage account backing the Unity Catalog metastore"
  value       = module.stack.uc_storage_account_name
}

output "metastore_id" {
  description = "Unity Catalog metastore ID"
  value       = module.stack.metastore_id
}

output "inference_catalog_name" {
  description = "Catalog used for model serving inference tables"
  value       = module.stack.inference_catalog_name
}

output "model_serving_endpoints" {
  description = "Names of all provisioned model serving endpoints"
  value       = module.stack.model_serving_endpoints
}

output "agent_waste_alert_names" {
  description = "Scheduled agent-waste SQL alerts created for this workspace (empty when disabled)"
  value       = module.stack.agent_waste_alert_names
}
