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
resource "aws_security_group" "management_sg" {
  count       = var.enable_dedicated_management_vpc || var.enable_dedicated_management_eni ? 1 : 0
  description = "Security group for Green FortiGate management ENI"
  vpc_id      = var.enable_dedicated_management_vpc ? data.aws_vpc.management_vpc[0].id : aws_vpc.green_inspection.id

  ingress {
    description = "Allow all ingress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
}
