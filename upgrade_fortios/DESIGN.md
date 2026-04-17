# Design: FortiGate Autoscale Blue-Green Redeployment

## Problem Statement

### Customer Situation
An existing FortiGate autoscale deployment was created using manual (non-simplified) Terraform
templates. The deployment has accumulated configuration problems:

- Missing or incorrect CloudWatch autoscale alarm thresholds
- Licenses out of sync with the ASG instance lifecycle
- Potentially other misconfigured variables (instance types, scaling policies, etc.)

Fixing these problems in-place carries risk: the existing deployment is in production, and
partial fixes can introduce new instability. A clean redeployment is safer and more reliable.

### Why Blue-Green

Blue-green redeployment solves all of the following simultaneously:

| Problem | In-Place Fix | Blue-Green |
|---------|-------------|-----------|
| Misconfigured alarms | Risky — triggers during fix | Fixed in Green from the start |
| License sync issues | Complex state manipulation | Clean slate in Green |
| FortiOS upgrade | Manual per-instance (kludgy) | New AMI in Green |
| Rollback capability | None | Blue stays live as fallback |
| Validation with real traffic | Cannot test before commit | Canary validation pre-cutover |

---

## Architecture

### Blue Environment (Existing)

The existing deployment. Remains fully operational throughout the process until operator
explicitly approves cleanup in Phase 6.

```
Spoke VPCs (East, West, etc.)
    │  TGW Route Tables → Blue GWLB Endpoints
    ▼
Transit Gateway
    │
    ▼
Blue Inspection VPC
    ├── GWLB + Target Group
    ├── FortiGate ASG (BYOL and/or On-Demand)
    ├── DynamoDB (instance tracking)
    ├── Lambda (lifecycle management)
    └── CloudWatch Alarms (broken/missing)
```

### Green Environment (New Deployment)

Deployed in parallel using the Autoscale Simplified Template. Identical inspection VPC CIDR,
new FortiOS version, correct configuration from the start.

```
Transit Gateway
    │
    ▼
Green Inspection VPC  ← SAME CIDR as Blue
    ├── GWLB + Target Group
    ├── FortiGate ASG (correctly configured)
    ├── DynamoDB (clean state)
    ├── Lambda (current version)
    └── CloudWatch Alarms (correct thresholds)
```

### Cutover: TGW Route Table Switch

The Transit Gateway route table is the single control point for traffic direction.
TGW routes point to **VPC attachment IDs**, not to GWLB endpoints. GWLB endpoints
are internal to the inspection VPC and are not visible at the TGW routing layer.

The cutover changes the attachment target in every TGW route that currently points
to the Blue inspection VPC attachment, replacing it with the Green inspection VPC
attachment. These routes are known precisely — they are managed by the
autoscale_template state file and extracted directly by `discover.py`.

**Before cutover:**
```
TGW Route Tables (spoke VPCs):
  0.0.0.0/0 → Blue inspection VPC attachment (tgw-attach-xxx)
```

**After cutover:**
```
TGW Route Tables (spoke VPCs):
  0.0.0.0/0 → Green inspection VPC attachment (tgw-attach-yyy)
```

The Green inspection VPC attachment is created when the autoscale_template is
deployed for Green. Its ID is known before cutover from `terraform output`.

This switch is fully reversible — rollback.py restores the original Blue
attachment ID to every route that was changed.

### Cutover: NAT Gateway EIP Migration

NAT Gateway EIPs are the source IP for all outbound egress traffic from the inspection
VPC. Customers whitelist these IPs on external firewalls, partner systems, and SaaS
services. If Green deploys with new EIPs, those whitelists break immediately at cutover.

EIPs cannot be shared between two NAT Gateways simultaneously — the migration requires
a brief handoff window. The cutover script executes this handoff as fast as possible:

```
Step 1:  TGW routes updated: Blue attachment → Green attachment  (traffic flows, Green uses temp EIPs)
Step 2:  Blue NAT Gateways deleted                               (Blue EIPs released — seconds)
Step 3:  Blue EIPs associated with Green NAT GWs                 (original EIPs restored — seconds)
Step 4:  Green temporary EIPs released
```

