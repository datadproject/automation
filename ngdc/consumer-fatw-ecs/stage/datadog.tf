###############################################################################
# consumer-fatw-ecs/stage/datadog.tf
#
# Calls the sidecar module once per Datadog-enabled service.
#
# Creates NO task definitions. ngdc-ecs-cluster-module remains the sole owner
# of aws_ecs_task_definition; this only produces fragments that locals.tf
# merges into the task-definition map.
#
# IDENTICAL in dev/test/stage/prod. All variation comes from ecs.tfvars.
###############################################################################

module "datadog" {
  for_each = local.dd_services

  # for_each works ONLY because the module declares no `provider "aws" {}`
  # block. If you get "Module is incompatible with count, for_each, and
  # depends_on", a provider block has been added to the module -- delete it.
  #
  # Source comes from a variable so the git ref is set in ecs.tfvars.
  # Move off a branch ref to a TAG before prod: a push to the branch changes
  # every consumer's next apply.
  source = var.dd_module_source

  aws_region = var.aws_region

  # --- Secrets: metadata lookup only; the value never enters state --------
  dd_api_key_secret_name     = var.dd_api_key_secret_name
  dd_api_key_secret_json_key = var.dd_api_key_secret_json_key

  # Explicit. Validated against the AWS partition inside the module.
  dd_site = var.dd_site

  # --- Unified Service Tagging --------------------------------------------
  dd_env     = var.environment
  dd_service = each.value.service_name
  dd_version = var.image_tag

  # --- Images: private mirror, pinned -------------------------------------
  agent_image     = var.dd_agent_image
  fluentbit_image = var.dd_fluentbit_image

  # --- Proxy: Agent and Fluent Bit configured SEPARATELY ------------------
  agent_proxy_https    = var.dd_agent_proxy_https
  agent_proxy_http     = var.dd_agent_proxy_http
  agent_proxy_no_proxy = var.dd_agent_proxy_no_proxy
  fluentbit_proxy      = var.dd_fluentbit_proxy

  # --- Signals -------------------------------------------------------------
  # NOTE: enable_logs REQUIRES the ngdc-ecs-cluster-module patch. With the
  # module unpatched, set dd_enable_logs = false on the service in tfvars --
  # metrics and APM work with no module change at all.
  enable_apm       = try(each.value.dd_enable_apm, true)
  enable_logs      = try(each.value.dd_enable_logs, true)
  enable_dogstatsd = try(each.value.dd_enable_dogstatsd, true)
  enable_profiling = try(each.value.dd_enable_profiling, false)
  log_source       = try(each.value.dd_log_source, var.dd_log_source)

  # --- Container reservations ---------------------------------------------
  # null by default -> the keys are OMITTED, matching your estate, where
  # container_cpu / container_memory are commented out on every container.
  # The generic module therefore needs no change for these.
  #
  # Task-level cpu/memory are NEVER modified. Backend stays 1024/2048.
  agent_cpu        = try(each.value.dd_agent_cpu, null)
  agent_memory     = try(each.value.dd_agent_memory, null)
  fluentbit_cpu    = try(each.value.dd_fluentbit_cpu, null)
  fluentbit_memory = try(each.value.dd_fluentbit_memory, null)

  # --- Behaviour -----------------------------------------------------------
  agent_essential    = false
  app_wait_for_agent = try(each.value.dd_app_wait_for_agent, false)
}

###############################################################################
# IAM
#
# The module emits the policy document; this repo attaches it.
#
# ngdc-ecs-cluster-module takes task_execution_role as an ARN INPUT -- it does
# not create the role -- so the role is owned outside both modules and there
# is no dependency cycle. local.dd_execution_role_names derives the name from
# the ARN already in ecs.tfvars.
#
# aws_iam_role_policy is an INLINE policy: namespaced per role, so it cannot
# collide with anything else attached to NGDC-FATW-ECS-Execution-Role, and
# removing it does not touch the role.
###############################################################################

resource "aws_iam_role_policy" "datadog_execution_secret" {
  for_each = local.dd_services

  # Service-scoped, so two services sharing the one execution role cannot
  # overwrite each other. Your estate shares
  # NGDC-FATW-ECS-Execution-Role across all six task definitions.
  name = "datadog-secret-read-${each.value.service_name}"

  role   = local.dd_execution_role_names[each.key]
  policy = module.datadog[each.key].execution_role_policy_json
}
