# FortiGate Autoscale Upgrade Toolset

## Purpose

This toolset upgrades a FortiGate autoscale group on AWS. Two upgrade strategies
are supported:

| Strategy | Use When | Downtime | Rollback |
|----------|----------|----------|---------|
| **In-Place** | Healthy deployment, FortiOS version bump only | Brief per-instance restart | Manual firmware downgrade |
| **Blue-Green** | Broken config, need fallback, or both remediation and upgrade | Near-zero (session interruption at cutover) | `rollback.py` restores TGW routes to Blue |

## In-Place Upgrade: Overview

Run `discover.py` first to build the inventory, then run `inplace_upgrade.py`. The script
reads the **live ASG state** from AWS and selects the appropriate path automatically:

**Path A — desired=0 (no running instances):**
```
Phase 0: Discovery    — Read state + detect architecture + detect path
Phase 1: Update LTs   — New launch template version with target AMI on both ASGs
                        Done. All future instances launch with new FortiOS.
```

**Path B — desired>0 (instances running, rolling replacement):**
```
Phase 0: Discovery    — Read state + detect architecture + detect path
Phase 1: Backup       — Export primary FortiGate config (safety net)
Phase 2: Update LTs   — New launch template version with target AMI on both ASGs
Phase 3: Rolling      — Terminate secondaries one at a time, wait for replacement
                        Terminate primary last — secondaries cover traffic, no gap
                        Lambda elects new primary from existing secondaries
Phase 4: Verify       — All instances on new AMI, GWLB healthy, primary elected
```

**Path C — desired=0 + config backup present:**
```
Phase 0: Discovery    — Detect path (desired=0 and .conf present in state/)
Phase 1: Update LTs   — New launch template version with target AMI on both ASGs
Phase 2: Launch       — Set ASG min=1, desired=1; wait for primary to be healthy
Phase 3: Config       — Restore blue_primary_config.conf via FortiGate REST API
                        (or operator restores via GUI if --fgt-api-key not provided)
Phase 4: Wait         — Poll until primary recovers from post-restore reboot
Phase 5: Scale out    — Restore original capacity; secondary syncs config from primary
```

## Blue-Green Upgrade: Overview

```
Phase 0: Discovery    — Extract all Blue resources from terraform state files
Phase 1: Backup       — Export primary FortiGate configuration
Phase 2: Deploy Green — green_inspection_stack module, same CIDRs, new FortiOS
Phase 3: Validate     — Confirm Green is healthy before cutover
Phase 4: Cutover      — TGW route flip: Blue → Green + EIP migration (nat_gw mode)
Phase 5: Monitor      — Blue stays suspended as fallback for validation period
Phase 6: Cleanup      — Destroy Blue after operator approval
```

Each phase requires explicit operator confirmation before proceeding.

## Directory Structure

```
upgrade_fortios/
├── README.md                   — This file
├── DESIGN.md                   — Full design rationale and architecture
├── INPLACE.md                  — In-place upgrade procedure detail
├── BLUE-GREEN-PLAN.md          — Blue-green operational runbook
├── DISCOVERY.md                — How to extract Blue environment from terraform state
├── scripts/
│   ├── discover.py             — Parse terraform state, output blue_inventory.json
│   ├── inplace_upgrade.py      — In-place upgrade workflow (Paths A, B, C)
│   ├── cutover.py              — TGW route flip + NAT GW EIP migration
│   ├── rollback.py             — Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh         — Stream Lambda CloudWatch logs during upgrade
└── state/
    ├── refresh.sh              — Copy fresh state files from terraform directories
    ├── autoscale_template.tfstate      (copied by refresh.sh)
    ├── existing_vpc_resources.tfstate  (copied by refresh.sh)
    ├── blue_inventory.json             (output of discover.py)
    └── green.tfstate                   (copied from green_inspection_stack after apply)
```

## Quick Reference: In-Place

**Step 1: Discovery**

```bash
cd upgrade_fortios
bash state/refresh.sh

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

**Step 2: Run upgrade**

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --fgt-api-key <api-key>   # optional — enables automated config restore (Path C)
```

The script detects the path automatically from ASG desired capacity and presence of
`state/blue_primary_config.conf`.

## Quick Reference: Blue-Green

| Phase | Script / Action | Gate |
|-------|-----------------|------|
| 0 Discovery | `discover.py` | Review inventory |
| 1 Backup | FortiGate GUI config export | Save to `state/blue_primary_config.conf` |
| 2 Deploy Green | `terraform apply` (green_inspection_stack) | Review plan |
| 3 Validate | Manual health checks + console review | All checks pass |
| 4 Cutover | `cutover.py --dry-run` then `cutover.py` | Monitor traffic |
| 5 Monitor | 24–48 h observation | Application teams confirm |
| 6 Cleanup | Manual `terraform destroy` (green_inspection_stack teardown of Blue) | Operator approval |

## Key Design Decisions

- **Same CIDRs (Blue-Green)** — Green inspection VPC uses identical CIDR blocks to Blue.
  This ensures the restored FortiGate configuration (vdom-exceptions, routes, policies)
  works without modification after restore.
- **Terraform state as discovery source** — Blue resources are discovered from the
  existing `terraform.tfstate`, not from AWS tags (which may not follow naming
  conventions on manually deployed environments).
- **TGW VPC attachment as cutover control plane (Blue-Green)** — TGW routes point to VPC
  attachment IDs. Cutover replaces the Blue inspection VPC attachment with the Green one
  across all affected TGW route tables.
- **NAT Gateway EIP preservation** — Blue NAT Gateway EIPs are migrated to Green during
  cutover so external allowlists remain valid.
- **Blue suspended, not destroyed (Blue-Green)** — After cutover, Blue ASG is suspended.
  Blue VPC remains intact for the monitoring period. Rollback is a single script call.
- **Progress file** — `cutover.py` writes `state/cutover_progress.json` after each phase.
  `rollback.py` reads it to determine exactly what ran and what needs to be undone.
- **ASG suspension (In-Place)** — Health check, launch, and terminate processes are
  suspended during in-place upgrade to prevent the ASG from replacing instances mid-upgrade.
