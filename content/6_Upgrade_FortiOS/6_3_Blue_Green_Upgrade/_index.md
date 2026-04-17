---
title: "Blue-Green Upgrade"
menuTitle: "Blue-Green Upgrade"
weight: 63
---

## Overview

Blue-green upgrade deploys a parallel (Green) inspection stack alongside the existing
(Blue) stack, validates Green under real conditions, then flips all TGW routes atomically
at cutover. Blue remains suspended as a live fallback until the operator explicitly approves
cleanup.

This strategy eliminates cross-version config sync issues and gives full rollback capability
at every phase up through cleanup.

---

## Architecture

### Blue Environment (Existing)

```
Spoke VPCs (East, West, ...)
        │
        ▼
Transit Gateway
        │  TGW route tables → Blue inspection VPC attachment
        ▼
Blue Inspection VPC  (10.0.0.0/16)
    ├── GWLB + Target Group
    ├── FortiGate ASG (BYOL + On-Demand)
    ├── DynamoDB (instance tracking)
    └── Lambda (lifecycle management)
```

### Green Environment (New — deployed in parallel)

```
Transit Gateway
        │  TGW attachment created but routes NOT switched yet
        ▼
Green Inspection VPC  (10.0.0.0/16)  ← SAME CIDR as Blue
    ├── GWLB + Target Group  (new)
    ├── FortiGate ASG (new FortiOS AMI, corrected config)
    ├── DynamoDB (clean state)
    └── Lambda (current version)
```

### After Cutover

```
Spoke VPCs
        │
        ▼
Transit Gateway
        │  TGW route tables → Green inspection VPC attachment
        ▼
Green Inspection VPC  (traffic flows here)

Blue Inspection VPC  (suspended — no new instances, kept as rollback target)
```

---

## Why the Same CIDR

Green uses the **same CIDR blocks** as the Blue inspection VPC. This is a deliberate
design choice, not a limitation.

FortiGate configurations contain hard-coded references to inspection VPC CIDRs:
- `vdom-exceptions` — reference management interface subnet CIDRs
- `router static` — routes to spoke VPC supernet via inspection VPC gateway
- `system interface` — IP addresses derived from subnet assignments
- `firewall address` — objects may reference internal subnets

If Green used different CIDRs, every CIDR reference in the exported Blue config would need
manual editing before restore. Identical CIDRs mean the config restores cleanly to Green
without modification.

Blue and Green are fully isolated VPCs with no peering between them — having the same CIDR
causes no routing conflict while they coexist.

---

## Phase 0 — Discovery

**Goal:** Produce a complete inventory of the Blue environment.

**Duration:** ~30 minutes  
**Traffic impact:** None (read-only)