The window between Step 1 and Step 3 where outbound traffic uses temporary IPs is
minimized by scripting Steps 2-3 immediately after Step 1 with no manual intervention.

**Green deployment:** Terraform deploys Green NAT Gateways with new temporary EIP
allocations. These are replaced at cutover and released afterward.

**Rollback implication:** Blue NAT Gateways are deleted at cutover. Rolling back after
EIP migration requires recreating Blue NAT Gateways and re-associating the original
EIPs (which will have been moved to Green). The rollback script handles this. The
original EIP allocation IDs are preserved in `blue_inventory.json`.

**EIP-mode deployments:** If the customer uses per-instance EIPs rather than NAT
Gateways (`access_internet_mode = "eip"`), EIPs are attached to ephemeral FortiGate
instances and are already non-deterministic. No EIP migration is needed — the discovery
script will set `egress_mode: eip` and the cutover script will skip EIP migration.

---

## Same CIDR Rationale

Green uses the **same CIDR blocks** as the Blue inspection VPC. This is a deliberate
design constraint, not a limitation.

### Why

FortiGate configurations contain hard-coded references to the inspection VPC CIDR blocks:

- **vdom-exceptions** — reference management interface subnet CIDRs
- **router static** — routes to spoke VPC supernet via inspection VPC gateway
- **router policy** — policy-based routing rules reference interface subnets
- **system interface** — IP addresses derived from subnet assignments
- **firewall address** — objects may reference internal subnets

If Green used different CIDRs, the exported Blue FortiGate config could not be restored
to Green without manually editing every CIDR reference. Using the same CIDRs means the
config restores cleanly.

### Implementation

The Green inspection VPC is deployed with the same `vpc_cidr_inspection` value as Blue.
Since Blue and Green exist simultaneously, they must be in the same AWS account and region
but are fully isolated VPCs — there is no peering or shared routing between them until
the TGW attachment for Green is created.

The TGW attachment for Green is created but routes are NOT switched until Phase 4 cutover.

---

## Discovery: Terraform State as Source of Truth

### Problem with Tag-Based Discovery

The existing deployment was created with manual templates that may not follow the
`{cp}-{env}-{resource}` Fortinet-Role tag convention. Tag-based discovery cannot be
relied upon.

### Solution: Parse terraform.tfstate

The customer's `terraform.tfstate` is the single source of truth for the Blue inventory.
Everything needed to drive the upgrade is extractable from state — no manual investigation
of the AWS console is required:

| Information Needed | Source in State |
|-------------------|----------------|
| VPC ID and CIDR | `aws_vpc` resource |
| Subnet IDs by type and AZ | `aws_subnet` resources |
| GWLB ARN and endpoint IDs | `aws_lb`, `aws_vpc_endpoint` resources |
| TGW attachment and route table IDs | `aws_ec2_transit_gateway_*` resources |
| ASG names, desired/min/max | `aws_autoscaling_group` resources |
| CloudWatch alarm thresholds | `aws_cloudwatch_metric_alarm` resources |
| Lambda function name | `aws_lambda_function` resource |
| DynamoDB table name | `aws_dynamodb_table` resource |
| Egress mode (NAT GW vs EIP) | Presence of `aws_nat_gateway` resources |
| NAT Gateway EIP allocation IDs | `aws_eip` resources associated with NAT GWs |
| FortiManager IP | `aws_instance` or variable in state inputs |
| Licensing config (BYOL/PAYG/FortiFlex) | `aws_autoscaling_group` launch template userdata |
| Dual vs single ASG | Count of `aws_autoscaling_group` resources |
| Management isolation mode | Presence/absence of dedicated management `aws_subnet` |
| Security group IDs | `aws_security_group` resources |

The `discover.py` script parses the state file and produces a structured inventory
(`blue_inventory.json`) that drives all subsequent phases. No manual input is required
beyond the state file path.

### Only One Item Requires Manual Input

The **target FortiOS version** for Green is the only value not in the state file.
Everything else is discovered automatically.

### State File Location

