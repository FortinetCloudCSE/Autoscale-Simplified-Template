#
# Green FortiGate Autoscale Group
#
# Calls the same upstream Fortinet module as autoscale_template but passes
# Green VPC resources directly (no tag-based discovery). All VPC resources
# are created in vpc_green.tf — no data source lookups for inspection VPC.
#

module "spk_tgw_gwlb_asg_fgt_igw" {
  source = "git::https://github.com/fortinetdev/terraform-aws-cloud-modules.git//examples/spk_tgw_gwlb_asg_fgt_igw"

  ## Root config
  region        = var.aws_region
  module_prefix = var.asg_module_prefix

  # Pass Green VPC resources directly — no tag-based discovery
  existing_security_vpc = {
    id = aws_vpc.green_inspection.id
  }
  existing_igw = {
    id = aws_internet_gateway.green_inspection.id
  }
  existing_tgw = {}
  existing_subnets = {
    fgt_login_az1 = {
      id                = aws_subnet.green_public_az1.id
      availability_zone = local.availability_zone_1
    }
    fgt_login_az2 = {
      id                = aws_subnet.green_public_az2.id
      availability_zone = local.availability_zone_2
    }
    gwlbe_az1 = {
      id                = aws_subnet.green_gwlbe_az1.id
      availability_zone = local.availability_zone_1
    }
    gwlbe_az2 = {
      id                = aws_subnet.green_gwlbe_az2.id
      availability_zone = local.availability_zone_2
    }
    fgt_internal_az1 = {
      id                = aws_subnet.green_private_az1.id
      availability_zone = local.availability_zone_1
    }
    fgt_internal_az2 = {
      id                = aws_subnet.green_private_az2.id
      availability_zone = local.availability_zone_2
    }
  }

