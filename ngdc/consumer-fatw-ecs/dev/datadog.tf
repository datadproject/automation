###############################################################################
# datadog.tf
#
# The module call, and nothing else. Locals live in locals.tf, data sources in
# data.tf, matching the layout of ngdc-ecs-cluster-module.
#
# IDENTICAL in dev/test/stage/prod. Every environment difference is in
# ecs.tfvars. Drop this file in unchanged; `diff dev/datadog.tf prod/datadog.tf`
# should stay empty forever.
#
# No resources here any more. The log group and the execution-role policy are
# module-owned now -- they exist only because the sidecars need them.
###############################################################################

module "datadog" {
  for_each = local.dd_services

  # for_each on a module works only because the module declares no configured
  # provider block. See the module README.
  source  = "${var.module_registry}/ngdc/datadog-ecs-sidecar/aws"
  version = var.datadog_module_version

  aws_region = var.aws_region

  # The container the ALB targets is the one we instrument.
  app_container_name = each.value.load_balancer.container_name

  # Module creates its own log group at /ecs/<env>/<service>/datadog-sidecars.
  # Set sidecar_log_group here instead if a central team owns log groups.
  sidecar_log_retention_days = var.dd_sidecar_log_retention_days

  # Module attaches the secret-read inline policy to this role. It does NOT
  # create the role -- you still own that. If your ECS module creates the
  # execution role, pass its name output here instead.
  execution_role_name = aws_iam_role.execution[each.key].name

  dd_api_key_secret_name = var.dd_api_key_secret_name

  # GOVCLOUD: ddog-gov.com. Validated against the region in variables.tf.
  dd_site = var.dd_site

  # Unified Service Tagging.
  dd_env     = var.environment
  dd_service = each.value.service_name
  dd_version = var.image_tag
  dd_tags    = var.dd_tags
  log_source = try(each.value.dd_log_source, var.dd_log_source)

  # null when the subnets have NAT or VPC endpoints.
  dd_proxy_https    = var.dd_proxy_https
  dd_proxy_no_proxy = var.dd_proxy_no_proxy

  # Private ECR, pinned by digest.
  agent_image     = var.dd_agent_image
  fluentbit_image = var.dd_fluentbit_image

  enable_apm       = try(each.value.dd_enable_apm, true)
  enable_logs      = try(each.value.dd_enable_logs, true)
  enable_dogstatsd = try(each.value.dd_enable_dogstatsd, true)
  enable_profiling = try(each.value.dd_enable_profiling, false)

  tags = var.common_tags
}
