#!/usr/bin/env bash
# ==============================================================================
# helpers.sh — Shared functions for Datadog API key rotation pipeline
# ==============================================================================
# Environment: AWS GovCloud, self-hosted GitLab, shell executor runners
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Proxy configuration (matches existing pipeline pattern)
# Override via env vars if your proxy differs per runner.
# ------------------------------------------------------------------------------
setup_proxy() {
  export HTTPS_PROXY="${HTTPS_PROXY:-10.111.225.254:8080}"
  export NO_PROXY="${NO_PROXY:-.sk1.us-gov-west-1.eks.amazonaws.com}"
  log_info "Proxy configured: HTTPS_PROXY=${HTTPS_PROXY}"
}

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
# Input:  JSON array of cluster objects (from parse_clusters)
# Output: Filtered JSON array
#
# CLUSTER_FILTER formats:
#   ""  or "all"                        — No filter, return all clusters
#   "name1,name2,name3"                 — Match by cluster name (comma-separated)
#   "tag:prod"                          — Match clusters that have the "prod" tag
#   "tag:prod,tag:us"                   — Match clusters that have ANY of the listed tags (OR)
#   "tag:prod+us"                       — Match clusters that have ALL listed tags (AND)
#   "name1,tag:eu"                      — Mix names and tags (OR logic between them)
# ------------------------------------------------------------------------------
filter_clusters() {
  local all_clusters="$1"
  local filter="${CLUSTER_FILTER:-all}"

  # No filter — return everything
  if [[ -z "$filter" || "$filter" == "all" ]]; then
    echo "$all_clusters"
    return 0
  fi

  log_info "Applying cluster filter: ${filter}"

  local result="[]"

  # Split filter by comma
  IFS=',' read -ra filter_parts <<< "$filter"

  for part in "${filter_parts[@]}"; do
    part=$(echo "$part" | xargs)  # trim whitespace

    if [[ "$part" == tag:*+* ]]; then
      # AND tag filter: tag:prod+us → must have ALL tags
      local tag_expr="${part#tag:}"
      IFS='+' read -ra and_tags <<< "$tag_expr"

      # Build jq filter: all tags must be present
      local jq_filter=".[]"
      for tag in "${and_tags[@]}"; do
        tag=$(echo "$tag" | xargs)
        jq_filter="${jq_filter} | select(.tags | index(\"${tag}\"))"
      done

      local matched
      matched=$(echo "$all_clusters" | jq -c "[${jq_filter}]")
      result=$(echo "$result" "$matched" | jq -s 'add | unique_by(.name)')

    elif [[ "$part" == tag:* ]]; then
      # Single tag filter: tag:prod
      local tag="${part#tag:}"
      local matched
      matched=$(echo "$all_clusters" | jq -c --arg t "$tag" \
        '[.[] | select(.tags | index($t))]')
      result=$(echo "$result" "$matched" | jq -s 'add | unique_by(.name)')

    else
      # Name filter: match by cluster inventory name
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
    exit 1
  fi

  echo "$result"
}

# ------------------------------------------------------------------------------
# Assume an IAM role via STS and export credentials into the current shell.
# Uses the same read/query pattern as the existing datadog_operator pipeline.
# Usage: assume_role <role_arn> <session_name>
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

  # Sanity check
  aws sts get-caller-identity
  log_info "Assumed role successfully."
}

# ------------------------------------------------------------------------------
# Clear assumed-role credentials, reverting to the pipeline's base identity.
# ------------------------------------------------------------------------------
clear_assumed_role() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# ------------------------------------------------------------------------------
# Configure kubectl for an EKS cluster.
# Usage: setup_kubeconfig <cluster_name> <region>
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
# Usage: retry <max_attempts> <command> [args...]
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
