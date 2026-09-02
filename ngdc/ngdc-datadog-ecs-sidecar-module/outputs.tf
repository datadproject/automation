output "container_definitions" {
  description = "Sidecar container definitions. concat() with your app container."
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
  description = "Merge into the app container's dockerLabels."
  value       = local.app_docker_labels
}

output "additional_cpu" {
  description = "Add to the task-level cpu."
  value       = var.agent_cpu + (var.enable_logs ? var.fluentbit_cpu : 0)
}

output "additional_memory" {
  description = "Add to the task-level memory."
  value       = var.agent_memory + (var.enable_logs ? var.fluentbit_memory : 0)
}

output "log_group_name" {
  description = "Sidecar log group, whether module-created or caller-supplied."
  value       = local.log_group_name
}

output "dd_api_key_secret_arn" {
  description = "Resolved ARN. Exposed for debugging."
  value       = data.aws_secretsmanager_secret.dd_api_key.arn
}

output "execution_role_policy_json" {
  description = <<-EOT
    Only needed when execution_role_name is null. When it is set, the module
    attaches this itself and you can ignore this output.
  EOT
  value       = data.aws_iam_policy_document.execution_role_secrets.json
}

output "partition" {
  description = "aws | aws-us-gov. Use to build partition-correct ARNs in the caller."
  value       = data.aws_partition.current.partition
}
