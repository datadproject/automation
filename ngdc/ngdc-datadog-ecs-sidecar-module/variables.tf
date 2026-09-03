###############################################################################
# ngdc-datadog-ecs-sidecar-module/variables.tf
#
# Fragment module. Emits container definitions and app-container fragments IN
# THE ngdc-ecs-cluster-module SCHEMA (container_name / environment as
# map(string) / port_mappings), not raw ECS JSON.
#
# Creates NO aws_ecs_task_definition, NO aws_ecs_service, NO aws_ecs_cluster,
# NO IAM. The generic ECS module remains the sole resource owner.
###############################################################################

###############################################################################
# Required
###############################################################################

variable "aws_region" {
  description = "Used for the KMS ViaService condition on the secret policy."
  type        = string
}

variable "dd_api_key_secret_name" {
  description = <<-EOT
    NAME of the Secrets Manager secret holding the Datadog API key.
    Terraform reads METADATA ONLY (the ARN). The secret value is never
    fetched into state -- that would require aws_secretsmanager_secret_version,
    which is deliberately not used. ECS resolves the value at task start.
  EOT
  type        = string
}

variable "dd_api_key_secret_json_key" {
  description = "Key inside a JSON secret. null for a plain-string secret."
  type        = string
  default     = null
}

# --- Unified Service Tagging
variable "dd_env" {
  description = "DD_ENV, e.g. dev / test / stage / prod."
  type        = string
}

variable "dd_service" {
  description = "DD_SERVICE, e.g. backend-service."
  type        = string
}

variable "dd_version" {
  description = "DD_VERSION. Wire to the app image tag or CI_COMMIT_SHORT_SHA."
  type        = string
}

variable "dd_site" {
  description = <<-EOT
    Explicit, no default. GovCloud uses ddog-gov.com -- a physically separate
    Datadog instance with its own org and its own API keys. A commercial-site
    key authenticates against nothing there.

    The log intake host is derived: http-intake.logs.<dd_site>
  EOT
  type        = string

  validation {
    condition = contains([
      "datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com",
      "datadoghq.eu", "ap1.datadoghq.com", "ddog-gov.com",
    ], var.dd_site)
    error_message = "dd_site must be a recognised Datadog site."
  }
}

variable "agent_image" {
  description = <<-EOT
    Fully-qualified, pinned Datadog Agent image.
    Closed/GovCloud: public.ecr.aws and gcr.io are unreachable -- use the
    private ECR mirror. Digest form preferred.
  EOT
  type        = string

  validation {
    condition     = !can(regex("^public\\.ecr\\.aws|^gcr\\.io", var.agent_image))
    error_message = "public.ecr.aws and gcr.io are unreachable from closed/GovCloud environments. Use the private mirror."
  }

  validation {
    condition     = !can(regex(":(latest|stable)$", var.agent_image))
    error_message = "Pin an explicit version or digest. 'latest' and 'stable' float."
  }
}

###############################################################################
# Log collection (FireLens / Fluent Bit)
#
# REQUIRES the generic ECS module patch. Without per-container
# log_configuration support the app container is locked to awslogs.
###############################################################################

variable "enable_logs" {
  description = <<-EOT
    true  -> app logs go to Datadog via awsfirelens + Fluent Bit sidecar.
             REQUIRES the generic ECS module patch.
    false -> no log_router; the app keeps the module's awslogs config.
             Works with the generic module UNPATCHED.

    Enabling this replaces the app container's awslogs driver, so app logs
    stop arriving in CloudWatch. Check retention/audit requirements first.
  EOT
  type        = bool
  default     = true
}

variable "fluentbit_image" {
  description = "Fully-qualified, pinned aws-for-fluent-bit image. Required when enable_logs."
  type        = string
  default     = null

  validation {
    condition     = var.fluentbit_image == null || !can(regex("^public\\.ecr\\.aws|^gcr\\.io", var.fluentbit_image))
    error_message = "public.ecr.aws and gcr.io are unreachable from closed/GovCloud environments."
  }

  validation {
    condition     = var.fluentbit_image == null || !can(regex(":(latest|stable)$", var.fluentbit_image))
    error_message = "Pin an explicit version or digest."
  }
}

variable "log_source" {
  description = "dd_source. Drives Datadog's log parsing pipeline: java, nodejs, python, nginx."
  type        = string
  default     = "ecs"
}

variable "log_router_essential" {
  description = "true: a dead router leaves the app's log driver nowhere to write."
  type        = bool
  default     = true
}

variable "app_depends_on_log_router" {
  description = "true: app waits for log_router START so early log lines are not dropped."
  type        = bool
  default     = true
}

###############################################################################
# Proxy
#
# The Agent and Fluent Bit are SEPARATE CONTAINERS with separate networking.
# DD_PROXY_* configures ONLY the Agent. Fluent Bit needs its own proxy option
# on the Datadog output plugin.
###############################################################################

variable "agent_proxy_https" {
  description = "Agent DD_PROXY_HTTPS, e.g. http://10.111.225.254:8080. null when subnets have NAT."
  type        = string
  default     = null
}

