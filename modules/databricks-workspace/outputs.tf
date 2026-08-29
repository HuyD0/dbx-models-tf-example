output "workspace_url" {
  description = "Workspace URL with https:// prefix (consumed by the AI-gateway reconciler and health-check scripts, and re-exported by workspace-stack)"
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace"
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_resource_id" {
  description = "Numeric Databricks workspace ID (used by the Databricks provider)"
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "managed_resource_group_id" {
  description = "ID of the managed resource group created by Databricks"
  value       = azurerm_databricks_workspace.this.managed_resource_group_id
}

output "access_connector_id" {
  description = "Resource ID of the Databricks Access Connector (for Unity Catalog storage credential)"
  value       = azurerm_databricks_access_connector.this.id
}

output "access_connector_principal_id" {
  description = "Principal ID of the Access Connector managed identity (for RBAC assignments)"
  value       = azurerm_databricks_access_connector.this.identity[0].principal_id
}
