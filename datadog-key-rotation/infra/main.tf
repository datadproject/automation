# ==============================================================================
# Datadog API Key Rotation — Hub Account Infrastructure
# ==============================================================================
# Manages:
#   - KMS key  (encrypts all Datadog secrets in Secrets Manager)
#   - Secrets Manager secret CONTAINERS (one per environment — no values stored)
#   - IAM role (DatadogRotationRole — assumed by GitLab rotation pipeline)
#
# IMPORTANT: No aws_secretsmanager_secret_version resource is used here.
# Secret values never enter Terraform state. Values are seeded once by the
# seed-secrets GitLab CI job, then managed entirely by the rotation pipeline.
# ==============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend config is passed via -backend-config flags in the GitLab CI job.
  # Nothing is hardcoded here — bucket name, region, and key come from
  # GitLab CI protected variables (TF_STATE_BUCKET, TF_STATE_REGION, etc.)
  backend "s3" {}
}

provider "aws" {
  region = var.hub_region
  # Credentials injected at runtime by the GitLab runner's IAM role.
  # Never hardcode access keys in provider blocks.
}

locals {
  environments = ["lower", "ist", "uat", "ept", "stage", "prod"]

  common_tags = {
    ManagedBy   = "gitlab-ci-terraform"
    Repository  = "datadog-key-rotation"
    Compliance  = "fedramp-high"
    Environment = "hub"
  }
}

# ==============================================================================
# KMS Key — encrypts all Datadog API keys at rest in Secrets Manager
# ==============================================================================
resource "aws_kms_key" "datadog_rotation" {
  description             = "Encrypts Datadog API keys in Secrets Manager for all environments"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  is_enabled              = true

  # Policy grants hub root full access and the rotation role decrypt access.
  # The IAM role is created below; using ARN directly avoids circular dependency
  # by referencing account ID + role name (role must match the resource below).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws-us-gov:iam::${var.hub_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowRotationRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws-us-gov:iam::${var.hub_account_id}:role/DatadogRotationRole"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "datadog-rotation-key" })
}

resource "aws_kms_alias" "datadog_rotation" {
  name          = "alias/datadog-rotation"
  target_key_id = aws_kms_key.datadog_rotation.key_id
}

# ==============================================================================
# Secrets Manager — one secret container per environment
#
# KEY DESIGN DECISION:
#   No aws_secretsmanager_secret_version resource is created.
#   Reason: Terraform would store the secret value in state (even encrypted
#   state is a liability in FedRAMP High scope). Instead:
#     - Terraform creates the container (name, KMS key, retention)
#     - The seed-secrets GitLab CI job populates the initial value
#     - The rotation pipeline manages all subsequent updates
#
# This means the first `terraform apply` creates empty containers.
# The seed-secrets job must be run once after apply.
# ==============================================================================
resource "aws_secretsmanager_secret" "datadog" {
  for_each = toset(local.environments)

  name                    = "datadog/${each.key}/api-key"
  description             = "Datadog API key for ${each.key} environment. Managed by gitlab-ci rotation pipeline — do not edit manually."
  kms_key_id              = aws_kms_key.datadog_rotation.arn
  recovery_window_in_days = 30

  tags = merge(local.common_tags, {
    Name        = "datadog-${each.key}-api-key"
    SecretEnv   = each.key
    Purpose     = "datadog-api-key-rotation"
  })
}

# ==============================================================================
# IAM Role — DatadogRotationRole
# Assumed by the GitLab runner during the rotation pipeline.
# Trusts the runner account with an external ID to prevent confused-deputy attacks.
# ==============================================================================
resource "aws_iam_role" "datadog_rotation" {
  name        = "DatadogRotationRole"
  description = "Allows GitLab rotation pipeline to read/write Datadog API keys in Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGitLabRunnerAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws-us-gov:iam::${var.gitlab_runner_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            # External ID prevents confused-deputy attack.
            # Must match the value in assume_hub_role() in rotate_key.sh.
            "sts:ExternalId" = "datadog-rotation-pipeline"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "DatadogRotationRole" })
}

resource "aws_iam_role_policy" "datadog_rotation" {
  name = "DatadogRotationPolicy"
  role = aws_iam_role.datadog_rotation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerReadWrite"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
          "secretsmanager:UpdateSecret"
        ]
        # Scoped to only the Datadog secrets — no wildcard
        Resource = [
          for env in local.environments :
          aws_secretsmanager_secret.datadog[env].arn
        ]
      },
      {
        Sid    = "KMSDecryptForSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.datadog_rotation.arn
      }
    ]
  })
}
