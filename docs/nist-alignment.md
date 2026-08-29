# NIST alignment

This deployment is designed to align with [NIST AI RMF 1.0](https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.100-1.pdf)
and the AI-relevant control families of [NIST SP 800-53 Rev. 5](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf).
The table below maps the controls we currently satisfy *through code* to the
mechanism that implements them. One control surface is not pure Terraform:
the pre-provisioned `databricks-*` Foundation Model endpoints are governed
out-of-band by `scripts/apply-ai-gateway.sh` (PUT
`/api/2.0/serving-endpoints/{name}/ai-gateway`), re-run by applies whose triggers changed (YAML hash, workspace settings) via
`terraform_data.ai_gateway_reconciler` in `modules/workspace-stack/main.tf`.
Items marked **operational** require a runbook or process outside the repo.

> This is a self-assessment to support a control conversation, not a formal
> attestation. Confirm the mapping with your security/compliance reviewer.

## NIST AI RMF (AI 100-1)

| Function | Subcategory | How this project addresses it |
|---|---|---|
| **GOVERN** | GOVERN-1.1 (legal & policy mapping) | All AI traffic flows through Databricks serving endpoints with the AI Gateway enabled, giving a single audit surface for policy enforcement. |
| GOVERN | GOVERN-1.4 (risk management roles) | Account-level groups (`environments/account/`) plus per-workspace `databricks_mws_permission_assignment` separate operator from consumer roles. |
| GOVERN | GOVERN-4.1 (workforce accountability) | The per-workspace `<workspace>-model-serving` SP (e.g. `dbx-dev-model-serving`) is the only identity allowed to call Azure OpenAI; the calling user is recorded per request in the inference tables (`requester`). |
| **MAP** | MAP-2.1 (system inventory) | `modules/model-serving/model_defaults.yaml` is the single source of truth: allowlisted external models, the external endpoints, the governed foundation endpoints, and the deny-list. `terraform state list` inventories the Terraform-managed external endpoints; the pre-provisioned `databricks-*` endpoints live outside state and are inventoried in the YAML. |
| MAP | MAP-3.4 (third-party components) | Models are explicitly enumerated as either *external* (Azure AI Foundry / Anthropic) or *foundation* (Databricks `system.ai.*`) in `model_defaults.yaml` — provenance is visible in code. |
| **MEASURE** | MEASURE-2.1 / 2.6 (performance & robustness) | `system.serving.endpoint_usage` captures latency and status per call; inference tables capture full prompts/completions for offline evaluation. |
| MEASURE | MEASURE-2.7 (security testing) | Rate limits default from `gateway_defaults` in `model_defaults.yaml` and can be overridden per workspace via `model_serving_rate_limits`; fallback routing is toggled via `model_serving_fallback_enabled`. |
| **MANAGE** | MANAGE-2.2 (incident response) | Inference table + endpoint usage data is queryable in SQL. Blocking a model is one edit to `disabled_foundation_models` plus an apply — the reconciler PUTs `rate_limit = 0` and fails the apply if any endpoint could not be reconciled, so governance drift is never silent. |
| MANAGE | MANAGE-4.1 (post-deployment monitoring) | UC inference tables are managed Delta tables — point Databricks SQL alerts or Lakehouse Monitoring at them. `databricks_budget` alerts (`environments/account/budgets.tf`) watch monthly LLM spend, optionally with a `BLOCK_USAGE` brake on AI Gateway budgets. |

## NIST SP 800-53 Rev. 5

