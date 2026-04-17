#
# Green Inspection VPC
#
# Creates a new inspection VPC with IDENTICAL CIDRs to the Blue deployment.
# Same CIDRs allow the Blue primary FortiGate config to be restored to Green
# without modification (interface IPs, routes, and policies all remain valid).
#
# Subnet CIDR calculation mirrors aws_inspection_vpc module logic exactly so
# Green subnets land on the same CIDR blocks as Blue.
#

locals {
  enable_nat_gateway = var.access_internet_mode == "nat_gw"

  # stack_infix: "-green" by default, "" when stack_label is cleared after Phase 6.
  # Used in all Name/Fortinet-Role tags so a single terraform apply renames every
  # VPC resource from {cp}-{env}-green-inspection-* to {cp}-{env}-inspection-*
  # (the pattern autoscale_template data sources match for the next upgrade cycle).
  stack_infix = var.stack_label != "" ? "-${var.stack_label}" : ""

  availability_zone_1 = "${var.aws_region}${var.availability_zone_1}"
  availability_zone_2 = "${var.aws_region}${var.availability_zone_2}"

  dedicated_mgmt         = var.enable_dedicated_management_vpc ? "-wdm" : var.enable_dedicated_management_eni ? "-wdm-eni" : ""
  fgt_config_file        = "./${var.firewall_policy_mode}${local.dedicated_mgmt}-${var.base_config_file}"
  management_device_index = var.firewall_policy_mode == "2-arm" ? 2 : 1

  # Subnet index offsets — mirrors aws_inspection_vpc/main.tf exactly
  # Ensures Green CIDRs are identical to Blue for the same subnet_bits value.
  subnet_index_addon_for_natgw      = local.enable_nat_gateway ? 1 : 0
  subnet_index_addon_for_management = var.enable_dedicated_management_eni ? 1 : 0
  subnet_index_add_natgw_mgmt       = 4 + local.subnet_index_addon_for_natgw + local.subnet_index_addon_for_management

  # AZ1 subnet CIDRs (base indexes: public=0, gwlbe=1, private=2, natgw=3, mgmt=4)
  public_subnet_cidr_az1     = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 0)
  gwlbe_subnet_cidr_az1      = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 1)
  private_subnet_cidr_az1    = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 2)
  natgw_subnet_cidr_az1      = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 3)
  management_subnet_cidr_az1 = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 4)

  # AZ2 subnet CIDRs (offset by subnet_index_add_natgw_mgmt)
  public_subnet_cidr_az2     = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 0 + local.subnet_index_add_natgw_mgmt)
  gwlbe_subnet_cidr_az2      = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 1 + local.subnet_index_add_natgw_mgmt)
  private_subnet_cidr_az2    = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 2 + local.subnet_index_add_natgw_mgmt)
  natgw_subnet_cidr_az2      = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 3 + local.subnet_index_add_natgw_mgmt)
  management_subnet_cidr_az2 = cidrsubnet(var.vpc_cidr_inspection, var.subnet_bits, 4 + local.subnet_index_add_natgw_mgmt)
}

# ==================================================================================
# VPC
# ==================================================================================

resource "aws_vpc" "green_inspection" {
  cidr_block           = var.vpc_cidr_inspection
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-vpc"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-vpc"
  }
}

resource "aws_default_route_table" "green_inspection" {
  default_route_table_id = aws_vpc.green_inspection.default_route_table_id
  tags = {
    Name = "${var.cp}-${var.env}${local.stack_infix}-inspection-default-rt (unused)"
  }
}

resource "aws_internet_gateway" "green_inspection" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-igw"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-igw"
  }
}

# ==================================================================================
# PUBLIC SUBNETS (FortiGate login / port1)
# ==================================================================================

resource "aws_subnet" "green_public_az1" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.public_subnet_cidr_az1
  availability_zone = local.availability_zone_1
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-az1"
  }
}
resource "aws_subnet" "green_public_az2" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.public_subnet_cidr_az2
  availability_zone = local.availability_zone_2
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-az2"
  }
}

