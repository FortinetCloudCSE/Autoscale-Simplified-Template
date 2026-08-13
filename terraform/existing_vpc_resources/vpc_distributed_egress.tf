#
# Lab distributed-egress VPCs for dual-egress (centralized + distributed) feature testing
#
# These are test-only scaffolding, NOT a production pattern. Each VPC gets its own IGW and its
# own GWLBe subnet; workload traffic in the private subnet is redirected (by autoscale_template,
# which owns route table mutation for infra we create here) to the shared GWLB Endpoint Service
# used by the centralized/Inspection VPC path, inspected by the same FortiGate autoscale group,
# then egresses locally through this VPC's own IGW -- no TGW hop involved.
#
# Resources are tagged with Fortinet-Role for discovery by autoscale_template, same mechanism
# already used for the Inspection VPC.
#
# Phase 1 (current): non-overlapping CIDRs, to verify the baseline works before testing whether
# a special FortiOS build (GWLBe-keyed GENEVE tunnels) allows the two VPCs to safely overlap.
#

#
# CIDR range-overlap check (start/end IP math, not just network-address equality -- a /23 and a
# /24 nested inside it would share a network address prefix without being byte-identical, so a
# naive string/cidrhost(...,0) comparison isn't enough here)
#
locals {
  distributed_cidr_octets_1 = [for o in split(".", split("/", var.vpc_cidr_distributed_1)[0]) : tonumber(o)]
  distributed_cidr_octets_2 = [for o in split(".", split("/", var.vpc_cidr_distributed_2)[0]) : tonumber(o)]

  distributed_cidr_start_1 = local.distributed_cidr_octets_1[0] * 16777216 + local.distributed_cidr_octets_1[1] * 65536 + local.distributed_cidr_octets_1[2] * 256 + local.distributed_cidr_octets_1[3]
  distributed_cidr_start_2 = local.distributed_cidr_octets_2[0] * 16777216 + local.distributed_cidr_octets_2[1] * 65536 + local.distributed_cidr_octets_2[2] * 256 + local.distributed_cidr_octets_2[3]

  distributed_cidr_end_1 = local.distributed_cidr_start_1 + pow(2, 32 - tonumber(split("/", var.vpc_cidr_distributed_1)[1])) - 1
  distributed_cidr_end_2 = local.distributed_cidr_start_2 + pow(2, 32 - tonumber(split("/", var.vpc_cidr_distributed_2)[1])) - 1

  distributed_cidrs_overlap = local.distributed_cidr_start_1 <= local.distributed_cidr_end_2 && local.distributed_cidr_start_2 <= local.distributed_cidr_end_1
}

check "distributed_cidrs_no_overlap" {
  assert {
    condition     = !var.enable_build_distributed_egress_vpcs || var.allow_distributed_cidr_overlap || !local.distributed_cidrs_overlap
    error_message = "vpc_cidr_distributed_1 (${var.vpc_cidr_distributed_1}) and vpc_cidr_distributed_2 (${var.vpc_cidr_distributed_2}) overlap. Phase 1 of dual-egress testing requires non-overlapping CIDRs. If you're intentionally testing phase 2 (overlap, e.g. against the Sony GWLBe-keyed GENEVE build), set allow_distributed_cidr_overlap = true to bypass this check."
  }
}

#
# VPC #1
#
module "vpc-distributed-1" {
  source                          = "git::https://github.com/40netse/terraform-modules.git//aws_inspection_vpc"
  count                           = var.enable_build_distributed_egress_vpcs ? 1 : 0
  vpc_name                        = "${var.cp}-${var.env}-distributed-1"
  vpc_cidr                        = var.vpc_cidr_distributed_1
  subnet_bits                     = var.distributed_subnet_bits
  availability_zone_1             = local.availability_zone_1
  availability_zone_2             = local.availability_zone_2
  availability_zone_3             = ""
  enable_nat_gateway              = false
  named_tgw                       = ""
  enable_tgw_attachment           = false
  enable_dedicated_management_eni = false
  tags                            = local.common_tags
}

#
# VPC #2
#
module "vpc-distributed-2" {
  source                          = "git::https://github.com/40netse/terraform-modules.git//aws_inspection_vpc"
  count                           = var.enable_build_distributed_egress_vpcs ? 1 : 0
  vpc_name                        = "${var.cp}-${var.env}-distributed-2"
  vpc_cidr                        = var.vpc_cidr_distributed_2
  subnet_bits                     = var.distributed_subnet_bits
  availability_zone_1             = local.availability_zone_1
  availability_zone_2             = local.availability_zone_2
  availability_zone_3             = ""
  enable_nat_gateway              = false
  named_tgw                       = ""
  enable_tgw_attachment           = false
  enable_dedicated_management_eni = false
  tags                            = local.common_tags
}

