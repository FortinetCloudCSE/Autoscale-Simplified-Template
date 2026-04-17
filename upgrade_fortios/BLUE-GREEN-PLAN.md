# Blue-Green FortiOS Upgrade Plan

## Overview

Blue-green upgrade deploys a parallel (green) inspection stack alongside the existing
(blue) stack, validates green, flips traffic at the TGW route table level, then tears
down blue. No in-place instance replacement — eliminates cross-version config sync issues.

---

## Current Architecture

```
Spoke VPCs (east/west)
    └── TGW
        ├── Spoke TGW attachments (one per spoke)
        │   └── TGW route tables → default route → Blue Inspection VPC TGW attachment
        └── Blue Inspection VPC TGW attachment
                └── Blue Inspection VPC
                        └── Blue GWLB → Blue ASG (FortiGate instances)
```

---

## Proposed Terraform Restructure

### Current layout (problem)

`existing_vpc_resources` owns everything — TGW, spokes, management VPC, and inspection
VPC — making it impossible to blue-green just the inspection layer without touching
shared infrastructure.

### Proposed layout

Split `existing_vpc_resources` into two layers:

#### Layer 1: `shared_infrastructure` (created once, never blue-greened)
- TGW
- Spoke VPCs (east/west) + TGW attachments
- Management VPC (FortiManager, FortiAnalyzer, Jump Box)
- TGW route tables for spokes
- **Variable**: `inspection_attachment_id` — points to whichever inspection VPC
  attachment is active (blue or green). Updating this and running `terraform apply`
  is the route flip.

#### Layer 2: `inspection_stack` (blue-greened)
- Inspection VPC + subnets
- TGW attachment for inspection VPC
- GWLB + target group
- FortiGate ASG + launch template
- Lambda + lifecycle hooks
- DynamoDB table

Takes shared infrastructure IDs as inputs (TGW ID, etc.). No tag-based discovery —
explicit variable inputs.

---

## Blue-Green Upgrade Flow

### Pre-conditions
- Blue inspection stack running, validated, config backed up
- Green inspection stack does not yet exist
- FortiGate API key generated on blue primary for config restore

### Step 1: Deploy Green

```
terraform apply  (inspection_stack — green workspace/state)
```

- New Inspection VPC with its own subnets, NAT gateways, GWLBe
- New TGW attachment for green Inspection VPC
- New GWLB + target group
- New ASG with new FortiOS AMI launch template
- New Lambda + lifecycle hooks (fully isolated from blue)
- Green FortiGates come up, Lambda assigns licenses, pushes bootstrap config

At this point blue is still handling all traffic.

### Step 2: Config Restore to Green Primary

Restore blue primary config backup to green primary via FortiGate REST API:

```
POST /api/v2/monitor/system/config/restore
```

- Green primary reboots
- Wait for green primary GWLB healthy
- Green secondary config-syncs from green primary (same FortiOS version, vdom-exceptions
  handle AZ/subnet differences)
- Wait for green secondary to be tagged and healthy

### Step 3: Validate Green

- All green instances GWLB healthy
- Green primary elected (ProtectedFromScaleIn)
- Config verified on green primary (spot-check key policies/routes)
- FortiManager/FortiAnalyzer registration (if applicable — green serial numbers need
  to be accepted)

### Step 4: Route Flip (Cutover)

Update `inspection_attachment_id` variable in `shared_infrastructure` from blue
attachment ID → green attachment ID:

```
terraform apply  (shared_infrastructure)
```

Updates all spoke TGW route tables simultaneously. Traffic now flows through green.
Blue is still running — rollback is re-running `terraform apply` with blue attachment ID.

### Step 5: Validate Traffic Through Green

- Confirm east/west spoke traffic is flowing through green FortiGates
- Check CloudWatch metrics, FortiGate logs
- Defined validation window before blue teardown (operator decision)

### Step 6: Tear Down Blue

```
terraform destroy  (inspection_stack — blue workspace/state)
```

- Destroys blue ASG, Lambda, GWLB, Inspection VPC, TGW attachment
- Blue serial numbers returned to FortiFlex pool (Lambda handles on termination)

---

## Open Questions / Decisions

### 1. NAT Gateway EIPs
Green gets new EIPs on its NAT gateways. If any external systems allowlist the blue
EIPs (firewall rules, SaaS tools, etc.) those need updating before or during cutover.

### 2. FortiManager / FortiAnalyzer
Green FortiGates have different serial numbers. FM/FA needs to accept new serials.
Config restore will carry FM/FA connection settings but FM/FA must authorize new devices.

### 3. Naming / Promotion
After blue is destroyed, the green `inspection_stack` is production.

**Resolved:** The `stack_label` variable controls the infix in all VPC Name and
Fortinet-Role tags. Default `"green"` produces `{cp}-{env}-green-inspection-*` tags
that do not collide with Blue's `{cp}-{env}-inspection-*` tags during the cutover
window. After Blue is destroyed, set `stack_label = ""` and run `terraform apply` —
a pure tag update (no resource recreation) that renames all VPC tags to the bare
`{cp}-{env}-inspection-*` pattern compatible with `autoscale_template` data sources
for the next upgrade cycle.

### 4. Rollback Window
How long to keep blue running after route flip before destroying?
- Too short: not enough validation time
- Too long: paying for double the FortiGate instances + licenses

### 5. FortiFlex License Availability
During the cutover window both blue and green ASGs are running — double the license
consumption. Ensure FortiFlex pool has sufficient capacity.

### 6. `existing_vpc_resources` Migration
Refactoring into `shared_infrastructure` + `inspection_stack` requires migrating
existing Terraform state (`terraform state mv`). Need a migration plan that does not
cause existing resources to be destroyed and recreated.

---

## Implemented Toolset

The blue-green upgrade is now implemented as discrete scripts rather than a single
orchestrator. Operators run each phase explicitly:

```
Phase 0: python3 scripts/discover.py       → state/blue_inventory.json
Phase 1: FortiGate GUI / CLI               → state/blue_primary_config.conf
Phase 2: terraform apply (green_inspection_stack) → state/green.tfstate
Phase 3: Manual validation checks
Phase 4: python3 scripts/cutover.py        → state/cutover_progress.json
         (TGW route flip + EIP migration)
Phase 5: Monitor for 24-48h
         python3 scripts/rollback.py       (if rollback needed)
Phase 6: terraform destroy (autoscale_template) + manual VPC cleanup
         Optional: set stack_label="" + terraform apply (green_inspection_stack)
                   → renames green tags to bare {cp}-{env}-inspection-* in-place
```

The Green inspection stack is deployed via `terraform/green_inspection_stack/` — a
dedicated module that creates an isolated inspection VPC with identical CIDRs to Blue,
passing all resource IDs directly to the Fortinet module (no tag-based discovery).

See `RUNBOOK.md` for the full step-by-step operational procedure.

---

## Relationship to In-Place Upgrade (Path B)

| | In-Place (Path B) | Blue-Green |
|---|---|---|
| FortiOS versions | Same major (e.g. 7.2.x) | Any (7.4 → 7.6) |
| Config sync during upgrade | Required | Not required |
| Traffic gap | None (rolling) | None (route flip) |
| Rollback | Complex | Simple (flip route back) |
| Cost | Normal | 2x during cutover window |
| Terraform state | Unchanged | New green state added |
| Time | ~30 min | Longer (full stack deploy) |

Use in-place for same-major-version upgrades where config sync works.
Use blue-green for cross-major-version upgrades or when in-place risk is unacceptable.
