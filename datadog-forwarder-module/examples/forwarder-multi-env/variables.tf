variable "aws_region" {
  type    = string
  default = "us-gov-west-1"
}

variable "application" {
  type    = string
  default = "fatw"
}

variable "forwarder_function_name" {
  type    = string
  default = "fatw-datadog-forwarder"
}

variable "dd_api_key_secret_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_ids) > 0
    error_message = "Provide private subnets with a route to the proxy."
  }
}

variable "proxy_url" {
  type    = string
  default = "http://10.111.225.254:8080"
}

variable "proxy_cidr" {
  type    = string
  default = "10.111.225.254/32"
}

variable "proxy_port" {
  type    = number
  default = 8080
}

variable "ecs_log_groups" {
  description = "Map of stable identifiers (for example dev_fe and dev_be) to unique existing log group names in this account/region."
  type        = map(string)
  validation {
    condition     = length(var.ecs_log_groups) > 0 && length(distinct(values(var.ecs_log_groups))) == length(var.ecs_log_groups)
    error_message = "Supply at least one group and list each log group only once."
  }
  validation {
    condition     = !contains(values(var.ecs_log_groups), "/aws/lambda/${var.forwarder_function_name}")
    error_message = "The Forwarder must not subscribe to its own log group."
  }
}

variable "dd_skip_ssl_validation" {
  description = "Retains the official proxy example behavior; false requires trusted proxy/intake certificates."
  type        = bool
  default     = true
}
