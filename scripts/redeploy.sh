#!/usr/bin/env bash
# redeploy.sh — full environment rebuild for the federated AI gateway layout.
#
# Deploy order (enforced by this script):
#   1. bootstrap                       (state backend, one-time)
#   2. environments/account            (metastore + account-level AAD groups)
#   3. environments/<env>/platform     (central inference catalog `llmlogs`,
#                                       admin-only read, writer grants for
#                                       workload groups)
#   4. environments/<env>/<team>       (per-team workspace + governed endpoints;
#                                       writes inference rows into `llmlogs`
#                                       prefixed by team name for cost
#                                       allocation). Teams in the same env can
#                                       be applied in any order once platform
#                                       is up.
#
# Usage: ./scripts/redeploy.sh [--env dev|prod|all] [--skip-bootstrap] [--dry-run]
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBSCRIPTION_ID="<YOUR_SUBSCRIPTION_ID>"
DATABRICKS_ACCOUNT_ID="<YOUR_DATABRICKS_ACCOUNT_ID>"
STATE_RG="rg-terraform-state"
STATE_SA="<YOUR_STATE_STORAGE_ACCOUNT>"
STATE_CONTAINER="tfstate"

# Workload teams per environment. Adding a new team is a two-line change here
# plus an entry in environments/<env>/platform/terraform.tfvars
# (inference_writer_groups) so its serving SP can write to `llmlogs`.
DEV_TEAMS=(team-a team-b)
PROD_TEAMS=(team-a team-b)

# ── Defaults ──────────────────────────────────────────────────────────────────
ENV="all"
SKIP_BOOTSTRAP=false
DRY_RUN=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)            ENV="$2";          shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    --dry-run)        DRY_RUN=true;      shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
die()  { echo -e "\033[1;31m  ✗ $*\033[0m"; exit 1; }

tf_apply() {
  local dir="$1"
  pushd "$dir" > /dev/null
  log "terraform init  →  ${dir#$REPO_ROOT/}"
  terraform init -input=false -reconfigure

  log "terraform plan  →  ${dir#$REPO_ROOT/}"
  terraform plan -input=false -out=tfplan

  if $DRY_RUN; then
    warn "DRY RUN — skipping apply in ${dir#$REPO_ROOT/}"
  else
    log "terraform apply →  ${dir#$REPO_ROOT/}"
    terraform apply -input=false tfplan
    rm -f tfplan
  fi
  popd > /dev/null
}

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
log "Checking prerequisites"

for cmd in az terraform; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH"
  ok "$cmd found: $(command -v "$cmd")"
done

DBX_CLI=false
if command -v databricks >/dev/null; then
  ok "databricks CLI found: $(command -v databricks)"
  DBX_CLI=true
else
  warn "databricks CLI not found — post-deploy verification will be skipped"
fi

# ── 2. Azure login ────────────────────────────────────────────────────────────
log "Verifying Azure CLI auth"
if ! az account show >/dev/null 2>&1; then
  warn "Not logged in — running az login"
  az login
fi
az account set --subscription "$SUBSCRIPTION_ID"
ok "Active subscription: $(az account show --query 'name' -o tsv) ($SUBSCRIPTION_ID)"

DBX_HOST="https://accounts.azuredatabricks.net"

# ── 3. Bootstrap (state backend) ──────────────────────────────────────────────
if $SKIP_BOOTSTRAP; then
  log "Skipping bootstrap (--skip-bootstrap)"
else
  log "Checking Terraform state backend"
  SA_EXISTS=$(az storage account show \
    --name "$STATE_SA" \
    --resource-group "$STATE_RG" \
    --query "name" -o tsv 2>/dev/null || true)

  if [[ -n "$SA_EXISTS" ]]; then
    ok "State backend exists: $STATE_SA — skipping bootstrap"
  else
    warn "State backend not found — running bootstrap"
    pushd "$REPO_ROOT/bootstrap" > /dev/null
    terraform init -input=false
    terraform plan -input=false -var="storage_account_name=$STATE_SA" -out=tfplan
    if $DRY_RUN; then
      warn "DRY RUN — skipping bootstrap apply"
    else
      terraform apply -input=false tfplan
      rm -f tfplan
    fi
    popd > /dev/null
    ok "Bootstrap complete"
  fi

  if ! $DRY_RUN; then
    az storage container show \
      --name "$STATE_CONTAINER" \
      --account-name "$STATE_SA" \
      --auth-mode login >/dev/null 2>&1 \
      && ok "State container '$STATE_CONTAINER' accessible" \
      || die "State container not accessible — check permissions on $STATE_SA"
  fi
fi

# ── 4. Account level (metastore + AAD groups) ─────────────────────────────────
log "Deploying: account"
tf_apply "$REPO_ROOT/environments/account"

