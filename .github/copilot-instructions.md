# Copilot instructions — terraform-databricks

This repository provisions an **Azure Databricks-based AI/ML platform** that
acts as a centralised **AI gateway** in front of Databricks foundation models
and Azure AI Foundry-hosted models, governed by Unity Catalog and aligned to
NIST AI RMF / SP 800-53.

When assisting in this repo, **stay strictly within these subject areas**:

- **Azure Databricks** — workspaces, VNet injection, Access Connectors,
  cluster policies, jobs, SQL warehouses, system tables.
- **Unity Catalog** — metastores, catalogs/schemas, grants, external
  locations, storage credentials, lineage, audit, inference tables.
- **Databricks Model Serving & AI Gateway** — external model endpoints,
  foundation model endpoints, provisioned throughput, usage tracking,
  inference tables, rate limits, guardrails, fallback routing,
  `system.serving.endpoint_usage`.
- **Azure AI Foundry** — model deployments (GPT-4o, GPT-5-mini, etc.),
  Foundry projects, hub/project resources, content safety, evaluations,
  served as upstream providers behind the Databricks AI gateway.
- **Terraform on Azure** — `azurerm`, `databricks`, `azuread` providers;
  remote state (Azure Storage backend in `bootstrap/`); module composition;
  `for_each`, `moved`, `import` blocks; provider aliasing for
  account vs workspace-scoped Databricks resources.
- **LLMOps / MLOps / AIOps** — MLflow (tracking, registry, model
  versions, aliases), prompt/eval workflows, inference table-based
  evaluation, drift & quality monitoring, Databricks Lakehouse Monitoring,
  agent evaluation, CI/CD for models and endpoints.
- **AI Gateway patterns** — centralised inference, key/secret rotation
  through Azure Key Vault + Databricks secret scopes, per-team rate limits,
  cost attribution, PII redaction, jailbreak/safety filters, fallback &
  load balancing across providers.
- **AI/ML platform best practices** — least-privilege identity (managed
  identities, service principals, AAD groups), network isolation
  (VNet injection, private endpoints, NCC), audit logging, secret
  management, environment separation (dev/prod), policy-as-code,
  NIST AI RMF + SP 800-53 control alignment.

## Out of scope — do not drift

Politely redirect or decline requests that fall outside the topics above
(e.g. generic web app development, non-Azure cloud guidance, frontend
frameworks, gaming, unrelated DevOps tooling). If a request is ambiguous,
ask whether it maps to one of the in-scope areas before proceeding.

## Repository conventions

- **Modules** live in `modules/` and are composed by `modules/workspace-stack`.
  Prefer extending existing modules over creating new top-level modules.
- **Environments** under `environments/<env>/` each have their own
  `providers.tf`, `terraform.tfvars`, and remote state config.
  `environments/account/` is account-scoped (metastore, AAD groups);
  `environments/dbx-dev/` is the single workspace-scoped environment —
  it owns the `main` Unity Catalog catalog directly and its own model
  serving endpoints.
- **Provider aliases**: use the account-level Databricks provider for
  metastores, groups, and metastore assignments; use the workspace-level
  provider for catalogs, schemas, grants, endpoints, jobs.
- **Model serving** is enabled directly on the `dbx-dev` workspace
  (`enable_model_serving = true`); there is no separate catalog-only
  "platform" workspace in this repo.
- **Secrets**: never inline credentials. Use Azure Key Vault + Databricks
  secret scopes, surfaced as `{{secrets/scope/key}}` references in
  endpoint configs.
- **Validation**: run `terraform fmt -recursive`, `terraform validate`,
  `tflint`, and `scripts/pre-push-check.sh` before suggesting a change is
  complete. Pre-commit hooks (`.pre-commit-config.yaml`) are authoritative.
- **Docs**: substantive changes to model-serving, architecture, or controls
  must be reflected in the matching file under `docs/`.

## Coding guidance

- Pin provider versions in `required_providers`; do not loosen constraints.
- Prefer `for_each` with stable string keys over `count`.
- Use `sensitive = true` for any variable or output carrying secrets,
  tokens, or connection strings.
- Tag every Azure resource with at least `environment`, `owner`, and
  `cost-center` where the module exposes tags.
- For new AI gateway endpoints: always enable `usage_tracking_config`,
  `inference_table_config`, and a sensible `rate_limits` block.
- For new Unity Catalog objects: grant the minimum privileges, prefer
  group principals over user principals, and document the grant in the
  module's `README` or `outputs.tf`.

## When in doubt

Consult `docs/model-serving.md`, `docs/architecture.md`, and
`docs/nist-alignment.md` before proposing architectural changes. Reference
the Databricks Terraform provider, Azure Databricks, and Azure AI Foundry
official docs over blog posts.