#
# Fortinet-Role tags for resource discovery by autoscale_template
#

# VPC tags
resource "aws_ec2_tag" "distributed_1_vpc_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].vpc_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-vpc"
}
resource "aws_ec2_tag" "distributed_2_vpc_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].vpc_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-vpc"
}

# IGW tags
resource "aws_ec2_tag" "distributed_1_igw_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].igw_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-igw"
}
resource "aws_ec2_tag" "distributed_2_igw_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].igw_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-igw"
}

# Private (workload) subnet tags -- autoscale_template redirects this subnet's default route to
# its own GWLB Endpoint; no default route is set here (mirrors the Inspection VPC's private subnet)
resource "aws_ec2_tag" "distributed_1_subnet_private_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].subnet_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-private-az1"
}
resource "aws_ec2_tag" "distributed_1_subnet_private_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].subnet_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-private-az2"
}
resource "aws_ec2_tag" "distributed_2_subnet_private_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].subnet_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-private-az1"
}
resource "aws_ec2_tag" "distributed_2_subnet_private_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].subnet_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-private-az2"
}

# Private route table tags -- autoscale_template looks these up to set the GWLBe default route
resource "aws_ec2_tag" "distributed_1_rt_private_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].route_table_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-private-rt-az1"
}
resource "aws_ec2_tag" "distributed_1_rt_private_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].route_table_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-private-rt-az2"
}
resource "aws_ec2_tag" "distributed_2_rt_private_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].route_table_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-private-rt-az1"
}
resource "aws_ec2_tag" "distributed_2_rt_private_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].route_table_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-private-rt-az2"
}

# GWLBe subnet tags -- autoscale_template creates its aws_vpc_endpoint in these subnets
resource "aws_ec2_tag" "distributed_1_subnet_gwlbe_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].subnet_gwlbe_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-gwlbe-az1"
}
resource "aws_ec2_tag" "distributed_1_subnet_gwlbe_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-1[0].subnet_gwlbe_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-1-gwlbe-az2"
}
resource "aws_ec2_tag" "distributed_2_subnet_gwlbe_az1_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].subnet_gwlbe_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-gwlbe-az1"
}
resource "aws_ec2_tag" "distributed_2_subnet_gwlbe_az2_role" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  resource_id = module.vpc-distributed-2[0].subnet_gwlbe_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-distributed-2-gwlbe-az2"
}

#
# Default route for GWLBe subnets to this VPC's own IGW -- after FortiGate inspection via the
# shared GWLB, return traffic exits locally here instead of hairpinning back through the TGW
#
resource "aws_route" "distributed_1_gwlbe_default_route_igw_az1" {
  depends_on             = [module.vpc-distributed-1]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-1[0].route_table_gwlbe_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-1[0].igw_id
}
resource "aws_route" "distributed_1_gwlbe_default_route_igw_az2" {
  depends_on             = [module.vpc-distributed-1]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-1[0].route_table_gwlbe_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-1[0].igw_id
}
resource "aws_route" "distributed_2_gwlbe_default_route_igw_az1" {
  depends_on             = [module.vpc-distributed-2]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-2[0].route_table_gwlbe_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-2[0].igw_id
}
resource "aws_route" "distributed_2_gwlbe_default_route_igw_az2" {
  depends_on             = [module.vpc-distributed-2]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-2[0].route_table_gwlbe_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-2[0].igw_id
}

#
# Default route for the public subnets to this VPC's own IGW. This is the ONLY subnet in each
# distributed VPC that gets a public IP -- it never gets redirected to the GWLB endpoint (that
# only happens to the private subnet, owned by autoscale_template), so there's no risk of the
# asymmetric-routing/GWLB-flow-symmetry problem a public IP would create on the private subnet.
#
resource "aws_route" "distributed_1_public_default_route_igw_az1" {
  depends_on             = [module.vpc-distributed-1]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-1[0].route_table_public_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-1[0].igw_id
}
resource "aws_route" "distributed_1_public_default_route_igw_az2" {
  depends_on             = [module.vpc-distributed-1]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-1[0].route_table_public_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-1[0].igw_id
}
resource "aws_route" "distributed_2_public_default_route_igw_az1" {
  depends_on             = [module.vpc-distributed-2]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-2[0].route_table_public_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-2[0].igw_id
}
resource "aws_route" "distributed_2_public_default_route_igw_az2" {
  depends_on             = [module.vpc-distributed-2]
  count                  = var.enable_build_distributed_egress_vpcs ? 1 : 0
  route_table_id         = module.vpc-distributed-2[0].route_table_public_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-distributed-2[0].igw_id
}

