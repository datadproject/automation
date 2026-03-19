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
#   NEW_DD_API_KEY     — The new API key (injected by generate_matrix.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-datadog}"
K8S_SECRET_NAME="${K8S_SECRET_NAME:-datadog-secret}"
K8S_SECRET_KEY="${K8S_SECRET_KEY:-api-key}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600s}"

# ------------------------------------------------------------------------------
# Update the Kubernetes secret with the new API key
# Uses delete + create pattern (matching the existing pipeline approach)
# ------------------------------------------------------------------------------
update_secret() {
  local new_key="$1"

  # Debug: confirm we have an actual key value, not a variable reference
  log_info "NEW_DD_API_KEY length: ${#new_key} chars, last4: ${new_key: -4}"
  if [[ "$new_key" == *"GITLAB"* || "$new_key" == *"TOKEN"* || "$new_key" == *"{"* ]]; then
    log_error "NEW_DD_API_KEY contains a variable reference instead of actual key value!"
    log_error "Value looks like a literal variable name. Check child-pipeline.yml generation."
    exit 1
  fi

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

  # Verify what was actually written
  local written_key
  written_key=$(kubectl get secret "$K8S_SECRET_NAME" -n "$K8S_NAMESPACE" \
    -o jsonpath="{.data.${K8S_SECRET_KEY}}" | base64 -d)
  log_info "Secret written. Verify last4: ${written_key: -4}"

  log_info "Secret ${K8S_SECRET_NAME} updated successfully."

  # Also update any OTHER secrets referenced by the DatadogAgent CR (operator)
  update_operator_secret "$new_key"
}

# ------------------------------------------------------------------------------
# Check if Datadog Operator's DatadogAgent CR references a different secret.
# If so, update that secret too.
# ------------------------------------------------------------------------------
update_operator_secret() {
  local new_key="$1"

  # Check if a DatadogAgent CR exists
  local dda_name
  dda_name=$(kubectl get datadogagent -n "$K8S_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$dda_name" ]]; then
    log_info "No DatadogAgent CR found — skipping operator secret check."
    return 0
  fi

  log_info "Found DatadogAgent CR: ${dda_name}"

  # Get the secret name the operator uses for the API key
  local operator_secret_name operator_secret_key
  operator_secret_name=$(kubectl get datadogagent "$dda_name" -n "$K8S_NAMESPACE" \
    -o jsonpath='{.spec.credentials.apiSecret.secretName}' 2>/dev/null || true)
  operator_secret_key=$(kubectl get datadogagent "$dda_name" -n "$K8S_NAMESPACE" \
    -o jsonpath='{.spec.credentials.apiSecret.keyName}' 2>/dev/null || true)

  # Fallback: check under spec.global.credentials (newer operator versions)
  if [[ -z "$operator_secret_name" ]]; then
    operator_secret_name=$(kubectl get datadogagent "$dda_name" -n "$K8S_NAMESPACE" \
      -o jsonpath='{.spec.global.credentials.apiSecret.secretName}' 2>/dev/null || true)
    operator_secret_key=$(kubectl get datadogagent "$dda_name" -n "$K8S_NAMESPACE" \
      -o jsonpath='{.spec.global.credentials.apiSecret.keyName}' 2>/dev/null || true)
  fi

  # Default key name if not specified
  operator_secret_key="${operator_secret_key:-api-key}"

  if [[ -z "$operator_secret_name" ]]; then
    log_info "DatadogAgent CR does not specify a separate apiSecret — using default secret."
    return 0
  fi

  # If the operator uses the same secret we already updated, skip
  if [[ "$operator_secret_name" == "$K8S_SECRET_NAME" ]]; then
    log_info "Operator uses same secret (${K8S_SECRET_NAME}) — already updated."
    return 0
  fi

  # Update the operator's secret too
  log_info "Operator uses different secret: ${operator_secret_name} key=${operator_secret_key}"
  log_info "Updating operator secret..."

  if kubectl get secret "$operator_secret_name" -n "$K8S_NAMESPACE" &>/dev/null; then
    kubectl delete secret "$operator_secret_name" -n "$K8S_NAMESPACE"
  fi

  kubectl create secret generic "$operator_secret_name" \
    --from-literal="${operator_secret_key}=${new_key}" \
    -n "$K8S_NAMESPACE"

  log_info "Operator secret ${operator_secret_name} updated."
}

