module "stack" {
  source = "../../../modules/workspace-stack"

  team        = "platform"
  environment = "prod"

  location                = var.location
  resource_group_name     = var.resource_group_name
  workspace_name          = var.workspace_name
  vnet_cidr               = var.vnet_cidr
  tags                    = var.tags
  uc_storage_account_name = var.uc_storage_account_name
  metastore_id            = var.metastore_id

  # The platform workspace OWNS the centralized inference catalog.
  # It does not own a `main` catalog (other workspaces have their own) and it
  # does not serve any models. Its only job is to host `llmlogs` and govern
  # who can read/write it.
  create_main_catalog      = false
  create_inference_catalog = true
  inference_table_catalog  = var.inference_table_catalog
  inference_table_schema   = var.inference_table_schema

  # Admin-only ALL_PRIVILEGES (read + write + manage). No other group gets
  # SELECT on the catalog or schema.
  inference_admin_groups = var.inference_admin_groups

  # Cross-workspace writer principals. Members of these groups (typically
  # team owner/deployer groups whose identities apply Terraform in the team
  # workspaces) can write inference tables here but cannot read them.
  inference_writer_groups = var.inference_writer_groups

  enable_model_serving        = false
  workspace_groups            = []
  consumer_groups             = []
  contributor_group_object_id = var.contributor_group_object_id

  deployment_sp_client_id = var.deployment_sp_client_id

  providers = {
    databricks          = databricks
    databricks.accounts = databricks.accounts
  }
}
