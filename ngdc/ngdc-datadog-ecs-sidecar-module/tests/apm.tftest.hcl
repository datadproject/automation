mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws-us-gov" }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn        = "arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789012:secret:datadog-abcdef"
      kms_key_id = ""
    }
  }
}

variables {
  aws_region             = "us-gov-west-1"
  dd_site                = "ddog-gov.com"
  dd_env                 = "dev"
  dd_service             = "backend"
  dd_version             = "test"
  dd_api_key_secret_name = "datadog"
  agent_image            = "123456789012.dkr.ecr.us-gov-west-1.amazonaws.com/datadog-agent:7.70.0"
  agent_proxy_https      = "http://10.111.225.254:8080"
}

run "apm_preserves_awslogs_by_default" {
  command = plan
  assert {
    condition     = output.container_names == ["datadog-agent"] && output.app_log_configuration == null
    error_message = "The default must keep awslogs and emit only the Agent sidecar."
  }
  assert {
    condition     = output.app_environment["DD_TRACE_ENABLED"] == "true" && output.app_environment["DD_AGENT_HOST"] == "127.0.0.1" && output.sidecar_container_definitions["datadog-agent"].environment["DD_APM_ENABLED"] == "true"
    error_message = "APM must stay enabled for the application and Agent."
  }
  assert {
    condition     = alltrue([for dependency in output.app_depends_on : dependency.containerName != "log_router"])
    error_message = "There must be no log_router dependency."
  }
}
