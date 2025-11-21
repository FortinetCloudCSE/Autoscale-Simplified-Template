
resource "aws_security_group" "management-vpc-sg" {
  count = var.enable_dedicated_management_vpc || var.enable_dedicated_management_eni ? 1 : 0
  description = "Security Group for ENI in the management VPC"
  vpc_id = var.enable_dedicated_management_vpc ? data.aws_vpc.management_vpc[0].id : data.aws_vpc.inspection_vpc.id
  ingress {
    description = "Allow egress ALL"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [ "0.0.0.0/0" ]
  }
  egress {
    description = "Allow egress ALL"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [ "0.0.0.0/0" ]
  }
}

module "spk_tgw_gwlb_asg_fgt_igw" {
  source = "git::https://github.com/fortinetdev/terraform-aws-cloud-modules.git//examples/spk_tgw_gwlb_asg_fgt_igw"

  ## Note: Please go through all arguments in this file and replace the content with your configuration! This file is just an example.
  ## "<YOUR-OWN-VALUE>" are parameters that you need to specify your own value.

  ## Root config
  region     = var.aws_region

  module_prefix = var.asg_module_prefix
  existing_security_vpc = {
    id = data.aws_vpc.inspection_vpc.id
  }
  existing_igw = {
    id = data.aws_internet_gateway.inspection_igw.id
  }
  existing_tgw = {
    id = data.aws_ec2_transit_gateway.existing_tgw.id
  }
  existing_subnets = {
    fgt_login_az1 = {
      id = data.aws_subnet.inspection_public_subnet_az1.id
      availability_zone = local.availability_zone_1
    },
    fgt_login_az2 = {
      id = data.aws_subnet.inspection_public_subnet_az2.id
      availability_zone = local.availability_zone_2
    },
    gwlbe_az1 = {
      id = data.aws_subnet.inspection_gwlbe_subnet_az1.id
      availability_zone = local.availability_zone_1
    },
    gwlbe_az2 = {
      id = data.aws_subnet.inspection_gwlbe_subnet_az2.id
      availability_zone = local.availability_zone_2
    },
    fgt_internal_az1 = {
      id = data.aws_subnet.inspection_private_subnet_az1.id
      availability_zone = local.availability_zone_1
    },
    fgt_internal_az2 = {
      id = data.aws_subnet.inspection_private_subnet_az2.id
      availability_zone = local.availability_zone_2
    }
  }

