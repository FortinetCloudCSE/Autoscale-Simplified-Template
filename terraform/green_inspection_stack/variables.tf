variable "aws_region" {
  description = "The AWS region to use"
}
variable "availability_zone_1" {
  description = "Availability Zone 1 for VPC"
}
variable "availability_zone_2" {
  description = "Availability Zone 2 for VPC"
}
variable "subnet_bits" {
  description = "Number of bits in the network portion of the subnet CIDR. Must match Blue deployment."
  type        = number
}
variable "access_internet_mode" {
  description = "How FortiGates access the internet. 'nat_gw' or 'eip'. Must match Blue deployment."
  type        = string
  default     = "nat_gw"
}
variable "firewall_policy_mode" {
  description = "Firewall interface mode. '1-arm' or '2-arm'. Must match Blue deployment."
  type        = string
  default     = "2-arm"
}
variable "fortigate_gui_port" {
  description = "FortiGate GUI port"
  default     = 443
}
variable "keypair" {
  description = "EC2 keypair name for FortiGate instances"
}
variable "vpc_cidr_sg" {
  description = "List of CIDRs allowed in security group for management access"
  type        = list(string)
  default     = []
}
variable "cp" {
  description = "Customer prefix — must match Blue deployment (used for management VPC tag discovery)"
}
variable "env" {
  description = "Environment tag — must match Blue deployment (used for management VPC tag discovery)"
}
variable "enable_dedicated_management_vpc" {
  description = "Enable dedicated management interface in separate management VPC. Must match Blue deployment."
  type        = bool
}
variable "enable_dedicated_management_eni" {
  description = "Enable dedicated management ENI within the Green inspection VPC. Must match Blue deployment."
  type        = bool
}
variable "primary_scalein_protection" {
  description = "Enable scale-in protection on the primary FortiGate instance"
  type        = bool
  default     = true
}
variable "asg_module_prefix" {
  description = "Prefix for all Green ASG resources. Must be different from Blue to avoid naming collisions."
  type        = string
  default     = "green"
}
variable "stack_label" {
  description = "Label inserted between {cp}-{env} and -inspection-* in all VPC resource Name and Fortinet-Role tags. Default 'green' produces {cp}-{env}-green-inspection-* tags that do not collide with Blue's {cp}-{env}-inspection-* tags. After Blue is destroyed set to '' and run terraform apply to rename tags to the bare pattern compatible with autoscale_template data-source discovery for the next upgrade cycle."
  type        = string
  default     = "green"
}
variable "enable_tgw_attachment" {
  description = "Attach Green inspection VPC to an existing TGW. Must match Blue deployment."
  type        = bool
}
variable "attach_to_tgw_name" {
  description = "Name tag of the TGW to attach to. Same TGW as Blue."
  type        = string
  default     = ""
}
variable "allow_cross_zone_load_balancing" {
  description = "Allow GWLB to use healthy instances in a different zone"
  type        = bool
}
variable "vpc_cidr_inspection" {
  description = "CIDR for the Green inspection VPC. Must be identical to Blue inspection VPC CIDR."
}
variable "vpc_cidr_management" {
  description = "CIDR of the existing management VPC (shared with Blue, used for routing)"
  default     = ""
}
variable "vpc_cidr_spoke" {
  description = "Supernet CIDR covering all spoke VPCs (used in FortiGate routing config)"
  default     = ""
}
variable "endpoint_name_az1" {
  description = "Name tag of the GWLB endpoint in AZ1 created by the module (used for private subnet routing)"
  type        = string
  default     = ""
}
variable "endpoint_name_az2" {
  description = "Name tag of the GWLB endpoint in AZ2 created by the module (used for private subnet routing)"
  type        = string
  default     = ""
}
variable "fgt_instance_type" {
  description = "EC2 instance type for FortiGate instances"
  type        = string
  default     = ""
}
variable "fortios_version" {
  description = "Target FortiOS version for Green instances (e.g. '7.6.2')"
  type        = string
  default     = ""
}
variable "fortigate_asg_password" {
  description = "Admin password for FortiGate instances"
}
variable "asg_license_directory" {
  description = "S3 path to BYOL license files"
  type        = string
  default     = ""
}
variable "fortiflex_username" {
  description = "FortiFlex API username"
  type        = string
  default     = ""
}
variable "fortiflex_password" {
  description = "FortiFlex API password"
  type        = string
  default     = ""
}
variable "fortiflex_sn_list" {
  description = "List of FortiFlex serial numbers"
  type        = list(string)
  default     = [""]
}
variable "fortiflex_configid_list" {
  description = "List of FortiFlex config IDs"
  type        = list(string)
  default     = [""]
}
variable "base_config_file" {
  description = "FortiGate bootstrap config filename (e.g. 'fgt-conf.cfg')"
  type        = string
  default     = ""
}
variable "asg_byol_asg_min_size" {
  description = "Minimum size for the BYOL ASG"
  type        = number
}
variable "asg_byol_asg_max_size" {
  description = "Maximum size for the BYOL ASG"
  type        = number
}
variable "asg_byol_asg_desired_size" {
  description = "Desired size for the BYOL ASG"
  type        = number
}
variable "asg_ondemand_asg_min_size" {
  description = "Minimum size for the On-Demand ASG"
  type        = number
}
variable "asg_ondemand_asg_max_size" {
  description = "Maximum size for the On-Demand ASG"
  type        = number
}
variable "asg_ondemand_asg_desired_size" {
  description = "Desired size for the On-Demand ASG"
  type        = number
}
variable "enable_fortimanager_integration" {
  description = "Enable FortiManager integration. Green instances will connect with new serial numbers — requires re-authorization on FortiManager."
  type        = bool
  default     = false
}
variable "fortimanager_ip" {
  description = "FortiManager IP or FQDN"
  type        = string
  default     = ""
}
variable "fortimanager_sn" {
  description = "FortiManager serial number"
  type        = string
  default     = ""
}
variable "fortimanager_vrf_select" {
  description = "VRF for FortiManager connectivity"
  type        = number
  default     = 0
}
variable "gwlb_health_check_port" {
  description = "GWLB health check port (FortiGate probe-response port)"
  type        = number
}
variable "gwlb_health_check_interval" {
  description = "Interval in seconds between GWLB health checks"
  type        = number
}
variable "gwlb_healthy_threshold" {
  description = "Consecutive successes before a target is considered healthy"
  type        = number
}
variable "asg_health_check_grace_period" {
  description = "Seconds after launch before health checking begins"
  type        = number
}
