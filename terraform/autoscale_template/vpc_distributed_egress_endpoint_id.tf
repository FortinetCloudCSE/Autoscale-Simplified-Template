#
# Mode B: overlapping-CIDR distributed egress via GENEVE endpoint-id (EXPERIMENTAL)
#
# See variables.tf for the enable_distributed_egress_endpoint_id / distributed_egress_routing_mode
# variables, and MODE_B_ENDPOINT_ID_GENEVE.md / content/5_Templates/5_7_Overlapping_CIDR_Egress
# for the full design writeup. This file only computes the extra data Mode B's *-fgt-conf.cfg.tftpl
# block needs beyond what Mode A (vpc_distributed_egress.tf) already discovers: each distributed
# VPC's per-AZ GWLB Endpoint id (vpce-id, to key each dedicated GENEVE tunnel) and the shared GWLB's
# own per-AZ IP (the remote-ip every tunnel -- centralized and distributed alike -- terminates to).
#
# REQUIRES an STS/test FortiOS build with `endpoint-id` support on `config system geneve`. Not
# available on any generally-available FortiOS release as of this writing.
#

#
# The vendored module's own "gwlb_ips" output (fortinetdev/cloud-modules/aws, examples wrapper,
# v1.1.5) is decorative, not usable data -- its value is a heredoc string with the real map baked
# into a `#` comment line inside it (confirmed by inspecting the vendored .terraform/modules copy),
# not an actual Terraform map/object. It can't be indexed. So the shared GWLB's per-AZ IP is
# rediscovered here directly, using the exact same aws_network_interface filter the vendored
# module's own modules/aws/gwlb submodule uses internally (description = "ELB gwy/<gwlb-name>/*",
# interface-type = gateway_load_balancer) -- this avoids depending on unreleased/patched upstream
# module changes, consistent with how the missing `service_name` output gap was worked around
# elsewhere in this template (tag-based lookup instead of a module fork).
#
# Two things confirmed the hard way via `terraform plan` against real infra, not assumed:
#   1. The module's real LB name is "${var.asg_module_prefix}-gwlb-fgt" (module adds its own
#      hyphen -- var.asg_module_prefix itself is "asg", no trailing hyphen).
#   2. The GWLB's own ENIs do NOT live in the subnets tagged/passed in as
#      "${cp}-${env}-inspection-gwlbe-azN" (data.aws_subnet.inspection_gwlbe_az1/az2 in
#      vpc_inspection.tf) -- that's a different subnet than where AWS actually places the GWLB's
#      load-balancer nodes. Keying off subnet-id is unreliable; keying off each ENI's own
#      `availability_zone` attribute directly is authoritative and avoids the mismatch entirely.
#
data "aws_network_interfaces" "shared_gwlb_intfs" {
  count = var.enable_distributed_egress_endpoint_id ? 1 : 0
  filter {
    name   = "description"
    values = ["ELB gwy/${var.asg_module_prefix}-gwlb-fgt/*"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.inspection.id]
  }
  filter {
    name   = "interface-type"
    values = ["gateway_load_balancer"]
  }
}
data "aws_network_interface" "shared_gwlb_intf" {
  for_each = var.enable_distributed_egress_endpoint_id ? toset(data.aws_network_interfaces.shared_gwlb_intfs[0].ids) : toset([])
  id       = each.value
}

locals {
  # Mode B is AZ1/AZ2 only -- matches Mode A's own distributed VPC scope (vpc_distributed_egress.tf
  # has no az3 handling for distributed VPCs today), independent of the centralized-side az_list
  # local, which does support az3.
  distributed_az_list = ["az1", "az2"]

  shared_gwlb_ip_by_az = var.enable_distributed_egress_endpoint_id ? {
    for intf in data.aws_network_interface.shared_gwlb_intf :
    (intf.availability_zone == local.availability_zone_1 ? "az1" : "az2") => intf.private_ip
  } : {}

  # Reuses the exact same gwlb_endps key format ("${spk_vpc key}-${subnet_id}") and subnet data
  # sources Mode A already discovers in vpc_distributed_egress.tf -- no new AWS lookups needed for
  # the vpce-ids themselves, only the shared GWLB IP above is genuinely new.
  distributed_1_vpce_by_az = var.enable_distributed_egress_endpoint_id ? {
    az1 = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az1[0].id}"]
    az2 = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az2[0].id}"]
  } : {}
  distributed_2_vpce_by_az = var.enable_distributed_egress_endpoint_id ? {
    az1 = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az1[0].id}"]
    az2 = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az2[0].id}"]
  } : {}

  # One entry per distributed VPC, shaped for a single loop in the .cfg.tftpl instead of
  # duplicating a block per VPC. distance_10_dst is the specific-CIDR RPF-satisfying static route
  # (see MODE_B_ENDPOINT_ID_GENEVE.md fix #2); policy_dst/policy_src are the router-policy dst/src
  # match values in FortiOS's dotted-netmask form ("x.x.x.x/y.y.y.y"), which is the form validated
  # live for these new rules -- distinct from config router static's separate "ip mask" pair format
  # used a few lines below in the .cfg.tftpl.
  distributed_egress_endpoint_id_devices = var.enable_distributed_egress_endpoint_id ? [
    {
      key        = "d1"
      zone       = "d1-zone"
      vrf        = var.distributed_1_vrf
      cidr       = data.aws_vpc.distributed_1[0].cidr_block
      vpce_by_az = local.distributed_1_vpce_by_az
    },
    {
      key        = "d2"
      zone       = "d2-zone"
      vrf        = var.distributed_2_vrf
      cidr       = data.aws_vpc.distributed_2[0].cidr_block
      vpce_by_az = local.distributed_2_vpce_by_az
    },
  ] : []
}
