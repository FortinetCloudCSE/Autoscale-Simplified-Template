#
# Management VPC / ENI resources
#
# The management VPC is SHARED infrastructure — Green FortiGate instances connect
# to the same management VPC as Blue (same FortiManager, FortiAnalyzer, Jump Box).
# Resources here are discovered via Fortinet-Role tags using the same cp/env as Blue.
#
# Note: Green FortiGates have different serial numbers. After config restore,
# FortiManager must re-authorize the Green serial numbers before cutover.
#

locals {
  management_vpc_tag      = "${var.cp}-${var.env}-management-vpc"
  management_public_az1   = "${var.cp}-${var.env}-management-public-az1"
  management_public_az2   = "${var.cp}-${var.env}-management-public-az2"
}

# Management VPC (shared with Blue — discovered by Fortinet-Role tag)
data "aws_vpc" "management_vpc" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_vpc_tag]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Management VPC public subnets for Green FortiGate management ENIs
data "aws_subnet" "management_public_az1" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_public_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "management_public_az2" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_public_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security group for management ENIs
# Placed in management VPC (dedicated_management_vpc mode) or
# in the Green inspection VPC (dedicated_management_eni mode).
#
# Ingress is limited to vpc_cidr_sg, the same list Blue's management interfaces use
# (autoscale_template: aws_security_group.management-vpc-sg). The management interface
# normally has a public address, so this must never be open to 0.0.0.0/0 by default.
resource "aws_security_group" "management_sg" {
  count       = var.enable_dedicated_management_vpc || var.enable_dedicated_management_eni ? 1 : 0
  description = "Security group for Green FortiGate management ENI"
  vpc_id      = var.enable_dedicated_management_vpc ? data.aws_vpc.management_vpc[0].id : aws_vpc.green_inspection.id

  ingress {
    description = "Allow management access from allowed CIDRs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.vpc_cidr_sg
  }
  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.cp}-${var.env}-green-management-sg"
  }

  lifecycle {
    precondition {
      condition     = length(var.vpc_cidr_sg) > 0
      error_message = "vpc_cidr_sg is empty, so nothing could reach the Green FortiGates' management interfaces. Set it to the same list as Blue's autoscale_template: the addresses you manage from, and the management VPC's CIDR if a jump box, FortiManager or FortiAnalyzer there must reach them."
    }
  }
}
