module "stack" {
  source = "../../modules/workspace-stack"

  team        = var.team
  environment = "dev"

  location                          = var.location
  resource_group_name               = var.resource_group_name
  workspace_name                    = var.workspace_name
  sku                               = var.sku
  tags                              = var.tags
  vnet_cidr                         = var.vnet_cidr
  managed_resource_group_name       = var.managed_resource_group_name
  no_public_ip                      = var.no_public_ip
  public_network_access_enabled     = var.public_network_access_enabled
  infrastructure_encryption_enabled = var.infrastructure_encryption_enabled

  metastore_id                = var.metastore_id
  uc_storage_account_name     = var.uc_storage_account_name
  inference_table_catalog     = var.inference_table_catalog
  inference_table_schema      = var.inference_table_schema
  create_external_location    = true
  create_main_catalog         = var.create_main_catalog
  enable_model_serving        = var.enable_model_serving
  workspace_groups            = var.workspace_groups
  consumer_groups             = var.consumer_groups
  contributor_group_object_id = var.contributor_group_object_id

  ai_foundry_name                             = var.ai_foundry_name
  ai_foundry_resource_group                   = var.ai_foundry_resource_group
  openai_api_version                          = var.openai_api_version
  model_serving_fallback_enabled              = var.model_serving_fallback_enabled
  model_serving_rate_limits                   = var.model_serving_rate_limits
  model_serving_external_endpoints            = var.model_serving_external_endpoints
  model_serving_additional_external_endpoints = var.model_serving_additional_external_endpoints
  model_serving_admin_groups                  = var.model_serving_admin_groups

  deployment_sp_client_id = var.deployment_sp_client_id

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}
