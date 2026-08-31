#
# Dedicated NAT Gateway for the management VPC -- see var.enable_dedicated_management_nat_gateway
# for the full rationale. Single NAT Gateway, placed in AZ1 alongside FortiManager/FortiAnalyzer/
# the jump box, since traffic here (FortiGuard updates, license verification) is expected to
# be small and infrequent. FortiGate management interfaces in AZ2/AZ3 (if present) will incur
# a cross-AZ hop to reach it -- accepted tradeoff for a single NAT Gateway rather than one per AZ.
#

locals {
  # Carve the NAT Gateway subnet as a /28 out of the unused index-6 slot -- indices 0-5 (at
  # var.subnet_bits) are already consumed by the public/private az1-3 subnets the
  # aws_management_vpc module creates internally. Nesting one more cidrsubnet call down
  # to a /28 avoids wasting a full subnet_bits-sized block on something that only ever
  # holds one ENI (a NAT Gateway needs exactly 1 IP; /28 is AWS's enforced subnet floor).
  management_nat_gateway_subnet_block = cidrsubnet(var.vpc_cidr_management, var.subnet_bits, 6)
  management_nat_gateway_subnet_cidr  = cidrsubnet(local.management_nat_gateway_subnet_block, 4, 0)
}

resource "aws_subnet" "management_nat_gateway" {
  count             = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  depends_on        = [module.vpc-management]
  vpc_id            = module.vpc-management[0].vpc_id
  cidr_block        = local.management_nat_gateway_subnet_cidr
  availability_zone = local.availability_zone_1

  tags = merge({ Name = "${var.cp}-${var.env}-management-nat-gateway-subnet" }, local.common_tags)
}

resource "aws_eip" "management_nat_gateway" {
  count  = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  domain = "vpc"

  tags = merge({ Name = "${var.cp}-${var.env}-management-nat-gateway-eip" }, local.common_tags)
}

resource "aws_nat_gateway" "management" {
  count         = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  depends_on    = [module.vpc-management]
  allocation_id = aws_eip.management_nat_gateway[0].id
  subnet_id     = aws_subnet.management_nat_gateway[0].id

  tags = merge({ Name = "${var.cp}-${var.env}-management-nat-gateway" }, local.common_tags)
}

# The NAT Gateway's own subnet needs its own route table with a default route to the IGW --
# it can't share the public route table it's redirecting away from the IGW in vpc_management.tf.
resource "aws_route_table" "management_nat_gateway" {
  count      = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  depends_on = [module.vpc-management]
  vpc_id     = module.vpc-management[0].vpc_id

  tags = merge({ Name = "${var.cp}-${var.env}-management-nat-gateway-rt" }, local.common_tags)
}

resource "aws_route" "management_nat_gateway_default_igw" {
  count                  = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  route_table_id         = aws_route_table.management_nat_gateway[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-management[0].igw_id
}

resource "aws_route_table_association" "management_nat_gateway" {
  count          = (var.enable_build_management_vpc && var.enable_dedicated_management_nat_gateway) ? 1 : 0
  subnet_id      = aws_subnet.management_nat_gateway[0].id
  route_table_id = aws_route_table.management_nat_gateway[0].id
}
