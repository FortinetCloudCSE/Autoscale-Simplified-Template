variable "aws_region" {
  description = "The AWS region to use"
}
variable "additional_tags" {
  description = "Additional tags to apply to all resources. Merged with base tags in provider.tf default_tags, which propagates to every AWS resource in this template."
  type        = map(string)
  default     = {}
}
variable "availability_zone_1" {
  description = "Availability Zone 1 for VPC"
}
variable "availability_zone_2" {
  description = "Availability Zone 2 for VPC"
}
variable "availability_zone_3" {
  description = "Availability Zone 3 for VPC (optional, leave empty for 2-AZ deployments)"
  default     = ""
}
variable "cp" {
  description = "Customer Prefix to apply to all resources"
}
variable "env" {
  description = "The Tag Environment to differentiate prod/test/dev"
}
variable "subnet_bits" {
  description = "Number of bits in the network portion of the subnet CIDR"
}
variable "spoke_subnet_bits" {
  description = "Number of bits for spoke VPC subnet CIDR calculation"
  type        = number
  default     = 4
}
variable "keypair" {
  description = "Keypair for instances that support keypairs"
}
variable "management_cidr_sg" {
  description = "List of CIDRs to allow in security group for management access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "vpc_cidr_management" {
  description = "CIDR for the management VPC"
}
variable "vpc_cidr_inspection" {
  description = "CIDR for the inspection VPC"
  type        = string
  default     = "10.0.0.0/16"
}
variable "enable_autoscale_deployment" {
  description = "Deploy FortiGate AutoScale group with Gateway Load Balancer"
  type        = bool
  default     = true
}
variable "enable_ha_pair_deployment" {
  description = "Deploy FortiGate HA Pair with Active-Passive FGCP clustering"
  type        = bool
  default     = false
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
variable "create_tgw_routes_for_existing" {
  description = "Populate TGW route tables with routes between Management VPC and Spoke VPCs. Recommended for test environments only."
  type        = bool
  default     = false

  validation {
    condition     = !var.create_tgw_routes_for_existing || var.enable_build_existing_subnets
    error_message = "create_tgw_routes_for_existing can only be true when enable_build_existing_subnets is also true -- these routes point at the demo East/West spoke VPCs and TGW route tables that this template only builds in that mode. If you're attaching to an existing TGW (enable_build_existing_subnets = false), set this to false too."
  }
}
variable "use_propagations" {
  description = "Use TGW route table propagation instead of explicit static routes to exchange the East/West/Management VPC CIDRs across their TGW route tables. Only affects the CIDR-specific routes between the demo spokes and Management VPC -- the 0.0.0.0/0 default routes to the inspection VPC (which propagation cannot express) are unaffected and stay static either way."
  type        = bool
  default     = false

  validation {
    condition     = !var.use_propagations || var.enable_build_existing_subnets
    error_message = "use_propagations can only be true when enable_build_existing_subnets is also true -- it only applies to the demo East/West spoke and Management VPC TGW route tables this template builds in that mode."
  }
}
variable "enable_linux_spoke_instances" {
  description = "Boolean to allow creation of Linux Spoke Instances in East and West VPCs"
  type        = bool
}
variable "enable_windows_spoke_instances" {
  description = "Boolean to allow creation of one Windows Spoke Instance in each of the East and West VPCs (private only, reachable via jump box or FortiGate VIP)"
  type        = bool
  default     = false
}
variable "windows_instance_type" {
  description = "Windows Spoke Instance Type"
  type        = string
  default     = "t3.medium"
}
variable "windows_host_ip" {
  description = "Host portion of the Windows Spoke Instance IP address within the East/West public AZ1 subnets. Must not collide with linux_host_ip in the same subnets, and must fit within the subnet's host range (with the default spoke_subnet_bits = 4, subnets are /28 -- 16 addresses -- and AWS reserves the first 4 and the last, leaving host numbers roughly 4-14 usable)."
  type        = number
  default     = 13
}
variable "windows_keypair" {
  description = "Keypair for the Windows Spoke Instances. Must be an RSA-type keypair -- AWS rejects ED25519 keys for Windows AMIs with 'Unsupported: ED25519 key pairs are not supported with Windows AMIs', since Windows password retrieval (GetPasswordData) requires RSA encryption. This is deliberately separate from var.keypair, which may be ED25519 and is fine for Linux/FortiGate instances."
  type        = string
  default     = ""
}
variable "attach_to_tgw_name" {
  description = "Name of the TGW to attach to"
  type        = string
  default     = ""
}
variable "enable_tgw_attachment" {
  description = "Attach inspection VPC to Transit Gateway"
  type        = bool
  default     = false
}
variable "vpc_cidr_east" {
  description = "CIDR for the whole east VPC"
}
variable "vpc_cidr_west" {
  description = "CIDR for the whole west VPC"
}
#
# Distributed egress lab VPCs (dual-egress feature testing)
#
variable "enable_build_distributed_egress_vpcs" {
  description = "Boolean to build two lab distributed-egress VPCs for testing CIDR overlap behavior with the autoscale group's shared GWLB. Test-only scaffolding, not a production pattern."
  type        = bool
  default     = false
}
variable "vpc_cidr_distributed_1" {
  description = "CIDR for lab distributed-egress VPC #1. Must not overlap vpc_cidr_distributed_2 while testing the non-overlapping-CIDR baseline."
  type        = string
  default     = "10.100.0.0/24"
}
variable "vpc_cidr_distributed_2" {
  description = "CIDR for lab distributed-egress VPC #2. Must not overlap vpc_cidr_distributed_1 while testing the non-overlapping-CIDR baseline. Actual overlap check (range-based, not just network-address equality) lives in vpc_distributed_egress.tf as a check block, since a correct check needs locals a variable validation block can't reference."
  type        = string
  default     = "10.101.0.0/24"
}
variable "distributed_subnet_bits" {
  description = "Number of bits in the network portion of the subnet CIDR for distributed-egress VPCs (mirrors spoke_subnet_bits sizing since these are /24 VPCs, unlike the /16 inspection VPC)"
  type        = number
  default     = 4
}
variable "allow_distributed_cidr_overlap" {
  description = "Phase 2 of dual-egress testing: explicit opt-in to let vpc_cidr_distributed_1/_2 overlap, bypassing the non-overlap check in vpc_distributed_egress.tf. Only meaningful once the FortiGate ASG is actually running a build that can disambiguate traffic by GWLBe ID instead of by CIDR (e.g. the Sony GWLBe-keyed GENEVE test build) -- with standard FortiOS, overlapping CIDRs across these VPCs will be genuinely ambiguous to the inspecting FortiGate, not just a Terraform-level convenience toggle."
  type        = bool
  default     = false
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
  default     = true
}
variable "create_nat_gateway_subnets" {
  description = "Create NAT Gateway subnets for centralized internet egress"
  type        = bool
  default     = false
}
variable "create_management_subnet_in_inspection_vpc" {
  description = "Create dedicated management subnets and ENI in the inspection VPC"
  type        = bool
  default     = false
}