```bash
cd upgrade_fortios
bash state/refresh.sh

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

Review the output before proceeding:

```bash
python3 -m json.tool state/blue_inventory.json | less
```

**Gate:** Operator reviews inventory and confirms all resources are identified correctly.
Note the key values you will need for Green `terraform.tfvars`: `inspection_vpc.cidr_block`,
`egress_mode`, `autoscale_groups.byol.desired/min/max`, AZs, and TGW name.

See [Discovery](../6_4_discovery/) for details on the inventory schema.

---

## Phase 1 — Backup

**Goal:** Export the primary FortiGate configuration before any changes.

**Duration:** 30–60 minutes  
**Traffic impact:** None

{{% notice warning %}}
Do not skip this phase. The backup is required to restore Green's primary FortiGate to the
current production configuration after Green launches.
{{% /notice %}}

1. Identify the primary FortiGate instance — it has `ProtectedFromScaleIn: true` in the
   Blue ASG. The `blue_inventory.json` shows the primary instance ID.
2. Log in to the primary FortiGate GUI or SSH
3. **System → Settings → Backup → Full Configuration**
4. Save to `upgrade_fortios/state/blue_primary_config.conf`

**Gate:** Operator confirms backup file is present and readable.

### What the Config Backup Contains

| Included | Not Included |
|----------|-------------|
| Security policies (firewall rules) | Interface IP assignments (re-assigned by bootstrap) |
| Address objects and groups | Autoscale-specific dynamic config (pushed by Lambda) |
| Routing customizations | License state (handled by Green's clean licensing) |
| FortiManager connection settings | Session tables (stateful sessions interrupted at cutover — expected) |
| VPN configurations | |
| Custom logging/reporting | |

---

## Pre-Deployment Checklist

Complete this checklist before Phase 2. All items must be confirmed before deploying Green.

**Licensing**
- [ ] Enough licenses available for 2× capacity — Blue and Green run simultaneously during the monitoring window
- [ ] For BYOL: S3 license bucket has sufficient `.lic` files for Green instances
- [ ] For FortiFlex: token pool has capacity for Green desired count
- [ ] For PAYG: no license action needed

**Capacity**
- [ ] AWS account service limits allow the additional EC2 instances, EIPs, and NAT Gateways
- [ ] NAT Gateway quota allows 2 additional NAT GWs per AZ (Green creates its own temp NAT GWs)
- [ ] EIP quota allows 2 additional EIPs for Green temp NAT GWs

**Credentials and Access**
- [ ] AWS credentials have IAM permissions to create VPC, subnets, NAT GWs, TGW attachments, ASG, GWLB, Lambda, DynamoDB
- [ ] FortiGate API key ready for the Green primary (needed for config restore)
- [ ] FortiManager access available to re-authorize Green serial numbers (if FortiManager is enabled)

**Config and State**
- [ ] Phase 0 (Discovery) complete — `state/blue_inventory.json` exists and reviewed
- [ ] Phase 1 (Backup) complete — `state/blue_primary_config.conf` exists and readable
- [ ] Green `terraform.tfvars` prepared — `fortios_version` set, all required fields populated
- [ ] `vpc_cidr_inspection` in Green tfvars **matches Blue exactly** (required for config restore)
- [ ] `asg_module_prefix` set to `"green"` (avoids resource name collisions with Blue)

**FortiManager (if enabled)**
- [ ] FortiManager version 7.6.3+ has `fgfm-allow-vm enable` configured
- [ ] Operator prepared to authorize new Green serial numbers in FortiManager after config restore

---

## Phase 2 — Deploy Green

**Goal:** Deploy a correctly configured FortiGate ASG in a new inspection VPC.

**Duration:** 30–60 minutes  
**Traffic impact:** None — TGW routes unchanged, Blue still handles all traffic

### Prepare Green tfvars

The Green deployment uses a dedicated Terraform module at `terraform/green_inspection_stack/`.
Start from the provided example:

```bash
cd terraform/green_inspection_stack
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the required fields. Values should match your Blue
deployment — the `blue_inventory.json` provides a reference for all discovered parameters:

```hcl
# ── Required manual inputs ─────────────────────────────
fortios_version        = "7.6.2"      # Target FortiOS version
fortigate_asg_password = "..."        # FortiGate admin password
keypair                = "my-keypair" # EC2 key pair name

# ── Must match Blue exactly ───────────────────────────
cp                   = "acme"
env                  = "test"
aws_region           = "us-west-2"
availability_zone_1  = "a"
availability_zone_2  = "c"
vpc_cidr_inspection  = "10.0.0.0/16"   # MUST match Blue
subnet_bits          = 8               # MUST match Blue
firewall_policy_mode = "2-arm"         # MUST match Blue
access_internet_mode = "nat_gw"        # MUST match Blue

# ── Green-specific ─────────────────────────────────────
asg_module_prefix    = "green"         # REQUIRED: different from Blue
```

### Apply Green

```bash
cd terraform/green_inspection_stack
terraform init
terraform apply
```

{{% notice info %}}
Green's TGW attachment is created by `terraform apply` but TGW routes are **not** modified.
Blue continues handling all traffic.
{{% /notice %}}

Note the key outputs after apply — you will need them for verification:

```bash
terraform output green_tgw_attachment_id
terraform output green_natgw_az1_temp_eip
terraform output green_natgw_az2_temp_eip
```

Save the state file for the cutover script:

```bash
cp terraform.tfstate ../../upgrade_fortios/state/green.tfstate
```

### Restore Config to Green Primary

After Green FortiGates are running and the Lambda has initialized them, restore the Blue
config to the Green primary FortiGate.

**Option A — via FortiGate GUI (manual):**

1. Identify the Green primary instance — it has `ProtectedFromScaleIn: true` in the
   Green BYOL ASG
2. Open the Green primary FortiGate GUI at `https://<management-ip>/`
3. **System → Settings → Restore → Upload** `state/blue_primary_config.conf`
4. FortiGate reboots after restore (allow up to 10 minutes)
5. Log in again and verify security policies are present

**Option B — via FortiGate REST API:**

```bash
# Get Green primary management IP from AWS
aws ec2 describe-instances \
  --instance-ids <green-primary-instance-id> \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text

# POST config backup to Green primary
curl -k -X POST \
  "https://<green-primary-ip>/api/v2/monitor/system/config/restore" \
  -H "Authorization: Bearer <api-key>" \
  -F "source=upload" \
  -F "scope=global" \
  -F "file=@state/blue_primary_config.conf"
```

