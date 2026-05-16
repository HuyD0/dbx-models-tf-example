output "storage_account_name" {
  description = "Storage account name to use in backend.tf"
  value       = azurerm_storage_account.state.name
}

output "resource_group_name" {
  description = "Resource group containing the state storage account"
  value       = azurerm_resource_group.state.name
}

output "container_name" {
  description = "Blob container name to use in backend.tf"
  value       = azurerm_storage_container.state.name
}

output "sp_client_id" {
  description = "Service principal app (client) ID — set as ARM_CLIENT_ID"
  value       = azuread_application.terraform.client_id
}

output "sp_object_id" {
  description = "Service principal object ID"
  value       = azuread_service_principal.terraform.object_id
}

output "key_vault_name" {
  description = "Key Vault holding the SP credentials"
  value       = azurerm_key_vault.sp.name
}

output "key_vault_id" {
  description = "Key Vault resource ID"
  value       = azurerm_key_vault.sp.id
}

output "sp_secret_fetch_cmd" {
  description = "Command to populate ARM_CLIENT_SECRET in your local .env"
  value       = "az keyvault secret show --vault-name ${azurerm_key_vault.sp.name} --name terraform-sp-secret --query value -o tsv"
}