variable "agent_proxy_http" {
  description = "Agent DD_PROXY_HTTP. Falls back to agent_proxy_https."
  type        = string
  default     = null
}

variable "agent_proxy_no_proxy" {
  description = <<-EOT
    Extra NO_PROXY entries. The module ALWAYS unions in:
      169.254.170.2, localhost, 127.0.0.1
    Omitting 169.254.170.2 makes the Agent proxy its own task-metadata
    lookups, after which it cannot tag anything.
  EOT
  type        = list(string)
  default     = ["169.254.169.254"]
}

variable "fluentbit_proxy" {
  description = <<-EOT
    Proxy for the Fluent Bit Datadog output plugin. Fluent Bit does NOT read
    DD_PROXY_HTTPS.

    MUST be http:// form -- the plugin's `proxy` option expects an HTTP proxy
    URL even though the upstream connection is TLS.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.fluentbit_proxy == null || can(regex("^http://", var.fluentbit_proxy))
    error_message = "fluentbit_proxy must start with http:// . The Fluent Bit Datadog output proxy option does not accept https:// syntax."
  }
}

###############################################################################
# APM / DogStatsD -- same-task loopback
#
# All containers in an awsvpc task share one network namespace. No UDS and no
# shared volumes: that would need a task-level `volumes` entry and mountPoints
# the generic module would have to grow support for, for no benefit here.
###############################################################################

variable "enable_apm" {
  type    = bool
  default = true
}

variable "apm_receiver_port" {
  type    = number
  default = 8126
}

variable "enable_dogstatsd" {
  type    = bool
  default = true
}

variable "dogstatsd_port" {
  type    = number
  default = 8125
}

variable "dogstatsd_tag_cardinality" {
  type    = string
  default = "orchestrator"

  validation {
    condition     = contains(["low", "orchestrator", "high"], var.dogstatsd_tag_cardinality)
    error_message = "Must be low, orchestrator, or high."
  }
}

variable "enable_runtime_metrics" {
  type    = bool
  default = true
}

variable "enable_logs_injection" {
  description = "DD_LOGS_INJECTION. Requires the app's language tracer to do anything."
  type        = bool
  default     = true
}

variable "enable_profiling" {
  description = "DD_PROFILING_ENABLED. Billed separately by Datadog."
  type        = bool
  default     = false
}

###############################################################################
# Container sizing
#
# NOTE: your generic module has container_cpu / container_memory COMMENTED OUT
# (variables.tf:78-79, main.tf:49-50). Until the patch uncomments them these
# values are emitted but ignored, and the containers share the task-level
# allocation. That is functional -- just not reserved.
#
# These are CONTAINER reservations. Nothing is ever added to the task-level
# cpu/memory: Fargate task sizes are an allowlist and 512 + 192 = 704 is not
# one of them. Reservations must FIT INSIDE the declared task size.
###############################################################################

# null (default) = the key is OMITTED entirely, so the generic ECS module
# needs NO change for cpu/memory. Its container_cpu / container_memory are
# currently commented out (variables.tf:78-79, main.tf:49-50) and every
# existing container in your tfvars leaves them commented too, so the whole
# estate already runs with no container-level reservations. The sidecars
# match that. Set a number only if you also uncomment them in the module.
variable "agent_cpu" {
  type    = number
  default = null
}

variable "agent_memory" {
  type    = number
  default = null
}

variable "fluentbit_cpu" {
  type    = number
  default = null
}

variable "fluentbit_memory" {
  type    = number
  default = null
}

variable "emit_docker_labels" {
  description = <<-EOT
    false (default) = do not emit com.datadoghq.tags.* labels, so the generic
    module needs no docker_labels support.

    Unified Service Tagging still works: DD_ENV / DD_SERVICE / DD_VERSION are
    set on both the Agent and the app container, which is what the Agent
    actually reads on Fargate. The labels are a second, redundant path.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Agent behaviour
###############################################################################

variable "agent_essential" {
  description = "false: an Agent crash degrades observability but does not kill the workload."
  type        = bool
  default     = false
}

variable "app_wait_for_agent" {
  description = <<-EOT
    false (default). true adds dependsOn[datadog-agent] = HEALTHY, avoiding
    lost startup spans at the cost of coupling app startup to Agent health --
    reintroducing exactly what agent_essential = false avoids.
  EOT
  type        = bool
  default     = false
}

variable "agent_health_check_command" {
  type    = list(string)
  default = ["CMD-SHELL", "agent health"]
}

variable "agent_health_check" {
  type = object({
    interval     = optional(number, 15)
    timeout      = optional(number, 5)
    retries      = optional(number, 3)
    start_period = optional(number, 60)
  })
  default = {}
}

###############################################################################
# Escape hatches
###############################################################################

variable "extra_agent_environment" {
  description = "map(string), merged last so it overrides module-set Agent vars."
  type        = map(string)
  default     = {}
}

variable "extra_app_environment" {
  description = "map(string), merged last. e.g. tracer tuning."
  type        = map(string)
  default     = {}
}