# ------------------------------------------------------------------------------
# Restart Datadog agent pods to pick up the new key.
#
# Strategy:
#   - If Datadog Operator is present, restart only the operator. The operator
#     watches the secret and will reconcile the agent DaemonSet + cluster agent
#     automatically. We just wait for the operator pod to be ready.
#   - If NO operator (helm-only), manually restart the DaemonSet + cluster agent.
# ------------------------------------------------------------------------------
restart_datadog_agents() {
  log_info "Triggering rolling restart of Datadog agent resources..."

  local has_operator=false

  # Check for Datadog Operator
  if kubectl get deployment datadog-operator -n "$K8S_NAMESPACE" &>/dev/null; then
    has_operator=true
    log_info "Detected Datadog Operator. Restarting operator (it will reconcile agents)..."
    kubectl rollout restart deployment/datadog-operator -n "$K8S_NAMESPACE"
    kubectl rollout status deployment/datadog-operator -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"
    log_info "Operator restarted. Waiting 30s for operator to begin agent reconciliation..."
    sleep 30
  fi

  # Find the agent DaemonSet
  local agent_ds
  agent_ds=$(kubectl get daemonset -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$agent_ds" ]]; then
    # Fallback: try common names
    for ds_name in datadog-agent datadogagent datadog; do
      if kubectl get daemonset "$ds_name" -n "$K8S_NAMESPACE" &>/dev/null; then
        agent_ds="$ds_name"
        break
      fi
    done
  fi

  if [[ -n "$agent_ds" ]]; then
    if $has_operator; then
      # Operator manages agents — just wait for rollout to finish (operator triggers it)
      log_info "Waiting for DaemonSet ${agent_ds} rollout (operator-managed)..."
      kubectl rollout status daemonset/"$agent_ds" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" || {
        log_warn "DaemonSet rollout timed out. Checking pod status..."
        kubectl get pods -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=agent --no-headers | head -10
        log_warn "Pods may still be rolling out. Continuing to health check."
      }
    else
      # No operator — manually restart
      log_info "No operator detected. Manually restarting DaemonSet: ${agent_ds}"
      kubectl rollout restart daemonset/"$agent_ds" -n "$K8S_NAMESPACE"
      kubectl rollout status daemonset/"$agent_ds" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" || {
        log_warn "DaemonSet rollout timed out. Checking pod status..."
        kubectl get pods -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=agent --no-headers | head -10
        log_warn "Pods may still be rolling out. Continuing to health check."
      }
    fi
  else
    log_warn "No Datadog agent DaemonSet found in namespace ${K8S_NAMESPACE}"
  fi

  # Cluster agent — only manually restart if no operator
  if ! $has_operator; then
    local cluster_agent_deploy
    cluster_agent_deploy=$(kubectl get deployment -n "$K8S_NAMESPACE" -l app.kubernetes.io/component=cluster-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$cluster_agent_deploy" ]]; then
      log_info "Restarting Cluster Agent deployment: ${cluster_agent_deploy}"
      kubectl rollout restart deployment/"$cluster_agent_deploy" -n "$K8S_NAMESPACE"
      kubectl rollout status deployment/"$cluster_agent_deploy" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" || {
        log_warn "Cluster agent rollout timed out. Continuing to health check."
      }
    fi
  fi

  log_info "Agent restart phase complete."
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

  local new_key="${NEW_DD_API_KEY:-}"

  if [[ -z "$new_key" ]]; then
    log_error "NEW_DD_API_KEY is not set. Check that generate_matrix.sh ran correctly."
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