  ## VPC
  security_groups = {
    secgrp1 = {
      description = "Security group by Terraform"
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
      description = "Security group by Terraform for dedicated management port"
      ingress = {
        all_traffic = {
          from_port = "0"
          to_port   = "0"
          protocol  = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
      egress = {
        all_traffic = {
          from_port = "0"
          to_port   = "0"
          protocol  = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
  }

  vpc_cidr_block     = local.inspection_vpc_cidr
# spoke_cidr_list    = [var.vpc_cidr_east, var.vpc_cidr_west]
  spoke_cidr_list    = [ ]
  availability_zones = [local.availability_zone_1, local.availability_zone_2]

  ## Transit Gateway
  tgw_name        = "${var.cp}-${var.env}-tgw"
  tgw_description = "tgw for fortigate autoscale group"

  ## Auto scale group
  # This example is a hybrid license ASG
  fgt_intf_mode = var.firewall_policy_mode
  fgt_access_internet_mode = local.access_internet_mode
    asgs = {
    fgt_byol_asg = {
      fmg_integration = var.enable_fortimanager_integration ? {
        ip                  = var.fortimanager_ip
        sn                  = var.fortimanager_sn
        primary_only	    = true
        fgt_lic_mgmt        = "module"
        vrf_select          = 1
      } : null
      primary_scalein_protection = var.primary_scalein_protection
      extra_network_interfaces = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_subnet_az1[0].id : data.aws_subnet.inspection_management_subnet_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_subnet_az2[0].id : data.aws_subnet.inspection_management_subnet_az2[0].id
              zone_name = local.availability_zone_2
            }
          ]
          security_groups = [
            {
              id = aws_security_group.management-vpc-sg[0].id
            }
          ]
        }
      }
      template_name   = "fgt_asg_template"
      fgt_version     = var.fortios_version
      license_type    = "byol"
      instance_type   = var.fgt_instance_type
      fgt_password    = var.fortigate_asg_password
      keypair_name    = var.keypair
      lic_folder_path = var.asg_license_directory
      fortiflex_username      = var.fortiflex_username
      fortiflex_password      = var.fortiflex_password
      fortiflex_sn_list       = var.fortiflex_sn_list
      fortiflex_configid_list = var.fortiflex_configid_list

      # fortiflex_refresh_token = "<YOUR-OWN-VALUE>" # e.g. "NasmPa0CXpd56n6TzJjGqpqZm9Thyw"
      # fortiflex_sn_list = "<YOUR-OWN-VALUE>" # e.g. ["FGVMMLTM00000001", "FGVMMLTM00000002"]
      # fortiflex_configid_list = "<YOUR-OWN-VALUE>" # e.g. [2343]
      enable_fgt_system_autoscale = true
      intf_security_group = {
        login_port    = "secgrp1"
        internal_port = "secgrp1"
      }

      user_conf_file_path = local.fgt_config_file
      # There are 3 options for providing user_conf data:
      # user_conf_content : FortiGate Configuration
      # user_conf_file_path : The file path of configuration file
      # user_conf_s3 : Map of AWS S3
      asg_max_size          = var.asg_byol_asg_max_size
      asg_min_size          = var.asg_byol_asg_min_size
      asg_desired_capacity  = var.asg_byol_asg_desired_size
      create_dynamodb_table = true
      dynamodb_table_name   = "fgt_asg_track_table"
    },
    fgt_on_demand_asg = {
      fmg_integration = var.enable_fortimanager_integration ? {
        ip                  = var.fortimanager_ip
        sn                  = var.fortimanager_sn
        primary_only	    = true
        fgt_lic_mgmt        = "module"
        vrf_select          = var.fortimanager_vrf_select
      } : null
      primary_scalein_protection = var.primary_scalein_protection
      extra_network_interfaces = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_subnet_az1[0].id : data.aws_subnet.inspection_management_subnet_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id = var.enable_dedicated_management_vpc ? data.aws_subnet.management_public_subnet_az2[0].id : data.aws_subnet.inspection_management_subnet_az2[0].id
              zone_name = local.availability_zone_2
            }
          ]
          security_groups = [
            {
              id = aws_security_group.management-vpc-sg[0].id
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
      user_conf_file_path = local.fgt_config_file
      # There are 3 options for providing user_conf data:
      # user_conf_content : FortiGate Configuration
      # user_conf_file_path : The file path of configuration file
      # user_conf_s3 : Map of AWS S3
      asg_max_size          = var.asg_ondemand_asg_max_size
      asg_min_size          = var.asg_ondemand_asg_min_size
      asg_desired_capacity  = var.asg_ondemand_asg_desired_size
      # asg_desired_capacity = 0
      dynamodb_table_name = "fgt_asg_track_table"
      scale_policies = {
        byol_cpu_above_80 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = 1
        },
        byol_cpu_below_30 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = -1
        },
        ondemand_cpu_above_80 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = 1
        },
        ondemand_cpu_below_30 = {
          policy_type        = "SimpleScaling"
          adjustment_type    = "ChangeInCapacity"
          cooldown           = 60
          scaling_adjustment = -1
        }
      }
    }
  }

  ## Cloudwatch Alarm
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
      alarm_description   = "This metric monitors average ec2 cpu utilization of Auto Scale group fgt_asg_byol."
      datapoints_to_alarm = 1
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["byol_cpu_above_80"]
        }
      }
    },
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
      alarm_description   = "This metric monitors average ec2 cpu utilization of Auto Scale group fgt_asg_byol."
      datapoints_to_alarm = 1
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["byol_cpu_below_30"]
        }
      }
    },
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
      alarm_description = "This metric monitors average ec2 cpu utilization of Auto Scale group fgt_asg_ondemand."
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["ondemand_cpu_above_80"]
        }
      }
    },
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
      alarm_description = "This metric monitors average ec2 cpu utilization of Auto Scale group fgt_asg_ondemand."
      alarm_asg_policies = {
        policy_name_map = {
          "fgt_on_demand_asg" = ["ondemand_cpu_below_30"]
        }
      }
    }
  }

  ## Gateway Load Balancer
  enable_cross_zone_load_balancing = var.allow_cross_zone_load_balancing

  ## Spoke VPC
  enable_east_west_inspection = true
  # "<YOUR-OWN-VALUE>" # e.g.
  # spk_vpc = {
  #   # This is optional. The module will create Transit Gateway Attachment under each subnet in argument 'subnet_ids', and also create route table to let all traffic (0.0.0.0/0) forward to the TGW attachment with the subnets associated.
  #   "spk_vpc1" = {
  #     vpc_id = "vpc-123456789",
  #     subnet_ids = [
  #       "subnet-123456789",
  #       "subnet-123456789"
  #     ]
  #   }
  # }

  ## Tag
  general_tags = {
    "purpose" = "ASG_TEST"
  }
}

