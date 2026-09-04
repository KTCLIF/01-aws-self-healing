terraform {
  required_version = ">= 1.14.0, < 2.0.0"

  backend "local" {
    path = "state/p01-self-healing.tfstate"
  }

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  profile = var.aws_profile
  region  = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {
  lifecycle {
    postcondition {
      condition     = self.account_id == var.expected_account_id
      error_message = "Authenticated AWS account does not match expected_account_id. Refusing this P1 plan/apply context."
    }
  }
}
