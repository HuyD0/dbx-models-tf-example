terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}

resource "azurerm_databricks_access_connector" "this" {
  name                = "${var.workspace_name}-ac"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_databricks_workspace" "this" {
  name                = var.workspace_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  tags                = var.tags

  managed_resource_group_name           = var.managed_resource_group_name
  infrastructure_encryption_enabled     = var.infrastructure_encryption_enabled
  public_network_access_enabled         = var.public_network_access_enabled
  network_security_group_rules_required = var.public_network_access_enabled ? "AllRules" : "NoAzureDatabricksRules"
  default_storage_firewall_enabled      = true
  access_connector_id                   = azurerm_databricks_access_connector.this.id

  custom_parameters {
    no_public_ip                                         = var.no_public_ip
    virtual_network_id                                   = var.vnet_id
    public_subnet_name                                   = var.public_subnet_name
    public_subnet_network_security_group_association_id  = var.public_nsg_association_id
    private_subnet_name                                  = var.private_subnet_name
    private_subnet_network_security_group_association_id = var.private_nsg_association_id
  }
}
