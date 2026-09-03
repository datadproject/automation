###############################################################################
# ngdc-datadog-ecs-sidecar-module/data.tf
#
# Lookups only. No resources, no locals.
###############################################################################

data "aws_partition" "current" {}

# METADATA ONLY.
#
# aws_secretsmanager_secret returns the ARN and configuration. It does NOT
# return the secret value -- that would be aws_secretsmanager_secret_version,
# which writes plaintext into state and is deliberately not used.
#
# Resolving by NAME keeps account- and partition-specific ARNs out of tfvars.
data "aws_secretsmanager_secret" "dd_api_key" {
  name = var.dd_api_key_secret_name
}

# Emitted as an output. The CALLER attaches it to the ECS execution role.
#
# The module does not attach it: your generic ECS module takes
# task_execution_role as an ARN input, so the role is owned outside both
# modules. Emitting JSON keeps that ownership unambiguous and avoids this
# module needing a role name it would have to derive.
data "aws_iam_policy_document" "execution_role_secrets" {
  statement {
    sid       = "ReadDatadogApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.dd_api_key.arn]
  }

  # kms:Decrypt ONLY when the secret uses a customer-managed key, and scoped
  # to that key rather than "*". AWS-managed keys need no explicit grant.
  dynamic "statement" {
    for_each = try(data.aws_secretsmanager_secret.dd_api_key.kms_key_id, "") != "" ? [1] : []
    content {
      sid       = "DecryptDatadogApiKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [data.aws_secretsmanager_secret.dd_api_key.kms_key_id]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}
