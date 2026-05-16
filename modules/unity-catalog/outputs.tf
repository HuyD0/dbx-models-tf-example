output "catalog_name" {
  description = "Name of the Unity Catalog `main` catalog"
  value       = var.create_main_catalog ? databricks_catalog.main[0].name : "main"
}

output "inference_catalog_name" {
  description = "Catalog used for model serving inference tables"
  value       = local.manage_inference_catalog ? databricks_catalog.inference[0].name : (var.create_main_catalog ? databricks_catalog.main[0].name : "main")
}

output "schema_name" {
  description = "Name of the inference table schema (managed value if local, else passed-through input)"
  value       = length(databricks_schema.model_serving_logs) > 0 ? databricks_schema.model_serving_logs[0].name : var.inference_table_schema
}

output "schema_catalog_name" {
  description = "Catalog that contains the inference table schema"
  value       = length(databricks_schema.model_serving_logs) > 0 ? databricks_schema.model_serving_logs[0].catalog_name : var.inference_table_catalog
}

output "storage_account_name" {
  description = "Name of the ADLS Gen2 storage account backing Unity Catalog"
  value       = azurerm_storage_account.unity_catalog.name
}

output "metastore_id" {
  description = "Unity Catalog metastore ID assigned to this workspace"
  value       = var.metastore_id
}
