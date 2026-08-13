#
# Distributed egress (dual-egress: centralized + distributed) -- attach a GWLB Endpoint to each
# distributed VPC, sharing the SAME GWLB Endpoint Service the centralized/Inspection VPC path
# uses (one shared GWLB, not one-per-distributed-VPC -- see project_dual_egress_design memory).
#
# This uses the upstream module's native `spk_vpc` variable with ONLY `gwlbe_subnet_ids` set
# (no `subnet_ids`). Confirmed safe: autoscale_group.tf already passes `existing_tgw = {}` to
# this module, which makes its internal module.transit-gw.tgw output resolve to null
# (modules/aws/tgw/main.tf:4 -- existing_tgw non-null-but-empty is the "no TGW at all" branch).
# Every spk_vpc code path that would create TGW attachments/route tables is gated on
# `module.transit-gw.tgw == null ? {} : var.spk_vpc`, so those are always empty here regardless
# of what we put in spk_vpc -- only the unconditional `gwlb_endps` merge (which only depends on
# gwlbe_subnet_ids) actually takes effect. No custom service_name lookup needed.
#
# Two discovery mechanisms feed the same pool, unioned and deduped by subnet ID:
#   1. Tag-based (Fortinet-Role) -- picks up the lab distributed VPCs existing_vpc_resources
#      builds. Terraform also owns route table mutation for these (we redirect the private
#      subnet's default route to the new endpoint below).
#   2. Explicit subnet ID list (distributed_egress_endpoint_subnet_ids) -- for a real customer's
#      pre-existing VPC we don't own. Endpoint gets created; route table is left untouched.
#

#
# Tag-discovered lab distributed VPCs
#
data "aws_vpc" "distributed_1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-vpc"]
  }
}
data "aws_vpc" "distributed_2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-vpc"]
  }
}

data "aws_subnet" "distributed_1_gwlbe_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-gwlbe-az1"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "distributed_1_gwlbe_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-gwlbe-az2"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "distributed_2_gwlbe_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-gwlbe-az1"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "distributed_2_gwlbe_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-gwlbe-az2"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Private (workload) route tables -- these are what get redirected to the new GWLB Endpoint below
data "aws_route_table" "distributed_1_private_rt_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-private-rt-az1"]
  }
}
data "aws_route_table" "distributed_1_private_rt_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-private-rt-az2"]
  }
}
data "aws_route_table" "distributed_2_private_rt_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-private-rt-az1"]
  }
}
data "aws_route_table" "distributed_2_private_rt_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-private-rt-az2"]
  }
}

#
# Explicit production subnet IDs (customer-owned VPCs we don't tag/discover). Grouped by VPC
# since spk_vpc needs one entry per VPC with its list of gwlbe_subnet_ids.
#
data "aws_subnet" "explicit_distributed_egress" {
  for_each = var.enable_distributed_egress ? toset(var.distributed_egress_endpoint_subnet_ids) : toset([])
  id       = each.value
}

locals {
  distributed_tag_discovered = var.enable_distributed_egress ? {
    distributed_1 = {
      vpc_id = data.aws_vpc.distributed_1[0].id
      gwlbe_subnet_ids = [
        data.aws_subnet.distributed_1_gwlbe_az1[0].id,
        data.aws_subnet.distributed_1_gwlbe_az2[0].id,
      ]
    }
    distributed_2 = {
      vpc_id = data.aws_vpc.distributed_2[0].id
      gwlbe_subnet_ids = [
        data.aws_subnet.distributed_2_gwlbe_az1[0].id,
        data.aws_subnet.distributed_2_gwlbe_az2[0].id,
      ]
    }
  } : {}

  distributed_explicit_by_vpc = {
    for vpc_id in distinct([for s in data.aws_subnet.explicit_distributed_egress : s.vpc_id]) :
    "explicit-${vpc_id}" => {
      vpc_id           = vpc_id
      gwlbe_subnet_ids = [for s in data.aws_subnet.explicit_distributed_egress : s.id if s.vpc_id == vpc_id]
    }
  }

  distributed_spk_vpc = merge(local.distributed_tag_discovered, local.distributed_explicit_by_vpc)
}

#
# Mode A (CIDR-based classification, standard FortiOS): the distributed VPCs' traffic arrives on
# the SAME shared geneve-azN tunnels the centralized/Inspection VPC path already uses, so no new
# zones/tunnels/policies are needed -- the existing "private_to_internet"/"private_to_private"
# firewall policies in the *-fgt-conf.cfg.tftpl templates are already srcaddr/dstaddr "all" and
# apply to anything in "private-zone". The one real gap is `config router static`, which is built
# from spoke_cidrs and needs an entry per distributed VPC CIDR so the FortiGate knows to route
# traffic destined for it back out the correct geneve device. Requires non-overlapping CIDRs
# (enforced by the `check` block in existing_vpc_resources/vpc_distributed_egress.tf) -- this is
# Mode A only. Mode B (overlapping CIDRs via endpoint-id-keyed tunnels) is a separate, on-hold
# design -- see project_dual_egress_design memory.
#
data "aws_vpc" "explicit_distributed_egress" {
  for_each = toset([for s in data.aws_subnet.explicit_distributed_egress : s.vpc_id])
  id       = each.key
}

