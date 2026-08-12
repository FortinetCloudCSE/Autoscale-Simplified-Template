
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

  # Fortinet-Role tags are managed out-of-band via standalone aws_ec2_tag
  # resources (see the "Fortinet-Role Tags for resource discovery" blocks in
  # vpc_inspection.tf / vpc_management.tf). Without this, any update to the
  # tagged resource itself (e.g. from a provider schema change adding a new
  # computed attribute) causes the AWS provider to reconcile that resource's
  # live tag set against what it computes from its own `tags` argument alone
  # and DELETE any tag it doesn't recognize - including Fortinet-Role, which
  # breaks autoscale_template's resource discovery. ignore_tags tells the
  # provider to leave this key alone entirely.
  #
  # This also protects default_tags itself: without ignore_tags, restoring
  # default_tags here would reintroduce the exact conflict that got it
  # removed in the first place (PR #26) -- the provider would try to
  # reconcile Fortinet-Role against what default_tags + each resource's own
  # tags computes, seeing it as drift, and delete it.
  ignore_tags {
    keys = ["Fortinet-Role"]
  }
}
