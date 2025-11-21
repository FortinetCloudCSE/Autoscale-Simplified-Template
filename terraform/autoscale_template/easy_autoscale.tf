
locals {
    common_tags = {
    Environment = var.env
  }
}

check "config_validation" {
  assert {
    condition = !(var.enable_dedicated_management_eni && var.enable_dedicated_management_vpc)
    error_message = "Cannot enable both dedicated management VPC and dedicated management ENI"
  }
  assert {
    condition = var.firewall_policy_mode == "1-arm" || var.firewall_policy_mode == "2-arm"
    error_message = "access_internet_mode must be '1-arm' or '2-arm'"
  }
}

locals {
  availability_zone_1  = "${var.aws_region}${var.availability_zone_1}"
  availability_zone_2  = "${var.aws_region}${var.availability_zone_2}"
  access_internet_mode = local.enable_nat_gateway ? "nat_gw" : "eip"
}

locals {
  dedicated_mgmt = var.enable_dedicated_management_vpc ? "-wdm" : var.enable_dedicated_management_eni ? "-wdm-eni" : ""
  fgt_config_file           = "./${var.firewall_policy_mode}${local.dedicated_mgmt}-${var.base_config_file}"
  management_device_index   = var.firewall_policy_mode == "2-arm" ? 2 : 1
  management_vpc            = "${var.cp}-${var.env}-management-vpc"
  inspection_vpc            = "${var.cp}-${var.env}-inspection-vpc"
  inspection_public_az1     = "${var.cp}-${var.env}-inspection-public-az1-subnet"
  inspection_public_az2     = "${var.cp}-${var.env}-inspection-public-az2-subnet"
  inspection_gwlbe_az1      = "${var.cp}-${var.env}-inspection-gwlbe-az1-subnet"
  inspection_gwlbe_az2      = "${var.cp}-${var.env}-inspection-gwlbe-az2-subnet"
  inspection_private_az1    = "${var.cp}-${var.env}-inspection-private-az1-subnet"
  inspection_private_az2    = "${var.cp}-${var.env}-inspection-private-az2-subnet"
}

locals {
  management_public_az1                = "${var.cp}-${var.env}-management-public-az1-subnet"
  management_public_az2                = "${var.cp}-${var.env}-management-public-az2-subnet"
  inspection_management_az1            = "${var.cp}-${var.env}-inspection-management-az1-subnet"
  inspection_management_az2            = "${var.cp}-${var.env}-inspection-management-az2-subnet"
}
# data "aws_vpc_endpoint" "gwlb_endpoint_az1" {
#   filter {
#     name   = "tag:Name"
#     values = [var.endpoint_name_az1]
#   }
#   filter {
#     name   = "state"
#     values = ["available"]
#   }
#   vpc_id = data.aws_vpc.inspection_vpc.id
# }
# data "aws_vpc_endpoint" "gwlb_endpoint_az2" {
#   filter {
#     name   = "tag:Name"
#     values = [var.endpoint_name_az2]
#   }
#   filter {
#     name   = "state"
#     values = ["available"]
#   }
#   vpc_id = data.aws_vpc.inspection_vpc.id
# }
data "aws_vpc" "management_vpc" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [local.management_vpc]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "management_public_subnet_az1" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [local.management_public_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "management_public_subnet_az2" {
  count = var.enable_dedicated_management_vpc ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [local.management_public_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_vpc" "inspection_vpc" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_vpc]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
locals {
  inspection_vpc_cidr = data.aws_vpc.inspection_vpc.cidr_block
}
data "aws_internet_gateway" "inspection_igw" {
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-inspection-igw"]
  }
}
data "aws_ec2_transit_gateway" "existing_tgw" {
  filter {
    name   = "tag:Name"
    values = ["${var.cp}-${var.env}-tgw"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
data "aws_subnet" "inspection_public_subnet_az1" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_public_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_public_subnet_az2" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_public_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_gwlbe_subnet_az1" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_gwlbe_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_gwlbe_subnet_az2" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_gwlbe_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_private_subnet_az1" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_private_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_private_subnet_az2" {
  filter {
    name   = "tag:Name"
    values = [local.inspection_private_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_management_subnet_az1" {
  depends_on = [data.aws_vpc.inspection_vpc]
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [local.inspection_management_az1]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_subnet" "inspection_management_subnet_az2" {
  depends_on = [data.aws_vpc.inspection_vpc]
  count = var.enable_dedicated_management_eni ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [local.inspection_management_az2]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  vpc_id = data.aws_vpc.inspection_vpc.id
}
resource "random_string" "random" {
  length           = 5
  special          = false
}
data "aws_route_table" "inspection_private_route_table_az1" {
  subnet_id = data.aws_subnet.inspection_private_subnet_az1.id
  vpc_id = data.aws_vpc.inspection_vpc.id
}
data "aws_route_table" "inspection_private_route_table_az2" {
  subnet_id = data.aws_subnet.inspection_private_subnet_az1.id
  vpc_id = data.aws_vpc.inspection_vpc.id
}
# resource "aws_route" "inspection-ns-private-default-route-gwlbe-az1" {
#   route_table_id         = data.aws_route_table.inspection_private_route_table_az1.id
#   destination_cidr_block = "0.0.0.0/0"
#   vpc_endpoint_id        = data.aws_vpc_endpoint.gwlb_endpoint_az1.id
# }
# resource "aws_route" "inspection-ns-private-default-route-gwlbe-az2" {
#   route_table_id         = data.aws_route_table.inspection_private_route_table_az2.id
#   destination_cidr_block = "0.0.0.0/0"
#   vpc_endpoint_id        = data.aws_vpc_endpoint.gwlb_endpoint_az2.id
# }
