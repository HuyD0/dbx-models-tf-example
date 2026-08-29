output "endpoint_names" {
  description = "Names of all provisioned model serving endpoints (external/Azure-OpenAI)."
  value       = keys(databricks_model_serving.endpoints)
}

output "allowed_foundation_entities" {
  description = "Approved system.ai.* Foundation Model entity names from model_defaults.yaml. Audit documentation surfaced for ops tooling — NOT an enforced allowlist: enforcement is the disabled_foundation_models deny-list applied by apply-ai-gateway.sh, which is fail-open for newly released endpoints."
  value       = sort(tolist(local.allowed_foundation_entities))
}

output "governed_foundation_endpoints" {
  description = "Pre-provisioned `databricks-*` Foundation Model API endpoints governed via apply-ai-gateway.sh (rate limits + inference tables). Defined in modules/model-serving/model_defaults.yaml."
  value       = keys(local.governed_foundation_endpoints)
}

output "disabled_foundation_models" {
  description = "Pre-provisioned `databricks-*` Foundation Model API endpoints blocked via apply-ai-gateway.sh (rate_limit = 0). Defined in modules/model-serving/model_defaults.yaml."
  value       = sort(tolist(local.disabled_foundation_models))
}

output "model_defaults_yaml_hash" {
  description = "MD5 hash of model_defaults.yaml — used by workspace-stack's terraform_data reconciler to retrigger apply-ai-gateway.sh when the governance config changes."
  value       = filemd5("${path.module}/model_defaults.yaml")
}
