terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.115"
      configuration_aliases = [databricks, databricks.accounts]
    }
  }
}

locals {
  merged_tags = merge(var.tags, {
    team        = var.team
    environment = var.environment
    managed_by  = "terraform"
  })

  # Tags applied to Databricks objects (catalogs, schemas, model serving
  # endpoints) that support tagging. Keep this minimal — Databricks treats
  # these as governance metadata, not Azure billing tags.
  databricks_tags = {
    env            = var.environment
    owner          = var.team
    cost_center    = lookup(var.tags, "cost-center", var.team)
    data_sensitive = lookup(var.tags, "data_sensitivity", "public")
    shortcode      = lookup(var.tags, "shortcode", "aiml")
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.merged_tags
}

resource "azurerm_role_assignment" "contributor" {
  count                = var.contributor_group_object_id != null ? 1 : 0
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = var.contributor_group_object_id
}

module "networking" {
  source              = "../networking"
  workspace_name      = var.workspace_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  vnet_cidr           = var.vnet_cidr
  tags                = local.merged_tags
}

module "workspace" {
  source                            = "../databricks-workspace"
  workspace_name                    = var.workspace_name
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  sku                               = var.sku
  tags                              = local.merged_tags
  managed_resource_group_name       = var.managed_resource_group_name
  no_public_ip                      = var.no_public_ip
  public_network_access_enabled     = var.public_network_access_enabled
  infrastructure_encryption_enabled = var.infrastructure_encryption_enabled
  vnet_id                           = module.networking.vnet_id
  public_subnet_name                = module.networking.public_subnet_name
  private_subnet_name               = module.networking.private_subnet_name
  public_nsg_association_id         = module.networking.public_nsg_association_id
  private_nsg_association_id        = module.networking.private_nsg_association_id
}

# --- Deployment SP workspace admin ---
# Look up the deployment SP in the Databricks account and grant it ADMIN on
# this workspace so it can manage workspace-scoped resources (external
# locations, secret scopes, model serving endpoints) atomically with workspace
# creation. The SP is registered in the account by environments/account.

data "databricks_service_principal" "deployment_sp" {
  provider       = databricks.accounts
  application_id = var.deployment_sp_client_id
}

resource "databricks_mws_permission_assignment" "deployment_sp_admin" {
  provider     = databricks.accounts
  workspace_id = module.workspace.workspace_resource_id
  principal_id = data.databricks_service_principal.deployment_sp.id
  permissions  = ["ADMIN"]
}

module "unity_catalog" {
  source = "../unity-catalog"

  workspace_name                = var.workspace_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  tags                          = local.merged_tags
  uc_storage_account_name       = var.uc_storage_account_name
  inference_table_catalog       = var.inference_table_catalog
  inference_table_schema        = var.inference_table_schema
  create_inference_catalog      = var.create_inference_catalog
  inference_admin_groups        = var.inference_admin_groups
  inference_writer_groups       = var.inference_writer_groups
  access_connector_id           = module.workspace.access_connector_id
  access_connector_principal_id = module.workspace.access_connector_principal_id
  workspace_resource_id         = module.workspace.workspace_resource_id
  metastore_id                  = var.metastore_id
  create_external_location      = var.create_external_location
  create_main_catalog           = var.create_main_catalog
  workspace_groups              = var.workspace_groups
  workspace_consumer_groups     = var.consumer_groups
  workspace_reader_groups       = var.reader_groups
  databricks_tags               = local.databricks_tags
  owner_group                   = var.uc_owner_group

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}

module "model_serving" {
  count                         = var.enable_model_serving ? 1 : 0
  source                        = "../model-serving"
  ai_foundry_name               = var.ai_foundry_name
  ai_foundry_resource_group     = var.ai_foundry_resource_group
  openai_api_version            = var.openai_api_version
  name_prefix                   = var.workspace_name
  inference_table_catalog       = var.inference_table_catalog
  inference_table_schema        = var.inference_table_schema
  inference_table_prefix        = coalesce(var.inference_table_prefix, var.team)
  fallback_enabled              = var.model_serving_fallback_enabled
  endpoint_permissions_enabled  = var.model_serving_endpoint_permissions_enabled
  rate_limits                   = var.model_serving_rate_limits
  external_endpoints            = var.model_serving_external_endpoints
  additional_external_endpoints = var.model_serving_additional_external_endpoints
  consumer_groups               = var.consumer_groups
  admin_groups                  = var.model_serving_admin_groups
  guardrails                    = var.model_serving_guardrails
  databricks_tags               = local.databricks_tags

  providers = {
    databricks = databricks
  }

  depends_on = [module.unity_catalog]
}

# ── AI Gateway reconciler ───────────────────────────────────────────────────
# Pre-provisioned `databricks-*` Foundation Model endpoints cannot be
# managed by the Terraform provider (reserved name prefix). This resource
# re-asserts their AI-gateway config (rate limits + inference tables for
# approved models; rate_limit = 0 for blocked ones) on every `terraform
# apply`, by invoking scripts/apply-ai-gateway.sh in single-workspace mode.
#
# triggers_replace re-runs the provisioner whenever:
#   • the YAML governance file changes (filemd5 hash),
#   • the workspace URL changes (new workspace),
#   • the table prefix / catalog / schema changes.
#
# Out-of-band drift between applies (someone editing via UI) is NOT caught
# here — schedule the same script in CI or a Databricks Job for continuous
# reconciliation.
resource "terraform_data" "ai_gateway_reconciler" {
  count = var.enable_model_serving && var.ai_gateway_reconcile_on_apply ? 1 : 0

  triggers_replace = {
    yaml_hash     = module.model_serving[0].model_defaults_yaml_hash
    workspace_url = module.workspace.workspace_url
    prefix        = coalesce(var.inference_table_prefix, var.team)
    catalog       = var.inference_table_catalog
    schema        = var.inference_table_schema
  }

  provisioner "local-exec" {
    command     = "${path.module}/../../scripts/apply-ai-gateway.sh --single-workspace"
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      WORKSPACE_URL = module.workspace.workspace_url
      TABLE_PREFIX  = coalesce(var.inference_table_prefix, var.team)
      TABLE_CATALOG = var.inference_table_catalog
      TABLE_SCHEMA  = var.inference_table_schema
      YAML_PATH     = "${path.module}/../model-serving/model_defaults.yaml"
    }
  }

  depends_on = [module.model_serving]
}
