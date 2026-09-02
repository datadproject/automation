locals {
  # ---------------------------------------------------------------------------
  # Secret reference. ECS accepts an ARN suffix to pluck a key out of a JSON
  # secret: "<arn>:json-key::". For plain-string secrets we pass the bare ARN.
  # ---------------------------------------------------------------------------
  dd_api_key_value_from = (
    var.dd_api_key_secret_json_key == null
    ? data.aws_secretsmanager_secret.dd_api_key.arn
    : "${data.aws_secretsmanager_secret.dd_api_key.arn}:${var.dd_api_key_secret_json_key}::"
  )

  extra_tags = join(",", [for k, v in var.dd_tags : "${k}:${v}"])

  dd_tags_string = join(",", compact([
    "env:${var.dd_env}",
    "service:${var.dd_service}",
    "version:${var.dd_version}",
    local.extra_tags,
  ]))

  sidecar_log_config = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = var.sidecar_log_group
      "awslogs-region"        = var.aws_region
      "awslogs-stream-prefix" = "datadog"
    }
  }

  # Exclude the sidecars from their own container metrics.
  container_exclude = join(" ", compact([
    "name:datadog-agent",
    var.enable_logs ? "name:log_router" : "",
  ]))

  # Proxy config, only emitted when dd_proxy_https is set. DD_PROXY_NO_PROXY
  # must include 169.254.170.2 or the agent proxies its own task metadata
  # lookups and ends up unable to tag anything.
  proxy_environment = var.dd_proxy_https == null ? [] : [
    { name = "DD_PROXY_HTTPS", value = var.dd_proxy_https },
    { name = "DD_PROXY_HTTP", value = var.dd_proxy_https },
    { name = "DD_PROXY_NO_PROXY", value = join(" ", var.dd_proxy_no_proxy) },
  ]

  # ---------------------------------------------------------------------------
  # Sidecar 1: Datadog agent
  # ---------------------------------------------------------------------------
  agent_container = {
    name      = "datadog-agent"
    image     = var.agent_image
    essential = var.agent_essential
    cpu       = var.agent_cpu
    memory    = var.agent_memory

    environment = concat([
      # Tells the agent it is on Fargate, so it reads the ECS task metadata
      # endpoint instead of looking for a Docker socket it will never find.
      { name = "ECS_FARGATE", value = "true" },
      { name = "DD_SITE", value = var.dd_site },
      { name = "DD_ENV", value = var.dd_env },
      { name = "DD_SERVICE", value = var.dd_service },
      { name = "DD_VERSION", value = var.dd_version },
      { name = "DD_TAGS", value = local.dd_tags_string },

      # --- APM
      { name = "DD_APM_ENABLED", value = tostring(var.enable_apm) },
      # Required even under awsvpc: the trace agent binds loopback-only by
      # default and you get silent trace drops without this.
      { name = "DD_APM_NON_LOCAL_TRAFFIC", value = "true" },
      { name = "DD_APM_RECEIVER_PORT", value = "8126" },

      # --- DogStatsD
      { name = "DD_USE_DOGSTATSD", value = tostring(var.enable_dogstatsd) },
      { name = "DD_DOGSTATSD_NON_LOCAL_TRAFFIC", value = "true" },
      # Attaches task/container tags to custom metrics automatically.
      { name = "DD_DOGSTATSD_TAG_CARDINALITY", value = "orchestrator" },

      { name = "DD_CONTAINER_EXCLUDE", value = local.container_exclude },
    ], local.proxy_environment)

    # Never appears in the task definition JSON, in tfstate, or in CI vars.
    secrets = [
      { name = "DD_API_KEY", valueFrom = local.dd_api_key_value_from },
    ]

    portMappings = concat(
      var.enable_apm ? [{ containerPort = 8126, hostPort = 8126, protocol = "tcp" }] : [],
      var.enable_dogstatsd ? [{ containerPort = 8125, hostPort = 8125, protocol = "udp" }] : [],
    )

    # Lets the app container wait for a genuinely ready agent instead of
    # dropping the first ~30s of startup spans on every deploy.
    healthCheck = {
      command     = ["CMD-SHELL", "agent health"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    logConfiguration = local.sidecar_log_config
  }

  # ---------------------------------------------------------------------------
  # Sidecar 2: FireLens / fluent-bit log router
  # ---------------------------------------------------------------------------
  log_router_container = {
    name      = "log_router"
    image     = var.fluentbit_image
    essential = var.log_router_essential
    cpu       = var.fluentbit_cpu
    memory    = var.fluentbit_memory
    user      = "0"

    firelensConfiguration = {
      type = "fluentbit"
      options = {
        "enable-ecs-log-metadata" = "true"
      }
    }

    logConfiguration = local.sidecar_log_config
  }

  sidecar_containers = concat(
    [local.agent_container],
    var.enable_logs ? [local.log_router_container] : [],
  )

  # ---------------------------------------------------------------------------
  # Fragments merged into the CONSUMER's app container
  # ---------------------------------------------------------------------------
  app_log_configuration = var.enable_logs ? {
    logDriver = "awsfirelens"
    options = merge({
      Name        = "datadog"
      Host        = "http-intake.logs.${var.dd_site}"
      TLS         = "on"
      compress    = "gzip"
      provider    = "ecs"
      dd_service  = var.dd_service
      dd_source   = var.log_source
      dd_tags     = local.dd_tags_string
      retry_limit = "2"
      },
      # fluent-bit's datadog output needs its own proxy setting; it does not
      # read HTTPS_PROXY from the environment.
      var.dd_proxy_https == null ? {} : { proxy = var.dd_proxy_https },
    )
    secretOptions = [
      { name = "apikey", valueFrom = local.dd_api_key_value_from },
    ]
  } : null

  app_environment = concat(
    [
      { name = "DD_ENV", value = var.dd_env },
      { name = "DD_SERVICE", value = var.dd_service },
      { name = "DD_VERSION", value = var.dd_version },
      # awsvpc puts every container in one network namespace, so loopback works.
      { name = "DD_AGENT_HOST", value = "127.0.0.1" },
      # Injects trace_id/span_id into app logs -> log/trace correlation.
      { name = "DD_LOGS_INJECTION", value = "true" },
      { name = "DD_RUNTIME_METRICS_ENABLED", value = "true" },
    ],
    var.enable_apm ? [
      { name = "DD_TRACE_ENABLED", value = "true" },
      { name = "DD_TRACE_AGENT_PORT", value = "8126" },
    ] : [],
    var.enable_dogstatsd ? [
      { name = "DD_DOGSTATSD_PORT", value = "8125" },
    ] : [],
    var.enable_profiling ? [
      { name = "DD_PROFILING_ENABLED", value = "true" },
    ] : [],
  )

  app_depends_on = concat(
    [{ containerName = "datadog-agent", condition = "HEALTHY" }],
    var.enable_logs ? [{ containerName = "log_router", condition = "START" }] : [],
  )

  # Unified Service Tagging labels the agent reads off the task metadata.
  app_docker_labels = {
    "com.datadoghq.tags.env"     = var.dd_env
    "com.datadoghq.tags.service" = var.dd_service
    "com.datadoghq.tags.version" = var.dd_version
  }
}
