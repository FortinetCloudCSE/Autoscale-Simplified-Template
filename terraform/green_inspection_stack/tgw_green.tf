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
  count              = var.enable_tgw_attachment ? 1 : 0
  vpc_id             = aws_vpc.green_inspection.id
  subnet_ids         = [aws_subnet.green_private_az1.id, aws_subnet.green_private_az2.id]
  transit_gateway_id = data.aws_ec2_transit_gateway.tgw[0].id
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

# Dedicated route table for the Green inspection attachment.
# The operator adds spoke VPC CIDR routes here so FortiGate return traffic
# can reach spoke VPCs through the TGW.
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
