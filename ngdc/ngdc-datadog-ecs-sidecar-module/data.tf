###############################################################################
# Lookups only. No resources, no locals.
###############################################################################

data "aws_partition" "current" {}

# Resolved by NAME so consumers never hardcode an ARN (which differs per
# account and per partition) and so re-creating the secret needs no tfvars
# change.
data "aws_secretsmanager_secret" "dd_api_key" {
  name = var.dd_api_key_secret_name
}

# Emitted as an output for consumers who prefer to attach the policy
# themselves. When var.execution_role_name is set, main.tf attaches it.
data "aws_iam_policy_document" "execution_role_secrets" {
  statement {
    sid       = "ReadDatadogApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.dd_api_key.arn]
  }

  # Only when the secret uses a customer-managed KMS key.
  dynamic "statement" {
    for_each = try(data.aws_secretsmanager_secret.dd_api_key.kms_key_id, "") != "" ? [1] : []
    content {
      sid       = "DecryptDatadogApiKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}
