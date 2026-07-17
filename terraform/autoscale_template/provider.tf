
terraform {
  required_version = ">= 1.14.7, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

locals {
  common_tags = merge(
    {
      Environment = var.env
      Prefix      = var.cp
    },
    var.additional_tags
  )
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}
