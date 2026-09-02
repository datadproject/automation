terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# NOTE (deliberate, please read before "fixing" this file):
# There is intentionally NO `provider "aws" {}` block here.
#
# Your ngdc-ecs-cluster-module has a provider.tf. If it declares a configured
# provider block rather than just required_providers, that module cannot be
# used with count/for_each, cannot be given an aliased provider by the caller,
# and pins region/assume-role config inside the module. Terraform has warned
# on this since 0.13 and it will eventually hard-fail.
#
# Reusable modules declare requirements; the ROOT module configures providers.
