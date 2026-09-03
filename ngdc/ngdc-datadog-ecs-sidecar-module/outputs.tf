###############################################################################
# ngdc-datadog-ecs-sidecar-module/outputs.tf
#
# Fragments only, in the ngdc-ecs-cluster-module schema.
#
# DELIBERATELY ABSENT: additional_cpu / additional_memory.
# Those invited task_cpu = existing + additional, which produces invalid
# Fargate task sizes (512 + 192 = 704 is rejected). Fargate task sizes are an
# allowlist. Container reservations FIT INSIDE the declared task size; they
# are never added to it.
###############################################################################

output "sidecar_container_definitions" {
  description = <<-EOT
    MAP keyed by container name -- datadog-agent, and log_router when
    enable_logs. merge() into the task definition's container_definitions map.

    Shape matches ngdc-ecs-cluster-module: container_name, image, essential,
    environment as map(string), secrets, port_mappings, plus health_check /
    firelens_configuration / user / container_cpu / container_memory which
    require the module patch.
  EOT
  value       = local.sidecar_container_definitions
}

output "app_environment" {
  description = <<-EOT
    map(string) of Datadog env vars for the APP container.
    merge() into the app container's existing `environment` map -- the
    generic module renders it as [{name, value}].
  EOT
  value       = local.app_environment
}

output "app_docker_labels" {
  description = "Unified Service Tagging labels. merge() into the app container's docker_labels."
  value       = local.app_docker_labels
}

output "app_log_configuration" {
  description = <<-EOT
    awsfirelens logConfiguration for the app container, or null when
    enable_logs = false. When null the caller sets nothing and the app keeps
    the generic module's awslogs config.

    REQUIRES the generic module's per-container log_configuration override.
  EOT
  value       = local.app_log_configuration
}

output "app_depends_on" {
  description = "dependsOn entries for the app container. May be empty -- omit the key rather than setting []."
  value       = local.app_depends_on
}

output "execution_role_policy_json" {
  description = <<-EOT
    IAM policy for the ECS EXECUTION role: secretsmanager:GetSecretValue on
    the Datadog secret, plus kms:Decrypt scoped to the secret's CMK only when
    one is in use.

    The CALLER attaches this. Your generic ECS module takes
    task_execution_role as an ARN input, so the role is owned outside both
    modules.
  EOT
  value       = data.aws_iam_policy_document.execution_role_secrets.json
}

output "dd_api_key_secret_arn" {
  description = "Resolved secret ARN. Metadata only -- the value is never read."
  value       = data.aws_secretsmanager_secret.dd_api_key.arn
}

output "logs_intake_host" {
  description = "Derived from dd_site. Confirm this is the gov intake in GovCloud."
  value       = local.logs_intake_host
}

output "partition" {
  description = "aws | aws-us-gov. For partition-correct ARNs in the caller."
  value       = data.aws_partition.current.partition
}

output "container_names" {
  description = "Sidecar container names, for assertions in the caller."
  value       = keys(local.sidecar_container_definitions)
}
