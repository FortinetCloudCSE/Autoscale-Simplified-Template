# Blue Environment Discovery

## Overview

Discovery extracts the complete Blue environment inventory from the existing Terraform state
files. This avoids relying on AWS resource tags, which may not be present or consistent on
manually deployed environments.

## Getting the State Files

### Local State
If the customer's deployment uses local state, use the refresh script:
```bash
cd upgrade_fortios
bash state/refresh.sh
```

`refresh.sh` copies:
- `terraform/autoscale_template/terraform.tfstate` → `state/autoscale_template.tfstate`
- `terraform/existing_vpc_resources/terraform.tfstate` → `state/existing_vpc_resources.tfstate`

### Remote State (S3 Backend)
If the customer uses an S3 backend, pull state locally:
```bash
cd terraform/autoscale_template
terraform state pull > ../../upgrade_fortios/state/autoscale_template.tfstate

cd ../existing_vpc_resources
terraform state pull > ../../upgrade_fortios/state/existing_vpc_resources.tfstate
```

## What the State Files Contain

### autoscale_template.tfstate
- Inspection VPC ID and CIDR block
- Subnet IDs, CIDRs, and AZs
- Internet Gateway ID
- NAT Gateway IDs and EIP allocation IDs (if `access_internet_mode = "nat_gw"`)
- TGW attachment ID and TGW route table ID (inspection VPC attachment)
- TGW routes managed by the module
- GWLB ARN, target group ARN, and endpoint IDs
- BYOL and On-Demand ASG names, desired/min/max
- Launch template IDs and current AMI
- Lambda function name(s)
- DynamoDB table name
- CloudWatch alarm names and thresholds

### existing_vpc_resources.tfstate (optional — for blue-green)
- Spoke VPC TGW attachments and route tables
- TGW default routes pointing to inspection attachment (these are what `cutover.py` flips)

## Running Discovery

