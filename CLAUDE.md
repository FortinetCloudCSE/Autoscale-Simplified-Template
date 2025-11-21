# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT:** When adding new files, directories, or significant architectural changes to this repository, update this CLAUDE.md file to reflect those changes. This ensures future Claude Code instances have accurate context about the codebase structure.

## Project Overview

This repository contains the **FortiGate Autoscale Simplified Template** - a Terraform-based solution that simplifies the deployment of FortiGate autoscale groups in AWS. It serves as a wrapper around Fortinet's enterprise-grade [terraform-aws-cloud-modules](https://github.com/fortinetdev/terraform-aws-cloud-modules) to reduce deployment complexity while maintaining architectural flexibility.

The project includes:
- Terraform templates for deploying FortiGate autoscale groups with AWS Gateway Load Balancer (GWLB)
- Supporting infrastructure templates for testing and lab environments
- Hugo-based documentation workshop hosted at https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/

## Repository Structure

### Terraform Templates

Two main Terraform template directories exist under `terraform/`:

1. **`terraform/autoscale_template/`** - Core FortiGate autoscale deployment
   - Wraps the upstream `terraform-aws-cloud-modules` module
   - Main entry point: `autoscale_group.tf` (module invocation)
   - Configuration abstraction: `easy_autoscale.tf` (data sources and locals)
   - NAT Gateway logic: `nat_gw.tf`
   - FortiGate configuration templates: `*-arm-*-fgt-conf.cfg` files (1-arm/2-arm modes)
   - License directory: `asg_license/` for BYOL license files

2. **`terraform/existing_vpc_resources/`** - Optional supporting infrastructure for testing
   - Creates management VPCs, Transit Gateway, spoke VPCs, and test instances
   - Split across multiple files: `vpc_management.tf`, `vpc_inspection.tf`, `vpc_east.tf`, `vpc_west.tf`, `tgw.tf`, `ec2.tf`
   - User-data templates in `config_templates/`:
     - `fmgr-userdata.tftpl` - FortiManager instance initialization
     - `faz-userdata.tftpl` - FortiAnalyzer instance initialization
     - `jump-box-userdata.tpl` - Management VPC jump box/bastion host (basic tooling, no NAT forwarding)
     - `spoke-instance-userdata.tpl` - East/West spoke VPC test instances (web server, FTP, traffic generation tools)
     - `web-userdata.tpl` - Legacy template (deprecated, replaced by spoke-instance-userdata.tpl)

### Documentation

The `content/` directory contains Hugo-formatted markdown for the workshop documentation:
- `1_Introduction/` - Overview and prerequisites
- `2_Overview/` - Architecture and key benefits
- `3_Licensing/` - BYOL, PAYG, and FortiFlex licensing models
- `4_Solution_Components/` - In-depth architectural explanations
- `5_Templates/` - Deployment procedures and configuration examples

## Key Architectural Concepts

### Deployment Modes

**Firewall Policy Mode:**
- `1-arm`: Single interface for data plane (hairpin traffic pattern)
- `2-arm`: Separate trusted/untrusted interfaces (traditional firewall model)

**Internet Access Mode:**
- `eip`: Elastic IP per FortiGate instance (distributed egress)
- `nat_gw`: NAT Gateway for centralized egress (requires additional configuration)

**Management Options:**
- Standard: Management via data plane interfaces
- `enable_dedicated_management_eni`: Dedicated management ENI in inspection VPC
- `enable_dedicated_management_vpc`: Management in separate VPC (requires existing_vpc_resources)

### Resource Naming Convention

Resources use the pattern: `{cp}-{env}-{resource_name}`
- `cp` (Customer Prefix): Company/project identifier (e.g., "acme")
- `env` (Environment): Environment name (e.g., "test", "prod")
- Example: "acme-test-inspection-vpc"

**Critical:** The `cp` and `env` values MUST match between `existing_vpc_resources` and `autoscale_template` for resource discovery via AWS tags.

### Module Integration

The autoscale template invokes the upstream module from:
```
git::https://github.com/fortinetdev/terraform-aws-cloud-modules.git//examples/spk_tgw_gwlb_asg_fgt_igw
```

The simplified template (`easy_autoscale.tf`) uses data sources to discover existing resources by tag names and constructs the complex nested map structures required by the upstream module.

## Terraform Workflow

**Important:** Deploy `existing_vpc_resources` BEFORE `autoscale_template` if using both templates together for testing.

### For existing_vpc_resources

```bash
cd terraform/existing_vpc_resources

# Same workflow as above
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform plan
terraform apply
```

### For autoscale_template

```bash
cd terraform/autoscale_template

# Initialize (required after cloning or module changes)
terraform init

# Copy and customize configuration
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Validate configuration
terraform validate

# Preview changes
terraform plan

# Deploy infrastructure
terraform apply

# Destroy when done
terraform destroy
```

## Configuration File Locations

### Primary Configuration Files

- `terraform/autoscale_template/terraform.tfvars.example` - Main autoscale configuration template
- `terraform/existing_vpc_resources/terraform.tfvars.example` - Supporting infrastructure configuration
- Both `.example` files should be copied to `terraform.tfvars` and customized

### FortiGate Configuration Templates

Located in `terraform/autoscale_template/`:
- `1-arm-fgt-conf.cfg` - Single interface mode
- `2-arm-fgt-conf.cfg` - Dual interface mode
- `1-arm-wdm-fgt-conf.cfg` - Single interface with dedicated management VPC
- `2-arm-wdm-eni-fgt-conf.cfg` - Dual interface with dedicated management ENI
- etc.

