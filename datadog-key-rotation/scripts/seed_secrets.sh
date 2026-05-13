#!/usr/bin/env bash
# ==============================================================================
# seed_secrets.sh — ONE-TIME bootstrap: populate Secrets Manager with initial values
# ==============================================================================
# Run ONCE after terraform apply creates the empty secret containers.
# After this job, the rotation pipeline manages all updates.
#
# Reads initial API key values from GitLab CI masked+protected variables:
#   DD_INITIAL_KEY_LOWER, DD_INITIAL_KEY_IST, DD_INITIAL_KEY_UAT,
#   DD_INITIAL_KEY_EPT, DD_INITIAL_KEY_STAGE, DD_INITIAL_KEY_PROD
#
# Required env vars:
#   HUB_ACCOUNT_ROLE_ARN  — DatadogRotationRole ARN (from Terraform output)
#   HUB_ACCOUNT_REGION    — us-gov-west-1
#
# Secret values are NEVER written to any file. They pass only through
# memory: GitLab CI variable → bash variable → AWS API call → Secrets Manager.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

HUB_ACCOUNT_REGION="${HUB_ACCOUNT_REGION:-us-gov-west-1}"

# ------------------------------------------------------------------------------
# Assume the hub account IAM role (same pattern as rotate_key.sh)
# ------------------------------------------------------------------------------
assume_hub_role() {
  log_info "Assuming hub account role: ${HUB_ACCOUNT_ROLE_ARN}"

  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< \
    "$(aws sts assume-role \
      --role-arn "${HUB_ACCOUNT_ROLE_ARN}" \
      --role-session-name "dd-seed-secrets" \
      --external-id "datadog-rotation-pipeline" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text)"

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  log_info "Hub role assumed successfully."
}

# ------------------------------------------------------------------------------
# Write one secret value to Secrets Manager.
# The key value comes from a GitLab CI variable — never from a file.
# ------------------------------------------------------------------------------
seed_environment() {
  local env_name="$1"
  local initial_key="$2"
  local secret_id="datadog/${env_name}/api-key"

  if [[ -z "$initial_key" ]]; then
    log_warn "DD_INITIAL_KEY_${env_name^^} is not set — skipping ${env_name}"
    return 0
  fi

  # Validate the key looks like a Datadog key (32 hex chars) — sanity check
  if [[ "${#initial_key}" -lt 20 ]]; then
    log_error "DD_INITIAL_KEY_${env_name^^} looks too short (${#initial_key} chars). Is it set correctly?"
    return 1
  fi

  log_info "Seeding secret: ${secret_id} (last4: ${initial_key: -4})"

  aws secretsmanager put-secret-value \
    --secret-id "${secret_id}" \
    --secret-string "${initial_key}" \
    --region "${HUB_ACCOUNT_REGION}"

  # Verify: read back and confirm last4 match
  local verify_key
  verify_key=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" \
    --region "${HUB_ACCOUNT_REGION}" \
    --query 'SecretString' \
    --output text)

  if [[ "${verify_key: -4}" != "${initial_key: -4}" ]]; then
    log_error "Verification failed for ${env_name}: last4 mismatch after write!"
    return 1
  fi

  log_info "Verified ${secret_id} (last4: ${verify_key: -4}) ✓"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  log_info "========== Seed Secrets Manager with Initial Datadog API Keys =========="
  log_info "Values come from GitLab CI masked protected variables — not from any file."
  log_info ""

  if [[ -z "${HUB_ACCOUNT_ROLE_ARN:-}" ]]; then
    log_error "HUB_ACCOUNT_ROLE_ARN is not set."
    log_error "Set it in GitLab CI > Settings > Variables (value from Terraform output)."
    exit 1
  fi

  assume_hub_role

  # Each DD_INITIAL_KEY_* is a masked+protected GitLab CI variable.
  # After this job runs successfully, those variables can be deleted from GitLab.
  seed_environment "lower" "${DD_INITIAL_KEY_LOWER:-}"
  seed_environment "ist"   "${DD_INITIAL_KEY_IST:-}"
  seed_environment "uat"   "${DD_INITIAL_KEY_UAT:-}"
  seed_environment "ept"   "${DD_INITIAL_KEY_EPT:-}"
  seed_environment "stage" "${DD_INITIAL_KEY_STAGE:-}"
  seed_environment "prod"  "${DD_INITIAL_KEY_PROD:-}"

  log_info ""
  log_info "========== Seeding complete =========="
  log_info "You can now remove DD_INITIAL_KEY_* variables from GitLab CI."
  log_info "The rotation pipeline owns secret values from this point on."
}

main "$@"