```bash
cd upgrade_fortios

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

For blue-green upgrade, also pass the existing_vpc_resources state to discover spoke
TGW routes:

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
| `--vpc-state` | Path to `existing_vpc_resources.tfstate` (for TGW cutover routes) |
| `--target-version` | Target FortiOS version (e.g., `7.6.2`) — triggers AMI lookup |
| `--output` | Path for `blue_inventory.json` output (default: `blue_inventory.json`) |

## Discovery Script Output: blue_inventory.json

The `discover.py` script produces a flat JSON file. All sections are top-level keys.

### Actual Schema

```json
{
  "discovery_metadata": {
    "state_file": "state/autoscale_template.tfstate",
    "vpc_state_file": "state/existing_vpc_resources.tfstate",
    "discovered_at": "2025-01-15T10:30:00Z",
    "region": "us-west-2"
  },

  "inspection_vpc": {
    "vpc_id": "vpc-xxxxxxxxxxxxxxxxx",
    "cidr_block": "10.0.0.0/16"
  },

  "subnets": [
    {"id": "subnet-xxx", "cidr": "10.0.0.0/24", "az": "us-west-2a",
     "role": "acme-test-inspection-public-az1", "name": "acme-test-inspection-public-az1"},
    {"id": "subnet-yyy", "cidr": "10.0.2.0/24", "az": "us-west-2a",
     "role": "acme-test-inspection-private-az1", "name": "acme-test-inspection-private-az1"}
  ],

  "nat_gateways": [
    {"id": "nat-xxx", "subnet_id": "subnet-aaa",
     "eip_allocation_id": "eipalloc-xxx", "public_ip": "203.0.113.10"},
    {"id": "nat-yyy", "subnet_id": "subnet-bbb",
     "eip_allocation_id": "eipalloc-yyy", "public_ip": "203.0.113.11"}
  ],

  "egress_mode": "nat_gw",

  "gwlb": {
    "lb_arn": "arn:aws:elasticloadbalancing:us-west-2:...",
    "lb_name": "fortigate-gwlb",
    "target_group_arn": "arn:aws:elasticloadbalancing:us-west-2:...",
    "endpoint_ids": ["vpce-xxx", "vpce-yyy"]
  },

  "transit_gateway": {
    "tgw_id": "tgw-xxxxxxxxxxxxxxxxx",
    "inspection_attachment_id": "tgw-attach-xxx",
    "routes_to_update": [
      {
        "destination_cidr_block": "0.0.0.0/0",
        "route_table_id": "tgw-rtb-xxx",
        "current_attachment_id": "tgw-attach-xxx"
      }
    ]
  },

  "architecture": {
    "arch": "x86_64",
    "current_ami_id": "ami-xxxxxxxxxxxxxxxxx",
    "current_ami_name": "FortiGate-VM64-AWS build1762 (7.2.13) ...",
    "current_fortios_version": "7.2.13"
  },

  "target": {
    "fortios_version": "7.6.2",
    "byol_ami_id": "ami-yyyyyyyyyyyyyyy",
    "byol_ami_name": "FortiGate-VM64-AWS build1234 (7.6.2) ...",
    "ondemand_ami_id": "ami-zzzzzzzzzzzzzzz",
    "ondemand_ami_name": "FortiGate-VM64-AWSONDEMAND build1234 (7.6.2) ..."
  },

  "launch_templates": {
    "byol": {
      "id": "lt-xxx",
      "name": "fgt-byol-lt",
      "current_version": 1,
      "current_ami_id": "ami-xxxxxxxxxxxxxxxxx",
      "license_type": "byol",
      "target_ami_id": "ami-yyyyyyyyyyyyyyy"
    },
    "ondemand": {
      "id": "lt-yyy",
      "name": "fgt-ondemand-lt",
      "current_version": 1,
      "current_ami_id": "ami-xxxxxxxxxxxxxxxxx",
      "license_type": "ondemand",
      "target_ami_id": "ami-zzzzzzzzzzzzzzz"
    }
  },

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
  },

  "lambda": {
    "function_names": ["fgt-asg-handler-xxx"]
  },

  "dynamodb": {
    "table_name": "fgt_asg_track_table"
  },

  "cloudwatch_alarms": [
    {
      "alarm_name": "fgt-cpu-scale-out",
      "metric": "CPUUtilization",
      "threshold": 80,
      "comparison": "GreaterThanOrEqualToThreshold",
      "evaluation_periods": 2,
      "period": 120
    },
    {
      "alarm_name": "fgt-cpu-scale-in",
      "metric": "CPUUtilization",
      "threshold": 30,
      "comparison": "LessThanThreshold",
      "evaluation_periods": 2,
      "period": 120
    }
  ],

  "upgrade_path": "B",
  "upgrade_path_reason": "2 running instance(s) — rolling replacement",

  "vpc_resources": {
    "vpcs": [ ... ],
    "tgw_route_tables": { "spoke_east": "tgw-rtb-xxx", "spoke_west": "tgw-rtb-yyy" },
    "tgw_attachments": [ ... ],
    "cutover_routes": [
      {
        "destination_cidr_block": "0.0.0.0/0",
        "route_table_id": "tgw-rtb-xxx",
        "current_attachment_id": "tgw-attach-blue-xxx"
      }
    ]
  }
}
```

> **Note:** `vpc_resources` is only present when `--vpc-state` is provided.

---

## Key Fields for Each Upgrade Type

### In-Place Upgrade

`inplace_upgrade.py` reads:
- `autoscale_groups.byol.desired` / `autoscale_groups.ondemand.desired` — path detection
- `autoscale_groups.byol.asg_name` — ASG to operate on
- `autoscale_groups.byol.primary_instance` — instance to terminate last (Path B)
- `launch_templates.byol.id` / `launch_templates.ondemand.id` — LTs to update
- `target.byol_ami_id` / `target.ondemand_ami_id` — new AMI to set

### Blue-Green Cutover

`cutover.py` reads:
- `transit_gateway.routes_to_update` and `vpc_resources.cutover_routes` — TGW routes to flip
- `transit_gateway.inspection_attachment_id` — current Blue attachment (for `rollback.py`)
- `nat_gateways` — Blue NAT GW IDs and EIP allocation IDs (for EIP migration)
- `egress_mode` — determines whether EIP migration runs

---

## Identifying the Primary FortiGate Instance

The primary instance has scale-in protection enabled. To find it:

```bash
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='<byol_asg_name>' && ProtectedFromScaleIn==\`true\`]" \
  --output table
```

The primary instance is the one where `ProtectedFromScaleIn` is `true`.

---

## Manual Fallback

If the state file is unavailable or incomplete, resources can be identified manually:

```bash
# Find inspection VPC by name or CIDR
aws ec2 describe-vpcs --filters "Name=cidr,Values=10.0.0.0/16" --output table

# Find ASGs related to FortiGate
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'fgt')]" \
  --output table

# Find GWLB
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Type=='gateway']" \
  --output table

# Find TGW attachments for a VPC
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --output table
```
