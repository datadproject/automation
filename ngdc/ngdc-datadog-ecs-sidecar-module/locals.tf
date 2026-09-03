###############################################################################
# ngdc-datadog-ecs-sidecar-module/locals.tf
#
# All computation. Output shapes match ngdc-ecs-cluster-module's DSL:
#   container_name, image, essential, environment = map(string),
#   secrets, port_mappings, plus the keys added by the module patch.
###############################################################################

locals {
  # ---------------------------------------------------------------------------
  # Secret reference. ECS accepts an ARN suffix to select a key from a JSON
  # secret: <arn>:json-key::  . Plain-string secrets use the bare ARN.
  # ---------------------------------------------------------------------------
  dd_api_key_value_from = (
    var.dd_api_key_secret_json_key == null
    ? data.aws_secretsmanager_secret.dd_api_key.arn
    : "${data.aws_secretsmanager_secret.dd_api_key.arn}:${var.dd_api_key_secret_json_key}::"
  )

  # Derived from the site, so ddog-gov.com cannot silently keep pointing at
  # the commercial intake.
  logs_intake_host = "http-intake.logs.${var.dd_site}"

  # ---------------------------------------------------------------------------
  # Proxy -- AGENT ONLY. Fluent Bit's proxy is set on its output plugin below.
  #
  # 169.254.170.2 is the ECS task metadata endpoint; loopback keeps same-task
  # APM and DogStatsD traffic off the proxy. Unioned in unconditionally rather
  # than trusted to the caller.
  # ---------------------------------------------------------------------------
  agent_no_proxy = distinct(concat(
    var.agent_proxy_no_proxy,
    ["169.254.170.2", "localhost", "127.0.0.1"],
  ))

  agent_proxy_environment = var.agent_proxy_https == null ? {} : {
    DD_PROXY_HTTPS = var.agent_proxy_https
    DD_PROXY_HTTP  = coalesce(var.agent_proxy_http, var.agent_proxy_https)

    # Space-separated, matching Datadog's expected format.
    DD_PROXY_NO_PROXY = join(" ", local.agent_no_proxy)

    # Allows suffix/substring matching in NO_PROXY instead of exact-host only.
    DD_NO_PROXY_NONEXACT_MATCH = "true"
  }

  # ---------------------------------------------------------------------------
  # Datadog Agent container -- in the generic module's schema.
  #
  # NOTE: no DD_CONTAINER_EXCLUDE. Excluding the Agent and log_router would
  # remove them from container metrics and the Containers view -- exactly the
  # ECS/container visibility this deployment wants. Datadog does not require
  # the exclusion; it is a noise-reduction choice and here the signal is
  # wanted.
  #
  # environment is map(string) because the generic module renders it with
  #   [ for k, v in cdef.environment : { name = k, value = v } ]
  # ---------------------------------------------------------------------------
  agent_environment = merge(
    {
      # Tells the Agent it is on Fargate, so it reads the ECS task metadata
      # endpoint instead of looking for a Docker socket it will never find.
      ECS_FARGATE = "true"
      DD_SITE     = var.dd_site

      DD_ENV     = var.dd_env
      DD_SERVICE = var.dd_service
      DD_VERSION = var.dd_version

      # ECS / container health and metrics.
      DD_CONTAINER_LIFECYCLE_ENABLED = "true"

      # --- APM
      DD_APM_ENABLED           = tostring(var.enable_apm)
      DD_APM_RECEIVER_PORT     = tostring(var.apm_receiver_port)
      # Required even under awsvpc: the trace agent binds loopback-only by
      # default and you get silent trace drops without it.
      DD_APM_NON_LOCAL_TRAFFIC = "true"

      # --- DogStatsD
      DD_USE_DOGSTATSD              = tostring(var.enable_dogstatsd)
      DD_DOGSTATSD_PORT             = tostring(var.dogstatsd_port)
      DD_DOGSTATSD_NON_LOCAL_TRAFFIC = "true"
      DD_DOGSTATSD_TAG_CARDINALITY  = var.dogstatsd_tag_cardinality
    },
    local.agent_proxy_environment,
    var.extra_agent_environment,
  )

  agent_container = merge(
    {
    container_name = "datadog-agent"
    image          = var.agent_image
    essential      = var.agent_essential

    environment = local.agent_environment

    # The API key value never appears in the task definition JSON, in tfstate,
    # or in tfvars. ECS resolves it at task start via the EXECUTION role.
    secrets = [
      {
        name      = "DD_API_KEY"
        valueFrom = local.dd_api_key_value_from
      },
    ]

    port_mappings = concat(
      var.enable_apm ? [{
        containerPort = var.apm_receiver_port
        hostPort      = var.apm_receiver_port
        protocol      = "tcp"
      }] : [],
      var.enable_dogstatsd ? [{
        containerPort = var.dogstatsd_port
        hostPort      = var.dogstatsd_port
        protocol      = "udp"
      }] : [],
    )

    health_check = {
      command     = var.agent_health_check_command
      interval    = try(var.agent_health_check.interval, 15)
      timeout     = try(var.agent_health_check.timeout, 5)
      retries     = try(var.agent_health_check.retries, 3)
      startPeriod = try(var.agent_health_check.start_period, 60)
    }
    },
    # Omitted entirely when null, so the generic module needs no
    # container_cpu / container_memory support.
    var.agent_cpu == null ? {} : { container_cpu = var.agent_cpu },
    var.agent_memory == null ? {} : { container_memory = var.agent_memory },
  )

  # ---------------------------------------------------------------------------
  # Fluent Bit log router -- in the generic module's schema.
  #
  # No log_configuration override: it inherits the module's task-level awslogs
  # config, which is what we want for the sidecars' own stdout.
  # ---------------------------------------------------------------------------
  log_router_container = merge(
    {
    container_name = "log_router"
    image          = var.fluentbit_image
    essential      = var.log_router_essential

    environment = {}

    firelens_configuration = {
      type = "fluentbit"
      options = {
        "enable-ecs-log-metadata" = "true"
      }
    }
    },
    var.fluentbit_cpu == null ? {} : { container_cpu = var.fluentbit_cpu },
    var.fluentbit_memory == null ? {} : { container_memory = var.fluentbit_memory },
  )

  # A MAP keyed by container name, because the generic module's
  # container_definitions is a map. Adding sidecars is merge(), not concat().
  sidecar_container_definitions = merge(
    { "datadog-agent" = local.agent_container },
    var.enable_logs ? { "log_router" = local.log_router_container } : {},
  )

  # ---------------------------------------------------------------------------
  # App container fragments -- merged by the CALLER. Nothing here replaces
  # unrelated app settings.
  # ---------------------------------------------------------------------------

  # map(string) to merge() into the app container's existing `environment`.
  #
  # Same-task loopback, ONE consistent pattern: DD_AGENT_HOST +
  # DD_TRACE_AGENT_PORT. DD_TRACE_AGENT_URL is deliberately NOT also set --
  # setting both invites disagreement between tracer versions.
  app_environment = merge(
    {
      DD_ENV        = var.dd_env
      DD_SERVICE    = var.dd_service
      DD_VERSION    = var.dd_version
      DD_AGENT_HOST = "127.0.0.1"
    },
    var.enable_apm ? {
      DD_TRACE_ENABLED     = "true"
      DD_TRACE_AGENT_PORT  = tostring(var.apm_receiver_port)
    } : {},
    var.enable_dogstatsd ? {
      DD_DOGSTATSD_PORT = tostring(var.dogstatsd_port)
    } : {},
    var.enable_logs_injection ? { DD_LOGS_INJECTION = "true" } : {},
    var.enable_runtime_metrics ? { DD_RUNTIME_METRICS_ENABLED = "true" } : {},
    var.enable_profiling ? { DD_PROFILING_ENABLED = "true" } : {},
    var.extra_app_environment,
  )

  # Empty unless explicitly enabled -- see emit_docker_labels. UST already
  # works via DD_ENV / DD_SERVICE / DD_VERSION on both containers.
  app_docker_labels = var.emit_docker_labels ? {
    "com.datadoghq.tags.env"     = var.dd_env
    "com.datadoghq.tags.service" = var.dd_service
    "com.datadoghq.tags.version" = var.dd_version
  } : {}

  # FireLens output for the app container. API key via secretOptions, never
  # plaintext. `proxy` is Fluent Bit's own setting, independent of DD_PROXY_*.
  #
  # REQUIRES the generic module's per-container log_configuration override.
  app_log_configuration = var.enable_logs ? {
    logDriver = "awsfirelens"
    options = merge(
      {
        Name        = "datadog"
        Host        = local.logs_intake_host
        TLS         = "on"
        compress    = "gzip"
        provider    = "ecs"
        dd_service  = var.dd_service
        dd_source   = var.log_source
        dd_tags     = "env:${var.dd_env},service:${var.dd_service},version:${var.dd_version}"
        retry_limit = "2"
      },
      var.fluentbit_proxy == null ? {} : { proxy = var.fluentbit_proxy },
    )
    secretOptions = [
      {
        name      = "apikey"
        valueFrom = local.dd_api_key_value_from
      },
    ]
  } : null

  # dependsOn.
  #
  # Agent HEALTHY is OPT-IN (app_wait_for_agent, default false): with
  # agent_essential = false, forcing the app to block on Agent health would
  # reintroduce the coupling that setting exists to avoid.
  #
  # log_router START is on by default when logs are enabled -- START not
  # HEALTHY, so it is cheap, and without it early log lines are dropped.
  app_depends_on = concat(
    var.app_wait_for_agent ? [{
      containerName = "datadog-agent"
      condition     = "HEALTHY"
    }] : [],
    (var.enable_logs && var.app_depends_on_log_router) ? [{
      containerName = "log_router"
      condition     = "START"
    }] : [],
  )
}
