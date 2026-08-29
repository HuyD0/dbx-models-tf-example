# Minimal single-workspace deployment of the workspace-stack module:
# networking + workspace + Unity Catalog + model serving + AI-gateway
# reconciler, with every value a neutral placeholder.
#
# This example is compile-checked in CI (terraform init -backend=false &&
# terraform validate) so it can never drift from the module interface the
# way hand-written docs can. To actually deploy, copy it, add a remote
# state backend (see environments/dbx-dev/providers.tf), and replace the
# placeholder values.

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
      version = "~> 1.126"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

# Workspace-scoped Databricks provider. The ARM resource ID is built from
# variables (not module outputs) to avoid a provider → module output →
# provider cycle — the same pattern as environments/dbx-dev/providers.tf.
provider "databricks" {
  azure_workspace_resource_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Databricks/workspaces/${var.workspace_name}"
}

# Account-scoped Databricks provider — metastore assignment and group
# lookups happen at accounts.azuredatabricks.net.
provider "databricks" {
  alias      = "accounts"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

module "stack" {
  source = "../../modules/workspace-stack"

  team        = "example-team"
  environment = "dev"

  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_name      = var.workspace_name
  vnet_cidr           = "10.200.0.0/20"

  metastore_id            = var.metastore_id
  deployment_sp_client_id = var.deployment_sp_client_id

  # Model serving against an existing Azure AI Foundry account. Set
  # enable_model_serving = false for a workspace-only deployment.
  enable_model_serving      = true
  ai_foundry_name           = "aif-example"
  ai_foundry_resource_group = "rg-aifoundry-example"

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}
