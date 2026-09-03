variable "dd_task_definition_key" {
  type    = string
  default = "FATW-Dev-Backend-TD"
}

variable "dd_container_definition_key" {
  type    = string
  default = "FATW-Dev-Backend-CD"
}

variable "dd_api_key_secret_name" {
  type = string
}

variable "dd_api_key_secret_json_key" {
  type    = string
  default = null
}

variable "dd_api_key_kms_key_arn" {
  type    = string
  default = null
}

variable "dd_site" {
  type    = string
  default = "ddog-gov.com"
}

variable "dd_env" {
  type    = string
  default = "dev"
}

variable "dd_service" {
  type    = string
  default = "backend-service"
}

variable "dd_version" {
  type    = string
  default = "unknown"
}

variable "dd_log_source" {
  type    = string
  default = "php"
}

variable "dd_enable_logs" {
  type    = bool
  default = false
}

variable "dd_agent_image" {
  type = string
}

variable "dd_fluentbit_image" {
  type    = string
  default = null
}

variable "dd_agent_proxy_https" {
  type    = string
  default = null
}

variable "dd_agent_proxy_http" {
  type    = string
  default = null
}

variable "dd_agent_proxy_no_proxy" {
  type    = list(string)
  default = []
}

variable "dd_fluentbit_proxy" {
  type    = string
  default = null
}

variable "ecs_execution_role_name" {
  type    = string
  default = "NGDC-FATW-ECS-Execution-Role"
}

