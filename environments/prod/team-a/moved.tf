# Migration: prod/team-a was a flat composition of sub-modules.
# Consolidated into workspace-stack (same pattern as dev/team-* and prod/team-b).
# These moved blocks prevent destroy+recreate of live resources on the next apply.

moved {
  from = azurerm_resource_group.this
  to   = module.stack.azurerm_resource_group.this
}

moved {
  from = azurerm_role_assignment.contributor
  to   = module.stack.azurerm_role_assignment.contributor
}

moved {
  from = module.networking
  to   = module.stack.module.networking
}

moved {
  from = module.workspace
  to   = module.stack.module.workspace
}

moved {
  from = module.unity_catalog
  to   = module.stack.module.unity_catalog
}

moved {
  from = module.model_serving
  to   = module.stack.module.model_serving[0]
}

moved {
  from = terraform_data.ai_gateway_reconciler
  to   = module.stack.terraform_data.ai_gateway_reconciler[0]
}
