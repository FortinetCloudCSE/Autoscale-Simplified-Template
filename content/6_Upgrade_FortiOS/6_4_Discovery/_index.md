---
title: "Discovery"
menuTitle: "Discovery"
weight: 64
---

## Overview

`discover.py` extracts the complete Blue environment inventory from the existing
`terraform.tfstate` file and produces a structured `blue_inventory.json` used by
all subsequent upgrade phases.

Discovery does not rely on AWS resource tags — it reads the Terraform state directly.
This makes it reliable for deployments that were not created with the Simplified Template
and may not follow the `{cp}-{env}-{resource}` tag convention.

---

## Getting the State File

### Local State

If the deployment uses local Terraform state (default):

```bash
# Use the refresh script to copy fresh state into the working directory
bash upgrade_fortios/state/refresh.sh
```

`refresh.sh` copies:
- `terraform/autoscale_template/terraform.tfstate`
- `terraform/autoscale_template/terraform.tfvars`
- `terraform/existing_vpc_resources/terraform.tfstate`
- `terraform/existing_vpc_resources/terraform.tfvars`

into `upgrade_fortios/state/`.

### Remote State (S3 Backend)

If the deployment uses an S3 backend:

```bash
cd terraform/autoscale_template
terraform state pull > ../../upgrade_fortios/state/autoscale_template.tfstate

cd ../existing_vpc_resources
terraform state pull > ../../upgrade_fortios/state/existing_vpc_resources.tfstate
```

{{% notice warning %}}
Always pull a fresh state file before running discovery. An outdated state can produce
incorrect inventory results and cause scripts to target the wrong resources.
{{% /notice %}}

---

## Running Discovery

```bash
cd upgrade_fortios

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

For blue-green upgrade, also provide the `existing_vpc_resources` state to discover
spoke TGW routes that `cutover.py` will flip:

```bash
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

| Argument | Description |
|----------|-------------|
| `--state` | Path to `autoscale_template.tfstate` |
| `--vpc-state` | Path to `existing_vpc_resources.tfstate` (blue-green only — adds spoke TGW routes) |
| `--target-version` | Target FortiOS version (e.g., `7.6.2`) — triggers AMI lookup |
| `--output` | Path for `blue_inventory.json` output (default: `blue_inventory.json`) |

---

## What Is Discovered

| Category | Information Extracted |
|----------|-----------------------|
| **VPC** | VPC ID, CIDR block, region, availability zones |
| **Subnets** | IDs, CIDRs, and AZs for: public, private, GWLBE, NAT GW, management |
| **Internet Gateway** | IGW ID |
| **NAT Gateways** | NAT GW IDs, EIP allocation IDs, public IPs (if `nat_gw` egress mode) |
| **Transit Gateway** | TGW ID, inspection attachment ID, TGW route table IDs, spoke attachment IDs, routes to update at cutover |
| **GWLB** | Load balancer ARN, listener ARN, target group ARN, endpoint IDs per AZ |
| **Auto Scaling Groups** | BYOL and On-Demand ASG names, launch template IDs/versions, desired/min/max, current instances, primary instance |
| **Instance Architecture** | x86 vs ARM64 (detected from current launch template AMI name) |
| **Target AMI** | AMI ID for target FortiOS version and detected architecture |
| **Lambda** | Function name |
| **DynamoDB** | Table name |
| **CloudWatch** | Alarm names and current thresholds |
| **Security Groups** | Data plane and management security group IDs |
| **Egress Mode** | `nat_gw` or `eip` (determined from presence/absence of `aws_nat_gateway` resources) |

### Identifying the Primary Instance

The primary FortiGate has scale-in protection enabled. `discover.py` queries the live
ASG via `boto3` to find the instance where `ProtectedFromScaleIn` is `true`:

```bash
# Manual verification using AWS CLI
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='<byol_asg_name>' && ProtectedFromScaleIn==\`true\`]" \
  --output table
```

### Architecture Detection

| Launch Template AMI Name Contains | Architecture |
|-----------------------------------|-------------|
| `VMARM64-AWS` | ARM64 (BYOL) |
| `VM64-AWS` | x86 (BYOL) |
| `VMARM64-AWSONDEMAND` | ARM64 (On-Demand) |
| `VM64-AWSONDEMAND` | x86 (On-Demand) |

---

## blue_inventory.json Schema

All sections are top-level keys — there is no nesting under a `blue_environment` wrapper.

