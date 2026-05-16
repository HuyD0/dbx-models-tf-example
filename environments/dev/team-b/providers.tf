terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.115"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<YOUR_STATE_STORAGE_ACCOUNT>"
    container_name       = "tfstate"
    key                  = "databricks/dev/team-b/terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  use_oidc        = true
  subscription_id = var.subscription_id
}

provider "azuread" {
  use_oidc = true
}

data "azurerm_client_config" "current" {}

provider "databricks" {
  auth_type = "azure-client-secret"
  # Construct the ARM resource ID from variables rather than module outputs to
  # avoid a cyclic dependency (provider → module output → workspace resource →
  # provider). The Databricks provider derives the workspace URL from this ID.
  azure_workspace_resource_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Databricks/workspaces/${var.workspace_name}"
}

provider "databricks" {
  alias           = "accounts"
  auth_type       = "azure-client-secret"
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  azure_tenant_id = data.azurerm_client_config.current.tenant_id
}
