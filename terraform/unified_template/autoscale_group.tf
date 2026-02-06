locals {
  dedicated_mgmt = var.enable_dedicated_management_vpc ? "-wdm" : var.enable_dedicated_management_eni ? "-wdm-eni" : ""
}
locals {
  fgt_config_file = "./${var.firewall_policy_mode}${local.dedicated_mgmt}-${var.base_config_file}"
}
locals {
  management_device_index = var.firewall_policy_mode == "2-arm" ? 2 : 1
}
# Management VPC Fortinet-Role tags - auto-constructed from cp and env
locals {
  management_vpc = "${var.cp}-${var.env}-management-vpc"
}
locals {
  management_public_az1 = "${var.cp}-${var.env}-management-public-az1"
}
locals {
  management_public_az2 = "${var.cp}-${var.env}-management-public-az2"
}

# Management VPC lookups (for dedicated management VPC mode)
# Uses Fortinet-Role tags for consistency with inspection VPC resource discovery
data "aws_vpc" "management_vpc" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_vpc]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "public_subnet_az1" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_public_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "public_subnet_az2" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Fortinet-Role"
    values = [local.management_public_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security group for management interfaces
resource "aws_security_group" "management-vpc-sg" {
  count       = var.enable_dedicated_management_vpc || var.enable_dedicated_management_eni ? 1 : 0
  description = "Security Group for ENI in the management VPC"
  vpc_id      = var.enable_dedicated_management_vpc ? data.aws_vpc.management_vpc[0].id : data.aws_vpc.inspection.id
  ingress {
    description = "Allow ingress ALL"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allow egress ALL"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "spk_tgw_gwlb_asg_fgt_igw" {
  source = "git::https://github.com/fortinetdev/terraform-aws-cloud-modules.git//examples/spk_tgw_gwlb_asg_fgt_igw"

  #
  # Used for testing development test builds. Never use this in production.
  #

 #source = "/Users/mwooten/github/40netse/AWSTerraformModules//examples/spk_tgw_gwlb_asg_fgt_igw"

  ## Root config
  region        = var.aws_region
  module_prefix = var.asg_module_prefix

  # Use existing inspection VPC resources (looked up by Fortinet-Role tags)
  existing_security_vpc = {
    id = data.aws_vpc.inspection.id
  }
  existing_igw = {
    id = data.aws_internet_gateway.inspection.id
  }
  existing_tgw = {
  }
  existing_subnets = {
    fgt_login_az1 = {
      id                = data.aws_subnet.inspection_public_az1.id
      availability_zone = local.availability_zone_1
    },
    fgt_login_az2 = {
      id                = data.aws_subnet.inspection_public_az2.id
      availability_zone = local.availability_zone_2
    },
    gwlbe_az1 = {
      id                = data.aws_subnet.inspection_gwlbe_az1.id
      availability_zone = local.availability_zone_1
    },
    gwlbe_az2 = {
      id                = data.aws_subnet.inspection_gwlbe_az2.id
      availability_zone = local.availability_zone_2
    },
    fgt_internal_az1 = {
      id                = data.aws_subnet.inspection_private_az1.id
      availability_zone = local.availability_zone_1
    },
    fgt_internal_az2 = {
      id                = data.aws_subnet.inspection_private_az2.id
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
  tgw_description = "tgw for fortigate autoscale group"

  ## Auto scale group
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
      extra_network_interfaces   = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index     = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.public_subnet_az1[0].id : data.aws_subnet.inspection_management_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.public_subnet_az2[0].id : data.aws_subnet.inspection_management_az2[0].id
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

      user_conf_file_path   = local.fgt_config_file
      asg_max_size          = var.asg_byol_asg_max_size
      asg_min_size          = var.asg_byol_asg_min_size
      asg_desired_capacity  = var.asg_byol_asg_desired_size
      create_dynamodb_table = true
      dynamodb_table_name   = "fgt_asg_track_table"
    },
    fgt_on_demand_asg = {
      fmg_integration = var.enable_fortimanager_integration ? {
        ip           = var.fortimanager_ip
        sn           = var.fortimanager_sn
        primary_only = true
        fgt_lic_mgmt = "module"
        vrf_select   = var.fortimanager_vrf_select
      } : null
      primary_scalein_protection = var.primary_scalein_protection
      extra_network_interfaces   = !var.enable_dedicated_management_vpc && !var.enable_dedicated_management_eni ? {} : {
        "dedicated_port" = {
          device_index     = local.management_device_index
          enable_public_ip = true
          subnet = [
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.public_subnet_az1[0].id : data.aws_subnet.inspection_management_az1[0].id
              zone_name = local.availability_zone_1
            },
            {
              id        = var.enable_dedicated_management_vpc ? data.aws_subnet.public_subnet_az2[0].id : data.aws_subnet.inspection_management_az2[0].id
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
      user_conf_file_path  = local.fgt_config_file
      asg_max_size         = var.asg_ondemand_asg_max_size
      asg_min_size         = var.asg_ondemand_asg_min_size
      asg_desired_capacity = var.asg_ondemand_asg_desired_size
      dynamodb_table_name  = "fgt_asg_track_table"
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

  ## Tag
  general_tags = {
    "purpose" = "ASG_TEST"
  }
}
