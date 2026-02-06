#
# Unified Template - Deploy FortiGate Autoscale into Existing Inspection VPC
#
# This template deploys into an existing VPC that was created by existing_vpc_resources
# or any VPC with the correct Fortinet-Role tags.
#
# Required Fortinet-Role tags are listed at the end of this file.
#

locals {
  common_tags = {
    Environment = var.env
  }
}

check "config_validation" {
  assert {
    condition     = !(var.enable_dedicated_management_eni && var.enable_dedicated_management_vpc)
    error_message = "Cannot enable both dedicated management VPC and dedicated management ENI"
  }
  assert {
    condition     = var.access_internet_mode == "eip" || var.access_internet_mode == "nat_gw"
    error_message = "access_internet_mode must be 'eip' or 'nat_gw'"
  }
  assert {
    condition     = var.firewall_policy_mode == "1-arm" || var.firewall_policy_mode == "2-arm"
    error_message = "firewall_policy_mode must be '1-arm' or '2-arm'"
  }
}

locals {
  enable_nat_gateway = var.access_internet_mode == "nat_gw" ? true : false
}
locals {
  rfc1918_192 = "192.168.0.0/16"
}
locals {
  rfc1918_10 = "10.0.0.0/8"
}
locals {
  rfc1918_172 = "172.16.0.0/12"
}
locals {
  availability_zone_1 = "${var.aws_region}${var.availability_zone_1}"
}
locals {
  availability_zone_2 = "${var.aws_region}${var.availability_zone_2}"
}

resource "random_string" "random" {
  length  = 5
  special = false
}

#
# ==================================================================================
# DATA SOURCES - Look up existing inspection VPC resources by Fortinet-Role tag
# ==================================================================================
#

# VPC
data "aws_vpc" "inspection" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-vpc"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Internet Gateway
data "aws_internet_gateway" "inspection" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-igw"]
  }
}

# Subnets - Public
data "aws_subnet" "inspection_public_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-public-az1"]
  }
}
data "aws_subnet" "inspection_public_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-public-az2"]
  }
}

# Subnets - GWLBE
data "aws_subnet" "inspection_gwlbe_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-gwlbe-az1"]
  }
}
data "aws_subnet" "inspection_gwlbe_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-gwlbe-az2"]
  }
}

# Subnets - Private (TGW attachment)
data "aws_subnet" "inspection_private_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-private-az1"]
  }
}
data "aws_subnet" "inspection_private_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-private-az2"]
  }
}

# Subnets - Management (conditional)
data "aws_subnet" "inspection_management_az1" {
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-management-az1"]
  }
}
data "aws_subnet" "inspection_management_az2" {
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-management-az2"]
  }
}

# Route Tables - Public
data "aws_route_table" "inspection_public_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-public-rt-az1"]
  }
}
data "aws_route_table" "inspection_public_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-public-rt-az2"]
  }
}

# Route Tables - GWLBE
data "aws_route_table" "inspection_gwlbe_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-gwlbe-rt-az1"]
  }
}
data "aws_route_table" "inspection_gwlbe_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-gwlbe-rt-az2"]
  }
}

# Route Tables - Private
data "aws_route_table" "inspection_private_az1" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-private-rt-az1"]
  }
}
data "aws_route_table" "inspection_private_az2" {
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-private-rt-az2"]
  }
}

# Route Tables - Management (conditional)
data "aws_route_table" "inspection_management_az1" {
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-management-rt-az1"]
  }
}
data "aws_route_table" "inspection_management_az2" {
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-management-rt-az2"]
  }
}

# NAT Gateways (conditional on nat_gw mode)
data "aws_nat_gateway" "inspection_az1" {
  count = local.enable_nat_gateway ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-natgw-az1"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_nat_gateway" "inspection_az2" {
  count = local.enable_nat_gateway ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-natgw-az2"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# TGW Attachment (conditional)
data "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  count = var.enable_tgw_attachment ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-tgw-attachment"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# TGW Route Table (conditional)
data "aws_ec2_transit_gateway_route_table" "inspection" {
  count = var.enable_tgw_attachment ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-inspection-tgw-rtb"]
  }
}

# Transit Gateway (for route creation)
data "aws_ec2_transit_gateway" "tgw" {
  count = var.enable_tgw_attachment ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [var.attach_to_tgw_name]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# East/West TGW attachments and route tables (for existing_vpc_resources integration)
data "aws_ec2_transit_gateway_attachment" "east" {
  count = var.create_tgw_routes_for_existing ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-east-tgw-attachment"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_ec2_transit_gateway_route_table" "east-tgw-rtb" {
  count = var.create_tgw_routes_for_existing ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-east-tgw-rtb"]
  }
}
data "aws_ec2_transit_gateway_attachment" "west" {
  count = var.create_tgw_routes_for_existing ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-west-tgw-attachment"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_ec2_transit_gateway_route_table" "west-tgw-rtb" {
  count = var.create_tgw_routes_for_existing ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-west-tgw-rtb"]
  }
}

# GWLB Endpoints (created by the ASG module)
data "aws_vpc_endpoint" "asg_endpoint_az1" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az1]
  }
}
data "aws_vpc_endpoint" "asg_endpoint_az2" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az2]
  }
}

# Management VPC resources (for dedicated management VPC mode)
data "aws_internet_gateway" "management_igw_id" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-management-igw"]
  }
}

#
# ==================================================================================
# ROUTE MODIFICATIONS - Only created when modify_existing_route_tables = true
# ==================================================================================
#
# These routes modify the existing route tables to enable traffic flow through
# the FortiGate autoscale group.
#
# WARNING: Enabling modify_existing_route_tables will change existing routes which
# may temporarily disrupt traffic flow during deployment.
#

