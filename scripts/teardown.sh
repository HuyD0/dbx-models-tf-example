#!/usr/bin/env bash
# =============================================================================
# FULL TEARDOWN — terraform-databricks IaC + all Azure resources
# =============================================================================
# Destroys EVERYTHING this repo currently manages: the single `dbx-dev`
# workspace, Databricks account-level objects, and the Terraform state
# backend. This is irreversible. Read docs/TEARDOWN.md before running.
#
# Run it ONE PHASE AT A TIME (subcommands below) — not end-to-end. Each phase
# uses Terraform's native plan + "type yes" prompt as the gate. There is NO
# -auto-approve anywhere on purpose: you must read and approve every plan.
#
#   ./scripts/teardown.sh discover     # show what actually exists first
#   ./scripts/teardown.sh workspace    # dbx-dev (owns catalog + serving endpoints)
#   ./scripts/teardown.sh account      # Databricks account: metastore + groups
#   ./scripts/teardown.sh bootstrap    # state backend + SP + Key Vault  (CLEAN SHELL)
#   ./scripts/teardown.sh sweep        # purge soft-deleted KV, AAD app, orphan check
#
# Teardown order is the REVERSE of deploy order. Do not reorder.
#
# LEGACY TOPOLOGY NOTE
#   This repo previously deployed six workspaces (dev/prod x
#   platform/team-a/team-b) instead of the single `dbx-dev` workspace. If any
#   of those are still deployed, this script cannot tear them down — their
#   environment directories were removed when the repo was consolidated. Use
#   `git log` to find the commit before the consolidation, `git checkout
#   <sha> -- environments/dev environments/prod scripts/teardown.sh` into a
#   scratch worktree, and run the old script's `teams`/`platform` phases
#   against that checkout before continuing here.
#
# AUTH MODEL
#   workspace / account  -> authenticate as the Terraform SP:
#         az login                       # as yourself (needed to read Key Vault)
#         source scripts/dev-auth.sh     # exports ARM_* for the SP
#   bootstrap             -> authenticate as YOU, in a *fresh* shell with
#         NO ARM_* SP vars set (open a new terminal, `az login`, then run it).
#         dev-auth.sh's creds live in the Key Vault that bootstrap deletes, and
#         the SP cannot cleanly delete itself.
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

WORKSPACE_ENVS=(
  environments/dbx-dev
  environments/dbx-uat
)
ACCOUNT_ENV="environments/account"

RESOURCE_GROUPS=(
  rg-databricks-dbx-dev
  rg-databricks-dbx-uat
  rg-terraform-state
  rg-terraform-sp
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
  if [ ! -d "$env" ]; then warn "skip (missing): $env"; return; fi
  note "terraform destroy: $env"
  terraform -chdir="$env" init -reconfigure -input=false
  terraform -chdir="$env" destroy            # interactive: shows plan, asks 'yes'
}

# --- phases -------------------------------------------------------------------
discover() {
  note "Discovery — what Terraform thinks exists (per env state)"
  for env in "${WORKSPACE_ENVS[@]}" "$ACCOUNT_ENV"; do
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

workspace() {
  require_sp_auth
  warn "dbx-dev owns the 'main' catalog's model_serving_logs schema, which has"
  warn "force_destroy=false AND may hold inference tables auto-created at runtime"
  warn "by serving endpoints. terraform destroy WILL FAIL on a non-empty"
  warn "catalog/schema. If it does, see docs/TEARDOWN.md 'force_destroy'."
  confirm "Destroy the dbx-dev workspace?"
  for env in "${WORKSPACE_ENVS[@]}"; do destroy_env "$env"; done
  note "Workspace destroyed. Next: ./scripts/teardown.sh account"
}

account() {
  require_sp_auth
  warn "This destroys the Unity Catalog METASTORE ($METASTORE_ID)."
  warn "A metastore is ONE-PER-REGION-PER-ACCOUNT. If it was pre-existing/shared"
  warn "(the code says 'import it if one already exists'), destroying it affects"
  warn "the whole Databricks account, possibly beyond this Terraform. CONFIRM that"
  warn "this metastore is exclusively owned by this stack before proceeding."
  warn "force_destroy=false in environments/account/main.tf — see docs/TEARDOWN.md."
  confirm "Destroy account-level resources (metastore, groups, SCIM SP)?"
  destroy_env "$ACCOUNT_ENV"
  note "Account destroyed. Open a CLEAN shell, then: ./scripts/teardown.sh bootstrap"
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
  note "Bootstrap destroyed. Finally: ./scripts/teardown.sh sweep"
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
  note "metastore and account group (ad-dbx, PowerBI_users) are gone."
}

case "${1:-}" in
  discover)  discover ;;
  workspace) workspace ;;
  account)   account ;;
  bootstrap) bootstrap ;;
  sweep)     sweep ;;
  *) grep -E '^#( |==|$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