```json
{
  "discovery_metadata": {
    "state_file": "state/autoscale_template.tfstate",
    "vpc_state_file": "state/existing_vpc_resources.tfstate",
    "discovered_at": "2025-01-15T10:30:00Z",
    "region": "us-west-2"
  },
  "inspection_vpc": { "vpc_id": "vpc-xxx", "cidr_block": "10.0.0.0/16" },
  "subnets": [ { "id": "subnet-xxx", "cidr": "10.0.0.0/24", "az": "us-west-2a",
                  "role": "acme-test-inspection-public-az1", "name": "..." }, ... ],
  "nat_gateways": [
    { "id": "nat-xxx", "subnet_id": "subnet-aaa",
      "eip_allocation_id": "eipalloc-xxx", "public_ip": "203.0.113.10" }
  ],
  "egress_mode": "nat_gw",
  "gwlb": {
    "lb_arn": "arn:aws:elasticloadbalancing:...",
    "lb_name": "fortigate-gwlb",
    "target_group_arn": "arn:aws:elasticloadbalancing:...",
    "endpoint_ids": ["vpce-xxx", "vpce-yyy"]
  },
  "transit_gateway": {
    "tgw_id": "tgw-xxx",
    "inspection_attachment_id": "tgw-attach-xxx",
    "routes_to_update": [ ... ]
  },
  "architecture": {
    "arch": "x86_64",
    "current_ami_id": "ami-xxx",
    "current_ami_name": "FortiGate-VM64-AWS build1762 (7.2.13) ...",
    "current_fortios_version": "7.2.13"
  },
  "target": {
    "fortios_version": "7.6.2",
    "byol_ami_id": "ami-yyy",
    "byol_ami_name": "...",
    "ondemand_ami_id": "ami-zzz",
    "ondemand_ami_name": "..."
  },
  "launch_templates": {
    "byol":     { "id": "lt-xxx", "name": "...", "current_version": 1,
                  "current_ami_id": "ami-xxx", "license_type": "byol", "target_ami_id": "ami-yyy" },
    "ondemand": { "id": "lt-yyy", "name": "...", "current_version": 1,
                  "current_ami_id": "ami-xxx", "license_type": "ondemand", "target_ami_id": "ami-zzz" }
  },
  "autoscale_groups": { ... },
  "lambda": { "function_names": ["fgt-asg-handler-xxx"] },
  "dynamodb": { "table_name": "fgt_asg_track_table" },
  "cloudwatch_alarms": [ { "alarm_name": "...", "metric": "...", "threshold": 80, ... } ],
  "upgrade_path": "B",
  "upgrade_path_reason": "2 running instance(s) — rolling replacement",
  "vpc_resources": { ... }
}
```

> `vpc_resources` is only present when `--vpc-state` is provided. `target` is only
> present when `--target-version` is provided.

### Key Sections

#### `autoscale_groups`

```json
"autoscale_groups": {
  "byol": {
    "asg_name": "fgt-byol-asg-xxx",
    "license_type": "byol",
    "desired": 2,
    "min": 1,
    "max": 4,
    "instances": [
      {"instance_id": "i-xxx", "health": "Healthy", "lifecycle": "InService", "protected": true},
      {"instance_id": "i-yyy", "health": "Healthy", "lifecycle": "InService", "protected": false}
    ],
    "primary_instance": "i-xxx",
    "launch_template_id": "lt-xxx"
  },
  "ondemand": {
    "asg_name": "fgt-ondemand-asg-xxx",
    "license_type": "ondemand",
    "desired": 0,
    "min": 0,
    "max": 4,
    "instances": [],
    "primary_instance": null
  }
}
```

The `desired` values determine the in-place upgrade path:
- Both `desired=0`, no `.conf` backup → Path A
- Both `desired=0` + `state/blue_primary_config.conf` present → Path C
- Either `desired>0` → Path B

#### `transit_gateway.routes_to_update`

```json
"routes_to_update": [
  {
    "destination_cidr_block": "0.0.0.0/0",
    "route_table_id": "tgw-rtb-xxx",
    "current_attachment_id": "tgw-attach-xxx"
  }
]
```

Routes from the `autoscale_template` state managed by the Fortinet module.
`cutover.py` also merges `vpc_resources.cutover_routes` (from `--vpc-state`) which
contains spoke VPC TGW routes. Both sources are de-duplicated at cutover time.

---

## Manual Fallback

If the state file is unavailable or incomplete, resources can be identified using
AWS CLI queries:

```bash
# Find inspection VPC by CIDR
aws ec2 describe-vpcs \
  --filters "Name=cidr,Values=10.0.0.0/16" \
  --output table

# Find FortiGate ASGs
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'fgt')]" \
  --output table

# Find Gateway Load Balancer
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Type=='gateway']" \
  --output table

# Find TGW attachments for a VPC
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --output table

# Find primary FortiGate instance (scale-in protected)
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='<asg-name>' && ProtectedFromScaleIn==\`true\`]" \
  --output table
```

Populate a `blue_inventory.json` manually from these results if needed. Use the schema
above as a template.
