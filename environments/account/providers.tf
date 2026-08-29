terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.126"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "tfstatee18f8286"
    container_name       = "tfstate"
    key                  = "databricks/account/terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}

data "azurerm_client_config" "current" {}

# Account-level Databricks provider only — no workspace provider here.
provider "databricks" {
  auth_type       = "azure-client-secret"
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  azure_tenant_id = data.azurerm_client_config.current.tenant_id
}
