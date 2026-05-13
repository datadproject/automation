#!/usr/bin/env bash
# ==============================================================================
# rotate_key.sh — Stage 1: Create a new Datadog API key, store in Secrets Manager
# ==============================================================================
# Flow:
#   1. Assume hub account IAM role (DatadogRotationRole)
#   2. Read current API key from AWS Secrets Manager (datadog/${DD_ENV}/api-key)
#   3. Validate connectivity to Datadog API with current key
#   4. Look up the current key's ID in Datadog (needed for revocation later)
#   5. Create a new Datadog API key
#   6. Write the new key back to Secrets Manager
#   7. Write rotation_state.json artifact for downstream stages
#
# Required GitLab CI variables (Settings > CI/CD > Variables):
#   HUB_ACCOUNT_ROLE_ARN   — ARN of DatadogRotationRole in hub account
#   HUB_ACCOUNT_REGION     — us-gov-west-1
#   DD_ENV                 — Environment name: lower | ist | uat | ept | stage | prod
#   DD_APP_KEY             — Datadog Application key (api_keys_read + api_keys_write)
#
# NO secret values are stored in any file. The flow is:
#   Secrets Manager → bash variable → Datadog API → bash variable → Secrets Manager
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

DD_API_BASE="https://api.ddog-gov.com"
ROTATION_STATE_FILE="${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json"
DRY_RUN="${DRY_RUN:-false}"
DD_ENV="${DD_ENV:-}"
HUB_ACCOUNT_REGION="${HUB_ACCOUNT_REGION:-us-gov-west-1}"
SECRET_ID="datadog/${DD_ENV}/api-key"

# ------------------------------------------------------------------------------
# Assume the hub account IAM role to access Secrets Manager.
# Uses the same read/query pattern as the rest of the pipeline.
# ------------------------------------------------------------------------------
assume_hub_role() {
  log_info "Assuming hub account role for Secrets Manager access..."

  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< \
    "$(aws sts assume-role \
      --role-arn "${HUB_ACCOUNT_ROLE_ARN}" \
      --role-session-name "dd-rotation-${DD_ENV}-${CI_PIPELINE_ID:-manual}" \
      --external-id "datadog-rotation-pipeline" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text)"

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  log_info "Hub role assumed. Caller: $(aws sts get-caller-identity --query 'Arn' --output text)"
}

# ------------------------------------------------------------------------------
# Read the current API key from Secrets Manager.
# The value passes through a bash variable only — never written to disk.
# ------------------------------------------------------------------------------
read_current_key() {
  log_info "Reading current API key from Secrets Manager: ${SECRET_ID}"

  local key
  key=$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --region "${HUB_ACCOUNT_REGION}" \
    --query 'SecretString' \
    --output text)

  if [[ -z "$key" || "$key" == "None" ]]; then
    log_error "Secrets Manager returned empty value for ${SECRET_ID}"
    log_error "Has the seed-secrets job been run? (infra-pipeline.gitlab-ci.yml)"
    exit 1
  fi

  log_info "Current key read from Secrets Manager (last4: ${key: -4})"
  echo "$key"
}

# ------------------------------------------------------------------------------
# Write the new API key back to Secrets Manager.
# This is the only persistent storage for the key value.
# ------------------------------------------------------------------------------
store_new_key() {
  local new_key="$1"

  log_info "Writing new key to Secrets Manager: ${SECRET_ID} (last4: ${new_key: -4})"

  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_ID}" \
    --region "${HUB_ACCOUNT_REGION}" \
    --secret-string "${new_key}"

  # Verify the write succeeded
  local verify_key
  verify_key=$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --region "${HUB_ACCOUNT_REGION}" \
    --query 'SecretString' \
    --output text)

  if [[ "${verify_key: -4}" != "${new_key: -4}" ]]; then
    log_error "Secrets Manager write verification failed — last4 mismatch!"
    exit 1
  fi

  log_info "New key stored and verified in Secrets Manager (last4: ${new_key: -4})"
}

