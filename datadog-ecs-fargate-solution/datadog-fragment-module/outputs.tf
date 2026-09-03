output "sidecar_container_definitions" {
  description = "Container map to merge into the existing task definition."
  value       = local.sidecar_container_definitions
}

output "app_environment" {
  description = "Environment map to merge into the application container."
  value       = local.app_environment
}

output "app_log_configuration" {
  description = "FireLens app log configuration; null while logs are disabled."
  value       = local.app_log_configuration
}

output "app_depends_on" {
  description = "Dependency entries for the application container."
  value       = local.app_depends_on
}

output "execution_role_policy_json" {
  description = "Policy required by the ECS execution role for secret injection."
  value       = data.aws_iam_policy_document.execution_role_secrets.json
}

output "dd_api_key_secret_arn" {
  value = data.aws_secretsmanager_secret.dd_api_key.arn
}

output "logs_intake_host" {
  value = local.logs_intake_host
}

