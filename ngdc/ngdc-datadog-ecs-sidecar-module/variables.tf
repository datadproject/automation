###############################################################################
# Required
###############################################################################

variable "aws_region" {
  description = "Region. Used for the sidecars' awslogs config and the KMS ViaService condition."
  type        = string
}

variable "dd_api_key_secret_name" {
  description = <<-EOT
    Name (not ARN) of the Secrets Manager secret holding the Datadog API key.
    Reuses the same secret as the EKS clusters, e.g. "platform/datadog/api-key".
    Store as a PLAIN STRING. If your org standard is JSON, set
    dd_api_key_secret_json_key as well.
  EOT
  type        = string
}

variable "dd_api_key_secret_json_key" {
  description = "If the secret is JSON, the key inside it. Leave null for plain string."
  type        = string
  default     = null
}

# Unified Service Tagging. These three are what correlate traces <-> logs
# <-> metrics in Datadog. Non-negotiable.
variable "dd_env" {
  description = "env tag, e.g. dev / prod. Wire to your existing environment var."
  type        = string
}

variable "dd_service" {
  description = "service tag, e.g. fatw-api."
  type        = string
}

variable "dd_version" {
  description = "version tag. Wire to the app image tag or CI_COMMIT_SHORT_SHA."
  type        = string
}

variable "sidecar_log_group" {
  description = "CloudWatch log group for the sidecars' OWN logs (not app logs)."
  type        = string
}

###############################################################################
# Optional
###############################################################################

variable "dd_site" {
  description = <<-EOT
    datadoghq.com | datadoghq.eu | us3.datadoghq.com | ddog-gov.com

    GOVCLOUD: use "ddog-gov.com". That is a physically separate Datadog
    instance with its own org and its own API keys -- a commercial-site key
    will authenticate against nothing here. If your EKS clusters report to
    datadoghq.com, this needs a DIFFERENT secret, not the same one.
  EOT
  type        = string
  default     = "datadoghq.com"
}

variable "dd_tags" {
  description = "Extra global tags applied to metrics, traces and logs."
  type        = map(string)
  default     = {}
}

variable "log_source" {
  description = "dd_source, drives Datadog's log parsing pipeline: java, nodejs, python, nginx..."
  type        = string
  default     = "ecs"
}

variable "agent_image" {
  description = <<-EOT
    Datadog agent image.

    GOVCLOUD: public.ecr.aws is NOT reachable from GovCloud regions and
    gcr.io is not either. You MUST mirror into a private ECR repo in your
    GovCloud account. The default below will fail to pull.
  EOT
  type        = string
  default     = "public.ecr.aws/datadog/agent:7.66.1"
}

variable "fluentbit_image" {
  description = "aws-for-fluent-bit image. Same GovCloud mirroring requirement as agent_image."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-for-fluent-bit:stable"
}

variable "agent_cpu" {
  type    = number
  default = 128
}

variable "agent_memory" {
  description = "Hard limit in MiB."
  type        = number
  default     = 512
}

variable "fluentbit_cpu" {
  type    = number
  default = 64
}

variable "fluentbit_memory" {
  type    = number
  default = 128
}

variable "enable_apm" {
  type    = bool
  default = true
}

variable "enable_dogstatsd" {
  type    = bool
  default = true
}

variable "enable_profiling" {
  description = "DD_PROFILING_ENABLED on the app container. Billed separately by Datadog."
  type        = bool
  default     = false
}

variable "enable_logs" {
  description = "false = skip the FireLens router entirely and keep your existing awslogs config."
  type        = bool
  default     = true
}

variable "agent_essential" {
  description = "false (default): an agent crash degrades observability but does not kill the task."
  type        = bool
  default     = false
}

variable "log_router_essential" {
  description = "true (default): a dead router means the app's log driver has nowhere to write."
  type        = bool
  default     = true
}

variable "app_container_name" {
  description = "Name of the app container, used to build the DD_CONTAINER_EXCLUDE list."
  type        = string
}

###############################################################################
# Egress proxy
#
# Your pipeline references HTTPS_PROXY=10.111.225.254:8080, so this estate is
# proxied. If the Fargate subnets have no direct route to the internet, the
# agent CANNOT reach Datadog intake without these. Symptom: the task starts
# clean, `agent health` passes, and no data ever appears in Datadog.
###############################################################################

variable "dd_proxy_https" {
  description = "e.g. http://10.111.225.254:8080. null when the subnets have NAT/direct egress."
  type        = string
  default     = null
}

variable "dd_proxy_no_proxy" {
  description = "Hosts bypassing the proxy. The ECS metadata endpoint MUST be here."
  type        = list(string)
  default     = ["169.254.169.254", "169.254.170.2"]
}
