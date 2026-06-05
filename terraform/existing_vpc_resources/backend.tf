terraform {
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "existing_vpc_resources/terraform.tfstate"
    region = "us-west-2"
  }
}
