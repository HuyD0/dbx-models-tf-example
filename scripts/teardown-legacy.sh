#!/usr/bin/env bash
# =============================================================================
# LEGACY FULL TEARDOWN — pre-dbx-dev-consolidation topology
# =============================================================================
# This is a snapshot of the ORIGINAL scripts/teardown.sh, preserved because it
# was NEVER COMMITTED to git before this repo was consolidated to a single
# `dbx-dev` workspace (it was an untracked file, so `git checkout` cannot
# recover it). If the six legacy workspaces below (dev/prod x
# platform/team-a/team-b) are still deployed in Azure, use THIS script (not
# the rewritten scripts/teardown.sh) to tear them down.
#
# IMPORTANT CAVEAT: this script destroys via `terraform -chdir=<env> destroy`,
# which requires each environment's `terraform.tfvars` to exist. Those files
# are gitignored (`*.tfvars` in .gitignore) and were NEVER committed. The
# consolidation session that created this snapshot only had
# environments/dev/platform/terraform.tfvars and
# environments/dev/team-a/terraform.tfvars loaded in context (both reproduced
# below in a comment for reference) — environments/dev/team-b and all of
# environments/prod/* tfvars were NOT read this session and are NOT
# recoverable from git or from this snapshot. If those workspaces are still
# deployed, you'll need to reconstruct their tfvars from the remote Terraform
# state backend (storage account tfstatee18f8286, containers under
# databricks/{dev,prod}/{platform,team-a,team-b}/terraform.tfstate) or from
# `az databricks workspace show` / Unity Catalog metadata, then recreate the
# env directories (main.tf/variables.tf/outputs.tf/providers.tf were
# committed and CAN be recovered via `git log` + `git show <sha>:<path>`).
#
# Destroys EVERYTHING, including PRODUCTION and the Terraform state backend.
# This is irreversible. Read docs/TEARDOWN-legacy.md before running.
#
# Run it ONE PHASE AT A TIME (subcommands below) — not end-to-end. Each phase
# uses Terraform's native plan + "type yes" prompt as the gate. There is NO
# -auto-approve anywhere on purpose: you must read and approve every plan.
#
#   ./scripts/teardown-legacy.sh discover     # show what actually exists first
#   ./scripts/teardown-legacy.sh teams        # dev/prod team-a + team-b
#   ./scripts/teardown-legacy.sh platform     # dev/prod platform (owns inference catalogs)
#   ./scripts/teardown-legacy.sh account      # Databricks account: metastore + groups
#   ./scripts/teardown-legacy.sh bootstrap    # state backend + SP + Key Vault  (CLEAN SHELL)
#   ./scripts/teardown-legacy.sh sweep        # purge soft-deleted KV, AAD app, orphan check
#
# Teardown order is the REVERSE of deploy order. Do not reorder.
#
# AUTH MODEL
#   teams / platform / account  -> authenticate as the Terraform SP:
#         az login                       # as yourself (needed to read Key Vault)
#         source scripts/dev-auth.sh     # exports ARM_* for the SP
#   bootstrap                   -> authenticate as YOU, in a *fresh* shell with
#         NO ARM_* SP vars set (open a new terminal, `az login`, then run it).
#         dev-auth.sh's creds live in the Key Vault that bootstrap deletes, and
#         the SP cannot cleanly delete itself.
#
# ── environments/dev/platform/terraform.tfvars (as read this session) ────────
#   uc_storage_account_name = "dbwdevplatformuc"
#   inference_table_catalog = "llmlogs_dev"
#   inference_admin_groups = ["ad-dbx"]
#   inference_writer_groups = ["ad-dbx-team-a", "ad-dbx-team-b"]
#   contributor_group_object_id = "4f515a8b-b79c-45aa-a21e-c060e50ba65d"
#
# ── environments/dev/team-a/terraform.tfvars (as read this session) ──────────
#   uc_storage_account_name = "dbwdevteamauc"
#   ai_foundry_name = "aif-huy-dev" / ai_foundry_resource_group = "rg-aifoundry-dev"
#   inference_table_catalog = "llmlogs_dev"
#   workspace_groups = ["ad-dbx", "ad-dbx-team-a"]
#   contributor_group_object_id = "ae902d74-653b-4251-ab64-7ff395e7e4c1"
#
# dev/team-b and prod/* tfvars were NOT captured this session — see caveat above.
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# --- Known identifiers (from tfvars / bootstrap state) ------------------------
SUBSCRIPTION_ID="ea936670-dda1-4884-8467-49c225bf3e83"
BOOTSTRAP_KV="kv-tfsp-ea936670"
BOOTSTRAP_KV_LOCATION="eastus"          # bootstrap var.location default == eastus
STATE_STORAGE_ACCOUNT="tfstatee18f8286"
SP_DISPLAY_NAME="sp-terraform-databricks"
METASTORE_ID="e34cdfb0-ad14-4612-9eac-7dd05ff29e33"

