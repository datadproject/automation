###############################################################################
# ngdc-datadog-ecs-sidecar-module/main.tf
#
# This module creates NO AWS resources.
#
#   NO aws_ecs_task_definition   -- ngdc-ecs-cluster-module owns it
#   NO aws_ecs_service / aws_ecs_cluster
#   NO aws_iam_role / aws_iam_role_policy  -- caller attaches the emitted JSON
#   NO aws_cloudwatch_log_group
#
# Everything is computed in locals.tf and exposed in outputs.tf as fragments.
#
# main.tf holds only cross-variable validation that a single variable's
# validation block cannot express. terraform_data: no provider, no API calls,
# no cost.
#
# NOTE ON PRECONDITION CONDITIONS
# Terraform rejects a condition that is a constant expression:
#   "Invalid precondition expression ... condition must refer to at least one
#    object from elsewhere in the configuration."
# So each condition below is written as a real expression over the variables,
# and `count` is NOT used to select the failing case. This is a correction --
# an earlier revision used `count` plus `condition = false`, which does not
# plan.
###############################################################################

resource "terraform_data" "validations" {
  # Forces the conditions to depend on real values.
  input = {
    enable_logs       = var.enable_logs
    fluentbit_image   = var.fluentbit_image
    agent_proxy_https = var.agent_proxy_https
    fluentbit_proxy   = var.fluentbit_proxy
    dd_site           = var.dd_site
    partition         = data.aws_partition.current.partition
  }

  lifecycle {
    # Fluent Bit image is required when log collection is on.
    precondition {
      condition     = !var.enable_logs || var.fluentbit_image != null
      error_message = "enable_logs = true requires fluentbit_image. Set it to your pinned private-mirror image, or set enable_logs = false to keep the module's awslogs config."
    }

    # A proxied estate needs BOTH proxies. The Agent and Fluent Bit are
    # separate containers: setting only the Agent proxy gives working metrics
    # and traces with silently missing logs, which is hard to diagnose because
    # nothing errors.
    precondition {
      condition     = !(var.enable_logs && var.agent_proxy_https != null && var.fluentbit_proxy == null)
      error_message = "agent_proxy_https is set but fluentbit_proxy is not. Fluent Bit does not read DD_PROXY_HTTPS, so logs would silently fail to reach Datadog. Set fluentbit_proxy (http:// form)."
    }

    # GovCloud uses a separate Datadog instance with separate API keys.
    precondition {
      condition     = data.aws_partition.current.partition != "aws-us-gov" || var.dd_site == "ddog-gov.com"
      error_message = "This is the aws-us-gov partition but dd_site is not ddog-gov.com. A commercial-site API key authenticates against nothing on the Datadog GovCloud instance."
    }
  }
}
