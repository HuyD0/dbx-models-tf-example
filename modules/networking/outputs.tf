output "vnet_id" {
  description = "Resource ID of the VNet"
  value       = azurerm_virtual_network.this.id
}

output "public_subnet_name" {
  description = "Name of the public subnet"
  value       = azurerm_subnet.public.name
}

output "private_subnet_name" {
  description = "Name of the private subnet"
  value       = azurerm_subnet.private.name
}

output "public_nsg_association_id" {
  description = "Resource ID of the public subnet NSG association"
  value       = azurerm_subnet_network_security_group_association.public.id
}

output "private_nsg_association_id" {
  description = "Resource ID of the private subnet NSG association"
  value       = azurerm_subnet_network_security_group_association.private.id
}
