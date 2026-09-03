terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# There is intentionally NO `provider "aws" {}` block.
#
# A configured provider inside a reusable module blocks count/for_each on the
# module call -- and the consumer calls this module with for_each over the
# Datadog-enabled services. It also prevents the caller passing an aliased
# provider and pins region/assume-role behaviour inside the module.
#
# Reusable modules declare requirements; the ROOT module configures providers.
#
# Worth auditing ngdc-ecs-cluster-module/provider.tf for the same issue.
