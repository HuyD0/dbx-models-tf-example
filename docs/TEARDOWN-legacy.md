# LEGACY full teardown runbook (pre-`dbx-dev`-consolidation topology)

This is a snapshot of the **original** `docs/TEARDOWN.md`, preserved because it
was never committed to git before this repo was consolidated to a single
`dbx-dev` workspace (`docs/TEARDOWN.md` and `scripts/teardown.sh` were both
untracked files at the time of consolidation, so `git checkout` cannot
recover them). If the six legacy workspaces below (`dev`/`prod` ×
`platform`/`team-a`/`team-b`) are still deployed in Azure, use **this doc**
and [`scripts/teardown-legacy.sh`](../scripts/teardown-legacy.sh) — not the
rewritten `docs/TEARDOWN.md` / `scripts/teardown.sh`, which only know about
`dbx-dev`.

**Recovery caveat**: `scripts/teardown-legacy.sh` calls `terraform destroy`
against each environment directory, which requires that directory's
`terraform.tfvars` to exist. Those files are gitignored (`*.tfvars`) and were
**never committed**. Only `environments/dev/platform/terraform.tfvars` and
`environments/dev/team-a/terraform.tfvars` were read during the
consolidation session (their key values are reproduced in a comment at the
top of `scripts/teardown-legacy.sh`) — `environments/dev/team-b` and all of
`environments/prod/*` tfvars were **not** captured and are **not**
recoverable from git. If those workspaces are still deployed, reconstruct
their tfvars from the remote Terraform state backend (storage account
`tfstatee18f8286`, containers under
`databricks/{dev,prod}/{platform,team-a,team-b}/terraform.tfstate`) or from
`az databricks workspace show` / Unity Catalog metadata before running
`destroy` against them. The `.tf` files (`main.tf`, `variables.tf`,
`outputs.tf`, `providers.tf`) for the deleted environments *are* recoverable
via `git log --diff-filter=D -- environments/dev environments/prod` then
`git show <sha>~1:environments/dev/team-b/main.tf` etc.

Destroys **everything** this repo used to manage — dev, **prod**, the Databricks
account-level objects, the Terraform state backend, the deployment service
principal — and then sweeps Azure for anything Terraform leaves behind.

**This is irreversible.** Remote state, the metastore, and all workspaces go
away. Work through it phase by phase with
[`scripts/teardown-legacy.sh`](../scripts/teardown-legacy.sh); do not run it
end-to-end unattended.

## Order (reverse of deploy)

Deploy was `bootstrap → account → platform → teams`, so teardown is:

| # | Phase | What dies | Auth as |
|---|-------|-----------|---------|
| 0 | `discover` | nothing — inventory only | SP |
| 1 | `teams` | `dev/prod` × `team-a/team-b` workspaces, VNets, UC storage, model serving | SP |
| 2 | `platform` | `dev/prod` platform workspaces + the inference catalogs `llmlogs_dev/prod` | SP |
| 3 | `account` | UC **metastore**, account groups, account SCIM SP | SP |
| 4 | `bootstrap` | **state storage** `tfstatee18f8286`, Key Vault, SP, sub-scope role assignments | **you** |
| 5 | `sweep` | purge soft-deleted KV, delete AAD app, verify RGs gone | **you** |

Teams must precede platform (teams write into the platform-owned inference
catalog). Bootstrap is **last** — it holds the remote state backend for phases
1–3 and the SP creds everything authenticates with.

## Auth model (two identities)

```bash
# Phases 1–3 run as the Terraform service principal:
az login                       # as yourself — needed to read the Key Vault
source scripts/dev-auth.sh     # pulls SP creds from kv-tfsp-ea936670, exports ARM_*

# Phase 4 (bootstrap) runs as YOU, in a *fresh* shell with no ARM_* vars:
#   - dev-auth.sh's creds live in the very Key Vault bootstrap deletes
#   - the SP can't cleanly delete itself or its own role assignments
# Open a new terminal, `az login`, and do NOT source dev-auth.sh.
```

