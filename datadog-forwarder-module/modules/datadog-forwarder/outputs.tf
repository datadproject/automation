output "forwarder_arn" {
  description = "Datadog Forwarder Lambda ARN."
  value       = module.forwarder.datadog_forwarder_arn
}

output "forwarder_function_name" {
  description = "Datadog Forwarder Lambda function name."
  value       = module.forwarder.datadog_forwarder_function_name
}

output "forwarder_role_arn" {
  description = "Datadog Forwarder Lambda IAM role ARN."
  value       = module.forwarder.datadog_forwarder_role_arn
}

output "security_group_ids" {
  description = "Security groups attached to the Forwarder Lambda."
  value       = local.forwarder_security_group_ids
}

output "subscription_filter_names" {
  description = "CloudWatch subscription filter names created by this module."
  value       = { for k, v in aws_cloudwatch_log_subscription_filter.datadog : k => v.name }
}