#
# Private subnet routes - Point to GWLB endpoints for inspection
# This replaces the temporary NAT GW/IGW routes created by existing_vpc_resources
#
resource "aws_route" "inspection-private-default-route-gwlbe-az1" {
  count                  = var.modify_existing_route_tables ? 1 : 0
  route_table_id         = data.aws_route_table.inspection_private_az1.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.asg_endpoint_az1.id
}
resource "aws_route" "inspection-private-default-route-gwlbe-az2" {
  count                  = var.modify_existing_route_tables ? 1 : 0
  route_table_id         = data.aws_route_table.inspection_private_az2.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.asg_endpoint_az2.id
}

#
# TGW Routes - Replace default routes in east/west spoke TGW route tables
# These replace the temporary routes to management VPC (for jump box NAT during cloud-init)
# with routes to the inspection VPC for traffic inspection via GWLB
#
# First delete any existing default routes (created by existing_vpc_resources)
resource "null_resource" "delete_existing_east_tgw_default_route" {
  count = (var.enable_tgw_attachment && var.create_tgw_routes_for_existing) ? 1 : 0

  provisioner "local-exec" {
    command = "aws ec2 delete-transit-gateway-route --transit-gateway-route-table-id ${data.aws_ec2_transit_gateway_route_table.east-tgw-rtb[0].id} --destination-cidr-block 0.0.0.0/0 --region ${var.aws_region} || true"
  }
}
resource "null_resource" "delete_existing_west_tgw_default_route" {
  count = (var.enable_tgw_attachment && var.create_tgw_routes_for_existing) ? 1 : 0

  provisioner "local-exec" {
    command = "aws ec2 delete-transit-gateway-route --transit-gateway-route-table-id ${data.aws_ec2_transit_gateway_route_table.west-tgw-rtb[0].id} --destination-cidr-block 0.0.0.0/0 --region ${var.aws_region} || true"
  }
}

# Then create new routes pointing to inspection VPC
resource "aws_ec2_transit_gateway_route" "east-default-route-to-inspection" {
  count                          = (var.enable_tgw_attachment && var.create_tgw_routes_for_existing) ? 1 : 0
  depends_on                     = [null_resource.delete_existing_east_tgw_default_route]
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = data.aws_ec2_transit_gateway_vpc_attachment.inspection[0].id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.east-tgw-rtb[0].id
}
resource "aws_ec2_transit_gateway_route" "west-default-route-to-inspection" {
  count                          = (var.enable_tgw_attachment && var.create_tgw_routes_for_existing) ? 1 : 0
  depends_on                     = [null_resource.delete_existing_west_tgw_default_route]
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = data.aws_ec2_transit_gateway_vpc_attachment.inspection[0].id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.west-tgw-rtb[0].id
}

#
# ==================================================================================
# REQUIRED FORTINET-ROLE TAGS
# ==================================================================================
#
# The following Fortinet-Role tags must exist on the inspection VPC resources:
#
# | Resource Type        | Fortinet-Role Tag Value                          | Required |
# |----------------------|--------------------------------------------------|----------|
# | VPC                  | {cp}-{env}-inspection-vpc                        | Yes      |
# | Internet Gateway     | {cp}-{env}-inspection-igw                        | Yes      |
# | Public Subnet AZ1    | {cp}-{env}-inspection-public-az1                 | Yes      |
# | Public Subnet AZ2    | {cp}-{env}-inspection-public-az2                 | Yes      |
# | GWLBE Subnet AZ1     | {cp}-{env}-inspection-gwlbe-az1                  | Yes      |
# | GWLBE Subnet AZ2     | {cp}-{env}-inspection-gwlbe-az2                  | Yes      |
# | Private Subnet AZ1   | {cp}-{env}-inspection-private-az1                | Yes      |
# | Private Subnet AZ2   | {cp}-{env}-inspection-private-az2                | Yes      |
# | Public Route Table AZ1   | {cp}-{env}-inspection-public-rt-az1          | Yes      |
# | Public Route Table AZ2   | {cp}-{env}-inspection-public-rt-az2          | Yes      |
# | GWLBE Route Table AZ1    | {cp}-{env}-inspection-gwlbe-rt-az1           | Yes      |
# | GWLBE Route Table AZ2    | {cp}-{env}-inspection-gwlbe-rt-az2           | Yes      |
# | Private Route Table AZ1  | {cp}-{env}-inspection-private-rt-az1         | Yes      |
# | Private Route Table AZ2  | {cp}-{env}-inspection-private-rt-az2         | Yes      |
# | NAT Gateway AZ1      | {cp}-{env}-inspection-natgw-az1                  | If nat_gw mode |
# | NAT Gateway AZ2      | {cp}-{env}-inspection-natgw-az2                  | If nat_gw mode |
# | Mgmt Subnet AZ1      | {cp}-{env}-inspection-management-az1             | If dedicated mgmt ENI |
# | Mgmt Subnet AZ2      | {cp}-{env}-inspection-management-az2             | If dedicated mgmt ENI |
# | Mgmt Route Table AZ1 | {cp}-{env}-inspection-management-rt-az1          | If dedicated mgmt ENI |
# | Mgmt Route Table AZ2 | {cp}-{env}-inspection-management-rt-az2          | If dedicated mgmt ENI |
# | TGW Attachment       | {cp}-{env}-inspection-tgw-attachment             | If TGW enabled |
# | TGW Route Table      | {cp}-{env}-inspection-tgw-rtb                    | If TGW enabled |
#
# Example: For cp="acme" and env="test", the VPC tag would be "acme-test-inspection-vpc"
#
