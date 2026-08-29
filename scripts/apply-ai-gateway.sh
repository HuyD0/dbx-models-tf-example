#!/usr/bin/env bash
# apply-ai-gateway.sh — reconcile pre-provisioned `databricks-*` Foundation
# Model API endpoints to the desired state declared in
# modules/model-serving/model_defaults.yaml.
#
# Why this exists:
#   The `databricks-` endpoint name prefix is reserved by Databricks; the
#   Terraform provider rejects CREATE and UPDATE on these. We still need to
#   govern them (rate limits + inference tables for approved foundation
#   models; rate_limit=0 for blocked ones). The Databricks REST endpoint
#   `PUT /api/2.0/serving-endpoints/{name}/ai-gateway` accepts these updates.
#
# Source of truth:
#   modules/model-serving/model_defaults.yaml
#     ├── foundation_endpoints        → governed (rate limits + inference table)
#     ├── disabled_foundation_models  → blocked (rate_limit = 0)
#     └── gateway_defaults            → rate limits + guardrails applied to
#                                       every governed endpoint (same policy
#                                       Terraform applies to external ones)
#
# Per-workspace input (from terraform output):
#   workspace_url, inference_table_prefix, inference_table_catalog,
#   inference_table_schema, rate_limits.
#
# Usage:
#   scripts/apply-ai-gateway.sh                       # all workload workspaces
#   scripts/apply-ai-gateway.sh dbx-dev                # a single env directory
#   scripts/apply-ai-gateway.sh --dry-run dbx-dev      # print payloads, don't PUT
#
#   # Single-workspace mode (invoked by terraform_data.ai_gateway_reconciler):
#   #   bypasses terraform output / tfvars discovery and uses env vars.
#   WORKSPACE_URL=https://adb-…  TABLE_PREFIX=dbx-dev \
#     TABLE_CATALOG=main TABLE_SCHEMA=model_serving_logs \
#     scripts/apply-ai-gateway.sh --single-workspace
#
# Idempotency:
#   PUT /ai-gateway is fully idempotent. Re-running is safe.
#
# Limitations:
#   • Once an inference table prefix is set on an endpoint AND the UC table
#     exists, the prefix cannot be changed without DROP TABLE first.
#   • Once inference tables are disabled, re-enabling on the same endpoint
#     requires the existing UC tables to be absent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="${YAML_PATH:-$REPO_ROOT/modules/model-serving/model_defaults.yaml}"
DBX_AUDIENCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

DRY_RUN=false
SINGLE=false
TARGETS=()
# Endpoints whose PUT failed. Every endpoint is still attempted (one bad
# endpoint must not block the rest), but any failure fails the script —
# and therefore `terraform apply` — so governance drift is never silent.
FAILED=0

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)          DRY_RUN=true; shift ;;
    --single-workspace) SINGLE=true;  shift ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

# ── Prereqs ───────────────────────────────────────────────────────────────────
REQUIRED=(az yq jq curl)
$SINGLE || REQUIRED+=(terraform)
for cmd in "${REQUIRED[@]}"; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not in PATH" >&2; exit 1; }
done
[[ -f "$YAML" ]] || { echo "ERROR: $YAML not found" >&2; exit 1; }

