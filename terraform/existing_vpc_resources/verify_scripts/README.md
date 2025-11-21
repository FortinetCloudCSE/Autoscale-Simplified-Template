# AWS Infrastructure Verification Scripts

This directory contains bash scripts to verify AWS infrastructure resources created by the Terraform templates in the `existing_vpc_resources` directory.

## Overview

These scripts use AWS CLI commands to verify that infrastructure components have been deployed correctly according to the configuration in `terraform.tfvars`.

## Prerequisites

1. **AWS CLI** installed and configured with appropriate credentials
2. **Bash** shell (Linux, macOS, or WSL on Windows)
3. **AWS credentials** set up in your environment (via environment variables, AWS credentials file, or IAM role)
4. **Terraform** applied successfully with the `existing_vpc_resources` template

## Scripts

### Master Script

- **`verify_all.sh`** - Master script that can run all verification scripts or specific ones

### Individual Verification Scripts

- **`verify_management_vpc.sh`** - Verifies Management VPC resources (FortiManager, FortiAnalyzer, Jump Box)
- **`verify_inspection_vpc.sh`** - Verifies Inspection VPC resources (subnets, route tables, TGW attachment)
- **`verify_east_vpc.sh`** - Verifies East spoke VPC resources
- **`verify_west_vpc.sh`** - Verifies West spoke VPC resources

### Helper Scripts

- **`common_functions.sh`** - Shared functions used by all verification scripts (sourced automatically)

## Usage

### Run All Verifications

```bash
cd terraform/existing_vpc_resources/verify_scripts
./verify_all.sh --verify all
```

### Run Specific Component Verification

```bash
# Verify Management VPC only
./verify_all.sh --verify management

# Verify Inspection VPC only
./verify_all.sh --verify inspection

# Verify East VPC only
./verify_all.sh --verify east

# Verify West VPC only
./verify_all.sh --verify west

# Verify both spoke VPCs (East and West)
./verify_all.sh --verify spoke
```

### Run Individual Scripts Directly

You can also run individual verification scripts directly:

```bash
./verify_management_vpc.sh
./verify_inspection_vpc.sh
./verify_east_vpc.sh
./verify_west_vpc.sh
```

### Get Help

```bash
./verify_all.sh --help
```

## Output Format

The scripts provide colored output with clear pass/fail indicators:

- **[PASSED]** - Check passed successfully (green)
- **[FAILED]** - Check failed (red)
- **[SKIPPED]** - Check skipped due to configuration (yellow)
- **[INFO]** - Informational message (blue)

### Example Output

```
========================================
MANAGEMENT VPC VERIFICATION
========================================
[INFO] Reading configuration from: ../terraform.tfvars
[INFO] Region: us-west-1
[INFO] Availability Zones: us-west-1a, us-west-1b
[PASSED] Management VPC exists: vpc-0123456789abcdef0
[PASSED] VPC CIDR matches: 10.3.0.0/16
[PASSED] Internet Gateway exists and is attached: igw-0123456789abcdef0
[PASSED] Public subnet AZ1 exists: subnet-0123456789abcdef0
...

========================================
SUMMARY
========================================
Total Passed:  25
Total Failed:  0
Total Skipped: 3

All checks passed!
```

## Exit Codes

- **0** - All checks passed
- **1** - One or more checks failed

## What Gets Verified

### Management VPC (`verify_management_vpc.sh`)

- VPC existence and CIDR
- Internet Gateway attachment
- Public subnets in both AZs
- Route tables and routes (default to IGW, RFC1918 to TGW)
- TGW attachment (if enabled)
- Jump Box instance (if enabled)
- FortiManager instance (if enabled)
- FortiAnalyzer instance (if enabled)
- Instance IP addresses and public IP assignments

### Inspection VPC (`verify_inspection_vpc.sh`)

- VPC existence and CIDR
- Internet Gateway attachment
- All subnet types:
  - Public subnets (AZ1 and AZ2)
  - Private subnets (AZ1 and AZ2)
  - TGW subnets (AZ1 and AZ2)
  - GWLB subnets (AZ1 and AZ2)
  - NAT Gateway subnets (if `access_internet_mode = nat_gw`)
  - Management subnets (if enabled)
- Route tables for all subnet types
- Route table content verification
- TGW attachment with appliance mode
- NAT Gateways (if applicable)

### East VPC (`verify_east_vpc.sh`)

- VPC existence and CIDR
- Public and TGW subnets in both AZs
- Main route table with routes to TGW
- TGW attachment with appliance mode
- TGW route table association
- EC2 instances (if enabled)
- Security groups
- Instance IP addresses

### West VPC (`verify_west_vpc.sh`)

- Same checks as East VPC, but for West VPC resources

## Configuration

The scripts read configuration from `terraform.tfvars` in the parent directory (`../terraform.tfvars` relative to the scripts).

### Key Configuration Variables

The scripts automatically detect and adapt to these variables:

- `enable_build_management_vpc` - Enable/disable management VPC checks
- `enable_build_existing_subnets` - Enable/disable spoke VPC checks
- `enable_tgw_attachment` - Enable/disable TGW attachment checks
- `enable_management_tgw_attachment` - Enable/disable management VPC TGW attachment
- `enable_jump_box` - Enable/disable jump box checks
- `enable_fortimanager` - Enable/disable FortiManager checks
- `enable_fortianalyzer` - Enable/disable FortiAnalyzer checks
- `enable_linux_spoke_instances` - Enable/disable EC2 instance checks
- `access_internet_mode` - Affects NAT Gateway vs EIP checks
- `acl` - Affects public IP assignment checks

## Troubleshooting

### "VPC does not exist" errors

- Verify Terraform has been applied successfully
- Check that `cp` and `env` variables in `terraform.tfvars` match your deployment
- Verify AWS region is correct

### "Permission denied" errors

- Ensure scripts are executable: `chmod +x *.sh`
- Check AWS credentials have appropriate read permissions

### AWS CLI errors

- Ensure AWS CLI is installed: `aws --version`
- Verify credentials are configured: `aws sts get-caller-identity`
- Check you're in the correct AWS region

### Unexpected failures

- Review the detailed output to identify which specific check failed
- Verify the resource exists in AWS Console
- Check that `terraform.tfvars` matches your actual deployment
- Ensure Terraform apply completed successfully without errors

## Notes

1. These scripts are **read-only** and do not modify any AWS resources
2. Scripts must be run from the `verify_scripts` directory or use absolute paths
3. The scripts look for `terraform.tfvars` in the parent directory
4. Some checks may be skipped based on configuration flags
5. Resources are identified by Name tags using the format: `${cp}-${env}-<resource-name>`

## Support

For issues or questions:
- Review the verification prompt in `../verify_prompt.md`
- Check the Terraform configuration in the parent directory
- Ensure all prerequisites are met
- Review AWS CloudTrail logs for any deployment issues
