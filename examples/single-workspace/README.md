# Example: single governed workspace

The smallest end-to-end use of `modules/workspace-stack`: one VNet-injected
Databricks workspace with Unity Catalog, the model-serving endpoints from
`model_defaults.yaml`, and the AI-gateway reconciler for the pre-provisioned
`databricks-*` endpoints.

This example is **compile-checked in CI** (`terraform init -backend=false &&
terraform validate`), so it always matches the current module interface.

## Prerequisites

- The account layer applied once (`environments/account/`) — you need its
  `metastore_id` output and a deployment SP registered in the account.
- An Azure AI Foundry (Cognitive Services) account with the model
  deployments listed in `modules/model-serving/model_defaults.yaml`.

## Usage

```bash
cd examples/single-workspace

# Real deployments need remote state — copy the backend block from
# environments/dbx-dev/providers.tf before applying anything you care about.

terraform init
terraform plan \
  -var subscription_id=<azure-subscription-uuid> \
  -var databricks_account_id=<databricks-account-uuid> \
  -var metastore_id=<metastore-uuid> \
  -var deployment_sp_client_id=<sp-client-id>
```

Replace `aif-example` / `rg-aifoundry-example` in `main.tf` with your AI
Foundry account, or set `enable_model_serving = false` for a
workspace-plus-Unity-Catalog-only deployment.