# ------------------------------------------------------------------------------
# Clear the assumed-role credentials so subsequent AWS calls in this job
# use the runner's base credentials, not the hub role.
# ------------------------------------------------------------------------------
clear_hub_role() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# ------------------------------------------------------------------------------
# Pre-flight: verify required variables are set before doing anything
# ------------------------------------------------------------------------------
preflight() {
  local missing=0
  for var in HUB_ACCOUNT_ROLE_ARN HUB_ACCOUNT_REGION DD_ENV DD_APP_KEY; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required variable ${var} is not set."
      missing=1
    fi
  done

  if [[ -z "$DD_ENV" ]]; then
    log_error "DD_ENV must be one of: lower, ist, uat, ept, stage, prod"
    missing=1
  fi

  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi

  log_info "Pre-flight passed. Environment: ${DD_ENV}, Secret: ${SECRET_ID}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 1: Rotate Datadog API Key [env=${DD_ENV}] =========="

  preflight

  # Step 1: Assume hub role and read current key from Secrets Manager
  assume_hub_role
  local current_key
  current_key=$(read_current_key)

  # Step 2: Validate Datadog API connectivity with current key
  log_info "Validating Datadog API connectivity..."
  local validate_http_code
  validate_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X GET "${DD_API_BASE}/api/v1/validate" \
    -H "DD-API-KEY: ${current_key}")

  if [[ "$validate_http_code" != "200" ]]; then
    log_error "Datadog API validation failed. HTTP ${validate_http_code}"
    log_error "Check: proxy settings, network connectivity, and the key in Secrets Manager."
    exit 1
  fi
  log_info "Datadog API connectivity OK."

  # Step 3: Look up the current key's ID in Datadog (needed for revocation)
  log_info "Looking up current API key ID in Datadog..."
  local old_key_response old_key_id
  old_key_response=$(curl -s -X GET "${DD_API_BASE}/api/v2/api_keys" \
    -H "DD-API-KEY: ${current_key}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}")

  local api_error
  api_error=$(echo "$old_key_response" | jq -r '.errors // empty' 2>/dev/null)
  if [[ -n "$api_error" ]]; then
    log_error "Datadog API error listing keys: ${api_error}"
    exit 1
  fi

  local last4="${current_key: -4}"
  old_key_id=$(echo "$old_key_response" | jq -r --arg last4 "$last4" \
    '(.data // [])[] | select(.attributes.last4 == $last4) | .id' | head -1)

  if [[ -z "$old_key_id" || "$old_key_id" == "null" ]]; then
    log_warn "Could not find current key ID in Datadog — manual revocation may be needed."
    old_key_id=""
  else
    log_info "Current key ID: ${old_key_id}"
  fi

  # DRY RUN: stop here if just testing connectivity
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "========== DRY RUN — all checks passed, no changes made =========="
    log_info "  Datadog API:        reachable, key valid (env=${DD_ENV})"
    log_info "  Old key ID:         ${old_key_id:-unknown}"
    log_info "  Secrets Manager:    readable (secret=${SECRET_ID})"

    jq -n \
      --arg mode "dry_run" \
      --arg env "${DD_ENV}" \
      --arg pipeline_id "${CI_PIPELINE_ID:-manual}" \
      '{mode: $mode, env: $env, pipeline_id: $pipeline_id, verify_result: "skipped"}' \
      > "$ROTATION_STATE_FILE"
    exit 0
  fi

  # Step 4: Create new Datadog API key
  local key_name="auto-rotated-${DD_ENV}-$(date -u '+%Y%m%d')-pipeline-${CI_PIPELINE_ID:-manual}"
  log_info "Creating new Datadog API key: ${key_name}"

  local create_response
  create_response=$(curl -s -X POST "${DD_API_BASE}/api/v2/api_keys" \
    -H "Content-Type: application/json" \
    -H "DD-API-KEY: ${current_key}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -d "{\"data\":{\"type\":\"api_keys\",\"attributes\":{\"name\":\"${key_name}\"}}}")

  local create_error
  create_error=$(echo "$create_response" | jq -r '.errors // empty' 2>/dev/null)
  if [[ -n "$create_error" ]]; then
    log_error "Failed to create new Datadog API key: ${create_error}"
    log_error "Ensure DD_APP_KEY has api_keys_write scope."
    exit 1
  fi

  local new_key new_key_id
  new_key=$(echo "$create_response"    | jq -r '.data.attributes.key // empty')
  new_key_id=$(echo "$create_response" | jq -r '.data.id // empty')

  if [[ -z "$new_key" ]]; then
    log_error "Datadog did not return a key value. Response: ${create_response}"
    exit 1
  fi
  log_info "New Datadog API key created. ID: ${new_key_id}, last4: ${new_key: -4}"

  # Step 5: Write new key to Secrets Manager (replaces the current value)
  store_new_key "$new_key"

  # Step 6: Clear hub role credentials
  clear_hub_role

  # Step 7: Write rotation state artifact for downstream stages
  # Note: new_key IS written here so generate_matrix.sh can inject it into
  # child-pipeline.yml. The artifact is ephemeral (expires in 1 day).
  jq -n \
    --arg env          "${DD_ENV}" \
    --arg new_key      "${new_key}" \
    --arg new_key_id   "${new_key_id}" \
    --arg old_key_id   "${old_key_id}" \
    --arg old_key_last4 "${last4}" \
    --arg rotated_at   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg pipeline_id  "${CI_PIPELINE_ID:-manual}" \
    '{
      env:           $env,
      new_key:       $new_key,
      new_key_id:    $new_key_id,
      old_key_id:    $old_key_id,
      old_key_last4: $old_key_last4,
      rotated_at:    $rotated_at,
      pipeline_id:   $pipeline_id
    }' > "$ROTATION_STATE_FILE"

  log_info "Rotation state written to ${ROTATION_STATE_FILE}"
  log_info "Stage 1 complete. New key ID: ${new_key_id}, replaces key ID: ${old_key_id:-unknown}"
}

main "$@"
