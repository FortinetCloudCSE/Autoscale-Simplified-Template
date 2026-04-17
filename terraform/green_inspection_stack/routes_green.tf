#
# Green inspection VPC private subnet routes → GWLB endpoints
#
# Must run after the ASG module creates GWLB endpoints.
# Endpoint names are set by the module using asg_module_prefix.
# Set endpoint_name_az1 / endpoint_name_az2 in tfvars to match.
#

data "aws_vpc_endpoint" "green_endpoint_az1" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  vpc_id = aws_vpc.green_inspection.id
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az1]
  }
}
data "aws_vpc_endpoint" "green_endpoint_az2" {
  depends_on = [module.spk_tgw_gwlb_asg_fgt_igw]
  vpc_id = aws_vpc.green_inspection.id
  filter {
    name   = "tag:Name"
    values = [var.endpoint_name_az2]
  }
}

resource "aws_route" "green_private_az1_gwlbe" {
  route_table_id         = aws_route_table.green_private_az1.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.green_endpoint_az1.id
}
resource "aws_route" "green_private_az2_gwlbe" {
  route_table_id         = aws_route_table.green_private_az2.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = data.aws_vpc_endpoint.green_endpoint_az2.id
}
