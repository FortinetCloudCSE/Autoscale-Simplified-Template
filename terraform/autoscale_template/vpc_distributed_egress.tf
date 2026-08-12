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
