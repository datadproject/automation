#!/usr/bin/env bash
# ==============================================================================
# helpers.sh — Shared functions for Datadog API key rotation pipeline
# ==============================================================================
# Environment: AWS GovCloud, self-hosted GitLab, shell executor runners
#
# NOTE: This file does NOT set "set -euo pipefail". Each script that sources
# this file controls its own error handling. This prevents sourcing from
# killing the caller's shell on unset variables.
# ==============================================================================

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
log_warn()  { echo "[WARN]  $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >&2; }
log_error() { echo "[ERROR] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >&2; }

# ------------------------------------------------------------------------------
# Parse clusters.yml — requires yq v4+
# Outputs JSON array of cluster objects with defaults merged.
# ------------------------------------------------------------------------------
parse_clusters() {
  local config_file="${1:-config/clusters.yml}"

  yq eval -o=json '
    .clusters[] as $c |
    {
      "name":            $c.name,
      "aws_account_id":  $c.aws_account_id,
      "aws_region":      $c.aws_region,
      "cluster_name":    $c.cluster_name,
      "role_arn":         $c.role_arn,
      "namespace":       ($c.namespace // .defaults.namespace),
      "secret_name":     ($c.secret_name // .defaults.secret_name),
      "secret_key":      ($c.secret_key // .defaults.secret_key),
      "role_session_name": ($c.role_session_name // .defaults.role_session_name),
      "tags":            ($c.tags // [])
    }
  ' "$config_file" | jq -s '.'
}

# ------------------------------------------------------------------------------
# Filter clusters based on CLUSTER_FILTER env var.
# ------------------------------------------------------------------------------
filter_clusters() {
  local all_clusters="$1"
  local filter="${CLUSTER_FILTER:-all}"

  if [[ -z "$filter" || "$filter" == "all" ]]; then
    echo "$all_clusters"
    return 0
  fi

  log_info "Applying cluster filter: ${filter}"

  local result="[]"
  IFS=',' read -ra filter_parts <<< "$filter"

  for part in "${filter_parts[@]}"; do
    part=$(echo "$part" | xargs)

    if [[ "$part" == tag:*+* ]]; then
      local tag_expr="${part#tag:}"
      IFS='+' read -ra and_tags <<< "$tag_expr"
      local jq_filter=".[]"
      for tag in "${and_tags[@]}"; do
        tag=$(echo "$tag" | xargs)
        jq_filter="${jq_filter} | select(.tags | index(\"${tag}\"))"
      done
      local matched
      matched=$(echo "$all_clusters" | jq -c "[${jq_filter}]")
      result=$(echo "$result" "$matched" | jq -s 'add | unique_by(.name)')

    elif [[ "$part" == tag:* ]]; then
      local tag="${part#tag:}"
      local matched
      matched=$(echo "$all_clusters" | jq -c --arg t "$tag" \
        '[.[] | select(.tags | index($t))]')
      result=$(echo "$result" "$matched" | jq -s 'add | unique_by(.name)')

    else
      local matched
      matched=$(echo "$all_clusters" | jq -c --arg n "$part" \
        '[.[] | select(.name == $n)]')
      result=$(echo "$result" "$matched" | jq -s 'add | unique_by(.name)')
    fi
  done

  local count
  count=$(echo "$result" | jq length)
  log_info "Filter matched ${count} cluster(s)"

  if [[ "$count" -eq 0 ]]; then
    log_error "CLUSTER_FILTER '${filter}' matched zero clusters. Check filter and clusters.yml."
    return 1
  fi

  echo "$result"
}

# ------------------------------------------------------------------------------
# Assume an IAM role via STS and export credentials into the current shell.
# Uses the same read/query pattern as the existing datadog_operator pipeline.
# ------------------------------------------------------------------------------
assume_role() {
  local role_arn="$1"
  local session_name="${2:-gitlab-ci}"

  log_info "Assuming role: ${role_arn}"

  read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< \
    $(aws sts assume-role \
      --role-arn "$role_arn" \
      --role-session-name "$session_name" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text)

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  aws sts get-caller-identity
  log_info "Assumed role successfully."
}

# ------------------------------------------------------------------------------
# Clear assumed-role credentials
# ------------------------------------------------------------------------------
clear_assumed_role() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# ------------------------------------------------------------------------------
# Configure kubectl for an EKS cluster.
# ------------------------------------------------------------------------------
setup_kubeconfig() {
  local cluster_name="$1"
  local region="$2"

  log_info "Updating kubeconfig for cluster=${cluster_name} region=${region}"
  aws eks update-kubeconfig \
    --name "$cluster_name" \
    --region "$region"
}

# ------------------------------------------------------------------------------
# Retry a command with exponential backoff.
# ------------------------------------------------------------------------------
retry() {
  local max_attempts="$1"; shift
  local attempt=1
  local wait_time=5

  until "$@"; do
    if (( attempt >= max_attempts )); then
      log_error "Command failed after ${max_attempts} attempts: $*"
      return 1
    fi
    log_warn "Attempt ${attempt}/${max_attempts} failed. Retrying in ${wait_time}s..."
    sleep "$wait_time"
    (( attempt++ ))
    (( wait_time *= 2 ))
  done
}
