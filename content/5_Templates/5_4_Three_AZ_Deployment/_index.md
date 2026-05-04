---
title: "Three Availability Zone Deployment"
chapter: false
menuTitle: "3-AZ Deployment"
weight: 54
---

## Overview

By default, both templates deploy into two Availability Zones. Setting the `availability_zone_3` variable enables a third AZ across the Inspection VPC, Management VPC, and all spoke infrastructure. Existing 2-AZ deployments are unaffected — the variable defaults to empty string.

{{% notice info %}}
**Backward Compatible**: All AZ3 resources are conditional on `availability_zone_3 != ""`. Omitting the variable or leaving it empty produces an identical 2-AZ deployment.
{{% /notice %}}

---

## What Changes in a 3-AZ Deployment

### Inspection VPC

Each subnet type gains a third AZ subnet and corresponding route table:

| Subnet Type | AZ1 | AZ2 | AZ3 |
|-------------|-----|-----|-----|
| Public | ✅ | ✅ | ✅ |
| GWLBE | ✅ | ✅ | ✅ |
| Private (TGW) | ✅ | ✅ | ✅ |
| NAT GW | ✅ (if enabled) | ✅ (if enabled) | ✅ (if enabled) |
| Management | ✅ (if enabled) | ✅ (if enabled) | ✅ (if enabled) |

The TGW attachment is updated to include the AZ3 private subnet.

### Management VPC

A third public and private subnet are created in AZ3. The TGW attachment includes the AZ3 private subnet. The jump box default route is extended to the AZ3 private route table.

### Spoke VPCs (East / West)

Each spoke VPC gets an AZ3 public subnet and TGW attachment subnet. The TGW attachments for east and west include the AZ3 subnets.

### autoscale_template

- `availability_zones` passed to the upstream ASG module expands from 2 to 3 entries
- `existing_subnets` gains `fgt_login_az3`, `gwlbe_az3`, and `fgt_internal_az3`
- A third GWLB endpoint (`endpoint_name_az3`) is looked up and used to route the AZ3 private subnet
- Management ENI subnet list expands to include AZ3 (if dedicated management is enabled)

---

## CIDR Considerations

### Inspection VPC

The inspection VPC module calculates subnet CIDRs using a dynamic offset pattern. AZ3 subnets use `2 × offset` from the AZ1 base index — the same pattern already used for AZ2 (`1 × offset`).

With `subnet_bits = 8` on a `/16` VPC CIDR, each subnet is `/24`. Up to 5 subnet types × 3 AZs = 15 subnets — well within the 256 available `/24` blocks.

**Minimum inspection VPC size**: `/21` with `subnet_bits = 8` (supports 8 subnets; 3-AZ uses up to 15).  
**Recommended**: `/16` with `subnet_bits = 8`.

### Spoke VPCs

Spoke VPCs use `spoke_subnet_bits` to carve subnets. Each spoke needs 6 subnets (2 types × 3 AZs) at indices 0–5.

With `spoke_subnet_bits = 4` on a `/24` spoke VPC CIDR, you get 16 possible `/28` subnets — 6 are used.

**Minimum spoke VPC size**: `/24` with `spoke_subnet_bits = 4`.

---

## Fortinet-Role Tags Added for AZ3

The following additional `Fortinet-Role` tags are applied by `existing_vpc_resources` when `availability_zone_3` is set:

| Resource | Fortinet-Role Tag |
|----------|-------------------|
| Public Subnet AZ3 | `{cp}-{env}-inspection-public-az3` |
| GWLBE Subnet AZ3 | `{cp}-{env}-inspection-gwlbe-az3` |
| Private Subnet AZ3 | `{cp}-{env}-inspection-private-az3` |
| Management Subnet AZ3 | `{cp}-{env}-inspection-management-az3` (if mgmt ENI enabled) |
| NAT GW Subnet AZ3 | `{cp}-{env}-inspection-natgw-az3` (if nat_gw mode) |
| Public Route Table AZ3 | `{cp}-{env}-inspection-public-rt-az3` |
| GWLBE Route Table AZ3 | `{cp}-{env}-inspection-gwlbe-rt-az3` |
| Private Route Table AZ3 | `{cp}-{env}-inspection-private-rt-az3` |
| NAT GW Route Table AZ3 | `{cp}-{env}-inspection-natgw-rt-az3` (if nat_gw mode) |
| Management Route Table AZ3 | `{cp}-{env}-inspection-management-rt-az3` (if mgmt ENI enabled) |
| NAT Gateway AZ3 | `{cp}-{env}-inspection-natgw-az3` (if nat_gw mode) |
| Management Public Subnet AZ3 | `{cp}-{env}-management-public-az3` |

These tags are automatically discovered by `autoscale_template` data sources — no manual configuration required.

