# NIST alignment

This deployment is designed to align with [NIST AI RMF 1.0](https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.100-1.pdf)
and the AI-relevant control families of [NIST SP 800-53 Rev. 5](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf).
The table below maps the controls we currently satisfy *through Terraform* to
the resource that implements them. Items marked **operational** require a
runbook or process outside Terraform.

> This is a self-assessment to support a control conversation, not a formal
> attestation. Confirm the mapping with your security/compliance reviewer.

## NIST AI RMF (AI 100-1)

| Function | Subcategory | How this project addresses it |
|---|---|---|
| **GOVERN** | GOVERN-1.1 (legal & policy mapping) | All AI traffic flows through one Databricks gateway, giving a single audit surface for policy enforcement. |
| GOVERN | GOVERN-1.4 (risk management roles) | Account-level groups (`environments/account/`) plus per-workspace `databricks_mws_permission_assignment` separate operator from consumer roles. |
| GOVERN | GOVERN-4.1 (workforce accountability) | Service principal `dbw-model-serving` is the only identity allowed to call Azure OpenAI; user identity is preserved in inference tables (`request_metadata.principal`). |
| **MAP** | MAP-2.1 (system inventory) | Every model is declared in code (`modules/model-serving/main.tf`); `terraform state list` is the canonical inventory. |
| MAP | MAP-3.4 (third-party components) | Models are explicitly enumerated as either *external* (Azure AI Foundry) or *foundation* (Databricks `system.ai.*`) — provenance is visible in the module. |
| **MEASURE** | MEASURE-2.1 / 2.6 (performance & robustness) | `system.serving.endpoint_usage` captures latency and status per call; inference tables capture full prompts/completions for offline evaluation. |
| MEASURE | MEASURE-2.7 (security testing) | Rate limits + fallback routing are configured per endpoint via `model_serving_rate_limits` and `model_serving_fallback_enabled`. |
| **MANAGE** | MANAGE-2.2 (incident response) | Inference table + endpoint usage data is queryable in SQL; PAT used for fallback chaining has a 90-day TTL forcing rotation on redeploy. |
| MANAGE | MANAGE-4.1 (post-deployment monitoring) | UC inference tables are managed Delta tables — point Databricks SQL alerts or Lakehouse Monitoring at them. |

## NIST SP 800-53 Rev. 5

| Family | Control | Implementation |
|---|---|---|
| **AC** | AC-2 Account Management | AAD group `ad-dbx` controls workspace access via `databricks_mws_permission_assignment`. SP `dbw-model-serving` is dedicated to model serving and has no other roles. |
| AC | AC-3 Access Enforcement | RBAC: Access Connector MSI → `Storage Blob Data Contributor` + `Storage Account Contributor` (UC storage only). Model serving SP → `Cognitive Services OpenAI User` on the Foundry account only. |
| AC | AC-4 Information Flow Enforcement | VNet injection + NSGs with Databricks delegations; Secure Cluster Connectivity (`no_public_ip = true`) keeps cluster-to-control-plane traffic outbound only. |
| AC | AC-6 Least Privilege | All grants are scoped: storage roles to one storage account, OpenAI role to one Cognitive Services account, UC privileges per catalog. |
| **AU** | AU-2 Event Logging | `usage_tracking_config.enabled = true` on every endpoint; `system.serving.endpoint_usage` retained by Databricks. |
| AU | AU-3 Content of Audit Records | Inference tables include request, response, principal, latency, status, token usage. |
| AU | AU-12 Audit Record Generation | Storage Account has versioning + GRS; UC catalog has `metastore_force_destroy = false` in prod to prevent accidental loss. |
| **CM** | CM-2 Baseline Configuration | All infrastructure is in Terraform with remote state and `terraform.lock.hcl`. Drift detection: `terraform plan`. |
| CM | CM-7 Least Functionality | Only the endpoints declared in the module exist; Foundry deployments are referenced by name and not auto-discovered. |
| **IA** | IA-2 Identification & Authentication | Workspace logins are via AAD; service-to-service auth uses managed identities (storage) and SP + AAD token (Foundry). No long-lived shared secrets except the SP password (managed by Terraform) and the 90-day fallback PAT. |
| IA | IA-5 Authenticator Management | `azuread_service_principal_password` rotates whenever Terraform re-creates it; the fallback PAT has `lifetime_seconds = 7776000`. **Operational**: schedule quarterly `terraform apply -replace` to rotate. |
| **SC** | SC-7 Boundary Protection | VNet injection, public/private subnet split, NSGs, optional `public_network_access_enabled = false` for production. |
| SC | SC-8 Transmission Confidentiality | Storage account: `https_traffic_only_enabled = true`, `min_tls_version = TLS1_2`. Workspace endpoints are HTTPS-only. |
| SC | SC-12 Cryptographic Key Establishment | Workspace `infrastructure_encryption_enabled = true` adds a second encryption layer on DBFS. |
| SC | SC-28 Protection of Information at Rest | ADLS Gen2 with HNS + GRS for UC storage; Databricks-managed encryption for control-plane data. |
| **SI** | SI-4 System Monitoring | Inference tables + `endpoint_usage` enable real-time monitoring queries; rate limits provide automatic abuse protection. |
| SI | SI-10 Information Input Validation | Centralised gateway is the single chokepoint where input filters / Databricks AI Guardrails can be added. |

## Gaps and operational follow-ups

These are not implemented in Terraform and need an external process to fully
satisfy the corresponding controls:

- **Key/secret rotation cadence** (IA-5): the model-serving SP password and
  fallback PAT should be rotated on a defined schedule. Add a CI job that
  runs `terraform apply -replace=module.model_serving.azuread_service_principal_password.model_serving`.
- **Customer-managed keys** (SC-12, SC-28): workspace and storage currently
  use Microsoft-managed keys. Add `customer_managed_key` blocks if your
  policy requires CMK.
- **Private endpoints** (SC-7): consider Private Link for the workspace
  control plane and the Foundry account in regulated environments.
- **Centralised log forwarding** (AU-6): forward `system.serving.*` and
  inference tables to your SIEM (Sentinel, Splunk, etc.).
- **Content safety** (SI-10): pair the gateway with Azure AI Content Safety
  or Databricks AI Guardrails for prompt-injection / harmful-content
  filtering.
- **Model approval workflow** (GOVERN-1.4): require PR review on changes to
  `model_serving_external_endpoints` / `model_serving_foundation_endpoints`
  via `CODEOWNERS`.
