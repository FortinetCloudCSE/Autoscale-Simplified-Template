---
title: "Discovery"
menuTitle: "Discovery"
weight: 64
---

## Overview

### What discovery is for

Before anything is changed, the upgrade tools need to know exactly what they are working
on: which Auto Scaling groups and launch templates belong to the deployment, which load
balancer and Transit Gateway routes, which FortiGate is the primary, which FortiOS
version runs today, and which AMI is the target. Discovery collects all of that into one
file, `blue_inventory.json`. Every later step, in-place or blue-green, reads that file
instead of asking you for resource IDs.

"Blue" is the name the blue-green strategy gives to the existing environment. The same
inventory is used for an in-place upgrade.

### Where the information comes from

Discovery combines two sources:

- **The Terraform state file** says what was deployed. It is the authoritative list of
  the deployment's resources and their IDs. Because discovery reads the state directly,
  it does not depend on AWS tags or naming conventions, so it also works for deployments
  that were not created with the Simplified Template and do not follow the
  `{cp}-{env}-{resource}` convention.
- **Live AWS** says what is true right now: how many FortiGates are running, which one
  is the primary, and which AWS Marketplace AMI matches the target version.

### It changes nothing

Discovery only reads. It makes no change in AWS and none on the FortiGates, so it can be
run at any time and as often as you like, including well before the maintenance window
to see what an upgrade would do.

### What to do with the result

Discovery prints a summary: the current FortiOS version, the target AMI, the size of each
Auto Scaling group, the primary, and the upgrade path that applies. Read it before going
further. This is the cheapest place to catch a mistake, such as the wrong region or
account, an unexpected current version, or a group that is not in the state you thought.
If discovery cannot work something out safely (the region, the architecture, or an AMI
for the target version), it stops and says so instead of guessing.

### Keep it current

The inventory is a snapshot. Run discovery again shortly before the upgrade, from a fresh
copy of the Terraform state, and again after anything about the deployment changes.

{{% notice note %}}
The `state/` directory holds copies of the Terraform state and `terraform.tfvars`, which
contain credentials. It is excluded from git. Treat its contents as sensitive.
{{% /notice %}}

---

## Getting the State File

### Local State

If the deployment uses local Terraform state (default):

```bash
# Use the refresh script to copy fresh state into the working directory
bash upgrade_fortios/state/refresh.sh
```

`refresh.sh` copies these into `upgrade_fortios/state/`, renaming each after its template:
- `terraform/autoscale_template/terraform.tfstate` → `autoscale_template.tfstate`
- `terraform/autoscale_template/terraform.tfvars` → `autoscale_template.tfvars`
- `terraform/existing_vpc_resources/terraform.tfstate` → `existing_vpc_resources.tfstate`
- `terraform/existing_vpc_resources/terraform.tfvars` → `existing_vpc_resources.tfvars`

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
  --target-version 7.6.8 \
  --output state/blue_inventory.json
```

For blue-green upgrade, also provide the `existing_vpc_resources` state to discover
spoke TGW routes that `cutover.py` will flip:

```bash
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.8 \
  --output state/blue_inventory.json
