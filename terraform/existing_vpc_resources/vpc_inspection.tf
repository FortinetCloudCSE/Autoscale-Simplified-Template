#
# Inspection VPC for FortiGate Autoscale Group
#
# This VPC will be used by the autoscale_template to deploy the FortiGate autoscale group.
# Resources are tagged with Fortinet-Role for discovery by the autoscale_template.
#

locals {
  inspection_enable_nat_gateway = var.create_nat_gateway_subnets
}

module "vpc-inspection" {
  source                          = "git::https://github.com/40netse/terraform-modules.git//aws_inspection_vpc"
  count                           = var.enable_build_inspection_vpc ? 1 : 0
  depends_on                      = [module.vpc-transit-gateway]
  vpc_name                        = "${var.cp}-${var.env}-inspection"
  vpc_cidr                        = var.vpc_cidr_ns_inspection
  subnet_bits                     = var.subnet_bits
  availability_zone_1             = local.availability_zone_1
  availability_zone_2             = local.availability_zone_2
  enable_nat_gateway              = local.inspection_enable_nat_gateway
  named_tgw                       = var.attach_to_tgw_name
  enable_tgw_attachment           = var.enable_tgw_attachment
  enable_dedicated_management_eni = var.create_management_subnet_in_inspection_vpc
}

#
# Fortinet-Role Tags for resource discovery by autoscale_template
# These tags allow the autoscale_template to find resources created by this template
#

# VPC Tag
resource "aws_ec2_tag" "inspection_vpc_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].vpc_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-vpc"
}

# Subnet Tags - Public
resource "aws_ec2_tag" "inspection_subnet_public_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_public_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-public-az1"
}
resource "aws_ec2_tag" "inspection_subnet_public_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_public_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-public-az2"
}

# Subnet Tags - GWLBE
resource "aws_ec2_tag" "inspection_subnet_gwlbe_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_gwlbe_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-gwlbe-az1"
}
resource "aws_ec2_tag" "inspection_subnet_gwlbe_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_gwlbe_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-gwlbe-az2"
}

# Subnet Tags - Private
resource "aws_ec2_tag" "inspection_subnet_private_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-private-az1"
}
resource "aws_ec2_tag" "inspection_subnet_private_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-private-az2"
}

# Subnet Tags - NAT GW (conditional)
resource "aws_ec2_tag" "inspection_subnet_natgw_az1_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_natgw_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-az1"
}
resource "aws_ec2_tag" "inspection_subnet_natgw_az2_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_natgw_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-az2"
}

# Subnet Tags - Management (conditional)
resource "aws_ec2_tag" "inspection_subnet_management_az1_role" {
  count       = (var.enable_build_inspection_vpc && var.create_management_subnet_in_inspection_vpc) ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_management_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-management-az1"
}
resource "aws_ec2_tag" "inspection_subnet_management_az2_role" {
  count       = (var.enable_build_inspection_vpc && var.create_management_subnet_in_inspection_vpc) ? 1 : 0
  resource_id = module.vpc-inspection[0].subnet_management_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-management-az2"
}

# Route Table Tags - Public
resource "aws_ec2_tag" "inspection_rt_public_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_public_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-public-rt-az1"
}
resource "aws_ec2_tag" "inspection_rt_public_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_public_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-public-rt-az2"
}

# Route Table Tags - GWLBE
resource "aws_ec2_tag" "inspection_rt_gwlbe_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_gwlbe_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-gwlbe-rt-az1"
}
resource "aws_ec2_tag" "inspection_rt_gwlbe_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_gwlbe_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-gwlbe-rt-az2"
}

# Route Table Tags - Private
resource "aws_ec2_tag" "inspection_rt_private_az1_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_private_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-private-rt-az1"
}
resource "aws_ec2_tag" "inspection_rt_private_az2_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_private_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-private-rt-az2"
}

# Route Table Tags - NAT GW (conditional)
resource "aws_ec2_tag" "inspection_rt_natgw_az1_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_natgw_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-rt-az1"
}
resource "aws_ec2_tag" "inspection_rt_natgw_az2_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_natgw_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-rt-az2"
}

# Route Table Tags - Management (conditional)
resource "aws_ec2_tag" "inspection_rt_management_az1_role" {
  count       = (var.enable_build_inspection_vpc && var.create_management_subnet_in_inspection_vpc) ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_management_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-management-rt-az1"
}
resource "aws_ec2_tag" "inspection_rt_management_az2_role" {
  count       = (var.enable_build_inspection_vpc && var.create_management_subnet_in_inspection_vpc) ? 1 : 0
  resource_id = module.vpc-inspection[0].route_table_management_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-management-rt-az2"
}

# IGW Tag
resource "aws_ec2_tag" "inspection_igw_role" {
  count       = var.enable_build_inspection_vpc ? 1 : 0
  resource_id = module.vpc-inspection[0].igw_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-igw"
}

