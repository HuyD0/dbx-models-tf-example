output "workspace_id" {
  value = module.workspace.workspace_id
}

output "workspace_url" {
  value = module.workspace.workspace_url
}

output "workspace_resource_id" {
  value = module.workspace.workspace_resource_id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "access_connector_id" {
  value = module.workspace.access_connector_id
}

output "uc_storage_account_name" {
  value = module.unity_catalog.storage_account_name
}

output "metastore_id" {
  value = module.unity_catalog.metastore_id
}

output "inference_catalog_name" {
  value = module.unity_catalog.inference_catalog_name
}

output "model_serving_endpoints" {
  value = var.enable_model_serving ? module.model_serving[0].endpoint_names : []
}
