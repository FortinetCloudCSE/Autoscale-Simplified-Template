#
# Shared Gateway Load Balancer resources and FortiGate slots
#
# The GWLB, its single listener, the endpoint service and the GWLB endpoints are created here,
# at the root, not by the Fortinet module. They are shared by every FortiGate slot and are never
# destroyed by a blue-green upgrade.
#
# Each entry of fgt_slots (see variables.tf), "blue" or "green", is one FortiGate autoscale
# group: one module call in autoscale_group.tf plus its own target group below. The listener forwards to the
# target group of active_slot. A blue-green upgrade in the same VPC:
#
#   1. add a "green" slot with the new fortios_version          -> creates only green resources
#   2. restore the Blue configuration on Green's primary
#   3. set active_slot = "green"                                 -> changes only the listener
#   4. remove the "blue" slot after Blue has drained             -> destroys only blue resources
#
# A GWLB has one listener only, so the module is told not to create a target group, listener,
# endpoint service or endpoints of its own (existing_gwlb_tgp = {}, existing_gwlb_ep_service = {}).
#

locals {
  shared_prefix = var.asg_module_prefix == "" ? "" : "${var.asg_module_prefix}-"

  # Without fgt_slots, one "blue" slot is built from the top-level variables, so an existing
  # terraform.tfvars keeps working unchanged.
  # Every attribute is listed (null = use the top-level variable) so both branches have the same type.
  fgt_slots_input = length(var.fgt_slots) > 0 ? var.fgt_slots : {
    blue = {
      name_prefix                   = var.asg_module_prefix
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
  fgt_slots = {
    for k, v in local.fgt_slots_input : k => {
      name_prefix                   = v.name_prefix
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

  # Endpoint keys are the ones the module used, so existing endpoints keep their state entries:
  # "<prefix>-gwlbe_azN" in the inspection VPC, "<vpc>-<subnet id>" in distributed VPCs.
  gwlb_endpoints = merge(
    merge(
      {
        "${local.shared_prefix}gwlbe_az1" = { vpc_id = data.aws_vpc.inspection.id, subnet_id = data.aws_subnet.inspection_gwlbe_az1.id }
        "${local.shared_prefix}gwlbe_az2" = { vpc_id = data.aws_vpc.inspection.id, subnet_id = data.aws_subnet.inspection_gwlbe_az2.id }
      },
      var.availability_zone_3 == "" ? {} : {
        "${local.shared_prefix}gwlbe_az3" = { vpc_id = data.aws_vpc.inspection.id, subnet_id = data.aws_subnet.inspection_gwlbe_az3[0].id }
      }
    ),
    merge([
      for vpc_name, vpc_c in local.distributed_spk_vpc : {
        for sn_id in vpc_c.gwlbe_subnet_ids : "${vpc_name}-${sn_id}" => {
          vpc_id    = vpc_c.vpc_id
          subnet_id = sn_id
        }
      }
    ]...)
  )
}

check "fgt_slots" {
  assert {
    condition     = contains(keys(local.fgt_slots), var.active_slot)
    error_message = "active_slot (\"${var.active_slot}\") must be one of the fgt_slots keys: ${join(", ", keys(local.fgt_slots))}."
  }
  assert {
    condition     = length(distinct([for v in local.fgt_slots : v.name_prefix])) == length(local.fgt_slots)
    error_message = "Each fgt_slots entry needs its own name_prefix."
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

resource "aws_vpc_endpoint_service" "gwlb" {
  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]
  tags                       = merge({ Name = "${local.shared_prefix}gwlb_endpoint_service" }, local.common_tags)
}

resource "aws_vpc_endpoint" "gwlb" {
  for_each = local.gwlb_endpoints

  vpc_id            = each.value.vpc_id
  subnet_ids        = toset([each.value.subnet_id])
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  tags              = merge({ Name = each.key }, local.common_tags)

  lifecycle {
    create_before_destroy = true
  }
}

#
# Deployments made before the slots existed: the module created these resources. The moved
# blocks give them their new addresses in the state; nothing is destroyed or created in AWS.
# They have no effect on a new deployment.
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
moved {
  from = module.spk_tgw_gwlb_asg_fgt_igw.module.security-vpc-gwlb.aws_vpc_endpoint_service.gwlb_ep_service[0]
  to   = aws_vpc_endpoint_service.gwlb
}
moved {
  from = module.spk_tgw_gwlb_asg_fgt_igw.module.security-vpc-gwlb.aws_vpc_endpoint.gwlb_endps
  to   = aws_vpc_endpoint.gwlb
}