After restore, the FortiGate reboots. Poll until it returns to GWLB healthy state
(~5–10 minutes). The Green secondary will receive config from the Green primary
automatically via the Lambda once the primary is back online.

**Gate:** Terraform apply completes. Green ASG instances are healthy.

---

## Post-Deployment Verification Checklist

Complete this checklist after Phase 2 and before proceeding to Phase 3 (Validate Green).
These checks confirm that Green is structurally sound before automated validation runs.

**Infrastructure**
- [ ] `terraform apply` completed with no errors
- [ ] `state/green.tfstate` saved to `upgrade_fortios/state/`
- [ ] Green TGW attachment visible in AWS Console → Transit Gateway → Attachments
- [ ] Green inspection VPC created with correct CIDR (matches Blue)
- [ ] Green NAT Gateways created in both AZs (will have temporary EIPs)
- [ ] Green GWLB created and GWLB endpoints are in "Available" state

**FortiGate Health**
- [ ] Green ASG instances launched and in `InService` lifecycle state
- [ ] One Green instance has `ProtectedFromScaleIn: true` (primary elected)
- [ ] Green primary FortiGate accessible via HTTPS on management port
- [ ] Config restore completed without errors (check FortiGate event log)
- [ ] Green primary FortiGate shows expected security policies after restore

**Config Validation**
- [ ] Green primary `get system status` shows target FortiOS version
- [ ] `get router info routing-table all` shows expected routes (VPC subnets present)
- [ ] Security policies visible and match Blue (spot check 3–5 critical policies)
- [ ] FortiGate HA synchronization status shows secondary in sync (if applicable)

**FortiManager (if enabled)**
- [ ] Green serial numbers visible in FortiManager → Device Manager → Unauthorized Devices
- [ ] Green serial numbers authorized in FortiManager before proceeding to cutover
- [ ] Policy packages pushed to Green devices from FortiManager

**TGW Routing (confirm Blue still active)**
- [ ] Spoke VPC traffic still flows through Blue (verify via CloudWatch or FortiGate session logs)
- [ ] Green TGW attachment does **not** appear in spoke route tables (routes still point to Blue)

---

## Phase 3 — Validate Green

**Goal:** Confirm Green is healthy and ready for production traffic before cutover.

**Duration:** 30–60 minutes  
**Traffic impact:** None — Blue still handling all traffic

Manually verify each of the following before proceeding to cutover:

| Check | How to Verify |
|-------|--------------|
| ASG instances healthy | AWS Console → EC2 Auto Scaling → confirm all Green instances `InService` |
| GWLB targets healthy | AWS Console → EC2 → Load Balancers → Target Groups → confirm all targets healthy |
| Primary elected | Check for one instance with `ProtectedFromScaleIn: true` in Green BYOL ASG |
| Config restored | Log in to Green primary FortiGate → confirm expected security policies present |
| CloudWatch alarms | AWS Console → CloudWatch → Alarms → confirm Green alarms in `OK` state |
| Lambda operating | AWS Console → Lambda → confirm recent successful invocations in CloudWatch metrics |
| DynamoDB state | AWS Console → DynamoDB → scan `fgt_asg_track_table` → confirm Green instances registered |
| Licenses valid | FortiGate CLI: `get system status | grep -i license` — confirm valid |

**Gate:** All checks pass. Operator reviews results and confirms cutover can proceed.

{{% notice warning %}}
Do not proceed to cutover until all validation checks pass. A failed validation check
indicates Green is not ready to handle production traffic.
{{% /notice %}}

---

## Phase 4 — Cutover

**Goal:** Redirect production traffic from Blue to Green with minimum downtime.

**Duration:** Phase 1 (TGW flip) < 30 seconds. Phase 2 (EIP migration, nat_gw only) ~2–3 minutes.  
**Traffic impact:** Active sessions interrupted at TGW route flip. New sessions immediately
go through Green. Outbound source IPs are preserved after EIP migration completes.

### Pre-Cutover Checklist

Before running the cutover script, confirm:

- [ ] Phase 1 (Backup) complete — `state/blue_primary_config.conf` exists
- [ ] Phase 3 (Validate Green) passed — all automated checks green
- [ ] Post-deployment verification checklist complete
- [ ] Spoke VPC connectivity confirmed through Blue (last health check before cutover)
- [ ] Change window open (if required by your organization)
- [ ] Application teams notified of brief session interruption
- [ ] `state/green.tfstate` present in `upgrade_fortios/state/` directory

### Preview the Cutover Plan

Always run dry-run first to confirm what `cutover.py` will do:

```bash
cd upgrade_fortios

python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate \
  --dry-run
```