# NAT Gateway Tags (conditional)
resource "aws_ec2_tag" "inspection_natgw_az1_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].aws_nat_gateway_vpc_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-az1"
}
resource "aws_ec2_tag" "inspection_natgw_az2_role" {
  count       = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  resource_id = module.vpc-inspection[0].aws_nat_gateway_vpc_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-natgw-az2"
}

# TGW Attachment Tag (conditional)
resource "aws_ec2_tag" "inspection_tgw_attachment_role" {
  count       = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  resource_id = module.vpc-inspection[0].inspection_tgw_attachment_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-tgw-attachment"
}

# TGW Route Table Tag (conditional)
resource "aws_ec2_tag" "inspection_tgw_rtb_role" {
  count       = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  resource_id = module.vpc-inspection[0].inspection_tgw_route_table_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-inspection-tgw-rtb"
}

#
# Routes for the public subnet route tables
# If NAT gateway is enabled, make the default route go to the NAT gateway.
# If not, make the default route go to the internet gateway.
#
resource "aws_route" "inspection-public-default-route-ngw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_public_az1_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = module.vpc-inspection[0].aws_nat_gateway_vpc_az1_id
}
resource "aws_route" "inspection-public-default-route-ngw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && local.inspection_enable_nat_gateway) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_public_az2_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = module.vpc-inspection[0].aws_nat_gateway_vpc_az2_id
}
resource "aws_route" "inspection-public-default-route-igw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && !local.inspection_enable_nat_gateway) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_public_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection[0].igw_id
}
resource "aws_route" "inspection-public-default-route-igw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && !local.inspection_enable_nat_gateway) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_public_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection[0].igw_id
}

#
# Private subnet route tables - NO default route
# The autoscale_template will create the default route pointing to GWLB endpoints
# when modify_existing_route_tables = true
#

#
# Default route for GWLBE subnets to IGW
# After FortiGate inspection, internet-bound traffic exits via IGW
#
resource "aws_route" "inspection-gwlbe-default-route-igw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = var.enable_build_inspection_vpc ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection[0].igw_id
}
resource "aws_route" "inspection-gwlbe-default-route-igw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = var.enable_build_inspection_vpc ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection[0].igw_id
}

#
# Routes for GWLBE route tables to TGW for RFC1918 traffic
# This allows east-west inspection traffic to flow through the TGW
#
resource "aws_route" "inspection-gwlbe-192-route-tgw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az1_id
  destination_cidr_block = local.rfc1918_192
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "inspection-gwlbe-192-route-tgw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az2_id
  destination_cidr_block = local.rfc1918_192
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "inspection-gwlbe-10-route-tgw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az1_id
  destination_cidr_block = local.rfc1918_10
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "inspection-gwlbe-10-route-tgw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az2_id
  destination_cidr_block = local.rfc1918_10
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "inspection-gwlbe-172-route-tgw-az1" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az1_id
  destination_cidr_block = local.rfc1918_172
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "inspection-gwlbe-172-route-tgw-az2" {
  depends_on             = [module.vpc-inspection]
  count                  = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  route_table_id         = module.vpc-inspection[0].route_table_gwlbe_az2_id
  destination_cidr_block = local.rfc1918_172
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}

#
# TGW routes from east/west spoke VPCs to inspection VPC
# This enables east-west inspection through the FortiGate autoscale group
#
resource "aws_ec2_transit_gateway_route" "inspection-route-to-west-tgw" {
  count                          = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  depends_on                     = [module.vpc-inspection]
  destination_cidr_block         = var.vpc_cidr_west
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-west[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-inspection[0].inspection_tgw_route_table_id
}
resource "aws_ec2_transit_gateway_route" "inspection-route-to-east-tgw" {
  count                          = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? 1 : 0
  depends_on                     = [module.vpc-inspection]
  destination_cidr_block         = var.vpc_cidr_east
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-east[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-inspection[0].inspection_tgw_route_table_id
}

#
# NOTE: Default routes (0.0.0.0/0) from east/west spoke TGW route tables are created
# in tgw.tf pointing to management VPC (jump box) for spoke instance cloud-init.
# The autoscale_template will replace these routes to point to GWLB endpoints
# for FortiGate inspection.
#

#
# Management VPC routes to inspection VPC (if management VPC is enabled)
#
resource "aws_ec2_transit_gateway_route" "inspection-route-to-management-tgw" {
  count                          = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets && var.enable_build_management_vpc && local.enable_management_tgw_attachment) ? 1 : 0
  depends_on                     = [module.vpc-inspection, module.vpc-management]
  destination_cidr_block         = var.vpc_cidr_management
  transit_gateway_attachment_id  = module.vpc-management[0].management_tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-inspection[0].inspection_tgw_route_table_id
}
