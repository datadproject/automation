#!/usr/bin/env bash
# ==============================================================================
# verify.sh — Stage 3: Verify all clusters are reporting with the new key
# ==============================================================================
# Queries the Datadog GovCloud API to confirm hosts are still reporting after
# the key rotation. Waits up to VERIFY_TIMEOUT seconds for all expected
# clusters to check in.
#
# Required env vars:
#   DD_APP_KEY          — Datadog Application key
#   ROTATION_STATE_FILE — Path to rotation state JSON from stage 1
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

DD_API_BASE="https://api.ddog-gov.com"
ROTATION_STATE_FILE="${ROTATION_STATE_FILE:-${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json}"
CONFIG_FILE="${CONFIG_FILE:-config/clusters.json}"

# How long to wait for hosts to report (default: 10 minutes)
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"
# How often to poll (default: 30 seconds)
VERIFY_INTERVAL="${VERIFY_INTERVAL:-30}"

# ------------------------------------------------------------------------------
# Get list of expected cluster names from inventory (respects CLUSTER_FILTER)
# ------------------------------------------------------------------------------
get_expected_clusters() {
  local all_clusters
  all_clusters=$(parse_clusters "$CONFIG_FILE")

  local filtered
  filtered=$(filter_clusters "$all_clusters")

  echo "$filtered" | jq -r '.[].cluster_name'
}

# ------------------------------------------------------------------------------
# Check if a specific host/cluster is reporting to Datadog
# Uses the new API key from the rotation state.
# ------------------------------------------------------------------------------
check_cluster_reporting() {
  local new_key="$1"
  local cluster_name="$2"

  # Query Datadog for hosts with a matching cluster name tag
  # The agent reports kube_cluster_name as a host tag
  local response
  response=$(curl -sf -X GET \
    "${DD_API_BASE}/api/v1/hosts?filter=kube_cluster_name:${cluster_name}&count=1&from=$(( $(date +%s) - 300 ))" \
    -H "DD-API-KEY: ${new_key}" \
    -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" 2>/dev/null || echo '{"total_matching": 0}')

  local total
  total=$(echo "$response" | jq -r '.total_matching // 0')

  if [[ "$total" -gt 0 ]]; then
    return 0
  else
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Main verification loop
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 3: Verify Cluster Reporting =========="

  setup_proxy

  if [[ ! -f "$ROTATION_STATE_FILE" ]]; then
    log_error "Rotation state file not found: ${ROTATION_STATE_FILE}"
    exit 1
  fi

  local new_key
  new_key=$(jq -r '.new_key' "$ROTATION_STATE_FILE")

  # Build list of expected clusters
  mapfile -t expected_clusters < <(get_expected_clusters)
  local total_clusters=${#expected_clusters[@]}

  log_info "Expecting ${total_clusters} clusters to report."

  local start_time
  start_time=$(date +%s)
  local all_reporting=false

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))

    if (( elapsed > VERIFY_TIMEOUT )); then
      log_error "Verification timed out after ${VERIFY_TIMEOUT}s"
      break
    fi

    local reporting=0
    local not_reporting=()

    for cluster in "${expected_clusters[@]}"; do
      if check_cluster_reporting "$new_key" "$cluster"; then
        (( reporting++ ))
      else
        not_reporting+=("$cluster")
      fi
    done

    log_info "Reporting: ${reporting}/${total_clusters} (elapsed: ${elapsed}s)"

    if [[ "$reporting" -eq "$total_clusters" ]]; then
      all_reporting=true
      break
    fi

    if [[ ${#not_reporting[@]} -gt 0 ]]; then
      log_warn "Not yet reporting: ${not_reporting[*]}"
    fi

    sleep "$VERIFY_INTERVAL"
  done

  # Write verification result
  local verify_result
  if $all_reporting; then
    verify_result="success"
    log_info "All ${total_clusters} clusters verified. Rotation successful."
  else
    verify_result="partial"
    log_error "Not all clusters reporting. Manual intervention required."
    log_error "The old API key has NOT been revoked to prevent data loss."
  fi

  # Update rotation state with verification result
  local tmp
  tmp=$(mktemp)
  jq --arg result "$verify_result" \
     --arg verified_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     '. + {verify_result: $result, verified_at: $verified_at}' \
     "$ROTATION_STATE_FILE" > "$tmp" && mv "$tmp" "$ROTATION_STATE_FILE"

  if [[ "$verify_result" != "success" ]]; then
    exit 1
  fi
}

main "$@"