METASTORE_ID=$(
  terraform -chdir="$REPO_ROOT/environments/account" output -raw metastore_id 2>/dev/null || true
)
if [[ -n "$METASTORE_ID" ]]; then
  ok "Metastore ID: $METASTORE_ID"
else
  warn "Could not read metastore_id output — verify environments/account/outputs.tf"
fi

if ! $DRY_RUN && $DBX_CLI; then
  log "Verifying Databricks account groups"
  GROUP_COUNT=$(databricks account groups list \
    --account-id "$DATABRICKS_ACCOUNT_ID" \
    --output json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Resources', [])))" 2>/dev/null \
    || echo "0")
  ok "Account groups visible: $GROUP_COUNT"
fi

# ── 5. Platform env (central inference catalog) ──────────────────────────────
# Must apply BEFORE any workload workspace in the same env, so `llmlogs` exists
# when team endpoints attempt to register inference tables. Each platform env
# also owns the writer grants for that env's workload groups.
deploy_platform() {
  local env_name="$1"
  local dir="$REPO_ROOT/environments/$env_name/platform"
  [[ -d "$dir" ]] || die "Missing platform env: $dir"

  log "Deploying platform: $env_name/platform"
  tf_apply "$dir"

  if $DRY_RUN; then return; fi

  CATALOG=$(terraform -chdir="$dir" output -raw inference_catalog_name 2>/dev/null || true)
  if [[ -n "$CATALOG" ]]; then
    ok "Inference catalog ready: $CATALOG (admin-only read)"
  fi
}

# ── 6. Workload (team) workspaces ─────────────────────────────────────────────
deploy_team() {
  local env_name="$1"
  local team="$2"
  local dir="$REPO_ROOT/environments/$env_name/$team"
  [[ -d "$dir" ]] || { warn "Skipping missing env: $dir"; return; }

  log "Deploying team workspace: $env_name/$team"
  tf_apply "$dir"

  if $DRY_RUN; then return; fi

  WS_URL=$(terraform -chdir="$dir" output -raw workspace_url 2>/dev/null || true)
  WS_ID=$(terraform  -chdir="$dir" output -raw workspace_id  2>/dev/null || true)

  if [[ -z "$WS_URL" ]]; then
    warn "workspace_url output not found — skipping health check"
    return
  fi
  ok "Workspace URL: $WS_URL"

  log "Waiting for $env_name/$team workspace to become Succeeded"
  for i in $(seq 1 20); do
    STATE=$(az databricks workspace show --ids "$WS_ID" \
      --query "provisioningState" -o tsv 2>/dev/null || true)
    if [[ "$STATE" == "Succeeded" ]]; then
      ok "Workspace provisioned ($STATE)"
      break
    fi
    echo "  ... $i/20 — state: ${STATE:-unknown}"
    sleep 15
  done

  if $DBX_CLI; then
    log "Checking model serving endpoints — $env_name/$team"
    databricks serving-endpoints list --host "$WS_URL" --output table 2>/dev/null \
      || warn "Could not list endpoints — auth with: databricks auth login --host $WS_URL"
  fi
}

# ── 7. Drive deploy order ─────────────────────────────────────────────────────
deploy_env() {
  local env_name="$1"
  shift
  local teams=("$@")

  deploy_platform "$env_name"
  for team in "${teams[@]}"; do
    deploy_team "$env_name" "$team"
  done
}

case "$ENV" in
  dev)  deploy_env dev  "${DEV_TEAMS[@]}"  ;;
  prod) deploy_env prod "${PROD_TEAMS[@]}" ;;
  all)
    deploy_env dev  "${DEV_TEAMS[@]}"
    deploy_env prod "${PROD_TEAMS[@]}"
    ;;
  *) die "Unknown --env value: $ENV (expected dev|prod|all)" ;;
esac

# ── 8. Final summary ──────────────────────────────────────────────────────────
log "Deployment complete — listing Databricks resource groups"
az group list \
  --subscription "$SUBSCRIPTION_ID" \
  --query "[?contains(name, 'databricks')].{Name:name, State:properties.provisioningState}" \
  -o table

if ! $DRY_RUN && $DBX_CLI; then
  log "Listing Databricks workspaces (account view)"
  databricks account workspaces list \
    --account-id "$DATABRICKS_ACCOUNT_ID" \
    --output table 2>/dev/null || warn "Could not list workspaces"
elif ! $DBX_CLI; then
  warn "After deploy, set up the workspace CLI profile:"
  warn "  databricks auth login --host $DBX_HOST --account-id $DATABRICKS_ACCOUNT_ID --profile dbx_dev"
fi

echo -e "\n\033[1;32m✓ All done.\033[0m"