---

## Configuration

### existing_vpc_resources

Add `availability_zone_3` to `terraform.tfvars`:

```hcl
aws_region          = "us-west-2"
availability_zone_1 = "a"
availability_zone_2 = "b"
availability_zone_3 = "c"   # Add this line
```

No other changes are required. All AZ3 resources are conditional on this value.

### autoscale_template

Add the same `availability_zone_3` value and the AZ3 GWLB endpoint name:

```hcl
aws_region          = "us-west-2"
availability_zone_1 = "a"
availability_zone_2 = "b"
availability_zone_3 = "c"           # Must match existing_vpc_resources

endpoint_name_az1 = "asg-gwlbe_az1"
endpoint_name_az2 = "asg-gwlbe_az2"
endpoint_name_az3 = "asg-gwlbe_az3"  # Add this line
```

{{% notice warning %}}
**Variable Coordination**

`availability_zone_3` must match exactly between `existing_vpc_resources` and `autoscale_template`, the same as `availability_zone_1` and `availability_zone_2`. A mismatch will cause `autoscale_template` data source lookups to fail.
{{% /notice %}}

### Finding the AZ3 GWLB Endpoint Name

The GWLB endpoint names are assigned by the upstream autoscale module. After `autoscale_template` apply completes, verify the endpoint names with:

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=<inspection-vpc-id>" \
            "Name=vpc-endpoint-type,Values=GatewayLoadBalancer" \
  --query 'VpcEndpoints[*].Tags[?Key==`Name`].Value' \
  --output table
```

The AZ3 endpoint name follows the same naming pattern as AZ1 and AZ2 — typically `{prefix}-gwlbe_az3`.

---

## Deployment Steps

### Step 1: Verify AZ Availability

Confirm your target region has at least three AZs and that the desired AZ suffix is valid:

```bash
aws ec2 describe-availability-zones \
  --region us-west-2 \
  --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' \
  --output table
```

### Step 2: Verify CIDR Capacity

Ensure your inspection VPC CIDR is large enough for the additional AZ3 subnets. See [CIDR Considerations](#cidr-considerations) above.

### Step 3: Update existing_vpc_resources tfvars

Add `availability_zone_3` to `terraform/existing_vpc_resources/terraform.tfvars`.

### Step 4: Re-initialize and Plan

```bash
cd terraform/existing_vpc_resources
terraform init -upgrade   # Required to pick up new module versions
terraform plan
```

Expected: additional subnet, route table, and tag resources for AZ3 in the plan output.

### Step 5: Apply existing_vpc_resources

```bash
terraform apply
```

### Step 6: Update autoscale_template tfvars

Add `availability_zone_3` and `endpoint_name_az3` to `terraform/autoscale_template/terraform.tfvars`.

### Step 7: Re-initialize and Plan

```bash
cd terraform/autoscale_template
terraform init -upgrade
terraform plan
```

### Step 8: Apply autoscale_template

```bash
terraform apply
```

---

## Outputs

`existing_vpc_resources` includes AZ3 subnet ID outputs for reference:

| Output | Description |
|--------|-------------|
| `inspection_subnet_public_az3_id` | Public subnet ID in AZ3 |
| `inspection_subnet_gwlbe_az3_id` | GWLBE subnet ID in AZ3 |
| `inspection_subnet_private_az3_id` | Private subnet ID in AZ3 |

---

## Upgrading an Existing 2-AZ Deployment

Adding `availability_zone_3` to an existing deployment is non-destructive. Terraform will add the new AZ3 resources without modifying the AZ1/AZ2 resources.

{{% notice warning %}}
**TGW Attachment Update**

Adding AZ3 requires modifying the existing TGW attachments for the inspection, east, and west VPCs to include the new AZ3 subnets. Terraform handles this automatically, but the TGW attachment update causes a brief interruption (~30 seconds) while AWS processes the change.

Plan this during a maintenance window if the environment is carrying production traffic.
{{% /notice %}}

To add a third AZ to an existing 2-AZ deployment:

```bash
# existing_vpc_resources
cd terraform/existing_vpc_resources
# Add availability_zone_3 to terraform.tfvars
terraform init -upgrade
terraform plan   # Review the plan — expect only additions and TGW attachment updates
terraform apply

# autoscale_template
cd terraform/autoscale_template
# Add availability_zone_3 and endpoint_name_az3 to terraform.tfvars
terraform init -upgrade
terraform plan
terraform apply
```

---

## Summary

| What to change | Where |
|---------------|-------|
| Add `availability_zone_3 = "c"` | Both `terraform.tfvars` files |
| Add `endpoint_name_az3` | `autoscale_template/terraform.tfvars` only |
| Run `terraform init -upgrade` | Both template directories |
| Everything else | Automatic — no code changes needed |
