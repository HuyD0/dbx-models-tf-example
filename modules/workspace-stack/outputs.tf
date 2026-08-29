output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace."
  value       = module.workspace.workspace_id
}

output "workspace_url" {
  description = "Databricks workspace URL (https://adb-....azuredatabricks.net)."
  value       = module.workspace.workspace_url
}

output "workspace_resource_id" {
  description = "Numeric Databricks workspace ID (used by the accounts API and the account env's workspace_ids map)."
  value       = module.workspace.workspace_resource_id
}

output "resource_group_name" {
  description = "Name of the resource group holding all workspace resources."
  value       = azurerm_resource_group.this.name
}

output "access_connector_id" {
  description = "Azure resource ID of the Access Connector used by Unity Catalog."
  value       = module.workspace.access_connector_id
}

output "uc_storage_account_name" {
  description = "Name of the Unity Catalog ADLS Gen2 storage account."
  value       = module.unity_catalog.storage_account_name
}

output "metastore_id" {
  description = "Unity Catalog metastore ID assigned to this workspace."
  value       = module.unity_catalog.metastore_id
}

output "inference_catalog_name" {
  description = "Catalog receiving inference tables (null when this workspace does not own one)."
  value       = module.unity_catalog.inference_catalog_name
}

output "model_serving_endpoints" {
  description = "Names of the Terraform-managed model serving endpoints (empty when serving is disabled)."
  value       = var.enable_model_serving ? module.model_serving[0].endpoint_names : []
}