resource "aws_route_table" "green_public_az1" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-rt-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-rt-az1"
  }
}
resource "aws_route_table" "green_public_az2" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-rt-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-public-rt-az2"
  }
}

resource "aws_route" "green_public_az1_igw" {
  route_table_id         = aws_route_table.green_public_az1.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}
resource "aws_route" "green_public_az2_igw" {
  route_table_id         = aws_route_table.green_public_az2.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}

resource "aws_route_table_association" "green_public_az1" {
  subnet_id      = aws_subnet.green_public_az1.id
  route_table_id = aws_route_table.green_public_az1.id
}
resource "aws_route_table_association" "green_public_az2" {
  subnet_id      = aws_subnet.green_public_az2.id
  route_table_id = aws_route_table.green_public_az2.id
}

# ==================================================================================
# GWLBE SUBNETS (Gateway Load Balancer Endpoints)
# ==================================================================================

resource "aws_subnet" "green_gwlbe_az1" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.gwlbe_subnet_cidr_az1
  availability_zone = local.availability_zone_1
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-az1"
  }
}
resource "aws_subnet" "green_gwlbe_az2" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.gwlbe_subnet_cidr_az2
  availability_zone = local.availability_zone_2
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-az2"
  }
}

resource "aws_route_table" "green_gwlbe_az1" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-rt-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-rt-az1"
  }
}
resource "aws_route_table" "green_gwlbe_az2" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-rt-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-gwlbe-rt-az2"
  }
}

resource "aws_route_table_association" "green_gwlbe_az1" {
  subnet_id      = aws_subnet.green_gwlbe_az1.id
  route_table_id = aws_route_table.green_gwlbe_az1.id
}
resource "aws_route_table_association" "green_gwlbe_az2" {
  subnet_id      = aws_subnet.green_gwlbe_az2.id
  route_table_id = aws_route_table.green_gwlbe_az2.id
}

# ==================================================================================
# PRIVATE SUBNETS (FortiGate internal port / TGW attachment)
# Default route to GWLB endpoints added in routes_green.tf after module runs.
# ==================================================================================

resource "aws_subnet" "green_private_az1" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.private_subnet_cidr_az1
  availability_zone = local.availability_zone_1
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-az1"
  }
}
resource "aws_subnet" "green_private_az2" {
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.private_subnet_cidr_az2
  availability_zone = local.availability_zone_2
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-az2"
  }
}

resource "aws_route_table" "green_private_az1" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-rt-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-rt-az1"
  }
}
resource "aws_route_table" "green_private_az2" {
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-rt-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-private-rt-az2"
  }
}

resource "aws_route_table_association" "green_private_az1" {
  subnet_id      = aws_subnet.green_private_az1.id
  route_table_id = aws_route_table.green_private_az1.id
}
resource "aws_route_table_association" "green_private_az2" {
  subnet_id      = aws_subnet.green_private_az2.id
  route_table_id = aws_route_table.green_private_az2.id
}

# ==================================================================================
# NAT GATEWAY SUBNETS AND NAT GATEWAYS (conditional on nat_gw mode)
#
# EIPs here are TEMPORARY. At cutover, the Blue NAT GW EIPs (known source IPs)
# are migrated to these NAT Gateways by the cutover script.
# ==================================================================================

resource "aws_subnet" "green_natgw_az1" {
  count             = local.enable_nat_gateway ? 1 : 0
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.natgw_subnet_cidr_az1
  availability_zone = local.availability_zone_1
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az1"
  }
}
resource "aws_subnet" "green_natgw_az2" {
  count             = local.enable_nat_gateway ? 1 : 0
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.natgw_subnet_cidr_az2
  availability_zone = local.availability_zone_2
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az2"
  }
}

