#!/usr/bin/env bash
# ==============================================================================
# revoke_old_key.sh — Stage 4: Revoke the old Datadog API key
# ==============================================================================
# Only runs if verification succeeded. Deletes the old API key from Datadog
# GovCloud so it can no longer be used.
#
# Required env vars:
#   DD_APP_KEY          — Datadog Application key
#   ROTATION_STATE_FILE — Path to rotation state JSON
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

DD_API_BASE="https://api.ddog-gov.com"
ROTATION_STATE_FILE="${ROTATION_STATE_FILE:-${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json}"

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 4: Revoke Old API Key =========="


  if [[ ! -f "$ROTATION_STATE_FILE" ]]; then
    log_error "Rotation state file not found: ${ROTATION_STATE_FILE}"
    exit 1
  fi

  # Validate that rotation_state.json has the required fields
  local new_key_check
  new_key_check=$(jq -r '.new_key // empty' "$ROTATION_STATE_FILE")
  if [[ -z "$new_key_check" ]]; then
    log_error "No new_key found in rotation_state.json. Cannot proceed with revoke."
    exit 1
  fi

  local new_key old_key_id old_key_last4
  new_key=$(jq -r '.new_key' "$ROTATION_STATE_FILE")
  old_key_id=$(jq -r '.old_key_id' "$ROTATION_STATE_FILE")
  old_key_last4=$(jq -r '.old_key_last4' "$ROTATION_STATE_FILE")

  if [[ -z "$old_key_id" || "$old_key_id" == "null" || "$old_key_id" == "" ]]; then
    log_warn "Old key ID is unknown. Cannot auto-revoke."
    log_warn "Please manually revoke the old key (last 4: ${old_key_last4}) in the Datadog console."
    exit 0
  fi

  log_info "Revoking old API key. ID: ${old_key_id}, last4: ${old_key_last4}"

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "${DD_API_BASE}/api/v2/api_keys/${old_key_id}" \
    -H "DD-API-KEY: ${new_key}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log_info "Old API key revoked successfully."
  elif [[ "$http_code" == "404" ]]; then
    log_warn "Old API key not found (already revoked?). HTTP 404."
  else
    log_error "Failed to revoke old API key. HTTP ${http_code}"
    log_error "Manual revocation required. Key ID: ${old_key_id}"
    exit 1
  fi

  # Final state update
  local tmp
  tmp=$(mktemp)
  jq --arg revoked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     '. + {old_key_revoked: true, revoked_at: $revoked_at}' \
     "$ROTATION_STATE_FILE" > "$tmp" && mv "$tmp" "$ROTATION_STATE_FILE"

  log_info "Rotation complete. Summary:"
  jq '{pipeline_id, rotated_at, verified_at, revoked_at, new_key_id, old_key_id, old_key_last4, verify_result, old_key_revoked}' \
    "$ROTATION_STATE_FILE"
}

main "$@"
