terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.78.0, < 7.0.0"
    }
  }
}

# Deliberately no provider "aws" block here. The caller supplies the provider.