  ## VPC
  security_groups = {
    secgrp1 = {
      description = "Security group for Green FortiGate data plane"
      ingress = {
        all_traffic = {
          from_port   = "0"
          to_port     = "0"
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      egress = {
        all_traffic = {
          from_port   = "0"
          to_port     = "0"
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
    management_secgrp1 = {
      description = "Security group for Green FortiGate dedicated management port"
      ingress = {
        all_traffic = {
          from_port   = "0"
          to_port     = "0"
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      egress = {
        all_traffic = {
          from_port   = "0"
          to_port     = "0"
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
  }

  vpc_cidr_block     = var.vpc_cidr_inspection
  spoke_cidr_list    = []
  availability_zones = [local.availability_zone_1, local.availability_zone_2]

  ## Transit Gateway
  tgw_name        = "${var.cp}-${var.env}-tgw"
  tgw_description = "tgw for green fortigate autoscale group"

  ## Auto Scale Groups
  fgt_intf_mode            = var.firewall_policy_mode
  fgt_access_internet_mode = var.access_internet_mode

  asgs = {
    fgt_byol_asg = {
      fmg_integration = var.enable_fortimanager_integration ? {
        ip           = var.fortimanager_ip
        sn           = var.fortimanager_sn
        primary_only = true
        fgt_lic_mgmt = "module"
        vrf_select   = 1
      } : null
      primary_scalein_protection = var.primary_scalein_protection
      extra_network_interfaces = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index     = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_az1[0].id : aws_subnet.green_management_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_az2[0].id : aws_subnet.green_management_az2[0].id
              zone_name = local.availability_zone_2
            }
          ]
          security_groups = [
            {
              id = aws_security_group.management_sg[0].id
            }
          ]
        }
      }
      template_name           = "fgt_asg_template"
      fgt_version             = var.fortios_version
      license_type            = "byol"
      instance_type           = var.fgt_instance_type
      fgt_password            = var.fortigate_asg_password
      keypair_name            = var.keypair
      lic_folder_path         = var.asg_license_directory
      fortiflex_username      = var.fortiflex_username
      fortiflex_password      = var.fortiflex_password
      fortiflex_sn_list       = var.fortiflex_sn_list
      fortiflex_configid_list = var.fortiflex_configid_list

      enable_fgt_system_autoscale = true
      intf_security_group = {
        login_port    = "secgrp1"
        internal_port = "secgrp1"
      }

      user_conf_file_path           = local.fgt_config_file
      asg_max_size                  = var.asg_byol_asg_max_size
      asg_min_size                  = var.asg_byol_asg_min_size
      asg_desired_capacity          = var.asg_byol_asg_desired_size
      create_dynamodb_table         = true
      dynamodb_table_name           = "fgt_asg_track_table"
      asg_health_check_grace_period = var.asg_health_check_grace_period
    }

    fgt_on_demand_asg = {
      fmg_integration = var.enable_fortimanager_integration ? {
        ip           = var.fortimanager_ip
        sn           = var.fortimanager_sn
        primary_only = true
        fgt_lic_mgmt = "module"
        vrf_select   = var.fortimanager_vrf_select
      } : null
      primary_scalein_protection = var.primary_scalein_protection
      extra_network_interfaces = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index     = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_az1[0].id : aws_subnet.green_management_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_az2[0].id : aws_subnet.green_management_az2[0].id
              zone_name = local.availability_zone_2
            }
          ]
          security_groups = [
            {
              id = aws_security_group.management_sg[0].id
            }
          ]
        }
      }
      template_name               = "fgt_asg_template_on_demand"
      fgt_version                 = var.fortios_version
      license_type                = "on_demand"
      instance_type               = var.fgt_instance_type
      fgt_password                = var.fortigate_asg_password
      keypair_name                = var.keypair
      enable_fgt_system_autoscale = true
      intf_security_group = {
        login_port    = "secgrp1"
        internal_port = "secgrp1"
      }
      user_conf_file_path           = local.fgt_config_file
      asg_max_size                  = var.asg_ondemand_asg_max_size
      asg_min_size                  = var.asg_ondemand_asg_min_size
      asg_desired_capacity          = var.asg_ondemand_asg_desired_size
      dynamodb_table_name           = "fgt_asg_track_table"
      asg_health_check_grace_period = var.asg_health_check_grace_period
      scale_policies = {
        byol_cpu_above_80 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = 1
        }
        byol_cpu_below_30 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = -1
        }
        ondemand_cpu_above_80 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = 1
        }
        ondemand_cpu_below_30 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = -1
        }
      }
    }
  }

  ## CloudWatch Alarms
  cloudwatch_alarms = {
    byol_cpu_above_80 = {
      comparison_operator = "GreaterThanOrEqualToThreshold"
      evaluation_periods  = 2
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      period              = 120
      statistic           = "Average"
      threshold           = 80
      dimensions = {
        AutoScalingGroupName = "fgt_byol_asg"
      }
      alarm_description   = "Green ASG BYOL CPU above 80%"
      datapoints_to_alarm = 1
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["byol_cpu_above_80"]
        }
      }
    }
    byol_cpu_below_30 = {
      comparison_operator = "LessThanThreshold"
      evaluation_periods  = 2
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      period              = 120
      statistic           = "Average"
      threshold           = 30
      dimensions = {
        AutoScalingGroupName = "fgt_byol_asg"
      }
      alarm_description   = "Green ASG BYOL CPU below 30%"
      datapoints_to_alarm = 1
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["byol_cpu_below_30"]
        }
      }
    }
    ondemand_cpu_above_80 = {
      comparison_operator = "GreaterThanOrEqualToThreshold"
      evaluation_periods  = 2
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      period              = 120
      statistic           = "Average"
      threshold           = 80
      dimensions = {
        AutoScalingGroupName = "fgt_on_demand_asg"
      }
      alarm_description = "Green ASG On-Demand CPU above 80%"
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["ondemand_cpu_above_80"]
        }
      }
    }
    ondemand_cpu_below_30 = {
      comparison_operator = "LessThanThreshold"
      evaluation_periods  = 2
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      period              = 120
      statistic           = "Average"
      threshold           = 30
      dimensions = {
        AutoScalingGroupName = "fgt_on_demand_asg"
      }
      alarm_description = "Green ASG On-Demand CPU below 30%"
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["ondemand_cpu_below_30"]
        }
      }
    }
  }

  ## Gateway Load Balancer
  enable_cross_zone_load_balancing = var.allow_cross_zone_load_balancing
  gwlb_health_check = {
    port              = var.gwlb_health_check_port
    protocol          = "HTTP"
    path              = "/"
    matcher           = "200-399"
    interval          = var.gwlb_health_check_interval
    healthy_threshold = var.gwlb_healthy_threshold
  }

  ## Spoke VPC
  enable_east_west_inspection = true

  ## Tags
  general_tags = {
    "purpose" = "GREEN_ASG"
  }
}
