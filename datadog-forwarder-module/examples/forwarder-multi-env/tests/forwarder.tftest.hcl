# Exercise the real official module; only external APIs are mocked.
mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-gov-west-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws-us-gov", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789012:secret:datadog-abcdef" }
  }
}

override_data {
  target = module.datadog_forwarder.data.http.forwarder_versions
  values = { response_body = "{\"latest\":{\"layer_version\":\"97\",\"forwarder_version\":\"5.0.0\"},\"mappings\":{}}" }
}

variables {
  dd_api_key_secret_name = "datadog"
  vpc_id                 = "vpc-12345678"
  private_subnet_ids     = ["subnet-12345678", "subnet-87654321"]
  ecs_log_groups = {
    dev_fe = "/ecs/dev-fe"
    dev_be = "/ecs/dev-be"
    qa     = "/ecs/qa"
    uat    = "/ecs/uat"
    prod   = "/ecs/prod"
  }
}

run "shared_forwarder" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_log_subscription_filter.datadog) == 5 && alltrue([for filter in aws_cloudwatch_log_subscription_filter.datadog : filter.filter_pattern == ""])
    error_message = "All FE/BE and environment groups must forward every event."
  }
  assert {
    condition     = length(aws_security_group.forwarder.ingress) == 0 && length(aws_security_group.forwarder.egress) == 1 && alltrue([for rule in aws_security_group.forwarder.egress : rule.from_port == 8080 && rule.to_port == 8080 && rule.protocol == "tcp" && rule.cidr_blocks == tolist(["10.111.225.254/32"])])
    error_message = "The Forwarder must permit only TCP 8080 to the proxy, with no ingress."
  }
}

run "reject_recursive_subscription" {
  command = plan
  variables {
    ecs_log_groups = { recursive = "/aws/lambda/fatw-datadog-forwarder" }
  }
  expect_failures = [var.ecs_log_groups]
}

run "reject_duplicate_subscription" {
  command = plan
  variables {
    ecs_log_groups = { fe = "/ecs/shared", be = "/ecs/shared" }
  }
  expect_failures = [var.ecs_log_groups]
}

run "reject_missing_private_subnets" {
  command = plan
  variables {
    private_subnet_ids = []
  }
  expect_failures = [var.private_subnet_ids]
}
