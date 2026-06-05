terraform {
  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "autoscale_template/terraform.tfstate"
    region = "us-west-2"
  }
}
