variable "aws_region" {
  description = "AWS region containing the ECS task and Secrets Manager secret."
  type        = string
}

variable "dd_api_key_secret_name" {
  description = "Name of the Secrets Manager secret containing the Datadog API key."
  type        = string
}

variable "dd_api_key_secret_json_key" {
  description = "JSON key within the secret; null when the secret is a plain string."
  type        = string
  default     = null
}

variable "dd_site" {
  description = "Datadog site, for example ddog-gov.com."
  type        = string
  default     = "ddog-gov.com"
}

variable "dd_env" {
  type = string
}

variable "dd_service" {
  type = string
}

variable "dd_version" {
  type    = string
  default = "unknown"
}

variable "log_source" {
  description = "Datadog log source, for example php, nodejs, or nginx."
  type        = string
  default     = "php"
}

variable "agent_image" {
  description = "Datadog Agent image URI accessible by the Fargate task."
  type        = string
}

variable "fluentbit_image" {
  description = "AWS for Fluent Bit image URI; required only when enable_logs is true."
  type        = string
  default     = null
}

variable "enable_apm" {
  type    = bool
  default = true
}

variable "enable_dogstatsd" {
  type    = bool
  default = false
}

variable "enable_logs" {
  type    = bool
  default = false
}

variable "enable_logs_injection" {
  type    = bool
  default = true
}

variable "enable_runtime_metrics" {
  type    = bool
  default = true
}

variable "enable_profiling" {
  type    = bool
  default = false
}

variable "apm_receiver_port" {
  type    = number
  default = 8126
}

variable "dogstatsd_port" {
  type    = number
  default = 8125
}

variable "dogstatsd_tag_cardinality" {
  type    = string
  default = "orchestrator"
}

variable "agent_essential" {
  description = "False prevents an Agent failure from stopping the application task."
  type        = bool
  default     = false
}

variable "log_router_essential" {
  type    = bool
  default = true
}

variable "app_wait_for_agent" {
  description = "Make the app wait for Agent HEALTHY. Keep false for initial rollout."
  type        = bool
  default     = false
}

variable "app_depends_on_log_router" {
  type    = bool
  default = true
}

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

variable "agent_proxy_https" {
  description = "Agent HTTPS proxy URL, or null when direct egress is available."
  type        = string
  default     = null
}

variable "agent_proxy_http" {
  type    = string
  default = null
}

variable "agent_proxy_no_proxy" {
  type    = list(string)
  default = []
}

variable "fluentbit_proxy" {
  description = "Fluent Bit Datadog output proxy, normally beginning with http://."
  type        = string
  default     = null

  validation {
    condition     = var.fluentbit_proxy == null || can(regex("^http://", var.fluentbit_proxy))
    error_message = "fluentbit_proxy must start with http://."
  }
}

variable "agent_health_check_command" {
  type    = list(string)
  default = ["CMD-SHELL", "agent health"]
}

variable "extra_agent_environment" {
  type    = map(string)
  default = {}
}

variable "extra_app_environment" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used by the secret, or null."
  type        = string
  default     = null
}
