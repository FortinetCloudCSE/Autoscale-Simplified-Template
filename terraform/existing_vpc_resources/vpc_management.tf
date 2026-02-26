locals {
  rfc1918_192 = "192.168.0.0/16"
}
locals {
  rfc1918_10 = "10.0.0.0/8"
}
locals {
  rfc1918_172 = "172.16.0.0/12"
}
resource "random_string" "random" {
  length           = 5
  special          = false
}

locals {
  faz_template_file = var.enable_fortianalyzer ? templatefile("${path.module}/config_templates/faz-userdata.tftpl", {
    faz_license_file   = var.fortianalyzer_license_file
    faz_vm_name        = var.fortianalyzer_vm_name
    faz_admin_password = var.fortianalyzer_admin_password
  }) : ""
}
locals {
  fmgr_template_file = var.enable_fortimanager ? templatefile("${path.module}/config_templates/fmgr-userdata.tftpl", {
    fmg_license_file   = var.fortimanager_license_file
    fmg_vm_name        = var.fortimanager_vm_name
    fmg_admin_password = var.fortimanager_admin_password
  }) : ""
}
module "vpc-management" {
  source                         = "git::https://github.com/40netse/terraform-modules.git//aws_management_vpc"
  count                          = var.enable_build_management_vpc ? 1 : 0
  depends_on                     = [ module.vpc-transit-gateway.tgw_id ]
  aws_region                     = var.aws_region
  cp                             = var.cp
  env                            = var.env
  vpc_name                       = "${var.cp}-${var.env}-management"
  vpc_cidr                       = var.vpc_cidr_management
  subnet_bits                    = var.subnet_bits
  availability_zone_1            = local.availability_zone_1
  availability_zone_2            = local.availability_zone_2
  named_tgw                      = var.attach_to_tgw_name
  enable_tgw_attachment          = local.enable_management_tgw_attachment
  acl                            = var.acl
  random_string                  = random_string.random.result
  keypair                        = var.keypair
  enable_fortianalyzer           = var.enable_fortianalyzer
  enable_fortianalyzer_public_ip = var.enable_fortianalyzer_public_ip
  enable_fortimanager            = var.enable_fortimanager
  enable_fortimanager_public_ip  = local.enable_fortimanager_public_ip
  enable_jump_box                = false
  enable_jump_box_public_ip      = false
  fortianalyzer_host_ip          = var.fortianalyzer_host_ip
  fortianalyzer_instance_type    = var.fortianalyzer_instance_type
  fortianalyzer_os_version       = var.fortianalyzer_os_version
  fortianalyzer_user_data        = local.faz_template_file
  fortimanager_host_ip           = var.fortimanager_host_ip
  fortimanager_instance_type     = var.fortimanager_instance_type
  fortimanager_os_version        = var.fortimanager_os_version
  fortimanager_user_data         = local.fmgr_template_file
  linux_host_ip                  = var.linux_host_ip
  linux_instance_type            = var.linux_instance_type
  vpc_cidr_sg                    = var.management_cidr_sg
}

#
# Fortinet-Role Tags for management VPC resource discovery by autoscale_template
#
resource "aws_ec2_tag" "management_vpc_role" {
  count       = var.enable_build_management_vpc ? 1 : 0
  resource_id = module.vpc-management[0].vpc_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-management-vpc"
}
resource "aws_ec2_tag" "management_subnet_public_az1_role" {
  count       = var.enable_build_management_vpc ? 1 : 0
  resource_id = module.vpc-management[0].subnet_management_public_az1_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-management-public-az1"
}
resource "aws_ec2_tag" "management_subnet_public_az2_role" {
  count       = var.enable_build_management_vpc ? 1 : 0
  resource_id = module.vpc-management[0].subnet_management_public_az2_id
  key         = "Fortinet-Role"
  value       = "${var.cp}-${var.env}-management-public-az2"
}

resource "aws_route" "management-public-default-route-igw" {
  depends_on             = [module.vpc-management]
  count                  = var.enable_build_management_vpc ? 1 : 0
  route_table_id         = module.vpc-management[0].route_table_management_public
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc-management[0].igw_id
}
#
# This is a bit bruce force. Route all the rfc-1918 space to the TGW. More specific route will handle the local traffic.
#