# ── Default targets: every workload workspace directly under environments/ ──
if ! $SINGLE && [[ ${#TARGETS[@]} -eq 0 ]]; then
  while IFS= read -r d; do
    rel="${d#$REPO_ROOT/environments/}"
    case "$rel" in
      account) continue ;;  # skip non-workload envs
      dbx-uat) continue ;; # enable_model_serving = false -- no endpoints to reconcile
    esac
    TARGETS+=("$rel")
  done < <(find "$REPO_ROOT/environments" -mindepth 1 -maxdepth 1 -type d | sort)
fi

# ── Load desired state from YAML ─────────────────────────────────────────────
# (read-loop, not mapfile, for macOS default bash 3.2 compatibility)
GOVERNED_ENDPOINTS=()
while IFS= read -r line; do GOVERNED_ENDPOINTS+=("$line"); done < <(yq -r '.foundation_endpoints | keys | .[]' "$YAML")
DISABLED_ENDPOINTS=()
while IFS= read -r line; do DISABLED_ENDPOINTS+=("$line"); done < <(yq -r '.disabled_foundation_models[]' "$YAML")

# ── Default AI-gateway policy (gateway_defaults) ─────────────────────────────
# The same defaults modules/model-serving applies to Terraform-managed
# external endpoints. Composed once into JSON here, reused per endpoint.
ENDPOINT_QPM=$(yq -r '.gateway_defaults.rate_limits.endpoint_qpm' "$YAML")
USER_QPM=$(yq -r '.gateway_defaults.rate_limits.user_qpm' "$YAML")
ENDPOINT_TPM=$(yq -r '.gateway_defaults.rate_limits.endpoint_tpm // ""' "$YAML")
UG_COUNT=$(yq -r '.gateway_defaults.rate_limits.user_group_limits // [] | length' "$YAML")

[[ "$ENDPOINT_QPM" =~ ^[0-9]+$ && "$USER_QPM" =~ ^[0-9]+$ ]] || {
  echo "ERROR: gateway_defaults.rate_limits.{endpoint_qpm,user_qpm} missing or non-numeric in $YAML" >&2
  exit 1
}

RATE_LIMITS_JSON=$(jq -n --argjson eqpm "$ENDPOINT_QPM" --argjson uqpm "$USER_QPM" '[
  { calls: $eqpm, key: "endpoint", renewal_period: "minute" },
  { calls: $uqpm, key: "user",     renewal_period: "minute" }
]')
if [[ -n "$ENDPOINT_TPM" && "$ENDPOINT_TPM" != "null" ]]; then
  RATE_LIMITS_JSON=$(jq --argjson t "$ENDPOINT_TPM" '.[0].tokens = $t' <<<"$RATE_LIMITS_JSON")
fi
for ((i = 0; i < UG_COUNT; i++)); do
  UG_GROUP=$(yq -r ".gateway_defaults.rate_limits.user_group_limits[$i].group" "$YAML")
  UG_QPM=$(yq -r ".gateway_defaults.rate_limits.user_group_limits[$i].qpm" "$YAML")
  UG_TPM=$(yq -r ".gateway_defaults.rate_limits.user_group_limits[$i].tpm // \"\"" "$YAML")
  UG_ENTRY=$(jq -n --arg g "$UG_GROUP" --argjson q "$UG_QPM" \
    '{ calls: $q, key: "user_group", principal: $g, renewal_period: "minute" }')
  if [[ -n "$UG_TPM" && "$UG_TPM" != "null" ]]; then
    UG_ENTRY=$(jq --argjson t "$UG_TPM" '.tokens = $t' <<<"$UG_ENTRY")
  fi
  RATE_LIMITS_JSON=$(jq --argjson e "$UG_ENTRY" '. + [$e]' <<<"$RATE_LIMITS_JSON")
done

# Guardrails: {} when the YAML omits them; merged into the governed payload.
# Scalars are read with yq and composed with jq so the script works with
# both yq flavors (kislyuk python-yq and mikefarah Go yq).
GUARDRAILS_JSON='{}'
if [[ "$(yq -r '.gateway_defaults | has("guardrails")' "$YAML")" == "true" ]]; then
  GR_IN_SAFETY=$(yq -r '.gateway_defaults.guardrails.input_safety // false' "$YAML")
  GR_IN_PII=$(yq -r '.gateway_defaults.guardrails.input_pii_behavior // ""' "$YAML")
  GR_OUT_SAFETY=$(yq -r '.gateway_defaults.guardrails.output_safety // false' "$YAML")
  GR_OUT_PII=$(yq -r '.gateway_defaults.guardrails.output_pii_behavior // ""' "$YAML")
  GUARDRAILS_JSON=$(jq -n \
    --argjson isafe "$GR_IN_SAFETY" --argjson osafe "$GR_OUT_SAFETY" \
    --arg ipii "$GR_IN_PII" --arg opii "$GR_OUT_PII" '
    { guardrails: {
        input:  ({ safety: $isafe } + (if $ipii != "" and $ipii != "null" then { pii: { behavior: $ipii } } else {} end)),
        output: ({ safety: $osafe } + (if $opii != "" and $opii != "null" then { pii: { behavior: $opii } } else {} end))
    } }')
fi

# ── Acquire token once ────────────────────────────────────────────────────────
TOKEN=$(az account get-access-token --resource "$DBX_AUDIENCE" --query accessToken -o tsv 2>/dev/null)
[[ -n "$TOKEN" ]] || { echo "ERROR: failed to acquire Databricks token (run 'az login')" >&2; exit 1; }

# ── Per-endpoint reconciler ───────────────────────────────────────────────────
put_ai_gateway() {
  local ws_url="$1"
  local endpoint="$2"
  local payload="$3"

  if $DRY_RUN; then
    echo "    [dry-run] PUT $endpoint"
    echo "$payload" | jq -c .
    return
  fi

  local http
  http=$(curl -s -o /tmp/aigw-resp.json -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$ws_url/api/2.0/serving-endpoints/$endpoint/ai-gateway")

  if [[ "$http" == "200" ]]; then
    echo "    ✓ $endpoint"
  else
    echo "    ✗ $endpoint (HTTP $http)"
    cat /tmp/aigw-resp.json >&2 || true
    echo >&2
    return 1
  fi
}

# ── Reconcile one workspace given URL + prefix + catalog + schema ────────────
reconcile_one() {
  local label="$1" ws_url="$2" team="$3" catalog="$4" schema="$5"

  # Sanitize the prefix to a valid Unity Catalog table-name component,
  # exactly like modules/model-serving/main.tf does for Terraform-managed
  # endpoints ("dbx-dev" → "dbx_dev") — otherwise foundation-endpoint
  # tables would get a hyphenated, invalid prefix.
  team=$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')

  echo ""
  echo "── $label @ $ws_url"
  echo "   prefix=$team  catalog=$catalog  schema=$schema"

  echo "  Governed:"
  for ep in "${GOVERNED_ENDPOINTS[@]}"; do
    local table_suffix table_prefix payload
    table_suffix=$(yq -r ".foundation_endpoints.\"$ep\".table_prefix" "$YAML")
    table_prefix="${team}_${table_suffix}"
    payload=$(jq -n \
      --arg cat "$catalog" \
      --arg sch "$schema" \
      --arg tbl "$table_prefix" \
      --argjson rl "$RATE_LIMITS_JSON" \
      --argjson gr "$GUARDRAILS_JSON" \
      '{
        usage_tracking_config: { enabled: true },
        rate_limits: $rl,
        inference_table_config: {
          enabled: true, catalog_name: $cat, schema_name: $sch, table_name_prefix: $tbl
        }
      } + $gr')
    put_ai_gateway "$ws_url" "$ep" "$payload" || FAILED=$((FAILED + 1))
  done

  echo "  Blocked:"
  local blocked_payload='{"usage_tracking_config":{"enabled":true},"rate_limits":[{"calls":0,"key":"endpoint","renewal_period":"minute"}]}'
  for ep in "${DISABLED_ENDPOINTS[@]}"; do
    put_ai_gateway "$ws_url" "$ep" "$blocked_payload" || FAILED=$((FAILED + 1))
  done
}

# ── Per-workspace reconciler (multi-env mode: reads terraform output + tfvars) ─
reconcile_workspace_from_tf() {
  local env_rel="$1"
  local dir="$REPO_ROOT/environments/$env_rel"
  [[ -d "$dir" ]] || { echo "  skip: $env_rel (no such directory)"; return; }

  local ws_url team catalog schema tfvars
  ws_url=$(terraform -chdir="$dir" output -raw workspace_url 2>/dev/null || true)
  if [[ -z "$ws_url" || "$ws_url" == "null" ]]; then
    echo "  skip: $env_rel (no workspace_url output — not yet applied?)"
    return
  fi

  tfvars="$dir/terraform.tfvars"
  # `|| true` because grep returns 1 (and trips set -e/pipefail) when the key
  # is absent — many envs omit inference_table_prefix and rely on the team default.
  team=$({ grep -E '^[[:space:]]*inference_table_prefix'  "$tfvars" || true; } | awk -F'"' '{print $2}')
  [[ -n "$team" ]] || team=$(basename "$dir" | tr - _)
  catalog=$({ grep -E '^[[:space:]]*inference_table_catalog' "$tfvars" || true; } | awk -F'"' '{print $2}')
  schema=$({  grep -E '^[[:space:]]*inference_table_schema'  "$tfvars" || true; } | awk -F'"' '{print $2}')

  reconcile_one "$env_rel" "$ws_url" "$team" "$catalog" "$schema"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if $SINGLE; then
  : "${WORKSPACE_URL:?--single-workspace mode requires WORKSPACE_URL env var}"
  : "${TABLE_PREFIX:?--single-workspace mode requires TABLE_PREFIX env var}"
  : "${TABLE_CATALOG:?--single-workspace mode requires TABLE_CATALOG env var}"
  : "${TABLE_SCHEMA:?--single-workspace mode requires TABLE_SCHEMA env var}"

  echo "Reconciling AI Gateway (single-workspace mode)"
  $DRY_RUN && echo "(dry-run — no PUT requests will be sent)"
  echo "Governed endpoints: ${GOVERNED_ENDPOINTS[*]:-(none)}"
  echo "Blocked  endpoints: ${#DISABLED_ENDPOINTS[@]} models"

  reconcile_one "single" "$WORKSPACE_URL" "$TABLE_PREFIX" "$TABLE_CATALOG" "$TABLE_SCHEMA"
else
  echo "Reconciling AI Gateway across ${#TARGETS[@]} workspace(s)"
  $DRY_RUN && echo "(dry-run — no PUT requests will be sent)"
  echo "Governed endpoints: ${GOVERNED_ENDPOINTS[*]:-(none)}"
  echo "Blocked  endpoints: ${#DISABLED_ENDPOINTS[@]} models"

  for t in "${TARGETS[@]}"; do
    reconcile_workspace_from_tf "$t"
  done
fi

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  echo "ERROR: $FAILED endpoint(s) failed to reconcile — desired AI-gateway state is NOT fully applied." >&2
  exit 1
fi
echo "Done."