```

| Argument | Description |
|----------|-------------|
| `--state` | Path to `autoscale_template.tfstate` |
| `--vpc-state` | Path to `existing_vpc_resources.tfstate` (blue-green only — adds spoke TGW routes) |
| `--target-version` | Target FortiOS version (e.g., `7.6.8`) — triggers AMI lookup |
| `--output` | Path for `blue_inventory.json` output (default: `blue_inventory.json`) |
| `--region` | AWS region of the deployment. Default: read from the state file, then from the AWS CLI profile |
| `--upgrade-path-verified` | Confirms that Fortinet's Upgrade Path Tool gives a single-step path from the running version to `--target-version`. Required for a blue-green discovery (`--vpc-state`) that crosses a minor or major version; without it discovery stops with an error and writes no inventory. The confirmation is recorded in the inventory, where `cutover.py` and `inplace_upgrade.py` read it. See [Check the upgrade path first](../6_3_blue_green_upgrade/#check-the-upgrade-path-first) |

Discovery stops with an error, and writes no inventory, when the region cannot be
determined, when the architecture of the current AMI cannot be read, or when no AMI for
the target version is found for one of the launch templates.

---

## What Is Discovered

| Category | Information Extracted |
|----------|-----------------------|
| **VPC** | VPC ID, CIDR block, region, availability zones |
| **Subnets** | IDs, CIDRs, and AZs for: public, private, GWLBE, NAT GW, management |
| **Internet Gateway** | IGW ID |
| **NAT Gateways** | NAT GW IDs, EIP allocation IDs, public IPs of the inspection VPC's NAT gateways. They are created by `existing_vpc_resources`, so they are found only when `--vpc-state` is given. `egress_mode` is `nat_gw` when any are found, `eip` otherwise |
| **Transit Gateway** | TGW ID, inspection attachment ID, TGW route table IDs, spoke attachment IDs, routes to update at cutover |
| **GWLB** | Load balancer ARN, listener ARN, target group ARN, endpoint IDs per AZ |
| **Auto Scaling Groups** | BYOL and On-Demand ASG names, launch template IDs/versions, desired/min/max, current instances, primary instance |
| **Instance Architecture** | x86 vs ARM64 (detected from current launch template AMI name) |
| **Target AMI** | AMI ID for target FortiOS version and detected architecture, from the same AWS Marketplace product as the current AMI |
| **Lambda** | Function name |
| **DynamoDB** | Table name |
| **CloudWatch** | Alarm names and current thresholds |
| **Security Groups** | Data plane and management security group IDs |
| **Egress Mode** | `nat_gw` or `eip` (determined from presence/absence of `aws_nat_gateway` resources) |

### Identifying the Primary Instance

The Lambda tags the elected primary `Autoscale Role: Primary`. `discover.py` reads that
tag from the live instances of each ASG:

```bash
# Manual verification using AWS CLI
aws ec2 describe-instances \
  --filters "Name=tag:Autoscale Role,Values=Primary" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text
```

If no instance carries the tag, discovery falls back to scale-in protection
(`ProtectedFromScaleIn`), and only when exactly one instance has it. Scale-in protection
is set only when the deployment has `primary_scalein_protection = true`.

`inplace_upgrade.py` identifies the primary again from live state when it runs, so an
inventory taken before a primary change does not send it to the wrong instance.

### Running Version and Version Change

The launch template in the state file is what Terraform last applied. After an in-place
upgrade that has not been reconciled it still names the old version. Discovery therefore
also reads the AMI of the running instances and reports the version the primary is
running (`architecture.running_fortios_version`), which is the version a configuration
backup would be taken on.

With `--target-version`, the inventory records the change as `version_change`:

```json
"version_change": {
  "from": "7.6.8",
  "to": "8.0.2",
  "kind": "major",
  "upgrade_path_verified": true
}
```

`kind` is `same`, `patch` (7.6.7 to 7.6.8), `minor` (7.4 to 7.6), `major` (7.6 to 8.0),
`downgrade`, or `unknown` when the running version cannot be read. `cutover.py` reads this
section and refuses a `minor`, `major` or `unknown` change that is not verified, and any
downgrade. `inplace_upgrade.py` applies the same rule to a config restore, using the
version in the backup file itself.

### Architecture and Target AMI

The architecture and the AWS Marketplace product code are read from the AMI the launch
template uses today (looked up by ID, which also works once that AMI is deprecated). The
target AMI is searched among images owned by AWS Marketplace with the same product code
whose name contains `(<target-version>)`. A name match alone is not accepted: anyone can
publish a public AMI with a FortiGate-looking name.

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
      {"instance_id": "i-xxx", "health": "Healthy", "lifecycle": "InService", "protected": true, "role": "Primary"},
      {"instance_id": "i-yyy", "health": "Healthy", "lifecycle": "InService", "protected": false, "role": "Secondary"}
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

The `desired` values show which in-place path applies. `inplace_upgrade.py` reads them
again from AWS when it starts, so the path follows the live group, not the inventory:
- Both `desired=0`, no `.conf` backup in `state/` → Path A
- Both `desired=0` + a `.conf` backup in `state/` → Path C
- Instances running → Path B

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

# Find primary FortiGate instance (tagged by the Lambda)
aws ec2 describe-instances \
  --filters "Name=tag:Autoscale Role,Values=Primary" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text
```

Populate a `blue_inventory.json` manually from these results if needed. Use the schema
above as a template.
