data "aws_partition" "current" {}

data "aws_secretsmanager_secret" "dd_api_key" {
  name = var.dd_api_key_secret_name
}

locals {
  dd_api_key_value_from = var.dd_api_key_secret_json_key == null ? (
    data.aws_secretsmanager_secret.dd_api_key.arn
    ) : (
    "${data.aws_secretsmanager_secret.dd_api_key.arn}:${var.dd_api_key_secret_json_key}::"
  )

  logs_intake_host = "http-intake.logs.${var.dd_site}"

  agent_no_proxy = distinct(concat(
    var.agent_proxy_no_proxy,
    ["169.254.170.2", "localhost", "127.0.0.1"],
  ))

  agent_proxy_environment = var.agent_proxy_https == null ? {} : {
    DD_PROXY_HTTPS             = var.agent_proxy_https
    DD_PROXY_HTTP              = coalesce(var.agent_proxy_http, var.agent_proxy_https)
    DD_PROXY_NO_PROXY          = join(" ", local.agent_no_proxy)
    DD_NO_PROXY_NONEXACT_MATCH = "true"
  }

  agent_environment = merge(
    {
      ECS_FARGATE                    = "true"
      DD_SITE                        = var.dd_site
      DD_ENV                         = var.dd_env
      DD_SERVICE                     = var.dd_service
      DD_VERSION                     = var.dd_version
      DD_CONTAINER_LIFECYCLE_ENABLED = "true"
      DD_APM_ENABLED                 = tostring(var.enable_apm)
      DD_APM_RECEIVER_PORT           = tostring(var.apm_receiver_port)
      DD_APM_NON_LOCAL_TRAFFIC       = "true"
      DD_USE_DOGSTATSD               = tostring(var.enable_dogstatsd)
      DD_DOGSTATSD_PORT              = tostring(var.dogstatsd_port)
      DD_DOGSTATSD_NON_LOCAL_TRAFFIC = "true"
      DD_DOGSTATSD_TAG_CARDINALITY   = var.dogstatsd_tag_cardinality
    },
    local.agent_proxy_environment,
    var.extra_agent_environment,
  )

  agent_container = merge(
    {
      container_name = "datadog-agent"
      image          = var.agent_image
      essential      = var.agent_essential
      environment    = local.agent_environment
      secrets = [{
        name      = "DD_API_KEY"
        valueFrom = local.dd_api_key_value_from
      }]
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
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    },
    var.agent_cpu == null ? {} : { container_cpu = var.agent_cpu },
    var.agent_memory == null ? {} : { container_memory = var.agent_memory },
  )

  log_router_container = merge(
    {
      container_name = "log_router"
      image          = var.fluentbit_image
      essential      = var.log_router_essential
      environment    = {}
      firelens_configuration = {
        type = "fluentbit"
        options = {
          enable-ecs-log-metadata = "true"
        }
      }
    },
    var.fluentbit_cpu == null ? {} : { container_cpu = var.fluentbit_cpu },
    var.fluentbit_memory == null ? {} : { container_memory = var.fluentbit_memory },
  )

  sidecar_container_definitions = merge(
    { "datadog-agent" = local.agent_container },
    var.enable_logs ? { "log_router" = local.log_router_container } : {},
  )

  app_environment = merge(
    {
      DD_ENV        = var.dd_env
      DD_SERVICE    = var.dd_service
      DD_VERSION    = var.dd_version
      DD_AGENT_HOST = "127.0.0.1"
    },
    var.enable_apm ? {
      DD_TRACE_ENABLED    = "true"
      DD_TRACE_AGENT_PORT = tostring(var.apm_receiver_port)
    } : {},
    var.enable_dogstatsd ? {
      DD_DOGSTATSD_PORT = tostring(var.dogstatsd_port)
    } : {},
    var.enable_logs_injection ? { DD_LOGS_INJECTION = "true" } : {},
    var.enable_runtime_metrics ? { DD_RUNTIME_METRICS_ENABLED = "true" } : {},
    var.enable_profiling ? { DD_PROFILING_ENABLED = "true" } : {},
    var.extra_app_environment,
  )

  app_log_configuration = var.enable_logs ? {
    logdriver = "awsfirelens"
    options = merge(
      {
        Name       = "datadog"
        Host       = local.logs_intake_host
        TLS        = "on"
        compress   = "gzip"
        provider   = "ecs"
        dd_service = var.dd_service
        dd_source  = var.log_source
        dd_tags    = "env:${var.dd_env},service:${var.dd_service},version:${var.dd_version}"
        retry_limit = "2"
      },
      var.fluentbit_proxy == null ? {} : { proxy = var.fluentbit_proxy },
    )
    secretOptions = [{
      name      = "apikey"
      valueFrom = local.dd_api_key_value_from
    }]
  } : null

  app_depends_on = concat(
    var.app_wait_for_agent ? [{
      containerName = "datadog-agent"
      condition     = "HEALTHY"
    }] : [],
    var.enable_logs && var.app_depends_on_log_router ? [{
      containerName = "log_router"
      condition     = "START"
    }] : [],
  )
}

data "aws_iam_policy_document" "execution_role_secrets" {
  statement {
    sid       = "ReadDatadogApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.dd_api_key.arn]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]

    content {
      sid       = "DecryptDatadogApiKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

