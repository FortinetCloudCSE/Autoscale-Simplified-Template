variable "aws_region" {
  description = "The AWS region to use"
}
variable "additional_tags" {
  description = "Additional tags to apply to all resources. Merged with base tags in provider.tf default_tags, which propagates to every AWS resource including those created by the upstream autoscale module."
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
variable subnet_bits {
  description = "Number of bits in the network portion of the subnet CIDR"
}
variable "public_subnet_index" {
  description = "Index of the public subnet"
  default = 0
}
variable "gwlbe_subnet_index" {
  description = "Index of the management subnet"
  default = 1
}
variable "private_subnet_index" {
  description = "Index of the private subnet"
  default = 2
}
variable "natgw_subnet_index" {
  description = "Index of the NAT GW subnet"
  default = 3
}
variable "access_internet_mode" {
  description = "Variable that defines how the fortigates in the autoscale group will access the internet. 'nat_gw' or 'eip'"
  type = string
  default = "nat_gw"
}
variable "fortigate_gui_port" {
  description = "Fortigate GUI Port"
  default = "443"
  type = string
}
variable "firewall_policy_mode" {
  description = "Firewall Policy Mode"
  type = string
  default = "2-arm"
}
variable "keypair" {
  description = "Keypair for instances that support keypairs"
}
variable "vpc_cidr_sg" {
    description = "List of CIDRs to allow in security group for management access"
    type        = list(string)
    default     = []
}
variable "cp" {
  description = "Customer Prefix to apply to all resources"
}
variable "env" {
  description = "The Tag Environment to differentiate prod/test/dev"
}
variable "enable_dedicated_management_vpc" {
  description = "Boolean to allow creation of dedicated management interface in management VPC"
  type        = bool
}
variable "enable_dedicated_management_eni" {
  description = "Boolean to allow creation of dedicated management subnets and ENI in the inspection VPC"
  type        = bool
}
variable "enable_fgt_management_public_ip" {
  description = "Boolean to attach a public IP to the FortiGate's dedicated management port (only relevant when enable_dedicated_management_vpc or enable_dedicated_management_eni is true)"
  type        = bool
  default     = true
}
variable "primary_scalein_protection" {
  description = "Boolean to set the scale-in protection for the primary instance in the autoscale group"
  type        = bool
  default     = true
}
variable "create_tgw_routes_for_existing" {
  description = "Boolean to allow creation of TGW routes for the existing_vpc_resources template"
  type        = bool
}
variable "enable_east_west_inspection" {
  description = "Boolean to allow creation of a separate autoscale group for east/west inspection"
  type        = bool
}
variable "enable_tgw_attachment" {
  description = "Allow Inspection VPC to attach to an existing TGW"
  type        = bool
}
variable "allow_cross_zone_load_balancing" {
  description = "Allow gateway load balancer to use healthy instances in a different zone"
  type        = bool
}
variable "asg_module_prefix" {
  description = "Module Prefix for East/West Autoscale Group"
  type        = string
  default     = ""
}
variable "vpc_cidr_inspection" {
    description = "CIDR for the whole NS inspection VPC"
}
variable "vpc_cidr_east" {
    description = "CIDR for the whole east VPC"
}
variable "vpc_cidr_west" {
    description = "CIDR for the whole west VPC"
}
variable "vpc_cidr_management" {
    description = "CIDR for the management VPC"
}
variable "spoke_cidrs" {
    description = "List of all spoke VPC CIDRs south of the TGW that need FortiGate east-west inspection routes. Leave empty to default to [vpc_cidr_east, vpc_cidr_west]; override with the real list of production spoke CIDRs if they differ from the demo east/west VPCs."
    type        = list(string)
    default     = []
}
variable "attach_to_tgw_name" {
  description = "Name of the TGW to attach to"
  type        = string
  default     = ""
}
#
# Distributed egress (dual-egress: centralized + distributed) feature
#
variable "enable_distributed_egress" {
  description = "Attach a GWLB Endpoint to each discovered distributed-egress VPC (tag-discovered lab VPCs from existing_vpc_resources, plus any explicit distributed_egress_endpoint_subnet_ids), sharing the same GWLB Endpoint Service used by the centralized/Inspection VPC path"
  type        = bool
  default     = false
}
variable "distributed_egress_endpoint_subnet_ids" {
  description = "Explicit list of GWLBe-placement subnet IDs in customer-owned distributed VPCs that this template doesn't otherwise discover via Fortinet-Role tags. A GWLB Endpoint is created in each, but -- unlike tag-discovered subnets -- their route tables are never modified; redirecting the customer's own route table to the new endpoint is left to the customer."
  type        = list(string)
  default     = []
}
variable "endpoint_name_az1" {
  description = "Name of the gwlb endpoint to route to in AZ1"
  type        = string
  default     = ""
}
variable "endpoint_name_az2" {
  description = "Name of the gwlb endpoint to route to in AZ2"
  type        = string
  default     = ""
}
variable "endpoint_name_az3" {
  description = "Name of the gwlb endpoint to route to in AZ3"
  type        = string
  default     = ""
}
#
# Overlapping-CIDR distributed egress via GENEVE endpoint-id (EXPERIMENTAL)
#
# Requires an STS/test FortiOS build with `endpoint-id` support on `config system geneve` --
# not available on any generally-available FortiOS release as of this writing. See
# OVERLAPPING_CIDR_GENEVE_ENDPOINT_ID.md at the repo root and
# content/5_Templates/5_7_Overlapping_CIDR_Egress for full detail. Reuses the same
# distributed_1/distributed_2 VPCs as the non-overlapping-CIDR design (enable_distributed_egress)
# -- this only changes HOW the FortiGate classifies their traffic (GENEVE tunnel identity instead
# of CIDR address), which is what allows vpc_cidr_distributed_1/vpc_cidr_distributed_2 to overlap.
#
variable "enable_distributed_egress_endpoint_id" {
  description = "Classify distributed_1/distributed_2 traffic by GENEVE endpoint-id (dedicated per-VPC tunnels) instead of CIDR address, removing the non-overlapping-CIDR requirement. Requires enable_distributed_egress = true and an STS FortiOS build with endpoint-id support. EXPERIMENTAL."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_distributed_egress_endpoint_id || var.enable_distributed_egress
    error_message = "enable_distributed_egress_endpoint_id requires enable_distributed_egress = true -- it reuses the non-overlapping-CIDR design's distributed VPC discovery and GWLB Endpoint attachment, it only changes how the FortiGate classifies the resulting traffic."
  }
}
variable "distributed_egress_routing_mode" {
  description = "Only used when enable_distributed_egress_endpoint_id is true. \"flat\" (default): all distributed devices share the default routing table (VRF 0), disambiguated by router-policy pinning -- confirmed via direct retest to be just as reliable as \"vrf\" once the specific-CIDR static route and CIDR-paired policy routes turned out to be unnecessary under either approach, so flat is the simpler default. \"vrf\": distributed_1/distributed_2 each get their own VRF (distributed_1_vrf/distributed_2_vrf) instead, trading a larger config footprint for routing-table-level isolation on top of the existing zone/firewall-policy isolation. See the Flat vs. VRF comparison in content/5_Templates/5_7_Overlapping_CIDR_Egress."
  type        = string
  default     = "flat"
  validation {
    condition     = contains(["flat", "vrf"], var.distributed_egress_routing_mode)
    error_message = "distributed_egress_routing_mode must be \"flat\" or \"vrf\"."
  }
}
variable "distributed_1_vrf" {
  description = "VRF ID for distributed_1's GENEVE tunnels. Only used when distributed_egress_routing_mode = \"vrf\". Must differ from distributed_2_vrf and from VRF 1 (already used by the dedicated management interface, port3)."
  type        = number
  default     = 100
}
variable "distributed_2_vrf" {
  description = "VRF ID for distributed_2's GENEVE tunnels. Only used when distributed_egress_routing_mode = \"vrf\". Must differ from distributed_1_vrf and from VRF 1 (already used by the dedicated management interface, port3)."
  type        = number
  default     = 200
}
variable "fgt_instance_type" {
  description = "Instance type for all of the Fortigates in the ASG's"
  type        = string
  default     = ""
}
variable "fortios_version" {
  description = "FortiGate OS Version of all instances in the Autoscale Groups"
  type        = string
  default     = ""
}
variable "fortigate_asg_password" {
  description = "Password for the Fortigate ASG"
}
variable "asg_license_directory" {
  description = "License Directory for North/South Autoscale Group"
  type        = string
  default     = ""
}
variable "fortiflex_username" {
  description = "Fortiflex Username to make FortiFlex API Calls"
  type        = string
  default     = ""
}
variable "fortiflex_password" {
    description = "Fortiflex Password to make FortiFlex API Calls"
    type        = string
    default     = ""
}
variable fortiflex_sn_list {
    description = "List of Serial Numbers for FortiFlex"
    type = list(string)
    default = [""]
}
variable fortiflex_configid_list {
    description = "Config ID for FortiFlex"
    type = list(string)
    default = [""]
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
    description = "Minimum size for the On Demand ASG"
    type        = number
}
variable "asg_ondemand_asg_max_size" {
    description = "Maximum size for the OnDemand ASG"
    type        = number
}
variable "asg_ondemand_asg_desired_size" {
    description = "Desired size for the OnDemand ASG"
    type        = number
}
variable "enable_fortimanager_integration" {
  description = "Boolean to enable FortiManager integration"
  type        = bool
  default     = false
}
variable "fortimanager_ip" {
  description = "IP address of the FortiManager"
  type        = string
  default     = ""
}
variable "fortimanager_sn" {
  description = "Serial Number of the FortiManager"
  type        = string
  default     = ""
}
variable "fortimanager_vrf_select" {
  description = "VRF to use to reach the Fortianager"
  type        = number
  default     = 0
}

variable "modify_existing_route_tables" {
  description = "Boolean to allow modification of existing route tables in the inspection VPC. When true, routes will be added to point private subnets to GWLB endpoints."
  type        = bool
  default     = true
}

variable "gwlb_health_check_port" {
  description = "Port for GWLB health check. Uses FortiGate probe-response port so health checks gate on config sync completion."
  type        = number
}

variable "gwlb_health_check_interval" {
  description = "Interval in seconds between GWLB health checks."
  type        = number
}

variable "gwlb_healthy_threshold" {
  description = "Number of consecutive health check successes required before considering a target healthy."
  type        = number
}

variable "asg_health_check_grace_period" {
  description = "Time in seconds after instance comes into service before health checking begins."
  type        = number
}
