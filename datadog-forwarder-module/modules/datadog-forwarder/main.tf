locals {
  forwarder_tags = merge(var.tags, {
    ManagedBy = "Terraform"
  })
}

resource "aws_security_group" "forwarder" {
  name        = var.security_group_name
  description = "Datadog Forwarder Lambda security group"
  vpc_id      = var.vpc_id

  ingress = []
  egress = [{
    description      = "Datadog Forwarder to corporate proxy"
    from_port        = var.proxy_port
    to_port          = var.proxy_port
    protocol         = "tcp"
    cidr_blocks      = [var.proxy_cidr]
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
    self             = false
  }]

  tags = merge(local.forwarder_tags, {
    Name = var.security_group_name
  })
}

locals {
  forwarder_security_group_ids = [aws_security_group.forwarder.id]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

module "forwarder" {
  source  = "DataDog/log-lambda-forwarder-datadog/aws"
  version = "2.0.4"

  region = data.aws_region.current.region

  function_name            = var.function_name
  dd_site                  = var.dd_site
  dd_api_key_secret_arn    = var.dd_api_key_secret_arn
  create_dd_api_key_secret = false
  dd_forward_log           = true
  dd_use_vpc               = true
  vpc_subnet_ids           = var.subnet_ids
  vpc_security_group_ids   = local.forwarder_security_group_ids
  dd_http_proxy_url        = var.proxy_url
  dd_no_proxy              = join(",", var.no_proxy)
  dd_skip_ssl_validation   = var.dd_skip_ssl_validation
  log_retention_in_days    = var.log_retention_in_days
  tags                     = local.forwarder_tags
}

resource "aws_lambda_permission" "cloudwatch_logs" {
  for_each = var.log_groups

  statement_id   = "AllowCWLogs-${substr(md5(each.key), 0, 12)}"
  action         = "lambda:InvokeFunction"
  function_name  = module.forwarder.datadog_forwarder_function_name
  principal      = "logs.${data.aws_region.current.region}.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "${trimsuffix(each.value.arn, ":*")}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "datadog" {
  for_each = var.log_groups

  name            = coalesce(try(each.value.subscription_name, null), "${each.key}-to-datadog")
  log_group_name  = each.value.name
  destination_arn = module.forwarder.datadog_forwarder_arn
  filter_pattern  = ""

  lifecycle {
    precondition {
      condition     = trimsuffix(each.value.arn, ":*") == "arn:aws-us-gov:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${each.value.name}"
      error_message = "Log groups must match their ARNs and belong to the Forwarder's GovCloud account and region."
    }
    precondition {
      condition     = each.value.name != "/aws/lambda/${var.function_name}"
      error_message = "Do not subscribe the Forwarder's own log group (recursive forwarding)."
    }
  }

  depends_on = [aws_lambda_permission.cloudwatch_logs]
}
