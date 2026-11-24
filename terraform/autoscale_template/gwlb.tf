#
# Shared Gateway Load Balancer and FortiGate slots
#
# The GWLB and its single listener are created here, at the root, not by the Fortinet module.
# The endpoint service and the GWLB endpoints (inspection VPC and distributed VPCs) are created
# by the "blue" module call (autoscale_group.tf), which is never removed: when the blue slot is
# not in use, that call keeps the endpoints and has no FortiGates.
#
# Each entry of fgt_slots, "blue" or "green", is one FortiGate autoscale group: one module call
# plus its own target group below. The listener forwards to the target group of active_slot.
# A blue-green upgrade in the same VPC:
#
#   1. add a "green" slot with the new fortios_version          -> creates only green resources
#   2. restore the Blue configuration on Green's primary
#   3. set active_slot = "green"                                 -> changes only the listener
#   4. remove the "blue" slot after Blue has drained             -> destroys only blue resources
#
# A GWLB has one listener only, so neither module call creates a target group or listener
# (existing_gwlb_tgp = {}).
#

locals {
  shared_prefix = var.asg_module_prefix == "" ? "" : "${var.asg_module_prefix}-"

  # Without fgt_slots, one "blue" slot is built from the top-level variables, so an existing
  # terraform.tfvars keeps working unchanged.
  # Every attribute is listed (null = use the top-level variable) so both branches have the same type.
  fgt_slots_input = length(var.fgt_slots) > 0 ? var.fgt_slots : {
    blue = {
      name_prefix                   = null
      fortios_version               = null
      fgt_instance_type             = null
      fortiflex_sn_list             = null
      asg_byol_asg_min_size         = null
      asg_byol_asg_max_size         = null
      asg_byol_asg_desired_size     = null
      asg_ondemand_asg_min_size     = null
      asg_ondemand_asg_max_size     = null
      asg_ondemand_asg_desired_size = null
    }
  }
  # Fixed name prefixes: "blue" keeps asg_module_prefix, so a deployment made before the
  # slots keeps its AWS names; "green" defaults to "<asg_module_prefix>-green".
  slot_prefix = {
    blue  = var.asg_module_prefix
    green = var.asg_module_prefix == "" ? "green" : "${var.asg_module_prefix}-green"
  }
  fgt_slots = {
    for k, v in local.fgt_slots_input : k => {
      name_prefix                   = k == "green" && v.name_prefix != null ? v.name_prefix : local.slot_prefix[k]
      fortios_version               = v.fortios_version != null ? v.fortios_version : var.fortios_version
      fgt_instance_type             = v.fgt_instance_type != null ? v.fgt_instance_type : var.fgt_instance_type
      fortiflex_sn_list             = v.fortiflex_sn_list != null ? v.fortiflex_sn_list : var.fortiflex_sn_list
      asg_byol_asg_min_size         = v.asg_byol_asg_min_size != null ? v.asg_byol_asg_min_size : var.asg_byol_asg_min_size
      asg_byol_asg_max_size         = v.asg_byol_asg_max_size != null ? v.asg_byol_asg_max_size : var.asg_byol_asg_max_size
      asg_byol_asg_desired_size     = v.asg_byol_asg_desired_size != null ? v.asg_byol_asg_desired_size : var.asg_byol_asg_desired_size
      asg_ondemand_asg_min_size     = v.asg_ondemand_asg_min_size != null ? v.asg_ondemand_asg_min_size : var.asg_ondemand_asg_min_size
      asg_ondemand_asg_max_size     = v.asg_ondemand_asg_max_size != null ? v.asg_ondemand_asg_max_size : var.asg_ondemand_asg_max_size
      asg_ondemand_asg_desired_size = v.asg_ondemand_asg_desired_size != null ? v.asg_ondemand_asg_desired_size : var.asg_ondemand_asg_desired_size
    }
  }

  # Autoscale group names the module gives each slot (module_prefix + "-" + the asgs key).
  slot_asgs = merge([
    for k, v in local.fgt_slots : merge(
      { "${k}/byol" = { slot = k, name = "${v.name_prefix}-fgt_byol_asg" } },
      v.asg_ondemand_asg_max_size > 0 ? { "${k}/ondemand" = { slot = k, name = "${v.name_prefix}-fgt_on_demand_asg" } } : {}
    )
  ]...)

  # GWLB subnets: the FortiGate interface that carries the GENEVE tunnels.
  gwlb_subnet_ids = concat(
    var.firewall_policy_mode == "1-arm"
    ? [data.aws_subnet.inspection_public_az1.id, data.aws_subnet.inspection_public_az2.id]
    : [data.aws_subnet.inspection_private_az1.id, data.aws_subnet.inspection_private_az2.id],
    var.availability_zone_3 == "" ? [] : (
      var.firewall_policy_mode == "1-arm"
      ? [data.aws_subnet.inspection_public_az3[0].id]
      : [data.aws_subnet.inspection_private_az3[0].id]
    )
  )

}