The correct template is selected automatically based on `firewall_policy_mode`, `enable_dedicated_management_vpc`, and `enable_dedicated_management_eni` variables.

### Linux Instance User-Data Templates

Located in `terraform/existing_vpc_resources/config_templates/`:

- **`jump-box-userdata.tpl`** - Management VPC jump box/bastion host
  - Basic system tools (sysstat, net-tools, awscli, apache2)
  - Terraform tooling (tfenv with version 1.7.5)
  - AWS credential configuration
  - **Does NOT include** NAT forwarding or iptables configuration
  - Used by: Management VPC jump box instance

- **`spoke-instance-userdata.tpl`** - Spoke VPC test instances (East/West)
  - All tools from jump-box template plus:
  - iperf3 for network performance testing
  - vsftpd for FTP testing
  - Sample FortiGate configuration examples
  - **Does NOT include** NAT forwarding or iptables configuration (removed to prevent instances acting as routers)
  - Used by: East and West spoke VPC Linux instances

- **`fmgr-userdata.tftpl`** - FortiManager initialization template
  - License injection
  - Admin password configuration
  - Hostname customization

- **`faz-userdata.tftpl`** - FortiAnalyzer initialization template
  - License injection
  - Admin password configuration
  - Hostname customization

**Note:** The original `web-userdata.tpl` included NAT forwarding configuration that allowed instances to forward traffic. This has been removed in the new spoke-instance templates to prevent security issues and unintended routing behavior.

## Important Variables

### Critical Matching Values

These must match between templates:
- `cp` - Customer prefix
- `env` - Environment name
- `attach_to_tgw_name` - Transit Gateway name (if using TGW)
- `vpc_cidr_management` - Management VPC CIDR

### Security Variables

- `keypair` - Existing EC2 key pair name (must exist in region)
- `my_ip` - Your IP/CIDR for security group rules
- `fortigate_asg_password` - FortiGate admin password (required)
- `fortimanager_admin_password` - FortiManager admin password (if enabled)
- `fortianalyzer_admin_password` - FortiAnalyzer admin password (if enabled)

## License Management

### FortiGate Licenses

Place BYOL license files in `terraform/autoscale_template/asg_license/`:
- BYOL licenses: `license1.lic`, `license2.lic`, etc.
- FortiFlex: Lambda function generates tokens (no files needed)
- PAYG: Uses AWS Marketplace licensing (no files needed)

### FortiManager/FortiAnalyzer Licenses

Place in separate directory (NOT in `asg_license/`):
- Specify path in `fortimanager_license_file` variable
- Specify path in `fortianalyzer_license_file` variable
- Leave empty ("") for PAYG instances

## Documentation Development

### Building Documentation Locally

The documentation uses Hugo and runs in Docker:

```bash
# Build documentation site
npm run hugo

# Output goes to docs/ directory
```

This runs a Docker container with the Hugo static site generator. The documentation is published to GitHub Pages from the `docs/` directory.

### Documentation Configuration

- `config.toml` - Hugo site configuration
- `content/` - Markdown content files
- `layouts/` - Custom Hugo templates (if present)
- `docs/` - Generated static site (git-tracked for GitHub Pages)

## Git Workflow

Current branch: `add_ha`
Main branch: `main`

The repository uses feature branches for development. Current work involves adding HA (High Availability) capabilities to the templates.

## Troubleshooting

### Terraform Debug Logging

Enable detailed logging:
```bash
export TF_LOG=DEBUG
export TF_LOG_PATH=terraform_debug.log
terraform apply
```

### Common Issues

1. **Resource not found errors**: Verify `cp` and `env` values match between templates
2. **License application failures**: Ensure license files are in correct directory and Lambda has S3 permissions
3. **FortiManager connection failures**: Check `fortimanager_ip` is reachable from FortiGate management interfaces
4. **CIDR overlap errors**: Ensure all VPC CIDRs are non-overlapping

### Validation Scripts

The `terraform/existing_vpc_resources/verify_scripts/` directory contains scripts for validating deployments (if present).

## AWS Requirements

### Required AWS Resources

- EC2 key pair (must exist before deployment)
- S3 bucket (for BYOL licenses)
- Sufficient EC2 instance limits for autoscale group size

### AWS Permissions Needed

Terraform requires IAM permissions for:
- VPC, subnet, route table, IGW operations
- EC2 instance, security group, ENI operations
- Gateway Load Balancer and endpoints
- Transit Gateway and attachments
- Lambda function deployment
- IAM role/policy creation
- CloudWatch logs and alarms

## Cost Considerations

Estimated monthly costs for full lab deployment:
- FortiGate instances: Varies by instance type and licensing
- FortiManager m5.xlarge: ~$73/month
- FortiAnalyzer m5.xlarge: ~$73/month
- Transit Gateway: ~$36/month + data processing
- NAT Gateways: $0.045/hour per AZ + data processing
- Gateway Load Balancer: ~$22/month + data processing

Always `terraform destroy` test environments when not in use to minimize costs.

## External References

- Upstream module: https://github.com/fortinetdev/terraform-aws-cloud-modules
- FortiGate documentation: https://docs.fortinet.com/
- Workshop site: https://fortinetcloudcse.github.io/Autoscale-Simplified-Template/
