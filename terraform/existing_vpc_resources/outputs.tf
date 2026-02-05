output "vpc_id" {
  value       = var.enable_build_management_vpc ? module.vpc-management[0].vpc_id : null
  description = "The VPC Id of the management VPC."
}
output "igw_id" {
  value       = var.enable_build_management_vpc ? module.vpc-management[0].igw_id : null
  description = "The IGW Id of the management VPC."
}
output "jump_box_public_ip" {
  value       = (var.enable_build_management_vpc && var.enable_jump_box && var.enable_jump_box_public_ip) ? aws_eip.jump_box_eip[0].public_ip : null
  description = "The public IP address of the jump box."
}
output "jump_box_private_ip" {
  value       = (var.enable_build_management_vpc && var.enable_jump_box) ? aws_instance.jump_box[0].private_ip : null
  description = "The private IP address of the jump box."
}
output "fortimanager_public_ip" {
  value = (local.enable_fortimanager_public_ip && var.enable_build_management_vpc) ? module.vpc-management[0].fortimanager_public_ip : null
  description = "The public IP address of the FortiManager."
}
output "fortimanager_private_ip" {
  value = (var.enable_fortimanager && var.enable_build_management_vpc) ? module.vpc-management[0].fortimanager_private_ip : null
  description = "The private IP address of the FortiManager."
}
output "fortianalyzer_public_ip" {
  value = (var.enable_fortianalyzer_public_ip && var.enable_fortianalyzer && var.enable_build_management_vpc) ? module.vpc-management[0].fortianalyzer_public_ip : null
  description = "The public IP address of the fortianalyzer."
}
output "fortianalyzer_private_ip" {
  value = (var.enable_fortianalyzer && var.enable_build_management_vpc) ? module.vpc-management[0].fortianalyzer_private_ip : null
  description = "The private IP address of the fortianalyzer."
}
output "east_vpc_id" {
  value = var.enable_build_existing_subnets ? module.vpc-east[0].vpc_id : null
  description = "The VPC Id of the east VPC."
}
output "west_vpc_id" {
  value = var.enable_build_existing_subnets ? module.vpc-west[0].vpc_id : null
  description = "The VPC Id of the west VPC."
}
#
# Inspection VPC Outputs
#
output "inspection_vpc_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].vpc_id : null
  description = "The VPC Id of the inspection VPC."
}
output "inspection_igw_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].igw_id : null
  description = "The IGW Id of the inspection VPC."
}
output "inspection_subnet_public_az1_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_public_az1_id : null
  description = "The subnet Id of the public subnet in AZ1."
}
output "inspection_subnet_public_az2_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_public_az2_id : null
  description = "The subnet Id of the public subnet in AZ2."
}
output "inspection_subnet_gwlbe_az1_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_gwlbe_az1_id : null
  description = "The subnet Id of the gwlbe subnet in AZ1."
}
output "inspection_subnet_gwlbe_az2_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_gwlbe_az2_id : null
  description = "The subnet Id of the gwlbe subnet in AZ2."
}
output "inspection_subnet_private_az1_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_private_az1_id : null
  description = "The subnet Id of the private subnet in AZ1."
}
output "inspection_subnet_private_az2_id" {
  value       = var.enable_build_inspection_vpc ? module.vpc-inspection[0].subnet_private_az2_id : null
  description = "The subnet Id of the private subnet in AZ2."
}
output "inspection_tgw_attachment_id" {
  value       = (var.enable_build_inspection_vpc && var.enable_build_existing_subnets) ? module.vpc-inspection[0].inspection_tgw_attachment_id : null
  description = "The transit gateway attachment id for the inspection VPC."
}