#
# Traffic-generator Linux instance -- one per distributed VPC, in the PRIVATE subnet, with a real
# EIP. Deliberately NOT in the public subnet: an instance there would route straight to/from this
# VPC's own IGW, bypassing the FortiGate entirely in both directions. Living in the private
# subnet instead means both directions are inspected -- outbound via the private subnet's own
# default route (autoscale_template redirects it to the AZ-matched GWLBe), and inbound via the
# Ingress Routing table autoscale_template attaches to this VPC's IGW (see below), which redirects
# the EIP's post-NAT traffic to the same GWLBe before it ever reaches the instance. Scoped to
# management_cidr_sg rather than the east/west spoke pattern's "allow all 0.0.0.0/0" since this
# instance is genuinely internet-facing.
#

data "aws_subnet" "distributed_1_private_az1" {
  count = var.enable_build_distributed_egress_vpcs ? 1 : 0
  id    = module.vpc-distributed-1[0].subnet_private_az1_id
}
data "aws_subnet" "distributed_2_private_az1" {
  count = var.enable_build_distributed_egress_vpcs ? 1 : 0
  id    = module.vpc-distributed-2[0].subnet_private_az1_id
}

data "aws_ami" "ubuntu_distributed" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-20250603*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

module "distributed_linux_iam_profile" {
  source        = "git::https://github.com/40netse/terraform-modules.git//aws_ec2_instance_iam_role"
  count         = var.enable_build_distributed_egress_vpcs ? 1 : 0
  iam_role_name = "${var.cp}-${var.env}-${random_string.random.result}-distributed-linux-instance_role"
}

resource "aws_security_group" "distributed_1_linux_sg" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  name        = "${var.cp}-${var.env}-distributed-1-linux-sg"
  description = "Security group for the distributed-1 traffic-generator Linux instance"
  vpc_id      = module.vpc-distributed-1[0].vpc_id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "HTTPS from allowed CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "ICMP from allowed CIDRs"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.rfc1918_10, local.rfc1918_172, local.rfc1918_192]
  }
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "distributed_2_linux_sg" {
  count       = var.enable_build_distributed_egress_vpcs ? 1 : 0
  name        = "${var.cp}-${var.env}-distributed-2-linux-sg"
  description = "Security group for the distributed-2 traffic-generator Linux instance"
  vpc_id      = module.vpc-distributed-2[0].vpc_id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "HTTPS from allowed CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "ICMP from allowed CIDRs"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.rfc1918_10, local.rfc1918_172, local.rfc1918_192]
  }
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "distributed_1_instance" {
  count = var.enable_build_distributed_egress_vpcs ? 1 : 0
  # Note: no dependency on the GWLBe/Ingress Routing wiring here -- that lives in
  # autoscale_template's state, applied separately. The instance is reachable only once both
  # stacks are applied (same bootstrapping order already documented for the private subnet's
  # outbound default route).
  depends_on               = [module.vpc-distributed-1]
  source                   = "git::https://github.com/40netse/terraform-modules.git//aws_ec2_instance"
  aws_ec2_instance_name    = "${var.cp}-${var.env}-distributed-1-instance"
  enable_public_ips        = true
  availability_zone        = local.availability_zone_1
  public_subnet_id         = module.vpc-distributed-1[0].subnet_private_az1_id
  public_ip_address        = cidrhost(data.aws_subnet.distributed_1_private_az1[0].cidr_block, 11)
  aws_ami                  = data.aws_ami.ubuntu_distributed[0].id
  keypair                  = var.keypair
  instance_type            = var.linux_instance_type
  security_group_public_id = aws_security_group.distributed_1_linux_sg[0].id
  acl                      = var.acl
  iam_instance_profile_id  = module.distributed_linux_iam_profile[0].id
  userdata_rendered        = ""
}
module "distributed_2_instance" {
  count                    = var.enable_build_distributed_egress_vpcs ? 1 : 0
  depends_on               = [module.vpc-distributed-2]
  source                   = "git::https://github.com/40netse/terraform-modules.git//aws_ec2_instance"
  aws_ec2_instance_name    = "${var.cp}-${var.env}-distributed-2-instance"
  enable_public_ips        = true
  availability_zone        = local.availability_zone_1
  public_subnet_id         = module.vpc-distributed-2[0].subnet_private_az1_id
  public_ip_address        = cidrhost(data.aws_subnet.distributed_2_private_az1[0].cidr_block, 11)
  aws_ami                  = data.aws_ami.ubuntu_distributed[0].id
  keypair                  = var.keypair
  instance_type            = var.linux_instance_type
  security_group_public_id = aws_security_group.distributed_2_linux_sg[0].id
  acl                      = var.acl
  iam_instance_profile_id  = module.distributed_linux_iam_profile[0].id
  userdata_rendered        = ""
}
