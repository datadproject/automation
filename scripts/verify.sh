#!/usr/bin/env bash
# ==============================================================================
# verify.sh — Verify clusters are reporting with the new key
# ==============================================================================
# Queries the Datadog GovCloud API to confirm hosts are still reporting after
# the key rotation. Does a single pass (no polling loop) since each cluster's
# rollout job already waited for pods to be ready and checked the API.
#
# Uses a threshold to decide pass/fail:
#   - VERIFY_THRESHOLD (default: 80) — minimum % of clusters that must be
#     reporting for the verification to pass and allow revoke to proceed.
#   - This handles the reality that 1-2 clusters out of 30 may be slow to
#     report without blocking the entire rotation.
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

# Minimum percentage of clusters that must be reporting to pass verification
VERIFY_THRESHOLD="${VERIFY_THRESHOLD:-80}"

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
# ------------------------------------------------------------------------------
check_cluster_reporting() {
  local new_key="$1"
  local cluster_name="$2"

  local response
  response=$(curl -sf -X GET \
    "${DD_API_BASE}/api/v1/hosts?filter=kube_cluster_name:${cluster_name}&count=1&from=$(( $(date +%s) - 900 ))" \
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
# Main — single pass, threshold-based
# ------------------------------------------------------------------------------
main() {
  log_info "========== Verify Cluster Reporting =========="

  if [[ ! -f "$ROTATION_STATE_FILE" ]]; then
    log_error "Rotation state file not found: ${ROTATION_STATE_FILE}"
    exit 1
  fi

  local new_key
  new_key=$(jq -r '.new_key' "$ROTATION_STATE_FILE")

  # Build list of expected clusters
  mapfile -t expected_clusters < <(get_expected_clusters)
  local total_clusters=${#expected_clusters[@]}

  log_info "Checking ${total_clusters} cluster(s) against Datadog API (threshold: ${VERIFY_THRESHOLD}%)"

  local reporting=0
  local not_reporting=()

  for cluster in "${expected_clusters[@]}"; do
    if check_cluster_reporting "$new_key" "$cluster"; then
      (( reporting++ ))
      log_info "  ✓ ${cluster}"
    else
      not_reporting+=("$cluster")
      log_warn "  ✗ ${cluster}"
    fi
  done

  # Calculate percentage
  local pct=0
  if (( total_clusters > 0 )); then
    pct=$(( (reporting * 100) / total_clusters ))
  fi

  log_info "Result: ${reporting}/${total_clusters} clusters reporting (${pct}%)"

  # Determine pass/fail based on threshold
  local verify_result
  if [[ "$reporting" -eq "$total_clusters" ]]; then
    verify_result="success"
    log_info "All ${total_clusters} clusters verified."
  elif (( pct >= VERIFY_THRESHOLD )); then
    verify_result="partial_pass"
    log_warn "${reporting}/${total_clusters} reporting (${pct}% >= ${VERIFY_THRESHOLD}% threshold). Proceeding."
    if [[ ${#not_reporting[@]} -gt 0 ]]; then
      log_warn "Not reporting: ${not_reporting[*]}"
      log_warn "These clusters may need manual investigation."
    fi
  else
    verify_result="fail"
    log_error "Only ${reporting}/${total_clusters} reporting (${pct}% < ${VERIFY_THRESHOLD}% threshold)."
    log_error "Not reporting: ${not_reporting[*]}"
    log_error "The old API key will NOT be revoked to prevent data loss."
  fi

  # Update rotation state with verification result
  local tmp
  tmp=$(mktemp)
  jq --arg result "$verify_result" \
     --arg verified_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     --arg reporting "${reporting}/${total_clusters}" \
     --arg pct "${pct}%" \
     '. + {verify_result: $result, verified_at: $verified_at, verify_reporting: $reporting, verify_pct: $pct}' \
     "$ROTATION_STATE_FILE" > "$tmp" && mv "$tmp" "$ROTATION_STATE_FILE"

  if [[ "$verify_result" == "fail" ]]; then
    exit 1
  fi
}

main "$@"
