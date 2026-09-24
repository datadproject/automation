variable "function_name" {
  description = "Datadog Forwarder Lambda function name. Use one Forwarder per account/region unless isolation is required."
  type        = string
  default     = "DatadogForwarder"
}

variable "dd_site" {
  description = "Datadog site. GovCloud default is ddog-gov.com."
  type        = string
  default     = "ddog-gov.com"
}

variable "dd_api_key_secret_arn" {
  description = "ARN of an existing AWS Secrets Manager secret containing the Datadog API key as plaintext."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the dedicated Forwarder security group."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the Forwarder Lambda. These subnets must be able to reach the proxy and required AWS services/endpoints."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "Provide at least one private subnet."
  }
}

variable "security_group_name" {
  description = "Name of the dedicated Forwarder security group."
  type        = string
  default     = "datadog-forwarder-sg"
}

variable "proxy_url" {
  description = "Corporate HTTP/HTTPS proxy URL, for example http://10.111.225.254:8080."
  type        = string
  default     = "http://10.111.225.254:8080"
}

variable "proxy_cidr" {
  description = "Proxy CIDR for the dedicated security group's only egress rule."
  type        = string
  default     = "10.111.225.254/32"
}

variable "proxy_port" {
  description = "Proxy TCP port used for SG egress."
  type        = number
  default     = 8080
}

variable "no_proxy" {
  description = "Hosts/IPs excluded from proxying."
  type        = list(string)
  default = [
    "localhost",
    "127.0.0.1",
    "169.254.169.254",
    "169.254.170.2"
  ]
}

variable "dd_skip_ssl_validation" {
  description = "The official Forwarder module recommends true when using dd_http_proxy_url. Set according to your security policy/proxy TLS behavior."
  type        = bool
  default     = true
}

variable "log_retention_in_days" {
  description = "Retention for the Forwarder's own CloudWatch log group."
  type        = number
  default     = 90
}

variable "log_groups" {
  description = <<-EOT
    CloudWatch log groups to forward to Datadog. An empty filter_pattern forwards all events from that log group.
    Example:
      {
        dev_ecs = {
          name              = "/ecs/DEV-ECS-CLUSTER"
          arn               = "arn:aws-us-gov:logs:us-gov-west-1:123456789012:log-group:/ecs/DEV-ECS-CLUSTER"
          subscription_name = "dev-ecs-to-datadog"
        }
      }
  EOT
  type = map(object({
    name              = string
    arn               = string
    subscription_name = optional(string)
  }))
  validation {
    condition     = length(distinct([for group in values(var.log_groups) : group.name])) == length(var.log_groups)
    error_message = "Each log group must appear only once."
  }
}

variable "tags" {
  description = "Tags applied to Forwarder resources."
  type        = map(string)
  default     = {}
}
