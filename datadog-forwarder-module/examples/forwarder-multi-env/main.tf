terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.21"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_secretsmanager_secret" "datadog_api_key" {
  name = var.dd_api_key_secret_name
}

data "aws_cloudwatch_log_group" "ecs" {
  for_each = var.ecs_log_groups
  name     = each.value
}

module "datadog_forwarder" {
  source  = "DataDog/log-lambda-forwarder-datadog/aws"
  version = "2.0.4"

  function_name         = var.forwarder_function_name
  dd_site               = "ddog-gov.com"
  dd_api_key_secret_arn = data.aws_secretsmanager_secret.datadog_api_key.arn

  create_dd_api_key_secret = false
  region                   = var.aws_region
  dd_forward_log           = true
  dd_use_vpc               = true
  vpc_subnet_ids           = var.private_subnet_ids
  vpc_security_group_ids   = [aws_security_group.forwarder.id]
  dd_http_proxy_url        = var.proxy_url
  dd_no_proxy              = "localhost,127.0.0.1,169.254.169.254,169.254.170.2"
  dd_skip_ssl_validation   = var.dd_skip_ssl_validation
  log_retention_in_days    = 90

  tags = {
    Application = var.application
    Environment = "shared"
  }
}

resource "aws_security_group" "forwarder" {
  name        = "${var.application}-datadog-forwarder-sg"
  description = "Datadog Forwarder proxy-only egress"
  vpc_id      = var.vpc_id
  ingress     = []
  egress = [{
    description      = "Corporate proxy"
    from_port        = var.proxy_port
    to_port          = var.proxy_port
    protocol         = "tcp"
    cidr_blocks      = [var.proxy_cidr]
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
    self             = false
  }]
}

resource "aws_cloudwatch_log_subscription_filter" "datadog" {
  for_each = var.ecs_log_groups

  name            = "${each.key}-ecs-to-datadog"
  log_group_name  = data.aws_cloudwatch_log_group.ecs[each.key].name
  destination_arn = module.datadog_forwarder.datadog_forwarder_arn
  filter_pattern  = ""

  # The official module creates account/region-scoped CloudWatch invocation
  # permission. Wait for it as well as the function before subscribing.
  depends_on = [module.datadog_forwarder]
}
