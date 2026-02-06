variable "aws_region" {
  description = "The AWS region to use"
}
variable "availability_zone_1" {
  description = "Availability Zone 1 for VPC"
}
variable "availability_zone_2" {
  description = "Availability Zone 2 for VPC"
}
variable "cp" {
  description = "Customer Prefix to apply to all resources"
}
variable "env" {
  description = "The Tag Environment to differentiate prod/test/dev"
}
variable subnet_bits {
  description = "Number of bits in the network portion of the subnet CIDR"
}
variable "keypair" {
  description = "Keypair for instances that support keypairs"
}
variable "vpc_cidr_sg" {
    description = "List of CIDRs to allow in security group for management access"
    type        = list(string)
    default     = []
}
variable "vpc_cidr_management" {
    description = "CIDR for the management VPC"
}
variable "vpc_cidr_ns_inspection" {
    description = "CIDR for the inspection VPC"
}
variable "enable_fortimanager" {
  description = "Boolean to allow creation of FortiManager in Inspection VPC"
  type        = bool
}
variable "enable_fortimanager_public_ip" {
  description = "Boolean to allow creation of FortiManager public IP in Inspection VPC"
  type        = bool
}
variable "fortimanager_instance_type" {
  description = "Instance type for fortimanager"
}
variable "fortimanager_os_version" {
  description = "Fortimanager OS Version for the AMI Search String"
}
variable "fortimanager_host_ip" {
  description = "Fortimanager IP Address"
}
variable "fortimanager_license_file" {
  description = "Full path for FortiManager License"
  type        = string
  default     = ""
}
variable "fortimanager_vm_name" {
  description = "FortiManager VM Name"
  type        = string
  default     = ""
}
variable "fortimanager_admin_password" {
  description = "FortiManager Admin Password"
  type        = string
  default     = ""
}
variable "enable_fortianalyzer" {
  description = "Boolean to allow creation of FortiAnalyzer in Inspection VPC"
  type        = bool
}
variable "enable_fortianalyzer_public_ip" {
  description = "Boolean to allow creation of FortiAnalyzer public IP in Inspection VPC"
  type        = bool
}
variable "fortianalyzer_host_ip" {
  description = "Fortianalyzer IP Address"
}
variable "fortianalyzer_instance_type" {
  description = "Instance type for fortianalyzer"
}
variable "fortianalyzer_os_version" {
  description = "Fortianalyzer OS Version for the AMI Search String"
}
variable "fortianalyzer_license_file" {
  description = "Full path for FortiAnalyzer License"
  type        = string
  default     = ""
}
variable "fortianalyzer_vm_name" {
  description = "fortianalyzer VM Name"
  type        = string
  default     = ""
}
variable "fortianalyzer_admin_password" {
  description = "fortianalyzer Admin Password"
  type        = string
  default     = ""
}
variable "enable_jump_box" {
  description = "Boolean to allow creation of Linux Jump Box in Inspection VPC"
  type        = bool
}
variable "enable_jump_box_public_ip" {
  description = "Boolean to allow creation of Linux Jump Box public IP in Inspection VPC"
  type        = bool
}
variable "linux_instance_type" {
  description = "Linux Endpoint Instance Type"
}
variable "linux_host_ip" {
  description = "Fortigate Host IP for all subnets"
}
variable "enable_build_existing_subnets" {
  description = "Enable building the existing subnets behind the TGW"
  type        = bool
}
variable "enable_build_management_vpc" {
  description = "Enable building the management vpc"
  type        = bool
}
variable "enable_management_tgw_attachment" {
  description = "Allow Management VPC to attach to an existing TGW"
  type        = bool
}
variable "enable_spoke_tgw_default_route_to_management" {
  description = "Create default routes (0.0.0.0/0) from spoke TGW route tables to management VPC. Set to false when autoscale_template takes over routing."
  type        = bool
  default     = true
}
variable "enable_linux_spoke_instances" {
  description = "Boolean to allow creation of Linux Spoke Instances in East and West VPCs"
  type        = bool
}
variable "attach_to_tgw_name" {
  description = "Name of the TGW to attach to"
  type        = string
  default     = ""
}
variable "vpc_cidr_east" {
    description = "CIDR for the whole east VPC"
}
variable "vpc_cidr_spoke" {
    description = "Super-Net CIDR for the spoke VPC's"
}
variable "vpc_cidr_east_public_az1" {
    description = "CIDR for the AZ1 public subnet in East VPC"
}
variable "vpc_cidr_east_public_az2" {
    description = "CIDR for the AZ2 public subnet in East VPC"
}
variable "vpc_cidr_east_tgw_az1" {
    description = "CIDR for the AZ1 TGW attachment subnet in East VPC"
}
variable "vpc_cidr_east_tgw_az2" {
    description = "CIDR for the AZ2 TGW attachment subnet in East VPC"
}
variable "vpc_cidr_west" {
    description = "CIDR for the whole west VPC"
}
variable "vpc_cidr_west_public_az1" {
    description = "CIDR for the AZ1 public subnet in west VPC"
}
variable "vpc_cidr_west_public_az2" {
    description = "CIDR for the AZ2 public subnet in west VPC"
}
variable "vpc_cidr_west_tgw_az1" {
    description = "CIDR for the AZ1 TGW attachment subnet in West VPC"
}
variable "vpc_cidr_west_tgw_az2" {
    description = "CIDR for the AZ2 TGW attachment subnet in West VPC"
}
variable "acl" {
  description = "The acl for linux instances"
}
#
# Inspection VPC Variables
#
variable "enable_build_inspection_vpc" {
  description = "Enable building the inspection VPC"
  type        = bool
}
variable "inspection_access_internet_mode" {
  description = "Variable that defines how the fortigates in the autoscale group will access the internet. 'nat_gw' or 'eip'"
  type        = string
  default     = "nat_gw"
}
variable "inspection_enable_dedicated_management_eni" {
  description = "Boolean to allow creation of dedicated management subnets and ENI in the inspection VPC"
  type        = bool
  default     = false
}
