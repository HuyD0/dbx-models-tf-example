# Budgets & budget policies (cost governance)

Account-level cost governance for the centralized LLM platform lives in
`environments/account/` and is driven by one schema-validated file:

```
environments/account/budget_defaults.yaml          # source of truth
environments/account/budget_defaults.schema.json   # validated in pre-commit + CI
environments/account/budgets.tf                    # materializes the YAML
```

It is deliberately separate from `modules/model-serving/model_defaults.yaml`:
that file's hash re-triggers the per-workspace AI-gateway reconciler, and a
budget threshold change must not cause workspace-side re-applies.

Two distinct mechanisms, both Public Preview, both account-scoped:

| | `databricks_budget` | `databricks_budget_policy` |
|---|---|---|
| Purpose | **Monitor/alert** on monthly spend | **Attribute** serverless spend via custom tags |
| Acts on | `system.billing.usage` records | Tags stamped onto `system.billing.usage` records |
| Attach point | Nothing — filters select usage | `budget_policy_id` on serving endpoints, jobs, pipelines, apps |
| Actions | Email alerts; usage blocking (AI Gateway budgets) | None — it's metadata |
| UI name | Budgets | **Serverless usage policies** (renamed; API unchanged) |

## 1. Budgets

Each entry in `budgets:` becomes a monthly cumulative USD list-price
monitor with up to 4 alerts (unique thresholds, one email block per
recipient).

Two flavors via `resource_type`:

- **`UNITY_AI_GATEWAY`** — the primary LLM-spend monitor. Tracks
  pay-per-token foundation models (including the pre-provisioned
  `databricks-*` endpoints Terraform cannot manage), external model
  endpoints, and `ai_query` batch inference. Near-real-time alerting, and
  the only flavor that supports `block_usage: true` (reject further AI
  Gateway traffic past the threshold — approximate enforcement, in-flight
  requests finish; a brake, not a hard cap). Provisioned-throughput
  serving is **not** covered.
- **`ALL_RESOURCES`** (default) — everything in the account, with up to
  24h lag between usage and alert. Keep at least one unfiltered
  ALL_RESOURCES budget as a catch-all: tag-filtered budgets silently miss
  untagged usage.

Filters:

- `tags:` match custom tags on billing records. The workspace-stack module
  stamps `cost_center` (defaults to the team name) on every serving
  endpoint, which is what the shipped `llm-spend-monthly` budget keys on.
  For AI Gateway budgets, tags match *endpoint* tags, not per-request tags.
- `workspaces:` names resolved through the `workspace_ids` variable
  (name → numeric ID — see the handoff below).

Caveats worth knowing: budget "spend" is **USD list price** (billing
credits and negotiated discounts are ignored), the calendar month is the
only window, email is the only notification channel, and max 1,000
budgets per account.

## 2. Budget policies (serverless usage policies)

Each entry in `budget_policies:` becomes a policy whose `custom_tags`
(max 20; `budget-policy-*` keys reserved) land on the
`system.billing.usage` records of any serverless resource running under
it — the chargeback key for model serving.

Grants are managed by an **authoritative**
`databricks_access_control_rule_set` per policy:

- `user_groups` → `roles/budgetPolicy.user` (may attach the policy)
- `manager_groups` → `roles/budgetPolicy.manager`
- the deployment SP is *always* granted manager — without use/manager
  rights on the policy, workspace applies that set `budget_policy_id` on
  an endpoint are rejected by the API.

Authoritative means Terraform owns **all** grants on the policy: anything
added in the UI is removed on the next apply. If a policy already has
manual grants, import its rule set first.

`bind_workspaces` restricts where the policy is usable (empty = whole
account).

## 3. The policy → endpoint handoff

Same pattern as `metastore_id`, in reverse:

```bash
# 1. Apply account (creates budgets + policies):
cd environments/account && terraform apply
terraform output budget_policy_ids
# { "llm-serving-dev" = "3d2f9a8e-..." }

# 2. Attach to a workspace's serving endpoints:
cd ../dbx-dev
echo 'model_serving_budget_policy_id = "3d2f9a8e-..."' >> terraform.tfvars
terraform apply   # in-place update on every endpoint
```

And for budgets/policies that reference workspaces by name, feed the
numeric IDs back to the account env:

```bash
cd environments/dbx-dev && terraform output workspace_resource_id
# → add to environments/account/terraform.tfvars:
#   workspace_ids = { dbx-dev = 1234567890123456 }
```

> **External-model caveat:** Databricks does not currently apply usage
> policies to endpoints serving *external* models (all of this repo's
> Terraform-managed endpoints today). The attachment is shipped
> null-by-default and forward-looking; the **guaranteed** attribution
> path for external-model spend is endpoint tags + the tag-filtered
> `UNITY_AI_GATEWAY` budget, which works regardless.

## 4. Importing pre-existing objects

```bash
# Budget created in the UI:
terraform import 'databricks_budget.this["llm-spend-monthly"]' "<account_id>|<budget_configuration_id>"

# Policy created in the UI:
terraform import 'databricks_budget_policy.this["llm-serving-dev"]' "<policy_id>"

# Its rule set (BEFORE first apply, to preserve manual grants):
terraform import 'databricks_access_control_rule_set.budget_policy["llm-serving-dev"]' \
  "accounts/<account_id>/budgetPolicies/<policy_id>/ruleSets/default"
```

## 5. How this fits the governance picture

| Layer | Mechanism | Where |
|---|---|---|
| Who may call a model | endpoint ACLs (`CAN_QUERY`) + model allowlist/blocklist | workspace (`modules/model-serving`) |
| How much they may call | AI Gateway rate limits (QPM/TPM, per user/group) | `gateway_defaults` in `model_defaults.yaml` |
| What it costs, per team | endpoint tags + budget policy custom tags → `system.billing.usage` | account + workspace |
| When spend is too high | budgets (email alerts, optional AI Gateway usage blocking) | account (`budget_defaults.yaml`) |
| What was said | inference tables + `system.serving.endpoint_usage` | workspace |
