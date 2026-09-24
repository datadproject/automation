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
}
