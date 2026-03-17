#!/usr/bin/env bash
# ==============================================================================
# rollout.sh — Stage 2: Roll out new API key to a single EKS cluster
# ==============================================================================
# Called once per cluster (parallel GitLab jobs via matrix). This script:
#   1. Assumes the cross-account IAM role
#   2. Updates kubeconfig for the target EKS cluster
#   3. Patches the Kubernetes secret with the new Datadog API key
#   4. Triggers a rolling restart of the Datadog agent
#   5. Waits for rollout to complete
#
# Required env vars:
#   CLUSTER_NAME       — EKS cluster name
#   AWS_REGION         — AWS region (e.g., us-gov-west-1)
#   ROLE_ARN           — Cross-account IAM role ARN (GovCloud partition)
#   K8S_NAMESPACE      — Namespace where DD secret lives (default: datadog)
#   K8S_SECRET_NAME    — K8s secret name (default: datadog-secret)
#   K8S_SECRET_KEY     — Key in the secret data map (default: api-key)
#   ROTATION_STATE_FILE — Path to rotation state JSON from stage 1
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-datadog}"
K8S_SECRET_NAME="${K8S_SECRET_NAME:-datadog-secret}"
K8S_SECRET_KEY="${K8S_SECRET_KEY:-api-key}"
ROTATION_STATE_FILE="${ROTATION_STATE_FILE:-${CI_PROJECT_DIR:-$(pwd)}/rotation_state.json}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

# ------------------------------------------------------------------------------
# Update the Kubernetes secret with the new API key
# Uses delete + create pattern (matching the existing pipeline approach)
# ------------------------------------------------------------------------------
update_secret() {
  local new_key="$1"

  log_info "Updating secret ${K8S_NAMESPACE}/${K8S_SECRET_NAME} key=${K8S_SECRET_KEY}"

  # Check if secret exists
  if kubectl get secret "$K8S_SECRET_NAME" -n "$K8S_NAMESPACE" &>/dev/null; then
    log_info "Existing secret found. Deleting and recreating..."
    kubectl delete secret "$K8S_SECRET_NAME" -n "$K8S_NAMESPACE"
  fi

  # Recreate with the new key (matches existing pipeline:
  # kubectl create secret generic datadog-secret --from-literal=api-key="$TOKEN" -n datadog)
  kubectl create secret generic "$K8S_SECRET_NAME" \
    --from-literal="${K8S_SECRET_KEY}=${new_key}" \
    -n "$K8S_NAMESPACE"

  log_info "Secret updated successfully."
}

# ------------------------------------------------------------------------------
# Restart Datadog agent pods to pick up the new key
# ------------------------------------------------------------------------------
restart_datadog_agents() {
  log_info "Triggering rolling restart of Datadog agent resources..."

  # Try Datadog Operator first
  if kubectl get deployment datadog-operator -n "$K8S_NAMESPACE" &>/dev/null; then
    log_info "Detected Datadog Operator deployment. Restarting operator..."
    kubectl rollout restart deployment/datadog-operator -n "$K8S_NAMESPACE"
    kubectl rollout status deployment/datadog-operator -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
  fi

  # Restart the agent DaemonSet
  local agent_ds
  agent_ds=$(kubectl get daemonset -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$agent_ds" ]]; then
    log_info "Restarting DaemonSet: ${agent_ds}"
    kubectl rollout restart daemonset/"$agent_ds" -n "$K8S_NAMESPACE"
    kubectl rollout status daemonset/"$agent_ds" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
  else
    log_warn "No Datadog agent DaemonSet found with label app.kubernetes.io/component=agent"
    # Fallback: try common names used by operator/helm
    for ds_name in datadog-agent datadogagent datadog; do
      if kubectl get daemonset "$ds_name" -n "$K8S_NAMESPACE" &>/dev/null; then
        log_info "Restarting DaemonSet: ${ds_name}"
        kubectl rollout restart daemonset/"$ds_name" -n "$K8S_NAMESPACE"
        kubectl rollout status daemonset/"$ds_name" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
        break
      fi
    done
  fi

  # Restart cluster agent if present
  local cluster_agent_deploy
  cluster_agent_deploy=$(kubectl get deployment -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=cluster-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$cluster_agent_deploy" ]]; then
    log_info "Restarting Cluster Agent deployment: ${cluster_agent_deploy}"
    kubectl rollout restart deployment/"$cluster_agent_deploy" -n "$K8S_NAMESPACE"
    kubectl rollout status deployment/"$cluster_agent_deploy" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
  fi

  log_info "All Datadog agent resources restarted."
}

# ------------------------------------------------------------------------------
# Quick health check — verify at least one agent pod is running
# ------------------------------------------------------------------------------
health_check() {
  log_info "Running post-rollout health check..."

  local ready_pods
  ready_pods=$(kubectl get pods -n "$K8S_NAMESPACE" \
    -l app.kubernetes.io/component=agent \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c "True" || true)

  if [[ "$ready_pods" -eq 0 ]]; then
    # Fallback: check by common labels
    ready_pods=$(kubectl get pods -n "$K8S_NAMESPACE" \
      -l app=datadog \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      2>/dev/null | grep -c "True" || true)
  fi

  if [[ "$ready_pods" -eq 0 ]]; then
    log_error "No ready Datadog agent pods found after rollout!"
    kubectl get pods -n "$K8S_NAMESPACE" --show-labels
    exit 1
  fi

  log_info "Health check passed. ${ready_pods} agent pod(s) ready."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Stage 2: Rollout to ${CLUSTER_NAME} (${AWS_REGION}) =========="

  setup_proxy

  if [[ ! -f "$ROTATION_STATE_FILE" ]]; then
    log_error "Rotation state file not found: ${ROTATION_STATE_FILE}"
    exit 1
  fi

  local new_key
  new_key=$(jq -r '.new_key' "$ROTATION_STATE_FILE")

  if [[ -z "$new_key" || "$new_key" == "null" ]]; then
    log_error "New API key not found in rotation state file."
    exit 1
  fi

  # Step 1: Assume cross-account role
  assume_role "$ROLE_ARN" "dd-rotation-${CLUSTER_NAME}"

  # Step 2: Configure kubectl
  setup_kubeconfig "$CLUSTER_NAME" "$AWS_REGION"

  # Step 3: Update the secret
  retry 3 update_secret "$new_key"

  # Step 4: Restart Datadog agents
  restart_datadog_agents

  # Step 5: Health check
  health_check

  # Clear assumed role for safety
  clear_assumed_role

  log_info "Rollout to ${CLUSTER_NAME} complete."
}

main "$@"
