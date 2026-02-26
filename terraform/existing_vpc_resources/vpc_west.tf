
locals {
  west_public_subnet_cidr_az1 = cidrsubnet(var.vpc_cidr_west, var.spoke_subnet_bits, 0)
  west_tgw_subnet_cidr_az1    = cidrsubnet(var.vpc_cidr_west, var.spoke_subnet_bits, 1)
  west_public_subnet_cidr_az2 = cidrsubnet(var.vpc_cidr_west, var.spoke_subnet_bits, 2)
  west_tgw_subnet_cidr_az2    = cidrsubnet(var.vpc_cidr_west, var.spoke_subnet_bits, 3)
}
#
# west VPC
#
module "vpc-west" {
  source      = "git::https://github.com/40netse/terraform-modules.git//aws_vpc"
  depends_on  = [ module.vpc-transit-gateway.tgw_id ]
  count       = var.enable_build_existing_subnets ? 1 : 0
  vpc_name                   = "${var.cp}-${var.env}-west-vpc"
  vpc_cidr                   = var.vpc_cidr_west
}

module "subnet-west-public-az1" {
  source                     = "git::https://github.com/40netse/terraform-modules.git//aws_subnet"
  count                      = var.enable_build_existing_subnets ? 1 : 0
  subnet_name                = "${var.cp}-${var.env}-west-public-az1-subnet"
  vpc_id                     = module.vpc-west[0].vpc_id
  availability_zone          = local.availability_zone_1
  subnet_cidr                = local.west_public_subnet_cidr_az1
}
module "subnet-west-public-az2" {
  source            = "git::https://github.com/40netse/terraform-modules.git//aws_subnet"
  count             = var.enable_build_existing_subnets ? 1 : 0
  subnet_name       = "${var.cp}-${var.env}-west-public-az2-subnet"
  vpc_id            = module.vpc-west[0].vpc_id
  availability_zone = local.availability_zone_2
  subnet_cidr       = local.west_public_subnet_cidr_az2
}

#
# TGW attachment subnets - dedicated subnets for TGW to avoid IP conflicts with EC2 instances
#
module "subnet-west-tgw-az1" {
  source = "git::https://github.com/40netse/terraform-modules.git//aws_subnet"
  count  = var.enable_build_existing_subnets ? 1 : 0

  subnet_name       = "${var.cp}-${var.env}-west-tgw-az1-subnet"
  vpc_id            = module.vpc-west[0].vpc_id
  availability_zone = local.availability_zone_1
  subnet_cidr       = local.west_tgw_subnet_cidr_az1
}
module "subnet-west-tgw-az2" {
  source = "git::https://github.com/40netse/terraform-modules.git//aws_subnet"
  count  = var.enable_build_existing_subnets ? 1 : 0

  subnet_name       = "${var.cp}-${var.env}-west-tgw-az2-subnet"
  vpc_id            = module.vpc-west[0].vpc_id
  availability_zone = local.availability_zone_2
  subnet_cidr       = local.west_tgw_subnet_cidr_az2
}

#
# TGW subnet route table - routes traffic to TGW for internet egress
#
resource "aws_route_table" "west-tgw-rt" {
  count  = var.enable_build_existing_subnets ? 1 : 0
  vpc_id = module.vpc-west[0].vpc_id
  tags = {
    Name = "${var.cp}-${var.env}-west-tgw-rt"
  }
}
resource "aws_route_table_association" "west-tgw-az1" {
  count          = var.enable_build_existing_subnets ? 1 : 0
  subnet_id      = module.subnet-west-tgw-az1[0].id
  route_table_id = aws_route_table.west-tgw-rt[0].id
}
resource "aws_route_table_association" "west-tgw-az2" {
  count          = var.enable_build_existing_subnets ? 1 : 0
  subnet_id      = module.subnet-west-tgw-az2[0].id
  route_table_id = aws_route_table.west-tgw-rt[0].id
}
resource "aws_route" "default-route-west-tgw-subnet" {
  depends_on             = [module.vpc-transit-gateway-attachment-west]
  count                  = var.enable_build_existing_subnets ? 1 : 0
  route_table_id         = aws_route_table.west-tgw-rt[0].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}

#
# Default route table that is created with the main VPC.
#
resource "aws_default_route_table" "route_west" {
  count                  = var.enable_build_existing_subnets ? 1 : 0
  default_route_table_id = module.vpc-west[0].vpc_main_route_table_id
  tags = {
    Name = "${var.cp}-${var.env}-west-vpc-main-route-table"
  }
}
resource "aws_route" "default-route-west-public" {
  depends_on             = [module.vpc-transit-gateway-attachment-west]
  count                  = var.enable_build_existing_subnets ? 1 : 0
  route_table_id         = module.vpc-west[0].vpc_main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "management-route-west-public" {
  depends_on             = [module.vpc-transit-gateway-attachment-west]
  count                  = (var.enable_build_existing_subnets && var.enable_build_management_vpc) ? 1 : 0
  route_table_id         = module.vpc-west[0].vpc_main_route_table_id
  destination_cidr_block = var.vpc_cidr_management
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