Dry-run output shows:

- Which TGW route tables will be updated (route table IDs and CIDRs)
- Blue attachment ID → Green attachment ID
- Which Blue NAT Gateways will be deleted (EIPs shown)
- Which Green NAT Gateways will be recreated with Blue EIPs

Review this output carefully before proceeding.

### Execute the Cutover

```bash
python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate
```

The script prompts for confirmation before executing. The cutover sequence:

**Phase 1 — TGW Route Flip** (< 30 seconds)

```
For each spoke TGW route table:
  Replace: 0.0.0.0/0 → Blue attachment
      with: 0.0.0.0/0 → Green attachment

→ Traffic immediately routes to Green FortiGates
```

**Phase 2 — NAT Gateway EIP Migration** (nat_gw mode only, ~2–3 minutes)

```
Step 2a  Delete Blue NAT Gateways          → Blue EIPs released
Step 2b  Wait for deletion                  (~60 s)
Step 2c  Create new Green NAT GWs           using Blue EIP allocation IDs
Step 2d  Wait for new NAT GWs available     (~60 s)
Step 2e  Update Green VPC route tables      old Green natgw IDs → new natgw IDs
Step 2f  Delete original Green NAT GWs      (temp EIPs)
Step 2g  Release Green temp EIP allocations

→ Outbound source IPs preserved — external firewall rules and IP allowlists unchanged
```

Progress is written to `state/cutover_progress.json` after each phase so that
`rollback.py` can undo exactly what was done.

{{% notice info %}}
**EIP mode** (`access_internet_mode = "eip"`): EIPs are attached to ephemeral FortiGate
instances and are already non-deterministic. No EIP migration is needed — Phase 2 is
skipped automatically when `egress_mode: eip` is set in the inventory. Total cutover
duration is under 30 seconds.
{{% /notice %}}

### Post-Cutover Verification

After `cutover.py` completes, verify immediately:

```bash
# Confirm spoke route tables point to Green attachment
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <spoke-rtb-id> \
  --filters "Name=type,Values=static"

# Check Green ASG instance health
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <green-byol-asg-name>
```

- [ ] Spoke TGW route tables show Green attachment ID
- [ ] Test traffic from East/West spoke VPCs passes through Green (check FortiGate session logs)
- [ ] Green GWLB target health: all targets healthy
- [ ] Green CloudWatch alarms in OK state
- [ ] For nat_gw mode: new Green NAT GWs show Blue EIPs (verify in AWS Console)
- [ ] Outbound connectivity from spoke VPCs uses expected public source IPs

### Rollback From Cutover

If traffic issues are detected immediately after cutover:

```bash
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json
```

`rollback.py` reads `cutover_progress.json` to determine exactly what ran and performs
the inverse:

- **TGW routes** are immediately restored to Blue attachment (< 30 seconds)
- **NAT Gateway EIPs** — if Phase 2 completed, `rollback.py` deletes the new Green
  NAT GWs holding Blue EIPs, recreates Blue NAT GWs in the original Blue subnets with
  the original EIP allocation IDs, and updates Blue VPC route tables. Allow 2–3 minutes.

```bash
# Preview rollback before executing
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json \
  --dry-run
```

{{% notice warning %}}
Rollback after EIP migration requires recreating Blue NAT Gateways, which takes ~2 minutes.
During this window Blue instances handle traffic but outbound traffic may use different
source IPs until the new Blue NAT GWs are ready.
{{% /notice %}}

**Gate:** Traffic confirmed flowing through Green (or Blue if rolled back). Connectivity
to all spoke VPCs verified.

---

## Phase 5 — Monitor

**Goal:** Confirm Green stability under production traffic before destroying Blue.

**Duration:** 24–48 hours  
**Traffic impact:** None — operating normally on Green

During this phase:
- Blue ASG is **suspended** (no new instances launch or terminate)
- All existing Blue instances remain running
- TGW routes point to Green
- Rollback is still possible via `rollback.py`

### Monitoring

| Source | What to Watch |
|--------|--------------|
| CloudWatch | Green ASG instance health, CPU utilization, scaling events |
| FortiGate | Session counts, policy hit counts, threat logs |
| Application teams | Application connectivity and performance |

### Rollback During Monitoring Window

If issues are found during the monitoring period:

```bash
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json
```

Traffic returns to Blue immediately. Investigate and fix Green before attempting
another cutover.

**Gate:** 24–48 hours of stable operation. Application teams confirm no issues.
Operator explicitly approves Blue teardown before proceeding.

---

## Phase 6 — Cleanup

**Goal:** Destroy Blue environment and release resources.

