output "fortigate_configuration_file"{
  value = local.fgt_config_template
  description = "Fortigate configuration template file"
}

data "aws_launch_template" "fgt_byol" {
  name       = "asg-fgt_asg_template"
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
}

output "fortigate_ami_id" {
  value       = data.aws_launch_template.fgt_byol.image_id
  description = "AMI ID used by the FortiGate BYOL autoscale group"
}