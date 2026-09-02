###############################################################################
# Secrets Manager lookup
#
# We resolve by NAME so the consumer never hardcodes an ARN (which differs per
# account) and so rotation/re-creation of the secret does not require a tfvars
# change.
###############################################################################

data "aws_secretsmanager_secret" "dd_api_key" {
  name = var.dd_api_key_secret_name
}

###############################################################################
# IAM
#
# IMPORTANT DESIGN DECISION:
# This module creates NO IAM roles or policies. It emits a policy DOCUMENT that
# the root module attaches to whatever execution role it already owns.
#
# Creating an aws_iam_role here is how you get EntityAlreadyExists collisions
# when two modules in the same account both want "<service>-execution", and how
# you get perpetual diffs when the cluster module and this module both attach
# policies to the same role. Emitting a document and letting exactly one module
# own the role keeps that conflict impossible.
###############################################################################

data "aws_iam_policy_document" "execution_role_secrets" {
  statement {
    sid       = "ReadDatadogApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.dd_api_key.arn]
  }

  # Only emitted when the secret uses a customer-managed KMS key.
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