The customer's state file may be:
- Local: `terraform/autoscale_template/terraform.tfstate`
- Remote: S3 backend (requires `terraform state pull > terraform.tfstate`)

---

## FortiGate Configuration Migration

### Backup

Before any changes, export the primary FortiGate's full configuration:

1. Identify the primary instance — the one with scale-in protection enabled
2. SSH or GUI login to the primary FortiGate
3. Export full config: `execute backup full-config sftp ...` or GUI download
4. Store the backup locally before proceeding

### What Gets Migrated

The FortiGate config contains:
- Security policies (firewall rules)
- Address objects and groups
- Service objects
- VPN configurations (if any — note: VPN cannot be terminated on ASG)
- FortiManager connection settings (vdom-exceptions)
- Routing table customizations
- Any custom logging/reporting configuration

### What Does NOT Get Migrated

- Interface IP assignments (re-assigned by bootstrap on new instances)
- Autoscale-specific dynamic config (injected by Lambda on instance launch)
- License state (handled by Green's clean licensing setup)
- Session tables (stateful sessions will be interrupted at cutover — this is expected)

### Restore to Green

After Green FortiGate instances are running, restore the backup config to the primary
Green instance. The same CIDRs ensure interface references remain valid.

---

## Phase Detail

### Phase 0: Discovery (30 minutes)

**Goal:** Produce a complete inventory of the Blue environment.

**Inputs:**
- `terraform.tfstate` from the customer's autoscale_template deployment

**Actions:**
- Run `discover.py --state terraform.tfstate`
- Review `blue_inventory.json` output
- Verify all critical resources are identified

**Outputs:**
- `blue_inventory.json` — complete Blue resource inventory

**Gate:** Operator reviews and confirms inventory is complete and accurate.

---

### Phase 1: Backup (1 hour)

**Goal:** Export the primary FortiGate configuration before any changes.

**Inputs:**
- Primary FortiGate instance IP (from Blue inventory)
- Admin credentials

**Actions:**
- Identify primary instance (scale-in protection attribute)
- Export full configuration via GUI or CLI
- Store backup as `blue_primary_config.conf`
- Document current FortiOS version

**Gate:** Operator confirms backup is complete and readable.

---

### Phase 2: Deploy Green (30-60 minutes)

**Goal:** Deploy a correctly configured FortiGate ASG in a new inspection VPC.

**Inputs:**
- `blue_inventory.json` (CIDRs, AZs, TGW details)
- `blue_primary_config.conf` (FortiGate configuration)
- Target FortiOS version
- Corrected `terraform.tfvars` for autoscale_template

**Actions:**
- Prepare Green `terraform.tfvars`:
  - Same `vpc_cidr_inspection` as Blue
  - Correct alarm thresholds
  - Correct licensing configuration
  - Target FortiOS AMI version
  - Same AZs as Blue
- Run `terraform apply` (autoscale_template)
- Restore `blue_primary_config.conf` to Green primary instance
- **Do NOT modify TGW routes yet**

**Key terraform.tfvars differences from Blue:**
- Fixed `asg_cpu_scale_out_threshold` and `asg_cpu_scale_in_threshold`
- Correct `asg_byol_asg_desired_size`, `min_size`, `max_size`
- Corrected `fortios_version`
- Fixed licensing variables

**Gate:** Terraform apply completes successfully. FortiGate instances are healthy in ASG.

---

### Phase 3: Validate Green (30-60 minutes)

**Goal:** Confirm Green is healthy and ready to receive production traffic.

**Actions:**
- Verify all Green ASG instances pass GWLB health checks
- Confirm primary instance is elected (has `ProtectedFromScaleIn: true`)
- Spot-check security policies on Green primary FortiGate
- Confirm CloudWatch alarms are configured with correct thresholds
- Verify Lambda function has recent successful invocations in CloudWatch
- Confirm DynamoDB table has Green instances registered
- Verify licenses are assigned and active

**Gate:** All checks pass. Operator reviews and confirms.

---

### Phase 4: Cutover (5-10 minutes)

**Goal:** Atomically redirect production traffic from Blue to Green.

**Pre-cutover checklist:**
- [ ] Blue backup confirmed
- [ ] Green validation passed
- [ ] Change window opened (if required)
- [ ] Rollback procedure reviewed

**Actions:**
- Run `cutover.py --dry-run` to preview all changes
- Run `cutover.py` to execute:
  1. Replace all spoke TGW routes: Blue attachment → Green attachment
  2. (nat_gw mode) Delete Blue NAT GWs, create new Green NAT GWs with Blue EIP
     allocation IDs, update Green VPC route tables, release Green temp EIPs
- Monitor traffic flow immediately after cutover

**Expected impact:**
- Active sessions through Blue FortiGates will be interrupted (stateful sessions reset)
- New sessions immediately go through Green
- Impact window: seconds to minutes depending on session timeouts

**Gate:** Traffic confirmed flowing through Green. No connectivity loss to spoke VPCs.

---

### Phase 5: Monitor (24-48 hours)

**Goal:** Confirm Green stability under production traffic before committing to cleanup.

**Blue status during this phase:** ASG suspended (no new instances launch or terminate),
all existing Blue instances remain running. TGW routes point to Green.

**Rollback procedure (if needed):**
- Run `rollback.py --inventory blue_inventory.json --progress state/cutover_progress.json`
- Restores TGW routes to Blue attachment ID
- If EIP migration ran: recreates Blue NAT GWs with original EIP allocation IDs
- Traffic returns to Blue immediately (TGW flip < 60 s; NAT GW recreation ~2 min)

**Monitoring:**
- CloudWatch: Green ASG instance health, CPU utilization, scaling events
- FortiGate: session counts, policy hit counts, threat logs
- Application teams: confirm application connectivity

**Gate:** 24-48 hours of stable operation. Application teams confirm no issues.

---

### Phase 6: Cleanup (1-2 hours)

**Goal:** Destroy Blue environment and release resources.

**Actions:**
- Confirm Blue ASG is suspended (no new instances launching)
- `terraform destroy` in `terraform/autoscale_template` — destroys Blue ASG, GWLB,
  Lambda, DynamoDB, and launch templates. The Blue inspection VPC is in
  `existing_vpc_resources` alongside shared infrastructure (TGW, management VPC);
  do NOT run `terraform destroy` on that module. Delete the Blue inspection VPC
  manually after confirming no other resources reference it.
- Archive `blue_primary_config.conf` and `blue_inventory.json` for audit purposes
- **Optional: rename Green tags** — set `stack_label = ""` in
  `terraform/green_inspection_stack/terraform.tfvars` and run `terraform apply`.
  Renames all VPC Name/Fortinet-Role tags from `{cp}-{env}-green-inspection-*` to
  `{cp}-{env}-inspection-*` in-place (no resource recreation). Makes the stack
  discoverable by `autoscale_template` data sources for the next upgrade cycle.

**Gate:** Operator explicitly approves destruction. This is irreversible.

---

## Rollback Decision Tree

```
Phase 2 (Deploy Green) fails
  → Fix terraform.tfvars, re-run apply
  → Blue is unaffected

Phase 3 (Validate Green) fails
  → Debug Green issues
  → Destroy Green, fix, redeploy
  → Blue is unaffected

Phase 4 (Cutover) — traffic issues detected
  → Run rollback.py immediately
  → Blue resumes handling traffic
  → Investigate Green before re-attempting cutover

Phase 5 (Monitor) — issues found
  → Run rollback.py
  → Blue resumes handling traffic
  → Investigate and fix Green

Phase 6 (Cleanup) — no rollback possible
  → Blue is destroyed
```

---

## Risk Considerations

| Risk | Mitigation |
|------|-----------|
| Same CIDR conflict during parallel operation | Blue and Green are isolated VPCs — no routing between them |
| Session interruption at cutover | Expected and accepted; brief interruption of active sessions |
| Green config restore fails | Test config restore on one instance before full cutover |
| License issues on Green | Validate license state in Phase 3 before cutover |
| TGW route update fails mid-cutover | Script checks each route update; partial failure leaves some spokes on Blue |
| FortiManager loses sync | Re-authorize Green instances in FortiManager post-cutover |
