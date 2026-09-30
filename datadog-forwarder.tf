###############################################################################
# DATADOG LAMBDA LOG FORWARDER
#
# ECS -> awslogs -> CloudWatch Logs -> Lambda -> Datadog
###############################################################################

data "aws_secretsmanager_secret" "datadog_forwarder_api_key" {
  provider = aws.fatw
  name     = var.dd_api_key_secret_name
}

module "datadog_forwarder" {
  source  = "DataDog/log-lambda-forwarder-datadog/aws"
  version = "2.0.5"

  providers = {
    aws = aws.fatw
  }

  function_name = "fatw-datadog-forwarder"
  region        = var.region

  dd_api_key_secret_arn = data.aws_secretsmanager_secret.datadog_forwarder_api_key.arn
  dd_site               = "ddog-gov.com"

  dd_forward_log      = true
  dd_trace_enabled    = false
  dd_enhanced_metrics = false

  dd_tags = "env:${var.environment_tag},service:backend-service"

  dd_use_vpc = true

  vpc_subnet_ids         = var.dd_forwarder_subnet_ids
  vpc_security_group_ids = var.dd_forwarder_security_group_ids

  dd_http_proxy_url = var.dd_proxy_https
  dd_no_proxy       = join(",", var.dd_forwarder_no_proxy)

  dd_fetch_lambda_tags    = false
  dd_fetch_s3_tags        = false
  dd_fetch_log_group_tags = false

  dd_store_failed_events = false

  memory_size           = 1024
  timeout               = 120
  log_retention_in_days = 14

  tags = {
    Environment = var.environment_tag
    Application = "FATW"
    ManagedBy   = "Terraform"
  }
}

###############################################################################
# CLOUDWATCH LOG GROUP -> DATADOG FORWARDER LAMBDA
###############################################################################

resource "aws_cloudwatch_log_subscription_filter" "datadog_forwarder" {
  provider = aws.fatw

  name            = "fatw-datadog-forwarder"
  log_group_name  = var.dd_log_group_name
  filter_pattern  = ""
  destination_arn = module.datadog_forwarder.datadog_forwarder_arn

  depends_on = [
    module.datadog_forwarder
  ]
}
