output "container_definitions" {
  description = "Sidecar container definitions. concat() with your app container(s)."
  value       = local.sidecar_containers
}

output "app_log_configuration" {
  description = "Set as logConfiguration on the app container. null when enable_logs = false."
  value       = local.app_log_configuration
}

output "app_environment" {
  description = "Merge into the app container's environment list."
  value       = local.app_environment
}

output "app_depends_on" {
  description = "Set as dependsOn on the app container."
  value       = local.app_depends_on
}

output "app_docker_labels" {
  description = "Merge into the app container's dockerLabels (Unified Service Tagging)."
  value       = local.app_docker_labels
}

output "execution_role_policy_json" {
  description = "Attach to the task EXECUTION role. This module deliberately does not create IAM resources."
  value       = data.aws_iam_policy_document.execution_role_secrets.json
}

output "additional_cpu" {
  description = "Add to the task-level cpu."
  value       = var.agent_cpu + (var.enable_logs ? var.fluentbit_cpu : 0)
}

output "additional_memory" {
  description = "Add to the task-level memory."
  value       = var.agent_memory + (var.enable_logs ? var.fluentbit_memory : 0)
}

output "dd_api_key_secret_arn" {
  description = "Resolved ARN, exposed for debugging and for policies owned elsewhere."
  value       = data.aws_secretsmanager_secret.dd_api_key.arn
}
