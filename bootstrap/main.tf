terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  use_oidc        = true
  subscription_id = var.subscription_id
}

provider "azuread" {
  use_oidc = true
}

locals {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = var.storage_account_name
  container_name       = "tfstate"
  sp_name              = "sp-terraform-databricks"
  kv_name              = "kv-tfsp-${substr(var.subscription_id, 0, 8)}"
}

# ── Import blocks for resources created before bootstrap was Terraformed ─────

import {
  to = azurerm_resource_group.state
  id = "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-state"
}

import {
  to = azurerm_resource_group.sp
  id = "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-sp"
}

import {
  to = azurerm_storage_account.state
  id = "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-state/providers/Microsoft.Storage/storageAccounts/<YOUR_STATE_STORAGE_ACCOUNT>"
}

import {
  to = azurerm_storage_container.state
  id = "https://<YOUR_STATE_STORAGE_ACCOUNT>.blob.core.windows.net/tfstate"
}

import {
  to = azurerm_role_assignment.state_contributor
  id = "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-state/providers/Microsoft.Storage/storageAccounts/<YOUR_STATE_STORAGE_ACCOUNT>/providers/Microsoft.Authorization/roleAssignments/<YOUR_ROLE_ASSIGNMENT_ID>"
}

import {
  to = azurerm_key_vault.sp
  id = "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-terraform-sp/providers/Microsoft.KeyVault/vaults/<YOUR_KV_NAME>"
}

resource "azurerm_resource_group" "state" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "state" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
  }
}

resource "azurerm_storage_container" "state" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "state_contributor" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── Service principal ────────────────────────────────────────────────────────

resource "azuread_application" "terraform" {
  display_name = local.sp_name
}

resource "azuread_service_principal" "terraform" {
  client_id = azuread_application.terraform.client_id
}

resource "random_password" "sp_secret_seed" {
  length  = 4
  special = false
  upper   = false
}

resource "azuread_service_principal_password" "terraform" {
  service_principal_id = azuread_service_principal.terraform.id
  display_name         = "managed-by-terraform-bootstrap"
  end_date             = "2028-05-16T00:00:00Z"
}

# ── Key Vault ────────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "sp" {
  name     = "rg-terraform-sp"
  location = var.location
  tags     = var.tags
}

resource "azurerm_key_vault" "sp" {
  name                       = local.kv_name
  resource_group_name        = azurerm_resource_group.sp.name
  location                   = azurerm_resource_group.sp.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  tags                       = var.tags
}

# Allow the person running bootstrap (you) to read/write secrets
resource "azurerm_role_assignment" "kv_current_user_admin" {
  scope                = azurerm_key_vault.sp.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Allow the SP to read its own secret (and any future secrets it needs)
resource "azurerm_role_assignment" "kv_sp_reader" {
  scope                = azurerm_key_vault.sp.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.terraform.object_id
}

# Store the SP client secret in Key Vault
resource "azurerm_key_vault_secret" "sp_secret" {
  name         = "terraform-sp-secret"
  value        = azuread_service_principal_password.terraform.value
  key_vault_id = azurerm_key_vault.sp.id
  content_type = "SP client secret for ${local.sp_name}"

  depends_on = [azurerm_role_assignment.kv_current_user_admin]
}

# Store the SP app ID alongside the secret for convenience
resource "azurerm_key_vault_secret" "sp_client_id" {
  name         = "terraform-sp-client-id"
  value        = azuread_application.terraform.client_id
  key_vault_id = azurerm_key_vault.sp.id
  content_type = "SP app (client) ID for ${local.sp_name}"

  depends_on = [azurerm_role_assignment.kv_current_user_admin]
}

# ── SP role assignments on the subscription ───────────────────────────────────
# Contributor — needed to create/update Azure resources (workspaces, VNets, etc.)

resource "azurerm_role_assignment" "sp_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

# Storage Blob Data Contributor — needed to read/write Terraform remote state
resource "azurerm_role_assignment" "sp_state_blob" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.terraform.object_id
}

# User Access Administrator scoped to *this subscription* (needed to create
# role assignments for managed identities / Unity Catalog access connectors).
# Scoped narrowly; remove if your pipeline runs as Owner.
resource "azurerm_role_assignment" "sp_uaa" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.terraform.object_id
}
