#
# access mode = nat_gw will create the nat gateway subnets, but we don't want to
# actually create the nat gateways (and charges) until the fortgates are in place to
# send traffic through them.

locals {
  enable_nat_gateway = var.access_internet_mode == "nat_gw" ? true : false
  create_nat_gateway = false
}
module "vpc-inspection" {
  source = "git::https://github.com/40netse/terraform-modules.git//aws_inspection_vpc"
  depends_on                       = [ module.vpc-transit-gateway.tgw_id,
                                       module.vpc-transit-gateway-attachment-west,
                                       module.vpc-transit-gateway-attachment-east]
  vpc_name                         = "${var.cp}-${var.env}-inspection"
  vpc_cidr                         = var.vpc_cidr_inspection
  subnet_bits                      = var.subnet_bits
  availability_zone_1              = local.availability_zone_1
  availability_zone_2              = local.availability_zone_2
  enable_nat_gateway               = local.enable_nat_gateway
  create_nat_gateway               = local.create_nat_gateway
  enable_dedicated_management_eni  = var.create_management_subnet_in_inspection_vpc
  named_tgw                        = var.attach_to_tgw_name
  enable_tgw_attachment            = var.enable_tgw_attachment
  create_gwlb_route_associations   = false
}

#
# if you are using the existing_vpc_resources template, setup the TGW route tables to route everything.
# If you are not using existing_vpc_resources template, the equivalent routes will need to be created manually.
#
resource "aws_ec2_transit_gateway_route" "inspection-route-to-west-tgw" {
  count                          = var.create_tgw_routes_for_existing ? 1 : 0
  depends_on                     = [module.vpc-inspection]
  destination_cidr_block         = var.vpc_cidr_west
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-west[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-inspection.inspection_tgw_route_table_id
}
resource "aws_ec2_transit_gateway_route" "inspection-route-to-east-tgw" {
  count                          = var.create_tgw_routes_for_existing? 1 : 0
  depends_on                     = [module.vpc-inspection]
  destination_cidr_block         = var.vpc_cidr_east
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-east[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-inspection.inspection_tgw_route_table_id
}

#
# Default route in public subnet route table points to IGW
# NAT Gateways are created later in the autoscale_template deployment
#
resource "aws_route" "inspection-public-default-route-igw-az1" {
  depends_on             = [module.vpc-inspection]
  route_table_id         = module.vpc-inspection.route_table_public_az1_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection.igw_id
}

resource "aws_route" "inspection-public-default-route-igw-az2" {
  depends_on             = [module.vpc-inspection]
  route_table_id         = module.vpc-inspection.route_table_public_az2_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-inspection.igw_id
}
