###############################################################################
# datadog.tf
#
# Uses the OFFICIAL Datadog module:
#   https://github.com/DataDog/terraform-aws-ecs-datadog
#   registry: DataDog/ecs-datadog/aws//modules/ecs_fargate
#
# IMPORTANT STRUCTURAL POINT
# This module WRAPS aws_ecs_task_definition -- it creates the task definition
# itself rather than handing you containers to merge. So for Datadog-enabled
# services the task definition is produced HERE, and your existing
# aws_ecs_task_definition resource must exclude those services.
# See task-definitions-PATCH.md.
#
# Identical in dev/test/stage/prod. All variation lives in ecs.tfvars.
###############################################################################

module "datadog_task" {
  for_each = local.dd_services

  source  = "DataDog/ecs-datadog/aws//modules/ecs_fargate"
  version = var.datadog_module_version

  # ---------------------------------------------------------------------------
  # Task definition (same arguments as aws_ecs_task_definition, but config
  # blocks become attributes: `runtime_platform = {...}` not `runtime_platform {...}`)
  # ---------------------------------------------------------------------------
  family = "${var.environment}-${each.value.service_name}"

  # The module adds the agent + fluentbit containers on top of these and
  # injects the tracer env vars, volume mounts and log driver into them.
  container_definitions = jsonencode([local.dd_app_container[each.key]])

  cpu    = each.value.cpu
  memory = each.value.memory

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  runtime_platform = {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  # UDS sockets for APM and DogStatsD need a shared volume. This is the
  # Datadog-recommended transport on Fargate; see dd_apm/dd_dogstatsd below.
  volumes = [
    { name = "dd-sockets" },
  ]

  # pid_mode = "task" is the module default and is required for process
  # monitoring, but it triggers an AWS bug that limits `ecs execute-command`
  # to a single container per task. Set to null if your teams rely on exec.
  pid_mode = var.dd_pid_mode

  # ---------------------------------------------------------------------------
  # IAM -- roles are still created by THIS repo. We only hand over the ARNs.
  #
  # add_dd_ecs_permissions lets the module attach the policies it needs
  # (secret read + ECS metadata). Note upstream issue #47: when an execution
  # role and a secret are both provided the module creates that policy
  # unconditionally, with no opt-out yet.
  # ---------------------------------------------------------------------------
  execution_role = {
    arn                    = aws_iam_role.execution[each.key].arn
    add_dd_ecs_permissions = true
  }

  task_role = {
    arn                    = aws_iam_role.task[each.key].arn
    add_dd_ecs_permissions = true
  }

  # ---------------------------------------------------------------------------
  # Datadog configuration
  # ---------------------------------------------------------------------------
  dd_api_key_secret = {
    arn = data.aws_secretsmanager_secret.dd_api_key.arn
  }

  # GOVCLOUD: ddog-gov.com. Separate Datadog org, separate API key.
  dd_site = var.dd_site

  # Unified Service Tagging.
  dd_env     = var.environment
  dd_service = each.value.service_name
  dd_version = var.image_tag

  # NOTE: dd_tags is a STRING here, not a map. "key1:value1, key2:value2".
  dd_tags = local.dd_tags_string

  # GOVCLOUD: public.ecr.aws is unreachable. Point at private ECR.
  # The module composes registry + image_version, so this is TAG-based --
  # it does not accept a digest. See README for the trade-off.
  dd_registry      = var.dd_agent_registry
  dd_image_version = var.dd_agent_version

  # An agent crash must not take down the service.
  dd_essential = false

  # Application containers wait for the agent before starting, so startup
  # traces are not dropped on every deploy.
  dd_is_datadog_dependency_enabled = true

  dd_apm = {
    enabled = try(each.value.dd_enable_apm, true)
    # UDS instead of loopback TCP. Datadog's recommended transport on
    # Fargate: avoids network overhead and simplifies origin detection.
    socket_enabled = true
    profiling      = try(each.value.dd_enable_profiling, false)
  }

  dd_dogstatsd = {
    enabled                  = try(each.value.dd_enable_dogstatsd, true)
    socket_enabled           = true
    origin_detection_enabled = true
    dogstatsd_cardinality    = "orchestrator"
  }

  dd_log_collection = {
    enabled = try(each.value.dd_enable_logs, true)
    fluentbit_config = {
      # GOVCLOUD: private ECR mirror.
      registry      = var.dd_fluentbit_registry
      image_version = var.dd_fluentbit_version

      # Datadog defaults both of these to false. We enable them: a dead log
      # router leaves the app's log driver with nowhere to write, and the
      # dependency prevents losing startup logs.
      is_log_router_essential          = true
      is_log_router_dependency_enabled = true

      log_driver_configuration = {
        # GOVCLOUD: module default is http-intake.logs.datadoghq.com, which
        # is wrong for ddog-gov.com. Must be set explicitly.
        host_endpoint = "http-intake.logs.${var.dd_site}"
        tls           = true
        compress      = "gzip"
        service_name  = each.value.service_name
        source_name   = try(each.value.dd_log_source, var.dd_log_source)
      }
    }
  }

  # Escape hatch for anything the typed interface does not cover. Overwrites
  # module-set variables with the same key, so use sparingly.
  #
  # Proxy config goes here: your estate references HTTPS_PROXY
  # 10.111.225.254:8080. DD_PROXY_NO_PROXY must include 169.254.170.2 or the
  # agent proxies its own ECS task-metadata lookups and cannot tag anything.
  dd_environment = var.dd_proxy_https == null ? [] : [
    { name = "DD_PROXY_HTTPS", value = var.dd_proxy_https },
    { name = "DD_PROXY_HTTP", value = var.dd_proxy_https },
    { name = "DD_PROXY_NO_PROXY", value = join(" ", var.dd_proxy_no_proxy) },
  ]

  tags = var.common_tags
}