resource "aws_route_table" "green_natgw_az1" {
  count  = local.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-rt-az1"
  }
}
resource "aws_route_table" "green_natgw_az2" {
  count  = local.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-rt-az2"
  }
}

resource "aws_route" "green_natgw_az1_igw" {
  count                  = local.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.green_natgw_az1[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}
resource "aws_route" "green_natgw_az2_igw" {
  count                  = local.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.green_natgw_az2[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}

resource "aws_route_table_association" "green_natgw_az1" {
  count          = local.enable_nat_gateway ? 1 : 0
  subnet_id      = aws_subnet.green_natgw_az1[0].id
  route_table_id = aws_route_table.green_natgw_az1[0].id
}
resource "aws_route_table_association" "green_natgw_az2" {
  count          = local.enable_nat_gateway ? 1 : 0
  subnet_id      = aws_subnet.green_natgw_az2[0].id
  route_table_id = aws_route_table.green_natgw_az2[0].id
}

# Temporary EIPs — replaced by Blue EIPs at cutover
resource "aws_eip" "green_natgw_az1" {
  count  = local.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags = {
    Name = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-eip-az1-temp"
  }
}
resource "aws_eip" "green_natgw_az2" {
  count  = local.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags = {
    Name = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-eip-az2-temp"
  }
}

resource "aws_nat_gateway" "green_az1" {
  count         = local.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.green_natgw_az1[0].id
  subnet_id     = aws_subnet.green_natgw_az1[0].id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az1"
  }
  depends_on = [aws_internet_gateway.green_inspection]
}
resource "aws_nat_gateway" "green_az2" {
  count         = local.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.green_natgw_az2[0].id
  subnet_id     = aws_subnet.green_natgw_az2[0].id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-natgw-az2"
  }
  depends_on = [aws_internet_gateway.green_inspection]
}

# ==================================================================================
# MANAGEMENT SUBNETS (conditional on dedicated management ENI mode)
# Only used when enable_dedicated_management_eni = true.
# When enable_dedicated_management_vpc = true, management ENIs go into the
# existing shared management VPC (discovered in management.tf).
# ==================================================================================

resource "aws_subnet" "green_management_az1" {
  count             = var.enable_dedicated_management_eni ? 1 : 0
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.management_subnet_cidr_az1
  availability_zone = local.availability_zone_1
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-az1"
  }
}
resource "aws_subnet" "green_management_az2" {
  count             = var.enable_dedicated_management_eni ? 1 : 0
  vpc_id            = aws_vpc.green_inspection.id
  cidr_block        = local.management_subnet_cidr_az2
  availability_zone = local.availability_zone_2
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-az2"
  }
}

resource "aws_route_table" "green_management_az1" {
  count  = var.enable_dedicated_management_eni ? 1 : 0
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-rt-az1"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-rt-az1"
  }
}
resource "aws_route_table" "green_management_az2" {
  count  = var.enable_dedicated_management_eni ? 1 : 0
  vpc_id = aws_vpc.green_inspection.id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-rt-az2"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-management-rt-az2"
  }
}

resource "aws_route" "green_management_az1_igw" {
  count                  = var.enable_dedicated_management_eni ? 1 : 0
  route_table_id         = aws_route_table.green_management_az1[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}
resource "aws_route" "green_management_az2_igw" {
  count                  = var.enable_dedicated_management_eni ? 1 : 0
  route_table_id         = aws_route_table.green_management_az2[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}

resource "aws_route_table_association" "green_management_az1" {
  count          = var.enable_dedicated_management_eni ? 1 : 0
  subnet_id      = aws_subnet.green_management_az1[0].id
  route_table_id = aws_route_table.green_management_az1[0].id
}
resource "aws_route_table_association" "green_management_az2" {
  count          = var.enable_dedicated_management_eni ? 1 : 0
  subnet_id      = aws_subnet.green_management_az2[0].id
  route_table_id = aws_route_table.green_management_az2[0].id
}
