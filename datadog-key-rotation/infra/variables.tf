# ==============================================================================
# Variables — all sensitive values come from GitLab CI protected variables,
# never from defaults or hardcoded values in this file.
# ==============================================================================

variable "hub_account_id" {
  description = "AWS account ID for the hub account where Secrets Manager lives"
  type        = string
  # Injected at runtime: TF_VAR_hub_account_id (GitLab CI protected variable)
  # Example: "123456789012"
}

variable "hub_region" {
  description = "AWS GovCloud region for the hub account"
  type        = string
  default     = "us-gov-west-1"
}

variable "gitlab_runner_account_id" {
  description = "AWS account ID where GitLab shell executor runners run. DatadogRotationRole trusts this account."
  type        = string
  # Injected at runtime: TF_VAR_gitlab_runner_account_id (GitLab CI protected variable)
  # This is the account whose IAM principal the runner uses — not a secret, just a config value
}