TEAM_ENVS=(
  environments/dev/team-a
  environments/dev/team-b
  environments/prod/team-a     # NOTE: workspace is "dbw-prod" and region is EASTUS
  environments/prod/team-b
)
PLATFORM_ENVS=(
  environments/dev/platform
  environments/prod/platform
)
ACCOUNT_ENV="environments/account"

RESOURCE_GROUPS=(
  rg-databricks-dev-team-a   rg-databricks-dev-team-b
  rg-databricks-prod-team-a  rg-databricks-prod-team-b
  rg-databricks-dev-platform rg-databricks-prod-platform
  rg-terraform-state         rg-terraform-sp
)

# --- helpers ------------------------------------------------------------------
note()    { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
warn()    { printf '\n\033[1;33m!! %s\033[0m\n' "$*"; }
confirm() { read -r -p "$* [type 'yes' to continue] " a; [ "$a" = "yes" ] || { echo "Aborted."; exit 1; }; }

require_sp_auth() {
  if [ -z "${ARM_CLIENT_ID:-}" ]; then
    warn "ARM_CLIENT_ID is not set. Run:  az login  &&  source scripts/dev-auth.sh"
    exit 1
  fi
}

destroy_env() {
  local env="$1"
  if [ ! -d "$env" ]; then warn "skip (missing): $env — recover with: git log --diff-filter=D -- $env ; git checkout <sha>~1 -- $env  (tfvars will still be missing, see header)"; return; fi
  note "terraform destroy: $env"
  terraform -chdir="$env" init -reconfigure -input=false
  terraform -chdir="$env" destroy            # interactive: shows plan, asks 'yes'
}

# --- phases -------------------------------------------------------------------
discover() {
  note "Discovery — what Terraform thinks exists (per env state)"
  for env in "${TEAM_ENVS[@]}" "${PLATFORM_ENVS[@]}" "$ACCOUNT_ENV"; do
    [ -d "$env" ] || continue
    echo "### $env"
    terraform -chdir="$env" init -reconfigure -input=false >/dev/null 2>&1 || warn "init failed for $env"
    terraform -chdir="$env" state list 2>/dev/null || echo "  (no state / not initialized)"
    echo
  done
  echo "### bootstrap (local state)"
  terraform -chdir=bootstrap state list 2>/dev/null || echo "  (no state)"

  note "Discovery — what Azure actually has"
  echo "# Resource groups:";        az group list -o table || true
  echo; echo "# databricks-rg-* (workspace-managed RGs):"
  az group list --query "[?starts_with(name,'databricks-rg-')].name" -o tsv || true
  echo; echo "# Terraform SP app registration:"
  az ad app list --display-name "$SP_DISPLAY_NAME" --query "[].{name:displayName,appId:appId}" -o table || true
  echo; echo "# Soft-deleted key vaults:"
  az keyvault list-deleted --query "[].{name:name,location:properties.location}" -o table || true
}

teams() {
  require_sp_auth
  confirm "Destroy ALL FOUR team workspaces (dev + prod, team-a + team-b)?"
  for e in "${TEAM_ENVS[@]}"; do destroy_env "$e"; done
  note "Teams destroyed. Next: ./scripts/teardown-legacy.sh platform"
}

platform() {
  require_sp_auth
  warn "PLATFORM owns the inference catalogs (llmlogs_dev / llmlogs_prod),"
  warn "which have force_destroy=false AND may hold inference tables auto-created"
  warn "at runtime by team serving endpoints. terraform destroy WILL FAIL on a"
  warn "non-empty catalog/schema. If it does, see docs/TEARDOWN-legacy.md 'force_destroy'."
  confirm "Destroy BOTH platform workspaces (dev + prod)?"
  for e in "${PLATFORM_ENVS[@]}"; do destroy_env "$e"; done
  note "Platform destroyed. Next: ./scripts/teardown-legacy.sh account"
}

account() {
  require_sp_auth
  warn "This destroys the Unity Catalog METASTORE ($METASTORE_ID)."
  warn "A metastore is ONE-PER-REGION-PER-ACCOUNT. If it was pre-existing/shared"
  warn "(the code says 'import it if one already exists'), destroying it affects"
  warn "the whole Databricks account, possibly beyond this Terraform. CONFIRM that"
  warn "this metastore is exclusively owned by this stack before proceeding."
  warn "force_destroy=false in environments/account/main.tf — see docs/TEARDOWN-legacy.md."
  confirm "Destroy account-level resources (metastore, groups, SCIM SP)?"
  destroy_env "$ACCOUNT_ENV"
  note "Account destroyed. Open a CLEAN shell, then: ./scripts/teardown-legacy.sh bootstrap"
}

bootstrap() {
  if [ -n "${ARM_CLIENT_ID:-}" ]; then
    warn "ARM_CLIENT_ID is set — you are in an SP-authenticated shell."
    warn "Bootstrap deletes that SP + the Key Vault holding its secret, so it must"
    warn "run as YOU. Open a fresh terminal, run 'az login' only, then re-run this."
    exit 1
  fi
  note "Bootstrap auth = your az login (DefaultAzureCredential)."
  warn "If destroy errors on the placeholder import{} blocks in bootstrap/main.tf"
  warn "(ids like <YOUR_SUBSCRIPTION_ID>), comment those import blocks out first."
  confirm "Destroy bootstrap: state storage ($STATE_STORAGE_ACCOUNT), Key Vault, SP, role assignments?"
  terraform -chdir=bootstrap init -reconfigure -input=false
  terraform -chdir=bootstrap destroy
  note "Bootstrap destroyed. Finally: ./scripts/teardown-legacy.sh sweep"
}

sweep() {
  note "Azure cleanup sweep — catch what Terraform leaves behind"

  echo "# Soft-deleted Key Vault '$BOOTSTRAP_KV' (retained 7 days unless purged):"
  if az keyvault list-deleted --query "[?name=='$BOOTSTRAP_KV']" -o tsv | grep -q .; then
    confirm "PURGE soft-deleted Key Vault '$BOOTSTRAP_KV' (permanent)?"
    az keyvault purge --name "$BOOTSTRAP_KV" --location "$BOOTSTRAP_KV_LOCATION"
  else
    echo "  none found."
  fi

  echo; echo "# Terraform SP app registration '$SP_DISPLAY_NAME':"
  appid=$(az ad app list --display-name "$SP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)
  if [ -n "${appid:-}" ] && [ "$appid" != "None" ]; then
    warn "Still present (Terraform may lack Graph perms to delete it)."
    confirm "Delete AAD app registration $appid?"
    az ad app delete --id "$appid"
  else
    echo "  gone."
  fi

  echo; echo "# Resource groups that should no longer exist:"
  for rg in "${RESOURCE_GROUPS[@]}"; do
    if az group show -n "$rg" >/dev/null 2>&1; then warn "STILL EXISTS: $rg"; else echo "  gone: $rg"; fi
  done

  echo; echo "# Orphaned workspace-managed RGs (databricks-rg-*):"
  az group list --query "[?starts_with(name,'databricks-rg-')].name" -o tsv || true

  echo; echo "# Any role assignments still pointing at a deleted principal:"
  az role assignment list --all --query "[?principalName==null].{role:roleDefinitionName,scope:scope}" -o table 2>/dev/null || true

  note "Sweep complete. Manually confirm in the Databricks account console that the"
  note "metastore and account groups (ad-dbx, PowerBI_users, ad-dbx-team-*) are gone."
}

case "${1:-}" in
  discover)  discover ;;
  teams)     teams ;;
  platform)  platform ;;
  account)   account ;;
  bootstrap) bootstrap ;;
  sweep)     sweep ;;
  *) grep -E '^#( |==|$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
