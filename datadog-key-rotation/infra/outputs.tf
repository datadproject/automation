# ==============================================================================
# Outputs — copy these values into GitLab CI > Settings > CI/CD > Variables
# after the first terraform apply.
# ==============================================================================

output "hub_account_role_arn" {
  description = "→ Set this as HUB_ACCOUNT_ROLE_ARN in GitLab CI protected variables"
  value       = aws_iam_role.datadog_rotation.arn
}

output "kms_key_arn" {
  description = "KMS key ARN (reference only)"
  value       = aws_kms_key.datadog_rotation.arn
}

output "secret_names" {
  description = "Secrets Manager paths created per environment (values are empty until seed-secrets runs)"
  value = {
    for env in local.environments :
    env => "datadog/${env}/api-key"
  }
}

output "next_steps" {
  description = "What to do after apply"
  value       = <<-EOT
    NEXT STEPS:
    1. Copy HUB_ACCOUNT_ROLE_ARN output into GitLab CI > Settings > Variables
    2. Run the seed-secrets pipeline job to populate initial key values
    3. After seeding, the rotation pipeline is fully operational
  EOT
}