check "fgt_slots" {
  assert {
    condition     = contains(keys(local.fgt_slots), var.active_slot)
    error_message = "active_slot (\"${var.active_slot}\") must be one of the fgt_slots keys: ${join(", ", keys(local.fgt_slots))}."
  }
  assert {
    condition     = length(distinct([for v in local.fgt_slots : v.name_prefix])) == length(local.fgt_slots)
    error_message = "The green slot's name_prefix must differ from asg_module_prefix."
  }
  assert {
    condition     = try(var.fgt_slots["blue"].name_prefix, null) == null || try(var.fgt_slots["blue"].name_prefix, null) == var.asg_module_prefix
    error_message = "The blue slot always uses asg_module_prefix as its name_prefix; leave name_prefix out of fgt_slots.blue."
  }
}

resource "aws_lb" "gwlb" {
  name                             = "${local.shared_prefix}gwlb-fgt"
  load_balancer_type               = "gateway"
  enable_cross_zone_load_balancing = var.allow_cross_zone_load_balancing
  subnets                          = local.gwlb_subnet_ids
  tags                             = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "slot" {
  for_each = local.fgt_slots

  name                 = "${each.value.name_prefix}-gwlb-tgp-fgt"
  vpc_id               = data.aws_vpc.inspection.id
  target_type          = "instance"
  deregistration_delay = 30
  protocol             = "GENEVE"
  port                 = "6081"

  health_check {
    port              = var.gwlb_health_check_port
    protocol          = "HTTP"
    path              = "/"
    matcher           = "200-399"
    interval          = var.gwlb_health_check_interval
    healthy_threshold = var.gwlb_healthy_threshold
  }
  tags = local.common_tags
}

resource "aws_lb_listener" "gwlb" {
  load_balancer_arn = aws_lb.gwlb.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.slot[var.active_slot].arn
  }
  tags = merge({ Name = "${local.shared_prefix}gwlb-ln" }, local.common_tags)

  lifecycle {
    precondition {
      condition     = contains(keys(local.fgt_slots), var.active_slot)
      error_message = "active_slot (\"${var.active_slot}\") is not a key of fgt_slots. The active slot cannot be removed."
    }
  }
}

# Attach each slot's target group to that slot's autoscale group(s). The module gets no target
# group (existing_gwlb_tgp = {}), so its autoscale groups have none of their own.
resource "aws_autoscaling_traffic_source_attachment" "slot" {
  for_each = local.slot_asgs

  autoscaling_group_name = each.value.name
  traffic_source {
    identifier = aws_lb_target_group.slot[each.value.slot].arn
    type       = "elbv2"
  }
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw, module.spk_tgw_gwlb_asg_fgt_igw_green]
}

#
# Deployments made before the slots existed: the module created these three resources. The
# moved blocks give them their new addresses in the state; nothing is destroyed or created in
# AWS. They have no effect on a new deployment. The endpoint service and the endpoints do not
# move: the blue module call still creates them.
#
moved {
  from = module.spk_tgw_gwlb_asg_fgt_igw.module.security-vpc-gwlb.aws_lb.gwlb[0]
  to   = aws_lb.gwlb
}
moved {
  from = module.spk_tgw_gwlb_asg_fgt_igw.module.security-vpc-gwlb.aws_lb_listener.gwlb_ln[0]
  to   = aws_lb_listener.gwlb
}
moved {
  from = module.spk_tgw_gwlb_asg_fgt_igw.module.security-vpc-gwlb.aws_lb_target_group.gwlb_tgp[0]
  to   = aws_lb_target_group.slot["blue"]
}