**Duration:** 1–2 hours  
**Reversibility:** None — Blue is permanently destroyed

{{% notice warning %}}
**Irreversible.** Once Phase 6 completes, Blue is gone. Confirm Green is stable and
application teams have signed off before proceeding.
{{% /notice %}}

Blue's ASG, GWLB, Lambda, DynamoDB, and inspection VPC were created across two Terraform
state files (`autoscale_template` and `existing_vpc_resources`). The inspection VPC itself
is in `existing_vpc_resources` alongside shared infrastructure (TGW, management VPC,
spokes) — **do not run `terraform destroy` on `existing_vpc_resources`.**

Instead, destroy Blue resources selectively using targeted AWS CLI commands or by removing
them from the `autoscale_template` state and running `terraform destroy`:

```bash
cd terraform/autoscale_template

# Review what will be destroyed — ensure shared resources are NOT listed
terraform plan -destroy

# Destroy only autoscale_template resources (ASG, GWLB, Lambda, DynamoDB, LTs)
terraform destroy
```

The Blue inspection VPC and its subnets must be deleted separately after confirming
no other resources depend on them. The TGW attachment for Blue should already be in
a `deleted` state after `cutover.py` ran the TGW route flip — verify before proceeding.

After destroy completes:
- Archive `blue_primary_config.conf` and `blue_inventory.json` for audit purposes
- Green is now the production inspection stack
- On the next upgrade cycle, the current Green becomes Blue, and a new Green is deployed

### Optional: Remove "green" from Tags

Green's VPC resources carry `{cp}-{env}-green-inspection-*` tags to prevent collision with
Blue during the cutover window. After Blue is gone those tags can be renamed to the bare
`{cp}-{env}-inspection-*` pattern that `autoscale_template` data sources expect — making
the stack discoverable by a future `autoscale_template` deployment without modification.

Set `stack_label = ""` in `terraform/green_inspection_stack/terraform.tfvars` and run:

```bash
cd terraform/green_inspection_stack
terraform apply
```

This is a **pure tag update** — no VPC resources are recreated. All Name and Fortinet-Role
tags on the VPC, subnets, route tables, NAT Gateways, internet gateway, and TGW attachment
are renamed in a single apply.

{{% notice note %}}
`asg_module_prefix` controls ASG, GWLB, Lambda, and DynamoDB resource names — those
are not affected by `stack_label` and cannot be renamed without recreating the resources.
Set `asg_module_prefix = ""` (matching the Blue default) only when deploying a fresh stack
for the next upgrade cycle.
{{% /notice %}}

---

## Rollback Decision Tree

```
Phase 2 (Deploy Green) fails
  → Fix terraform.tfvars or Green config, re-run terraform apply
  → Blue is completely unaffected

Phase 3 (Validate Green) fails
  → Debug Green; destroy Green if needed, fix, and redeploy
  → Blue is completely unaffected

Phase 4 (Cutover) — traffic issues detected
  → Run rollback.py immediately (< 60 seconds)
  → Blue resumes all traffic
  → Investigate Green before re-attempting cutover

Phase 5 (Monitor) — issues found
  → Run rollback.py
  → Blue resumes all traffic
  → Investigate and fix Green

Phase 6 (Cleanup) — no rollback possible
  → Blue has been destroyed
```

---

## FortiManager / FortiAnalyzer Considerations

Green FortiGates have different serial numbers from Blue. If FortiManager or FortiAnalyzer
integration is enabled:

1. The config backup will carry FortiManager connection settings — Green FortiGates will
   attempt to connect to FortiManager after config restore
2. FortiManager must authorize the new serial numbers:
   **Device Manager → Device & Groups → right-click unauthorized device → Authorize**
3. If FortiManager is running version 7.6.3+, ensure `fgfm-allow-vm` is enabled:
   ```
   config system global
       set fgfm-allow-vm enable
   end
   ```

---

## Risk Considerations

| Risk | Mitigation |
|------|-----------|
| Same-CIDR conflict during parallel operation | Blue and Green are isolated VPCs — no routing between them |
| Session interruption at cutover | Expected and accepted; new sessions route to Green immediately |
| Green config restore fails | Test restore on one instance before full cutover; fallback to manual GUI restore |
| License capacity during monitoring | Ensure FortiFlex pool has capacity for 2x licenses during monitoring window |
| TGW route update fails mid-cutover | Script checks each route update; partial failure leaves some spokes on Blue — run rollback.py |
| FortiManager loses sync | Re-authorize Green serial numbers in FortiManager post-cutover |
| NAT Gateway EIP migration window | Brief period (seconds) where outbound uses temporary IPs — minimize by not interrupting cutover.py |
