
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
  region     = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}
