#
# Green inspection VPC private subnet routes → GWLB endpoints
#
# Must run after the ASG module creates GWLB endpoints.
# Endpoint names are set by the module using asg_module_prefix.
# Set endpoint_name_az1 / endpoint_name_az2 in tfvars to match.
#

data "aws_vpc_endpoint" "green_endpoint_az1" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  vpc_id     = aws_vpc.green_inspection.id
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az1]
  }
}
data "aws_vpc_endpoint" "green_endpoint_az2" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  vpc_id     = aws_vpc.green_inspection.id
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az2]
  }
}

#
# GWLB endpoint subnet routes
#
# Traffic the FortiGates have inspected comes back out of the GWLB endpoints, so these
# route tables decide where it goes next. Mirrors existing_vpc_resources
# (inspection-gwlbe-default-route-igw-* and inspection-gwlbe-{192,10,172}-route-tgw-*):
# RFC1918 destinations go to the Transit Gateway, everything else to the internet gateway.
# Without the RFC1918 routes nothing the FortiGates forward can reach a spoke VPC.
#
locals {
  rfc1918_cidrs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

resource "aws_route" "green_gwlbe_az1_igw" {
  route_table_id         = aws_route_table.green_gwlbe_az1.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}
resource "aws_route" "green_gwlbe_az2_igw" {
  route_table_id         = aws_route_table.green_gwlbe_az2.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.green_inspection.id
}

# A route to the Transit Gateway is only accepted once this VPC is attached to it.
resource "aws_route" "green_gwlbe_az1_tgw" {
  for_each               = var.enable_tgw_attachment ? toset(local.rfc1918_cidrs) : toset([])
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.green_inspection]
  route_table_id         = aws_route_table.green_gwlbe_az1.id
  destination_cidr_block = each.value
  transit_gateway_id     = data.aws_ec2_transit_gateway.tgw[0].id
}
resource "aws_route" "green_gwlbe_az2_tgw" {
  for_each               = var.enable_tgw_attachment ? toset(local.rfc1918_cidrs) : toset([])
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.green_inspection]
  route_table_id         = aws_route_table.green_gwlbe_az2.id
  destination_cidr_block = each.value
  transit_gateway_id     = data.aws_ec2_transit_gateway.tgw[0].id
}

resource "aws_route" "green_private_az1_gwlbe" {
  route_table_id         = aws_route_table.green_private_az1.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.green_endpoint_az1.id
}
resource "aws_route" "green_private_az2_gwlbe" {
  route_table_id         = aws_route_table.green_private_az2.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.green_endpoint_az2.id
}
