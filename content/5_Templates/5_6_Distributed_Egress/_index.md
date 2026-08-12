---
title: "Distributed Egress (Dual-Egress) VPCs"
chapter: false
menuTitle: "Distributed Egress"
weight: 56
---

## Overview

The FortiGate autoscale group can inspect traffic two ways at once: **centralized** egress, where spoke VPCs hairpin through the Transit Gateway to the Inspection VPC (the default architecture covered elsewhere in these templates), and **distributed** egress, where a workload VPC inspects its own outbound traffic locally through the same shared Gateway Load Balancer — no TGW hop involved.

{{% notice warning %}}
**Test/Lab Scaffolding, Not a Production Pattern**

The distributed-egress VPCs described on this page are built by `existing_vpc_resources` purely to validate the dual-egress design against real AWS infrastructure. They are not a template for how a customer's production distributed VPC should look — a real distributed VPC is typically pre-existing infrastructure you don't own the lifecycle of. See [Production VPC Discovery](#production-vpc-discovery) below for how that case is handled differently.
{{% /notice %}}

---

## Architecture

Both distributed VPCs are built by reusing the existing Inspection VPC module (`aws_inspection_vpc`) with its Transit Gateway attachment and NAT Gateway disabled — each gets:

- Its **own Internet Gateway**
- A **GWLBe subnet**, tagged for discovery, where `autoscale_template` attaches a GWLB Endpoint
- A **private (workload) subnet** — no default route until `autoscale_template` redirects it to the local GWLB Endpoint
- A **public subnet** hosting a traffic-generator Linux instance with an Elastic IP

The public subnet is intentionally kept out of the inspection path. Redirecting a subnet's default route to a GWLB Endpoint requires symmetric flow return — GWLB needs to see both directions of a connection through the same appliance. An inbound SSH session and its reply following different paths would violate that, so the reachable test instance lives in the subnet that's never redirected, while the private subnet models the actual traffic under test.

### Shared GWLB Endpoint Service

`autoscale_template` attaches a GWLB Endpoint per distributed VPC via the upstream autoscale module's native `spk_vpc` variable, using only `gwlbe_subnet_ids` (no `subnet_ids`). This lands on the **same** GWLB Endpoint Service the centralized/Inspection VPC path already uses — one shared GWLB, not one per distributed VPC. No `service_name` workaround is needed: `autoscale_template` already passes `existing_tgw = {}` to the upstream module, which makes its internal TGW resolve to `null`; every TGW-attachment side effect of `spk_vpc` is inert as a result, leaving only endpoint creation to actually take effect.

### Discovery

Two discovery mechanisms feed the same pool, unioned and deduped by subnet ID:

| Mechanism | Used for | Route table ownership |
|-----------|----------|------------------------|
| Fortinet-Role tag lookup | The lab VPCs built by `existing_vpc_resources` | `autoscale_template` redirects the private subnet's default route automatically |
| `distributed_egress_endpoint_subnet_ids` (explicit list) | A real customer VPC not built by this template | Endpoint only — route table changes are left to the customer |

#### Production VPC Discovery

For a customer's pre-existing distributed VPC, set `distributed_egress_endpoint_subnet_ids` in `autoscale_template/terraform.tfvars` to the GWLBe-placement subnet IDs directly. Terraform creates the GWLB Endpoint in each but never touches that VPC's route tables — pointing the workload subnet's default route at the new endpoint is a step you perform yourself, since this template doesn't own that infrastructure's lifecycle.

---

## Non-Overlapping vs. Overlapping CIDRs

The two lab VPCs can be deployed in either of two configurations:

### Phase 1 — Non-Overlapping (Default)

`vpc_cidr_distributed_1` and `vpc_cidr_distributed_2` are distinct, non-overlapping CIDRs. A `check` block validates this at plan time using real start/end IP range math (not just string comparison) — a plan fails immediately with a clear error if they overlap and `allow_distributed_cidr_overlap` isn't set.

### Phase 2 — Overlapping (Opt-In)

{{% notice warning %}}
**Standard FortiOS Cannot Disambiguate Overlapping CIDRs**

Setting both distributed VPCs to the same or overlapping CIDR is only meaningful if the FortiGate ASG is running a build capable of identifying which GWLB Endpoint (and therefore which VPC) a flow arrived from — standard FortiOS classifies traffic by source/destination CIDR alone, which becomes genuinely ambiguous once two VPCs share address space. This is a real architectural limitation being tested, not a Terraform toggle you can casually flip on a production-equivalent build.
{{% /notice %}}

Setting `allow_distributed_cidr_overlap = true` bypasses the check so `vpc_cidr_distributed_1`/`_2` can intentionally overlap — for example, both set to the same `/24` — to test whether a GWLBe-ID-aware FortiOS build removes the standard non-overlap requirement.

---

## Configuration

### existing_vpc_resources

```hcl
enable_build_distributed_egress_vpcs = true
vpc_cidr_distributed_1               = "10.100.0.0/24"
vpc_cidr_distributed_2               = "10.101.0.0/24"
distributed_subnet_bits              = 4
allow_distributed_cidr_overlap       = false   # true only when testing phase 2
```

### autoscale_template

```hcl
enable_distributed_egress = true

# Only needed for a real customer VPC not discovered via Fortinet-Role tags
# distributed_egress_endpoint_subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx"]
```

---

## Fortinet-Role Tags

`existing_vpc_resources` tags each distributed VPC's resources for discovery by `autoscale_template`, following the same pattern used by the Inspection VPC:

| Resource | Fortinet-Role Tag |
|----------|-------------------|
| VPC 1 / VPC 2 | `{cp}-{env}-distributed-1-vpc` / `{cp}-{env}-distributed-2-vpc` |
| IGW 1 / IGW 2 | `{cp}-{env}-distributed-1-igw` / `{cp}-{env}-distributed-2-igw` |
| Private subnet (AZ1/AZ2) | `{cp}-{env}-distributed-N-private-azX` |
| Private route table (AZ1/AZ2) | `{cp}-{env}-distributed-N-private-rt-azX` |
| GWLBe subnet (AZ1/AZ2) | `{cp}-{env}-distributed-N-gwlbe-azX` |

The GWLBe subnet's own route table is **not** tagged for external discovery — `existing_vpc_resources` wires its `0.0.0.0/0 → this VPC's own IGW` route directly via the module output, with no lookup needed by `autoscale_template`.

---

## Deployment Steps

### Step 1: Deploy the lab VPCs

```bash
cd terraform/existing_vpc_resources
# Set enable_build_distributed_egress_vpcs = true in terraform.tfvars
terraform apply
```

### Step 2: Verify the VPCs and routes

```bash
aws ec2 describe-vpcs --filters "Name=tag:Fortinet-Role,Values=*distributed*"
```

Confirm each VPC's GWLBe route table shows `0.0.0.0/0 → this VPC's own IGW`, and each private subnet route table shows only the local VPC CIDR (no default route yet).

### Step 3: Attach the GWLB Endpoints

```bash
cd terraform/autoscale_template
# Set enable_distributed_egress = true in terraform.tfvars
terraform apply
```

### Step 4: Verify the endpoint attachment

```bash
aws ec2 describe-vpc-endpoint-services   # confirm only one Endpoint Service exists
```

Re-check each distributed VPC's private subnet route table — it should now show `0.0.0.0/0 → vpce-xxxxxxxx`, pointing at the AZ-matched endpoint in that same VPC.

---

## Summary

| What to change | Where |
|-----------------|-------|
| Build the two lab VPCs | `existing_vpc_resources/terraform.tfvars`: `enable_build_distributed_egress_vpcs` |
| Set the CIDRs (phase 1 or 2) | `vpc_cidr_distributed_1`/`_2`, `allow_distributed_cidr_overlap` |
| Attach the GWLB Endpoints | `autoscale_template/terraform.tfvars`: `enable_distributed_egress` |
| Attach a real customer VPC | `distributed_egress_endpoint_subnet_ids` — endpoint only, route table left to the customer |
| Test overlapping CIDRs | Requires both `allow_distributed_cidr_overlap = true` and a FortiOS build that disambiguates by GWLBe ID |
