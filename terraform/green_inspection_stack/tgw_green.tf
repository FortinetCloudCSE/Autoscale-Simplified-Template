#
# Green TGW Attachment
#
# Creates a TGW attachment for the Green inspection VPC and a dedicated TGW
# route table for return-path routing (spoke CIDRs → Green FortiGates).
#
# IMPORTANT: This file does NOT modify any existing TGW route tables.
# Routing traffic through Green (cutover) is the operator's responsibility.
# The operator uses green_tgw_attachment_id from outputs to update their routes.
#
# The Green route table itself is filled in here (see "Return routes" below), so that
# traffic the Green FortiGates forward can reach the spoke and management VPCs as soon
# as the spoke routes are flipped.
#
# TGW propagation is disabled to prevent the Green VPC CIDR (identical to Blue)
# from conflicting with the already-propagated Blue VPC CIDR.
#

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

resource "aws_ec2_transit_gateway_vpc_attachment" "green_inspection" {
  count                  = var.enable_tgw_attachment ? 1 : 0
  vpc_id                 = aws_vpc.green_inspection.id
  subnet_ids             = [aws_subnet.green_private_az1.id, aws_subnet.green_private_az2.id]
  transit_gateway_id     = data.aws_ec2_transit_gateway.tgw[0].id
  appliance_mode_support = "enable"

  # Disable default route table association and propagation.
  # Green uses its own dedicated route table (below).
  # Propagation is disabled because Green and Blue share the same VPC CIDR —
  # propagating both would create a conflict in shared TGW route tables.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-tgw-attachment"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-tgw-attachment"
  }
}

# Dedicated route table for the Green inspection attachment. It holds the return
# routes below: the Transit Gateway uses it for everything that arrives from Green.
resource "aws_ec2_transit_gateway_route_table" "green_inspection" {
  count              = var.enable_tgw_attachment ? 1 : 0
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw[0].id
  tags = {
    Name          = "${var.cp}-${var.env}${local.stack_infix}-inspection-tgw-rtb"
    Fortinet-Role = "${var.cp}-${var.env}${local.stack_infix}-inspection-tgw-rtb"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "green_inspection" {
  count                          = var.enable_tgw_attachment ? 1 : 0
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.green_inspection[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.green_inspection[0].id
}

# ==================================================================================
# Return routes: Green inspection route table -> spoke and management VPCs
#
# Blue's inspection route table has a route to every VPC the FortiGates forward to
# (existing_vpc_resources: inspection-route-to-{east,west,management}-tgw, or the
# equivalent propagations when use_propagations = true). Green needs the same routes
# in its own table, or the Transit Gateway drops everything Green sends back.
#
# By default they are derived from the Transit Gateway itself: one static route per
# CIDR of every VPC attached to it, pointing at that VPC's attachment. VPCs whose
# primary CIDR equals vpc_cidr_inspection are skipped; that is Blue's inspection VPC
# and, once it exists, Green's own.
#
# Set tgw_return_routes to list the routes yourself instead. That is required when a
# destination is not a VPC in this account and region (VPN, Direct Connect, peering,
# or a VPC attached from another account), because those cannot be looked up here.
# ==================================================================================

locals {
  discover_tgw_return_routes = var.enable_tgw_attachment && var.tgw_return_routes == null
}

data "aws_ec2_transit_gateway_vpc_attachments" "on_tgw" {
  count = local.discover_tgw_return_routes ? 1 : 0
  filter {
    name   = "transit-gateway-id"
    values = [data.aws_ec2_transit_gateway.tgw[0].id]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_ec2_transit_gateway_vpc_attachment" "on_tgw" {
  for_each = local.discover_tgw_return_routes ? toset(data.aws_ec2_transit_gateway_vpc_attachments.on_tgw[0].ids) : toset([])
  id       = each.value
}

data "aws_vpc" "on_tgw" {
  for_each = data.aws_ec2_transit_gateway_vpc_attachment.on_tgw
  id       = each.value.vpc_id
}

locals {
  # { "<cidr>" = "<tgw attachment id>" }
  discovered_tgw_return_routes = merge([
    for attachment_id, vpc in data.aws_vpc.on_tgw : {
      for assoc in vpc.cidr_block_associations : assoc.cidr_block => attachment_id
      if assoc.state == "associated"
    } if vpc.cidr_block != var.vpc_cidr_inspection
  ]...)

  tgw_return_routes = !var.enable_tgw_attachment ? tomap({}) : (
    var.tgw_return_routes != null ? var.tgw_return_routes : local.discovered_tgw_return_routes
  )
}

resource "aws_ec2_transit_gateway_route" "green_return" {
  for_each                       = local.tgw_return_routes
  destination_cidr_block         = each.key
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.green_inspection[0].id
}