locals {
  distributed_egress_cidrs = var.enable_distributed_egress ? distinct(concat(
    [data.aws_vpc.distributed_1[0].cidr_block, data.aws_vpc.distributed_2[0].cidr_block],
    [for v in data.aws_vpc.explicit_distributed_egress : v.cidr_block],
  )) : []
}

#
# Default route for each tag-discovered private subnet -- redirect to this VPC's own AZ-matched
# GWLB Endpoint. Key format ("${spk_vpc key}-${subnet_id}") matches the upstream module's own
# gwlb_endps merge (modules/aws/gwlb -- examples/.../main.tf ~line 516). Only for tag-discovered
# (Terraform-owned) infra -- explicit-list subnets never get their route table touched.
#
resource "aws_route" "distributed_1_private_default_route_gwlbe_az1" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_1_private_rt_az1[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az1[0].id}"]
}
resource "aws_route" "distributed_1_private_default_route_gwlbe_az2" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_1_private_rt_az2[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az2[0].id}"]
}
resource "aws_route" "distributed_2_private_default_route_gwlbe_az1" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_2_private_rt_az1[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az1[0].id}"]
}
resource "aws_route" "distributed_2_private_default_route_gwlbe_az2" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_2_private_rt_az2[0].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az2[0].id}"]
}

#
# Ingress Routing (IGW Edge Association) -- without this, traffic to the private subnet's EIP'd
# instance(s) goes straight from the IGW to the instance and back, never touching the FortiGate.
# One route table per VPC, associated with that VPC's IGW itself (not a subnet), holding one route
# per AZ: the AZ's private-subnet CIDR -> that AZ's GWLB Endpoint. The IGW's own post-NAT delivery
# (public IP -> private IP) is unaffected; this only intercepts where that post-NAT packet goes
# next, redirecting it to the FortiGate for inspection before it reaches the instance. Symmetric
# with the private subnet's own default route (above), which already sends the reply back out the
# same AZ's GWLBe -- both directions now hit the FortiGate. Tag-discovered (lab) VPCs only, same
# as the private-subnet route above -- customer-owned VPCs from distributed_egress_endpoint_subnet_ids
# never get their routing touched.
#
data "aws_internet_gateway" "distributed_1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-igw"]
  }
}
data "aws_internet_gateway" "distributed_2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-igw"]
  }
}

data "aws_subnet" "distributed_1_private_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-private-az1"]
  }
}
data "aws_subnet" "distributed_1_private_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-1-private-az2"]
  }
}
data "aws_subnet" "distributed_2_private_az1" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-private-az1"]
  }
}
data "aws_subnet" "distributed_2_private_az2" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = ["${var.cp}-${var.env}-distributed-2-private-az2"]
  }
}

# The reused aws_inspection_vpc module already creates and Edge-Associates its own "<vpc>-igw-rt"
# route table with this VPC's IGW (same pattern the Inspection VPC itself relies on) -- AWS only
# allows ONE route-table-to-gateway association per IGW, so we can't create a second one. Discover
# the existing table by its association instead of creating a new one.
data "aws_route_table" "distributed_1_ingress" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "association.gateway-id"
    values = [data.aws_internet_gateway.distributed_1[0].id]
  }
}
data "aws_route_table" "distributed_2_ingress" {
  count = var.enable_distributed_egress ? 1 : 0
  filter {
    name   = "association.gateway-id"
    values = [data.aws_internet_gateway.distributed_2[0].id]
  }
}

resource "aws_route" "distributed_1_ingress_to_gwlbe_az1" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_1_ingress[0].id
  destination_cidr_block = data.aws_subnet.distributed_1_private_az1[0].cidr_block
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az1[0].id}"]
}
resource "aws_route" "distributed_1_ingress_to_gwlbe_az2" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_1_ingress[0].id
  destination_cidr_block = data.aws_subnet.distributed_1_private_az2[0].cidr_block
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_1-${data.aws_subnet.distributed_1_gwlbe_az2[0].id}"]
}
resource "aws_route" "distributed_2_ingress_to_gwlbe_az1" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_2_ingress[0].id
  destination_cidr_block = data.aws_subnet.distributed_2_private_az1[0].cidr_block
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az1[0].id}"]
}
resource "aws_route" "distributed_2_ingress_to_gwlbe_az2" {
  count                  = var.enable_distributed_egress ? 1 : 0
  route_table_id         = data.aws_route_table.distributed_2_ingress[0].id
  destination_cidr_block = data.aws_subnet.distributed_2_private_az2[0].cidr_block
  vpc_endpoint_id        = module.spk_tgw_gwlb_asg_fgt_igw.gwlb_endps["distributed_2-${data.aws_subnet.distributed_2_gwlbe_az2[0].id}"]
}
