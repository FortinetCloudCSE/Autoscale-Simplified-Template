#
# Outputs
#
# tgw_attachment_id and nat_gateway_* are the critical outputs for cutover.
# The operator uses tgw_attachment_id to update spoke TGW route tables.
# The cutover script uses nat_gateway_* to migrate Blue EIPs to Green NAT GWs.
#

output "green_vpc_id" {
  description = "Green inspection VPC ID"
  value       = aws_vpc.green_inspection.id
}

output "green_vpc_cidr" {
  description = "Green inspection VPC CIDR (identical to Blue)"
  value       = aws_vpc.green_inspection.cidr_block
}

# ── TGW ────────────────────────────────────────────────────────────────────────

output "green_tgw_attachment_id" {
  description = "Green inspection VPC TGW attachment ID. Update spoke TGW route tables to point here at cutover."
  value       = var.enable_tgw_attachment ? aws_ec2_transit_gateway_vpc_attachment.green_inspection[0].id : null
}

output "green_tgw_route_table_id" {
  description = "Green inspection TGW route table ID. Add spoke VPC CIDR routes here for FortiGate return-path routing."
  value       = var.enable_tgw_attachment ? aws_ec2_transit_gateway_route_table.green_inspection[0].id : null
}

# ── NAT Gateways (nat_gw mode only) ───────────────────────────────────────────

output "green_natgw_az1_id" {
  description = "Green NAT Gateway ID in AZ1. Cutover script migrates Blue EIP to this gateway."
  value       = local.enable_nat_gateway ? aws_nat_gateway.green_az1[0].id : null
}
output "green_natgw_az2_id" {
  description = "Green NAT Gateway ID in AZ2. Cutover script migrates Blue EIP to this gateway."
  value       = local.enable_nat_gateway ? aws_nat_gateway.green_az2[0].id : null
}

output "green_natgw_az1_temp_eip" {
  description = "Temporary EIP on Green NAT GW AZ1. Replaced by Blue EIP at cutover, then released."
  value       = local.enable_nat_gateway ? aws_eip.green_natgw_az1[0].public_ip : null
}
output "green_natgw_az2_temp_eip" {
  description = "Temporary EIP on Green NAT GW AZ2. Replaced by Blue EIP at cutover, then released."
  value       = local.enable_nat_gateway ? aws_eip.green_natgw_az2[0].public_ip : null
}

output "green_natgw_az1_eip_allocation_id" {
  description = "EIP allocation ID for Green NAT GW AZ1 temporary EIP"
  value       = local.enable_nat_gateway ? aws_eip.green_natgw_az1[0].id : null
}
output "green_natgw_az2_eip_allocation_id" {
  description = "EIP allocation ID for Green NAT GW AZ2 temporary EIP"
  value       = local.enable_nat_gateway ? aws_eip.green_natgw_az2[0].id : null
}

# ── Subnets ────────────────────────────────────────────────────────────────────

output "green_public_subnet_az1_id" {
  value = aws_subnet.green_public_az1.id
}
output "green_public_subnet_az2_id" {
  value = aws_subnet.green_public_az2.id
}
output "green_gwlbe_subnet_az1_id" {
  value = aws_subnet.green_gwlbe_az1.id
}
output "green_gwlbe_subnet_az2_id" {
  value = aws_subnet.green_gwlbe_az2.id
}
output "green_private_subnet_az1_id" {
  value = aws_subnet.green_private_az1.id
}
output "green_private_subnet_az2_id" {
  value = aws_subnet.green_private_az2.id
}

# ── GWLB Endpoints ─────────────────────────────────────────────────────────────

output "green_gwlb_endpoint_az1_id" {
  description = "Green GWLB endpoint ID in AZ1"
  value       = data.aws_vpc_endpoint.green_endpoint_az1.id
}
output "green_gwlb_endpoint_az2_id" {
  description = "Green GWLB endpoint ID in AZ2"
  value       = data.aws_vpc_endpoint.green_endpoint_az2.id
}
