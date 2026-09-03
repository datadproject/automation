###############################################################################
# ngdc-datadog-ecs-sidecar-module/provider.tf
#
# THIS FILE MUST NOT CONTAIN A `provider "aws" {}` BLOCK.
#
# The consumer calls this module with for_each:
#
#   module "datadog" {
#     for_each = local.dd_services
#     ...
#   }
#
# A configured provider block inside the module makes it a "legacy module" and
# Terraform refuses:
#
#   Error: Module is incompatible with count, for_each, and depends_on
#   The module at module.datadog is a legacy module which contains its own
#   local provider configurations, and so calls to it may not use the count,
#   for_each, or depends_on arguments.
#
# If you see that error, a provider block has been added to this module --
# most likely copied from ngdc-ecs-cluster-module/provider.tf, which does have
# one. Delete it. The ROOT module (fatw-ecs/<env>/) configures the provider.
#
# required_providers only. Nothing else belongs here.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
