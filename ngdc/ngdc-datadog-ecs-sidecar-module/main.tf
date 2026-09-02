###############################################################################
# Resources. Everything here exists ONLY because the sidecars need it, so it
# belongs to the module rather than to every consumer.
###############################################################################

# -----------------------------------------------------------------------------
# Log group for the sidecars' own stdout. Not app logs.
#
# Created by default. Set var.sidecar_log_group to reuse an existing group,
# e.g. where a central platform team owns log-group creation and retention.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sidecars" {
  count = var.sidecar_log_group == null ? 1 : 0

  name              = "/ecs/${var.dd_env}/${var.dd_service}/datadog-sidecars"
  retention_in_days = var.sidecar_log_retention_days
  kms_key_id        = var.sidecar_log_kms_key_arn

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Inline policy granting the EXECUTION role read access to the Datadog secret.
#
# WHY THIS IS SAFE FOR THE MODULE TO OWN:
# The rule is "do not create the ROLE", not "do not create IAM". Inline
# policies are namespaced per role, so there is no EntityAlreadyExists class
# of collision and no ambiguity about who owns the role -- the caller does.
# The module only attaches its own requirement to a role it is handed.
#
# Set var.execution_role_name to null to opt out and attach
# execution_role_policy_json yourself.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "execution_secret" {
  count = var.execution_role_name == null ? 0 : 1

  # Service-scoped name so two instances of this module attaching to the same
  # shared execution role do not overwrite each other.
  name   = "datadog-secret-read-${var.dd_service}"
  role   = var.execution_role_name
  policy = data.aws_iam_policy_document.execution_role_secrets.json
}
