module "stack" {
  source = "../../../modules/workspace-stack"

  team        = "team-b"
  environment = "prod"

  location                = var.location
  resource_group_name     = var.resource_group_name
  workspace_name          = var.workspace_name
  vnet_cidr               = var.vnet_cidr
  tags                    = var.tags
  uc_storage_account_name = var.uc_storage_account_name
  metastore_id            = var.metastore_id

  # Shared inference catalog — owned by environments/prod/platform. See
  # team-a/team-b/dev for the full pattern explanation.
  create_main_catalog      = var.create_main_catalog
  create_inference_catalog = false
  inference_table_catalog  = var.inference_table_catalog
  inference_table_schema   = var.inference_table_schema
  inference_table_prefix   = "team_b"

  enable_model_serving                       = true
  ai_foundry_name                            = var.ai_foundry_name
  ai_foundry_resource_group                  = var.ai_foundry_resource_group
  openai_api_version                         = var.openai_api_version
  model_serving_fallback_enabled             = var.model_serving_fallback_enabled
  model_serving_endpoint_permissions_enabled = var.model_serving_endpoint_permissions_enabled
  model_serving_rate_limits                  = var.model_serving_rate_limits
  model_serving_external_endpoints           = var.model_serving_external_endpoints
  model_serving_admin_groups                 = var.model_serving_admin_groups
  model_serving_guardrails                   = var.model_serving_guardrails

  workspace_groups            = var.workspace_groups
  consumer_groups             = var.consumer_groups
  contributor_group_object_id = var.contributor_group_object_id

  deployment_sp_client_id = var.deployment_sp_client_id

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}