| Family | Control | Implementation |
|---|---|---|
| **AC** | AC-2 Account Management | Groups are created once at the account level (`databricks_group` in `environments/account/`) and granted workspace access per group via `databricks_mws_permission_assignment` (USER); the deployment SP gets ADMIN the same way. The `<workspace>-model-serving` SP is dedicated to model serving and has no other roles. |
| AC | AC-3 Access Enforcement | RBAC: Access Connector MSI → `Storage Blob Data Contributor` on the UC storage account only (the broader Storage Account Contributor was removed for least privilege). Model serving SP → `Cognitive Services OpenAI User` on the Foundry account only. Endpoint ACLs: one authoritative `databricks_permissions` resource per endpoint grants consumer groups `CAN_QUERY` and admin groups `CAN_MANAGE`. |
| AC | AC-4 Information Flow Enforcement | VNet injection + NSGs with Databricks delegations; Secure Cluster Connectivity (`no_public_ip = true`) keeps cluster-to-control-plane traffic outbound only. |
| AC | AC-6 Least Privilege | All grants are scoped: storage roles to one storage account, the OpenAI role to one Cognitive Services account, UC privileges granted per catalog as an explicit list that excludes `MANAGE` and `APPLY_TAG` (reserved for the owner group). |
| **AU** | AU-2 Event Logging | `usage_tracking_config.enabled = true` on every endpoint — including blocked foundation endpoints, so attempts against them still land in `system.serving.endpoint_usage`. |
| AU | AU-3 Content of Audit Records | Inference tables include request, response, requester, latency, and status. |
| AU | AU-12 Audit Record Generation | Inference tables are Delta tables on GRS-replicated UC storage; `force_destroy = false` on the metastore (`environments/account/main.tf`) and the inference-table catalog (`modules/unity-catalog/main.tf`) prevents an apply from dropping logged records. |
| **CM** | CM-2 Baseline Configuration | All infrastructure is in Terraform with remote state and committed `.terraform.lock.hcl` files; CI runs `terraform init -lockfile=readonly`, so lock drift fails the build instead of being rewritten silently. Drift detection: `terraform plan` (on demand, plus a PR plan job gated behind `ENABLE_CI_PLAN`). |
| CM | CM-7 Least Functionality | External endpoints exist only if declared, and a plan-time precondition rejects any model not in `allowed_external_models`. Pre-provisioned `databricks-*` endpoints cannot be deleted; non-approved ones are throttled to zero via `disabled_foundation_models` → `rate_limit = 0`. That deny-list is **fail-open** for newly released endpoints — see Gaps. |
| **IA** | IA-2 Identification & Authentication | Workspace logins are via AAD; service-to-service auth uses managed identities (Access Connector MSI for storage) and the model-serving SP with Entra ID tokens (`openai_api_type = "azuread"`) for Foundry. CI authenticates with GitHub OIDC (`github-oidc-azure`, `ARM_USE_OIDC`) — no cloud secret stored in CI. The only long-lived secret is the SP client secret, held in a Databricks secret scope and consumed by endpoints as a `{{secrets/<scope>/<key>}}` reference, never plaintext. |
| IA | IA-5 Authenticator Management | `azuread_service_principal_password` is Terraform-managed; rotating it is a single `-replace` apply — the new value flows into `databricks_secret.sp_client_secret` and every endpoint picks it up through the secret reference. Anthropic API keys are secret references to pre-existing workspace secrets and never enter state. **Operational**: schedule the rotation (see Gaps). |
| **SC** | SC-7 Boundary Protection | VNet injection, public/private subnet split, NSGs, optional `public_network_access_enabled = false` for production. |
| SC | SC-8 Transmission Confidentiality | Storage account: `https_traffic_only_enabled = true`, `min_tls_version = TLS1_2`. Workspace endpoints are HTTPS-only. |
| SC | SC-12 Cryptographic Key Establishment | Workspace `infrastructure_encryption_enabled = true` adds a second encryption layer on DBFS. |
| SC | SC-28 Protection of Information at Rest | ADLS Gen2 with HNS + GRS for UC storage; Databricks-managed encryption for control-plane data. |
| **SI** | SI-4 System Monitoring | Inference tables + `endpoint_usage` enable real-time monitoring queries; rate limits provide automatic abuse protection. |
| SI | SI-10 Information Input Validation | The gateway is the single chokepoint for input controls. AI Gateway guardrails (safety filters, PII behavior) are wired through `gateway_defaults.guardrails` in `model_defaults.yaml` and the `model_serving_guardrails` override, but ship disabled by default — see Gaps. |

## Gaps and operational follow-ups

These are not implemented in code (or are known limitations of the chosen
mechanism) and need an external process to fully satisfy the corresponding
controls:

- **Fail-open deny-list** (CM-7, AC-3): foundation-model governance is a
  deny-list. A newly released pre-provisioned `databricks-*` endpoint is
  fully callable until someone adds it to `disabled_foundation_models` and
  an apply re-runs the reconciler. `allowed_foundation_entities` is audit
  documentation (also exported as a module output), **not** an enforced
  allowlist. Review the list whenever Databricks announces new
  pay-per-token models; a fail-closed alternative (revoking the default
  EXECUTE on `system.ai` and granting per model) needs account-team
  enablement and is out of scope for this demo.
- **Drift between applies** (CM-2, CM-7): the reconciler re-asserts
  foundation-endpoint gateway config only when `terraform apply` runs. A UI
  edit to rate limits or inference tables on those endpoints persists until
  the next apply. Schedule `scripts/apply-ai-gateway.sh` via a CI cron or a
  Databricks Job for continuous reconciliation, and consider a scheduled
  `terraform plan` for general infra drift.
- **Key/secret rotation cadence** (IA-5): the model-serving SP password
  should be rotated on a defined schedule, e.g. a quarterly
  `terraform apply -replace='module.stack.module.model_serving[0].azuread_service_principal_password.model_serving'`.
- **UC storage network controls** (AC-4, SC-7): the UC storage account has
  no storage firewall. Deny-by-default requires a resource-instance rule
  for the Access Connector plus an IP allowlist/private endpoint for the
  deployer — accepted for this demo, tracked here as a production
  hardening gap (see the comment in `modules/unity-catalog/main.tf`).
- **Customer-managed keys** (SC-12, SC-28): workspace and storage currently
  use Microsoft-managed keys. Add `customer_managed_key` blocks if your
  policy requires CMK.
- **Private endpoints** (SC-7): consider Private Link for the workspace
  control plane and the Foundry account in regulated environments.
- **Centralised log forwarding** (AU-6): forward `system.serving.*` and
  inference tables to your SIEM (Sentinel, Splunk, etc.).
- **Content safety** (SI-10): the guardrail knobs exist in code but are off
  by default — enable `gateway_defaults.guardrails` in
  `model_defaults.yaml` (or `model_serving_guardrails` per workspace), or
  pair the gateway with Azure AI Content Safety, for prompt-injection /
  harmful-content filtering.
- **Model approval workflow** (GOVERN-1.4): require PR review on changes to
  `modules/model-serving/model_defaults.yaml` (and the
  `model_serving_external_endpoints` /
  `model_serving_additional_external_endpoints` overrides) via a
  `CODEOWNERS` file — not yet present in this repo.
