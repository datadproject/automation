#!/usr/bin/env bash
# ==============================================================================
# rotate_key.sh — Stage 1: Create a new Datadog API key and store it
# ==============================================================================
# Required env vars:
#   GITLAB_DATADOG_API_TOKEN — Current Datadog API key (from GitLab masked variable)
#   DD_APP_KEY               — Datadog Application key with api_keys_write scope
#   GITLAB_TOKEN             — GitLab API token (project access token, api scope)
#   CI_PROJECT_ID            — GitLab project ID (auto-set by GitLab CI)
#   CI_API_V4_URL            — GitLab API base URL (auto-set by GitLab CI)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

DD_API_BASE="https://api.ddog-gov.com"
ROTATION_STATE_FILE="${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json"
DD_API_KEY_VAR_NAME="${DD_API_KEY_VAR_NAME:-GITLAB_DATADOG_API_TOKEN}"
DD_API_KEY="${GITLAB_DATADOG_API_TOKEN}"

# ------------------------------------------------------------------------------
# Pre-flight check — make sure required vars are set
# ------------------------------------------------------------------------------
preflight() {
  local missing=0
  for var in GITLAB_DATADOG_API_TOKEN DD_APP_KEY GITLAB_TOKEN CI_PROJECT_ID CI_API_V4_URL; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required variable ${var} is not set."
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi
  log_info "Pre-flight check passed."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 1: Rotate Datadog API Key =========="

  preflight

  # --- Step 1: Look up the current (old) key ID ---
  log_info "Looking up current API key ID in Datadog..."
  local old_key_response old_key_id
  old_key_response=$(curl -s -X GET "${DD_API_BASE}/api/v2/api_keys" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}")

  if [[ $? -ne 0 ]]; then
    log_error "Failed to query Datadog API. Check proxy/network."
    log_error "Response: ${old_key_response}"
    exit 1
  fi

  local last4="${DD_API_KEY: -4}"
  old_key_id=$(echo "$old_key_response" | jq -r --arg last4 "$last4" \
    '.data[] | select(.attributes.last4 == $last4) | .id' | head -1)

  if [[ -z "$old_key_id" || "$old_key_id" == "null" ]]; then
    log_warn "Could not determine current key ID. Old key will need manual revocation."
    old_key_id=""
  else
    log_info "Current API key ID: ${old_key_id}"
  fi

  # --- Step 2: Create a new API key ---
  local key_name="auto-rotated-$(date -u '+%Y%m%d-%H%M%S')-pipeline-${CI_PIPELINE_ID:-manual}"
  log_info "Creating new Datadog API key: ${key_name}"

  local create_response
  create_response=$(curl -s -X POST "${DD_API_BASE}/api/v2/api_keys" \
    -H "Content-Type: application/json" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -d "{\"data\":{\"type\":\"api_keys\",\"attributes\":{\"name\":\"${key_name}\"}}}")

  if [[ $? -ne 0 ]]; then
    log_error "Failed to create new API key. Check proxy/network."
    log_error "Response: ${create_response}"
    exit 1
  fi

  local new_key new_key_id
  new_key=$(echo "$create_response" | jq -r '.data.attributes.key')
  new_key_id=$(echo "$create_response" | jq -r '.data.id')

  if [[ -z "$new_key" || "$new_key" == "null" ]]; then
    log_error "Failed to create new Datadog API key."
    log_error "Response: ${create_response}"
    exit 1
  fi

  log_info "New API key created. Key ID: ${new_key_id}"

  # --- Step 3: Update GitLab CI/CD variable ---
  log_info "Updating GitLab CI/CD variable: ${DD_API_KEY_VAR_NAME}"

  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X PUT "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/variables/${DD_API_KEY_VAR_NAME}" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --form "value=${new_key}" \
    --form "protected=true" \
    --form "masked=true")

  if [[ "$http_code" != "200" ]]; then
    log_error "Failed to update GitLab variable. HTTP ${http_code}"
    log_error "The new key was created in Datadog (ID: ${new_key_id}) but NOT saved to GitLab."
    log_error "Manually update the variable or delete the new key in Datadog."
    exit 1
  fi

  log_info "GitLab variable updated successfully."

  # --- Step 4: Write rotation state for downstream stages ---
  jq -n \
    --arg new_key "$new_key" \
    --arg new_key_id "$new_key_id" \
    --arg old_key_id "$old_key_id" \
    --arg old_key_last4 "$last4" \
    --arg rotated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg pipeline_id "${CI_PIPELINE_ID:-manual}" \
    '{
      new_key: $new_key,
      new_key_id: $new_key_id,
      old_key_id: $old_key_id,
      old_key_last4: $old_key_last4,
      rotated_at: $rotated_at,
      pipeline_id: $pipeline_id
    }' > "$ROTATION_STATE_FILE"

  log_info "Rotation state written to ${ROTATION_STATE_FILE}"
  log_info "Stage 1 complete. New key ID: ${new_key_id}, Old key ID: ${old_key_id:-unknown}"
}

main "$@"
