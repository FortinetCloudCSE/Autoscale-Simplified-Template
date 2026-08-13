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
- A **private (workload) subnet** — no default route until `autoscale_template` redirects it to the local GWLB Endpoint. This is also where the traffic-generator Linux instance lives, with a real Elastic IP.
- An unused public subnet (created by the reused module regardless; nothing is deployed into it)

### Both Directions Through the FortiGate

The traffic-generator instance's EIP lives on an ENI in the **private** subnet, not a separate public subnet — that matters for getting both directions inspected:

- **Outbound**: the private subnet's own default route sends traffic to the AZ-matched GWLBe (`autoscale_template` wires this once the endpoint exists).
- **Inbound**: traffic to the EIP arrives at the VPC's IGW, which does its standard 1:1 EIP↔private-IP NAT — that's normal AWS behavior and happens regardless of anything else. What normally happens next (plain destination-based routing straight to the instance) is intercepted by an **Ingress Routing table** (an AWS "Edge Association" — a route table attached to the gateway itself, not a subnet). The reused `aws_inspection_vpc` module already creates and associates one of these per VPC (the same mechanism the Inspection VPC itself relies on) — AWS allows only one such association per Internet Gateway, so `autoscale_template` discovers that existing table (by its gateway association, not a new one) and adds one route per AZ to it: that AZ's private-subnet CIDR → the matching GWLB Endpoint. So the post-NAT packet gets redirected to the FortiGate before it ever reaches the instance.

Both legs land on the FortiGate's `private-zone` and get hairpinned straight back out the same geneve tunnel they arrived on (no NAT at the FortiGate — the IGW already did the only translation needed), and GWLB's own routing continues delivery from there: inbound continues on to the instance, outbound continues on to the internet via the same IGW.

An earlier version of this design deployed the test instance into a separate, unredirected public subnet specifically to avoid this — inbound and outbound looked like they had to take different paths, which would have broken GWLB's symmetric-flow requirement. That reasoning doesn't hold once both directions go through Ingress Routing and the private subnet's default route respectively — they're both symmetric through the same AZ's GWLBe, so keeping the instance out of the inspection path was unnecessary (and meant the instance was never actually being inspected at all).

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

## How the FortiGate Classifies Distributed Traffic

Distributed VPC traffic arrives on the **same shared `geneve-az1`/`geneve-az2` tunnels** the centralized/Inspection VPC path already uses — there's no new zone, tunnel, or firewall policy involved. The existing `private_to_internet`/`private_to_private` policies in the `*-fgt-conf.cfg.tftpl` templates are already `srcaddr`/`dstaddr "all"`, so once traffic lands in `private-zone` it's already handled.

The one piece that has to be correct is routing: the FortiGate needs a `config router static` entry per distributed VPC CIDR so it knows to route traffic destined for it back out the right geneve device. `autoscale_template` handles this automatically — every discovered distributed VPC's CIDR (tag-discovered lab VPCs, plus any `distributed_egress_endpoint_subnet_ids` VPCs) is merged into the FortiGate's `spoke_cidrs` list behind the scenes. You don't need to add these CIDRs to `spoke_cidrs` yourself.

{{% notice warning %}}
**Requires Non-Overlapping CIDRs**

Classification here is CIDR-based, so `vpc_cidr_distributed_1` and `vpc_cidr_distributed_2` must be distinct, non-overlapping CIDRs — otherwise the FortiGate can't tell which VPC a flow belongs to. A `check` block validates this at plan time using real start/end IP range math (not just string comparison), and fails the plan immediately if they overlap and `allow_distributed_cidr_overlap` isn't set. Leave `allow_distributed_cidr_overlap` at its default (`false`).
{{% /notice %}}

---

## Configuration

### existing_vpc_resources

```hcl
enable_build_distributed_egress_vpcs = true
vpc_cidr_distributed_1               = "10.100.0.0/24"
vpc_cidr_distributed_2               = "10.101.0.0/24"
distributed_subnet_bits              = 4
allow_distributed_cidr_overlap       = false   # leave false
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

Also check the Ingress Routing table associated with each VPC's IGW:

```bash
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<distributed-vpc-id>"
```

Look for a route table associated to the IGW itself (not a subnet — `Associations[].GatewayId` will be set instead of `SubnetId`), with one route per AZ: that AZ's private-subnet CIDR → `vpce-xxxxxxxx`.

### Step 5: Verify the FortiGate's static routes

On a primary FortiGate instance:

```
config router static
    show
```

You should see an entry per distributed VPC CIDR (in addition to the east/west spoke entries), each pointing at a `geneve-azN` device. If a distributed VPC's CIDR is missing, double-check it was actually discovered — either by Fortinet-Role tag (Step 2) or via `distributed_egress_endpoint_subnet_ids`.

---

## Summary

| What to change | Where |
|-----------------|-------|
| Build the two lab VPCs | `existing_vpc_resources/terraform.tfvars`: `enable_build_distributed_egress_vpcs` |
| Set the CIDRs (must be non-overlapping) | `vpc_cidr_distributed_1`/`_2` |
| Attach the GWLB Endpoints | `autoscale_template/terraform.tfvars`: `enable_distributed_egress` |
| Attach a real customer VPC | `distributed_egress_endpoint_subnet_ids` — endpoint only, route table left to the customer |
