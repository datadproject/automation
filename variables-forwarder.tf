###############################################################################
# DATADOG LAMBDA FORWARDER VARIABLES
###############################################################################

variable "dd_log_group_name" {
  description = "CloudWatch Logs log group that contains the ECS application logs."
  type        = string
}

variable "dd_forwarder_subnet_ids" {
  description = "Private subnet IDs for the Datadog Forwarder Lambda."
  type        = list(string)
}

variable "dd_forwarder_security_group_ids" {
  description = "Security group IDs for the Datadog Forwarder Lambda."
  type        = list(string)
}

variable "dd_forwarder_no_proxy" {
  description = "Addresses that the Datadog Forwarder Lambda should bypass the proxy for."
  type        = list(string)

  default = [
    "localhost",
    "127.0.0.1",
    "169.254.169.254",
    "169.254.170.2"
  ]
}