resource "aws_route" "public-192-route-tgw-az1" {
  depends_on             = [module.vpc-management]
  count                  = (var.enable_build_management_vpc && local.enable_management_tgw_attachment) ? 1 : 0
  route_table_id         = module.vpc-management[0].route_table_management_public
  destination_cidr_block = local.rfc1918_192
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "public-10-route-tgw" {
  depends_on             = [module.vpc-management]
  count                  = (var.enable_build_management_vpc && local.enable_management_tgw_attachment) ? 1 : 0
  route_table_id         = module.vpc-management[0].route_table_management_public
  destination_cidr_block = local.rfc1918_10
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_route" "public-172-route-tgw" {
  depends_on             = [module.vpc-management]
  count                  = (var.enable_build_management_vpc && local.enable_management_tgw_attachment) ? 1 : 0
  route_table_id         = module.vpc-management[0].route_table_management_public
  destination_cidr_block = local.rfc1918_172
  transit_gateway_id     = module.vpc-transit-gateway[0].tgw_id
}
resource "aws_ec2_transit_gateway_route" "route-to-west-tgw" {
  count                          = (local.enable_management_tgw_attachment && var.enable_build_management_vpc) ? 1 : 0
  depends_on                     = [module.vpc-management]
  destination_cidr_block         = var.vpc_cidr_west
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-west[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-management[0].management_tgw_route_table_id
}
resource "aws_ec2_transit_gateway_route" "route-to-east-tgw" {
  count                          = (local.enable_management_tgw_attachment && var.enable_build_management_vpc) ? 1 : 0
  depends_on                     = [module.vpc-management]
  destination_cidr_block         = var.vpc_cidr_east
  transit_gateway_attachment_id  = module.vpc-transit-gateway-attachment-east[0].tgw_attachment_id
  transit_gateway_route_table_id = module.vpc-management[0].management_tgw_route_table_id
}

#
# Jump Box - Created directly instead of via module for custom configuration
#
locals {
  jump_box_userdata = var.enable_jump_box ? templatefile("${path.module}/config_templates/jump-box-userdata.tftpl", {
    east_vpc_cidr = var.vpc_cidr_east
    west_vpc_cidr = var.vpc_cidr_west
  }) : ""
}

resource "aws_security_group" "jump_box_sg" {
  count       = (var.enable_build_management_vpc && var.enable_jump_box) ? 1 : 0
  name        = "${var.cp}-${var.env}-jump-box-sg"
  description = "Security group for jump box"
  vpc_id      = module.vpc-management[0].vpc_id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "All from RFC1918"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.rfc1918_10, local.rfc1918_172, local.rfc1918_192]
  }
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.cp}-${var.env}-jump-box-sg"
  }
}

resource "aws_instance" "jump_box" {
  count                  = (var.enable_build_management_vpc && var.enable_jump_box) ? 1 : 0
  depends_on             = [module.vpc-management, data.aws_ami.ubuntu]
  ami                    = data.aws_ami.ubuntu[0].id
  instance_type          = var.linux_instance_type
  key_name               = var.keypair
  subnet_id              = module.vpc-management[0].subnet_management_public_az1_id
  vpc_security_group_ids = [aws_security_group.jump_box_sg[0].id]
  private_ip             = cidrhost(cidrsubnet(var.vpc_cidr_management, var.subnet_bits, 0), var.linux_host_ip)
  user_data              = local.jump_box_userdata
  source_dest_check      = false  # Required for NAT functionality

  tags = {
    Name = "${var.cp}-${var.env}-jump-box"
  }
}

resource "aws_eip" "jump_box_eip" {
  count    = (var.enable_build_management_vpc && var.enable_jump_box && var.enable_jump_box_public_ip) ? 1 : 0
  instance = aws_instance.jump_box[0].id
  domain   = "vpc"

  tags = {
    Name = "${var.cp}-${var.env}-jump-box-eip"
  }
}

#
# Wait for jump box cloud-init to complete before creating spoke instances
# Spoke instances need the jump box NAT functionality to be ready for their cloud-init
#
resource "time_sleep" "wait_for_jump_box" {
  count           = (var.enable_build_management_vpc && var.enable_jump_box) ? 1 : 0
  depends_on      = [aws_instance.jump_box]
  create_duration = "5m"
}

#
# Default routes for private subnet route tables pointing to jump box ENI
# This allows traffic from spoke VPCs (via TGW) to NAT through the jump box
#
resource "aws_route" "private-az1-default-to-jump-box" {
  count                  = (var.enable_build_management_vpc && var.enable_jump_box) ? 1 : 0
  depends_on             = [aws_instance.jump_box]
  route_table_id         = module.vpc-management[0].route_table_management_private_az1
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.jump_box[0].primary_network_interface_id
}

resource "aws_route" "private-az2-default-to-jump-box" {
  count                  = (var.enable_build_management_vpc && var.enable_jump_box) ? 1 : 0
  depends_on             = [aws_instance.jump_box]
  route_table_id         = module.vpc-management[0].route_table_management_private_az2
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.jump_box[0].primary_network_interface_id
}
