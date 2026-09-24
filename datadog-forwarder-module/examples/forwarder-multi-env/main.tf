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
  source = "../../modules/datadog-forwarder"

  function_name         = var.forwarder_function_name
  dd_site               = "ddog-gov.com"
  dd_api_key_secret_arn = data.aws_secretsmanager_secret.datadog_api_key.arn

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  security_group_name = "${var.application}-datadog-forwarder-sg"

  proxy_url  = var.proxy_url
  proxy_cidr = var.proxy_cidr
  proxy_port = var.proxy_port

  log_groups = {
    for env, lg in data.aws_cloudwatch_log_group.ecs : env => {
      name              = lg.name
      arn               = lg.arn
      subscription_name = "${env}-ecs-to-datadog"
    }
  }

  tags = {
    Application = var.application
    Environment = "shared"
  }
}
