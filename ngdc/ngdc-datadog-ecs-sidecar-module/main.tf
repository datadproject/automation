###############################################################################
# ngdc-datadog-ecs-sidecar-module/main.tf
#
# This module intentionally creates NO AWS resources.
#
#   NO aws_ecs_task_definition   -- ngdc-ecs-cluster-module owns it
#   NO aws_ecs_service
#   NO aws_ecs_cluster
#   NO aws_iam_role / aws_iam_role_policy   -- caller attaches the emitted JSON
#   NO aws_cloudwatch_log_group             -- sidecars inherit the task-level
#                                              awslogs config from the module
#
# Everything is computed in locals.tf and exposed in outputs.tf as fragments.
#
# main.tf holds only cross-variable validation that a single variable's
# validation block cannot express. terraform_data: no provider, no API calls,
# no cost.
###############################################################################

# Fluent Bit image is required when log collection is on.
resource "terraform_data" "validate_fluentbit_image" {
  count = var.enable_logs ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.fluentbit_image != null
      error_message = "enable_logs = true requires fluentbit_image. Set it to your pinned private-mirror image, or set enable_logs = false to keep the module's awslogs config."
    }
  }
}

# A proxied estate almost always needs BOTH proxies. The Agent and Fluent Bit
# are separate containers: setting only the Agent proxy produces working
# metrics and traces with silently missing logs, which is very hard to
# diagnose because nothing errors anywhere.
resource "terraform_data" "validate_proxy_pairing" {
  count = (var.enable_logs && var.agent_proxy_https != null && var.fluentbit_proxy == null) ? 1 : 0

  lifecycle {
    precondition {
      condition     = false
      error_message = "agent_proxy_https is set but fluentbit_proxy is not. Fluent Bit does not read DD_PROXY_HTTPS, so logs would silently fail to reach Datadog. Set fluentbit_proxy (http:// form)."
    }
  }
}

# GovCloud uses a separate Datadog instance with separate API keys.
resource "terraform_data" "validate_govcloud_site" {
  count = data.aws_partition.current.partition == "aws-us-gov" ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.dd_site == "ddog-gov.com"
      error_message = "This is the aws-us-gov partition but dd_site is not ddog-gov.com. A commercial-site API key authenticates against nothing on the Datadog GovCloud instance."
    }
  }
}