The script enforces this: phases 1–3 abort if `ARM_CLIENT_ID` is unset;
`bootstrap` aborts if it *is* set.

## No `-auto-approve`

Every `terraform destroy` here is interactive. Terraform prints the plan and
makes you type `yes`. That plan **is** the safety gate — read it. The wrapper
adds a second `yes` per phase on top.

## Run it

```bash
az login && source scripts/dev-auth.sh

./scripts/teardown-legacy.sh discover     # confirm what actually exists before deleting
./scripts/teardown-legacy.sh teams
./scripts/teardown-legacy.sh platform
./scripts/teardown-legacy.sh account

# new terminal, az login only (no dev-auth.sh):
./scripts/teardown-legacy.sh bootstrap
./scripts/teardown-legacy.sh sweep
```

## Two things that will bite you

### 1. `force_destroy = false` on non-empty catalogs / metastore

These are the steps most likely to **error mid-run**:

- `databricks_catalog.inference` (`llmlogs_dev` / `llmlogs_prod`) in
  `modules/unity-catalog/main.tf` is hardcoded
  `force_destroy = false`. The serving endpoints auto-create **inference tables**
  in its `model_serving_logs` schema at runtime — Terraform doesn't track those,
  so `destroy` on `platform` fails on a non-empty schema/catalog.
- `databricks_metastore.this` in
  `environments/account/main.tf` is also
  `force_destroy = false`.

Pick one remedy **before** the phase that hits it:

- **Drop the data first** (preferred, surgical) — with a workspace still up:
  ```
  DROP SCHEMA IF EXISTS llmlogs_dev.model_serving_logs CASCADE;
  DROP CATALOG IF EXISTS llmlogs_dev CASCADE;     # repeat for llmlogs_prod
  ```
  then run the phase.
- **Flip `force_destroy = true`**, `terraform … apply` that one change, then
  `destroy`. Edit the `inference` catalog resource (and/or the metastore), e.g.
  `terraform -chdir=environments/dev/platform apply -target=...`. Verify the
  databricks provider honors `force_destroy` at destroy time for your provider
  version (1.115) before relying on it — drop-first is the sure path.

### 2. Bootstrap's placeholder `import {}` blocks

`bootstrap/main.tf` has `import {}` blocks with literal
`<YOUR_SUBSCRIPTION_ID>` placeholders. They're no-ops once the resources are in
local state (they already are), but if `terraform destroy` tries to process them
and errors, **comment the `import` blocks out** and re-run.

## What "all Azure resources" covers (the `sweep` phase)

Terraform destroy removes the resource groups and everything in them, but leaves
a few things the sweep handles:

- **Soft-deleted Key Vault** `kv-tfsp-ea936670` (eastus) — bootstrap sets
  `purge_soft_delete_on_destroy = false`, so it lingers ~7 days. `sweep` purges it.
- **AAD app registration** `sp-terraform-databricks` — only deleted if the
  identity running bootstrap has Graph perms; `sweep` checks and deletes it.
- **Workspace-managed RGs** `databricks-rg-*` (random suffix) — should auto-delete
  with each workspace; `sweep` lists any orphans by pattern.
- **Resource groups** verified gone: `rg-databricks-{dev,prod}-{platform,team-a,team-b}`,
  `rg-terraform-state`, `rg-terraform-sp`.
- **Dangling role assignments** referencing the now-deleted SP.

Resources deleted *with* their RG (no extra step): UC storage accounts
`dbwdevplatformuc`, `dbwprodplatformuc`, `dbwdevteamauc`, `dbwdevteambuc`,
`dbwprodteambuc` (+ prod/team-a's), and state storage `tfstatee18f8286`.

After `sweep`, confirm in the **Databricks account console** that the metastore
and account groups (`ad-dbx`, `PowerBI_users`, `ad-dbx-team-*`) are gone.

## Oddballs to know about

- `prod/team-a` workspace is named **`dbw-prod`** (not `dbw-prod-team-a`) and
  lives in **eastus**, not canadacentral.
- The metastore is canadacentral; bootstrap (state + KV) is **eastus**.
