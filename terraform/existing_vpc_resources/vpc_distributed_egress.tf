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
    condition     = !var.enable_build_distributed_egress_vpcs || !local.distributed_cidrs_overlap
    error_message = "vpc_cidr_distributed_1 (${var.vpc_cidr_distributed_1}) and vpc_cidr_distributed_2 (${var.vpc_cidr_distributed_2}) overlap. This first phase of dual-egress testing requires non-overlapping CIDRs -- overlap is the later, more complicated scenario to test once this baseline passes."
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
