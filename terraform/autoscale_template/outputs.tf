output "fortigate_configuration_file" {
  value       = local.fgt_config_template
  description = "Fortigate configuration template file"
}

data "aws_launch_template" "fgt_byol" {
  for_each   = local.fgt_slots
  name       = "${each.value.name_prefix}-fgt_asg_template"
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw, module.spk_tgw_gwlb_asg_fgt_igw_green]
}

output "fortigate_ami_id" {
  value       = { for k, v in data.aws_launch_template.fgt_byol : k => v.image_id }
  description = "AMI ID used by each slot's FortiGate BYOL autoscale group"
}

output "active_slot" {
  value       = var.active_slot
  description = "The slot whose target group the GWLB listener forwards to"
}

output "gwlb_listener_arn" {
  value       = aws_lb_listener.gwlb.arn
  description = "The GWLB listener (one per GWLB)"
}

output "slot_target_group_arns" {
  value       = { for k, v in aws_lb_target_group.slot : k => v.arn }
  description = "Target group of each slot"
}