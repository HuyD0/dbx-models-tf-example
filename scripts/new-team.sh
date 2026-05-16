#!/usr/bin/env bash
# new-team.sh — scaffold a new team environment directory from templates.
#
# Usage:
#   ./scripts/new-team.sh <team-name> <env> <vnet-cidr> [location]
#
# Example:
#   ./scripts/new-team.sh team-c dev 10.182.0.0/20 canadacentral
#
# After running:
#   1. Copy terraform.tfvars.example → terraform.tfvars and fill in real values.
#   2. Update storage account name (must be unique, 3-24 chars, alphanumeric).
#   3. Add the new env to ENVS list in scripts/pre-push-check.sh.
#   4. Run: cd environments/<env>/<team> && terraform init

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="${REPO_ROOT}/environments/_templates"

team="${1:?Usage: $0 <team-name> <env> <vnet-cidr> [location]}"
env="${2:?Usage: $0 <team-name> <env> <vnet-cidr> [location]}"
vnet_cidr="${3:?Usage: $0 <team-name> <env> <vnet-cidr> [location]}"
location="${4:-canadacentral}"

# Derive underscore version of team name for inference_table_prefix
team_underscore="${team//-/_}"

target="${REPO_ROOT}/environments/${env}/${team}"

if [[ -d "${target}" ]]; then
  echo "ERROR: ${target} already exists. Aborting to prevent overwrite." >&2
  exit 1
fi

echo "Scaffolding ${env}/${team} from templates..."
mkdir -p "${target}"

for tmpl in main providers variables outputs; do
  sed \
    -e "s/TEAM_NAME/${team}/g" \
    -e "s/TEAM_UNDERSCORE/${team_underscore}/g" \
    -e "s/ENV_NAME/${env}/g" \
    -e "s|VNET_CIDR|${vnet_cidr}|g" \
    -e "s/LOCATION/${location}/g" \
    "${TEMPLATES}/${tmpl}.tf.tmpl" \
    > "${target}/${tmpl}.tf"
done

sed \
  -e "s/TEAM_NAME/${team}/g" \
  -e "s/TEAM_UNDERSCORE/${team_underscore}/g" \
  -e "s/ENV_NAME/${env}/g" \
  -e "s|VNET_CIDR|${vnet_cidr}|g" \
  -e "s/LOCATION/${location}/g" \
  "${TEMPLATES}/terraform.tfvars.example" \
  > "${target}/terraform.tfvars.example"

echo ""
echo "Created: ${target}/"
ls "${target}/"
echo ""
echo "Next steps:"
echo "  1. cp ${target}/terraform.tfvars.example ${target}/terraform.tfvars"
echo "     Edit terraform.tfvars — fill in real subscription_id, metastore_id, etc."
echo "  2. Update uc_storage_account_name (unique, 3-24 chars, lowercase alphanumeric)."
echo "  3. Add '${env}/${team}' to ENVS in scripts/pre-push-check.sh."
echo "  4. cd ${target} && terraform init"
