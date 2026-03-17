#!/usr/bin/env bash
# ==============================================================================
# rotate_key.sh — Stage 1: Create a new Datadog API key and store it
# ==============================================================================
# This script:
#   1. Creates a new API key in Datadog (GovCloud) via their API
#   2. Updates the GitLab CI/CD project variable with the new key
#   3. Writes the new + old key to a rotation state file for downstream stages
#
# Required env vars:
#   GITLAB_DATADOG_API_TOKEN — Current Datadog API key (from GitLab masked variable)
#   DD_APP_KEY               — Datadog Application key with api_keys_write scope
#   GITLAB_TOKEN             — GitLab API token (project access token, api scope)
#   CI_PROJECT_ID            — GitLab project ID (auto-set by GitLab CI)
#   CI_API_V4_URL            — GitLab API base URL (auto-set by GitLab CI)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Datadog GovCloud API base
DD_API_BASE="https://api.ddog-gov.com"

ROTATION_STATE_FILE="${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json"

# GitLab CI/CD variable name that holds the DD API key
DD_API_KEY_VAR_NAME="${DD_API_KEY_VAR_NAME:-GITLAB_DATADOG_API_TOKEN}"

# Use the actual variable
DD_API_KEY="${GITLAB_DATADOG_API_TOKEN}"

# ------------------------------------------------------------------------------
# Create a new Datadog API key
# ------------------------------------------------------------------------------
create_dd_api_key() {
  local key_name="auto-rotated-$(date -u '+%Y%m%d-%H%M%S')-pipeline-${CI_PIPELINE_ID:-manual}"

  log_info "Creating new Datadog API key: ${key_name}"

  local response
  response=$(curl -sf -X POST "${DD_API_BASE}/api/v2/api_keys" \
    -H "Content-Type: application/json" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -d "{\"data\":{\"type\":\"api_keys\",\"attributes\":{\"name\":\"${key_name}\"}}}")

  local new_key new_key_id
  new_key=$(echo "$response" | jq -r '.data.attributes.key')
  new_key_id=$(echo "$response" | jq -r '.data.id')

  if [[ -z "$new_key" || "$new_key" == "null" ]]; then
    log_error "Failed to create new Datadog API key. Response: ${response}"
    exit 1
  fi

  log_info "New API key created successfully. Key ID: ${new_key_id}"

  echo "$new_key"
  echo "$new_key_id" >&3
}

# ------------------------------------------------------------------------------
# Retrieve the ID of the current (old) API key so we can revoke it later
# ------------------------------------------------------------------------------
get_current_key_id() {
  log_info "Looking up current API key ID in Datadog..."

  local response
  response=$(curl -sf -X GET "${DD_API_BASE}/api/v2/api_keys" \
    -H "DD-API-KEY: ${DD_API_KEY}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}")

  # Match by the last 4 characters of the key (Datadog returns truncated keys)
  local last4="${DD_API_KEY: -4}"
  local key_id
  key_id=$(echo "$response" | jq -r --arg last4 "$last4" \
    '.data[] | select(.attributes.last4 == $last4) | .id')

  if [[ -z "$key_id" || "$key_id" == "null" ]]; then
    log_warn "Could not determine current key ID. Manual revocation may be required."
    echo ""
    return 0
  fi

  log_info "Current API key ID: ${key_id}"
  echo "$key_id"
}

# ------------------------------------------------------------------------------
# Update GitLab CI/CD variable
# ------------------------------------------------------------------------------
update_gitlab_variable() {
  local new_key="$1"

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
    exit 1
  fi

  log_info "GitLab variable updated successfully."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 1: Rotate Datadog API Key =========="

  setup_proxy

  # Get the old key ID before we do anything
  local old_key_id
  old_key_id=$(get_current_key_id)

  # Create new key — capture key on fd 1, key_id on fd 3
  local new_key new_key_id
  exec 3>&1
  new_key=$(create_dd_api_key 3>/dev/null)
  # Re-run to get the id (simpler than fd juggling in bash)
  new_key_id=$(curl -sf -X GET "${DD_API_BASE}/api/v2/api_keys" \
    -H "DD-API-KEY: ${new_key}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" | \
    jq -r ".data[] | select(.attributes.last4 == \"${new_key: -4}\") | .id" | head -1)

  # Update the GitLab variable so subsequent pipeline stages use the new key
  update_gitlab_variable "$new_key"

  # Write rotation state for downstream stages
  jq -n \
    --arg new_key "$new_key" \
    --arg new_key_id "$new_key_id" \
    --arg old_key_id "$old_key_id" \
    --arg old_key_last4 "${DD_API_KEY: -4}" \
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
  log_info "Stage 1 complete. New key ID: ${new_key_id}, Old key ID: ${old_key_id}"
}

main "$@"
