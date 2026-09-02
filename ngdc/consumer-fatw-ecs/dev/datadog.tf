# =============================================================================
# dev/datadog.tf
#
# Opt-in per service. Only entries in var.ecs_service with
# `datadog_enabled = true` get sidecars. Frontend stays untouched.
#
# This is a plain .tf file, not a .tmpl -- nothing in here needs envsubst, so
# keeping it out of the template avoids the dotless-${NAME} landmine entirely.
# =============================================================================

data "aws_partition" "current" {}

locals {
  # The opt-in filter. Frontend has no datadog_enabled key, so try() -> false.
  dd_services = {
    for name, svc in var.ecs_service : name => svc
    if try(svc.datadog_enabled, false)
  }
}

module "datadog" {
  for_each = local.dd_services

  # for_each on a module only works because the module declares no provider
  # block. This is exactly the constraint called out in the module README.
  source  = "${var.module_registry}/ngdc/datadog-ecs-sidecar/aws"
  version = var.datadog_module_version

  aws_region = var.aws_region

  # The container the ALB targets is the app container we instrument.
  app_container_name = each.value.load_balancer.container_name
  sidecar_log_group  = aws_cloudwatch_log_group.dd_sidecars[each.key].name

  dd_api_key_secret_name = var.dd_api_key_secret_name

  # GOVCLOUD: ddog-gov.com. See README before changing.
  dd_site = var.dd_site

  # Unified Service Tagging.
  dd_env     = var.environment
  dd_service = each.value.service_name
  dd_version = var.image_tag
  dd_tags    = var.dd_tags
  log_source = try(each.value.dd_log_source, var.dd_log_source)

  # Proxy. null when the subnets have NAT / VPC endpoints.
  dd_proxy_https    = var.dd_proxy_https
  dd_proxy_no_proxy = var.dd_proxy_no_proxy

  # GOVCLOUD: these MUST point at private ECR in the GovCloud account.
  agent_image     = var.dd_agent_image
  fluentbit_image = var.dd_fluentbit_image

  enable_apm       = try(each.value.dd_enable_apm, true)
  enable_logs      = try(each.value.dd_enable_logs, true)
  enable_dogstatsd = try(each.value.dd_enable_dogstatsd, true)
  enable_profiling = try(each.value.dd_enable_profiling, false)
}

resource "aws_cloudwatch_log_group" "dd_sidecars" {
  for_each = local.dd_services

  name              = "/ecs/${var.environment}/${each.value.service_name}/datadog-sidecars"
  retention_in_days = 7
}

# -----------------------------------------------------------------------------
# Execution role policy.
#
# The module emits a document; this repo owns the role. If your ECS module
# creates the execution role instead, expose its name as an output and swap
# the `role` argument below -- do NOT let two modules create the same role.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "dd_execution_secret" {
  for_each = local.dd_services

  name   = "datadog-secret-read"
  role   = aws_iam_role.execution[each.key].id
  policy = module.datadog[each.key].execution_role_policy_json
}

# -----------------------------------------------------------------------------
# Helpers the task-definition code consumes.
# -----------------------------------------------------------------------------
locals {
  # Sidecar container definitions, keyed by service. Empty list for services
  # without Datadog, so the concat() below is unconditional and safe.
  dd_sidecars = {
    for name, svc in var.ecs_service : name => try(
      module.datadog[name].container_definitions, []
    )
  }

  dd_extra_cpu = {
    for name, svc in var.ecs_service : name => try(
      module.datadog[name].additional_cpu, 0
    )
  }

  dd_extra_memory = {
    for name, svc in var.ecs_service : name => try(
      module.datadog[name].additional_memory, 0
    )
  }
}

output "datadog_enabled_services" {
  description = "Sanity check: should list backend_service only."
  value       = keys(local.dd_services)
}

output "datadog_task_sizing" {
  description = "Confirm these land on legal Fargate cpu/memory pairs."
  value = {
    for name, svc in local.dd_services : name => {
      cpu    = svc.cpu + local.dd_extra_cpu[name]
      memory = svc.memory + local.dd_extra_memory[name]
    }
  }
}
