# FortiGate Autoscale Upgrade Toolset

## Purpose

This toolset upgrades a FortiGate autoscale group on AWS. Two upgrade strategies
are supported:

| Strategy | Use When | Downtime | Rollback |
|----------|----------|----------|---------|
| **In-Place** | Healthy deployment with two or more instances, same-major FortiOS version bump | One instance short during each replacement; its connections are dropped | Previous launch template version (`state/inplace_rollback.json`), then roll again |
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

**Path B — instances running (rolling replacement):**
```
Phase 0: Discovery    — Read state + detect architecture
         Pre-flight   — Live checks: all instances InService, all GWLB targets healthy,
                        exactly one primary, two or more instances. Nothing is changed
                        if a check fails.
Phase 1: Backup       — Operator exports the primary's config (save under backups/)
Phase 2: Update LTs   — Target AMI on the launch templates of both ASGs; the previous
                        versions are saved to state/inplace_rollback.json
Phase 3: Rolling      — Replace secondaries one at a time, in both ASGs; each replacement
                        is identified by its new instance ID and must be InService, GWLB
                        healthy and tagged Secondary before the next one is touched
                        Replace the primary last, after the operator has checked the
                        config on an upgraded secondary and confirmed
                        Lambda promotes one of the upgraded secondaries
Phase 4: Verify       — All instances on target AMI, GWLB healthy, one primary, ASG
                        launches the target AMI, no ASG process left suspended
Phase 5: Restore      — Only with --restore-config FILE (cross-major-version upgrades)
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
│   ├── blue_green.py           — Blue-green Phases 0–3 end to end; stops before cutover
│   ├── prepare_green_config.py — Rewrite Blue's GWLB addresses in the backup for Green
│   ├── cutover.py              — TGW route flip + NAT GW EIP migration
│   ├── rollback.py             — Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh         — Stream Lambda CloudWatch logs during upgrade
├── tests/
│   ├── test_inplace_upgrade.py — Tests against a simulated ASG and Lambda (no AWS calls)
│   ├── test_prepare_green_config.py — Tests for the backup rewrite (no AWS calls)
│   └── test_blue_green.py      — Tests for blue_green.py against fakes (no AWS calls)
├── backups/                    — Config backups for a rolling upgrade (not in git)
└── state/
    ├── refresh.sh              — Copy fresh state files from terraform directories
    ├── autoscale_template.tfstate      (copied by refresh.sh)
    ├── existing_vpc_resources.tfstate  (copied by refresh.sh)
    ├── blue_inventory.json             (output of discover.py)
    ├── inplace_rollback.json           (launch template versions before an in-place upgrade)
    └── green.tfstate                   (copied from green_inspection_stack after apply)
```

## Quick Reference: In-Place

**Step 1: Discovery**

```bash
cd upgrade_fortios
bash state/refresh.sh

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.8 \
  --output state/blue_inventory.json
```

**Step 2: Run upgrade**

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script reads the live ASGs and selects the path: instances running → Path B; both
ASGs at zero → Path A, or Path C if a `.conf` backup is present in `state/`.

Options: `--restore-config FILE` (Path B, cross-major only: restore this backup to the new
primary after the roll), `--fgt-api-key KEY` (do a restore through the REST API instead of
the GUI), `--fgt-mgmt-port PORT` (FortiGate admin HTTPS port used for a restore, default
443), `--allow-single-instance` (accept the outage of replacing the only instance),
`--upgrade-path-verified` (required when a config restore crosses a minor or major version:
confirms that Fortinet's Upgrade Path Tool, https://docs.fortinet.com/upgrade-tool/fortigate,
gives a single-step path from the backup's version to the target).

`./upgrade --in-place --fortios-version 7.6.8` runs refresh, discovery and the upgrade in
order.

**Step 3: Reconcile Terraform**

Set `fortios_version` to the new version in `terraform/autoscale_template/terraform.tfvars`
and run `terraform plan`. The launch template is a Terraform resource; until this is done,
Terraform still describes the old version, and its AMI lookup fails once AWS Marketplace
deprecates the old AMI.

**Tests**

```bash
python3 tests/test_inplace_upgrade.py
```

## Quick Reference: Blue-Green

| Phase | Script / Action | Gate |
|-------|-----------------|------|
| 0 Discovery | `discover.py` | Review inventory |
| 1 Backup | FortiGate GUI config export | Save to `state/blue_primary_config.conf`; `cutover.py` stops without it |
| 2 Deploy Green | `terraform apply` (green_inspection_stack) | Review plan |
| 3 Validate | Manual health checks + console review | All checks pass |
| 4 Cutover | `cutover.py --dry-run` then `cutover.py` | Monitor traffic |
| 5 Monitor | 24–48 h observation | Application teams confirm |
| 6 Cleanup | Manual `terraform destroy` (green_inspection_stack teardown of Blue) | Operator approval |

`./upgrade --blue-green --fortios-version <v>` (`scripts/blue_green.py`) runs Phases 0–3,
including the backup, Green's tfvars, the restore with Green's GWLB addresses and the GENEVE
check. It stops there and prints the cutover commands; Phase 4 onwards is always by hand.

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
- **ASG suspension (In-Place)** — `ReplaceUnhealthy`, `AZRebalance` and `ScheduledActions`
  are suspended on both ASGs during the rolling replacement and resumed on every exit,
  including an operator abort. Launch and terminate stay active: the ASG itself launches
  each replacement.
- **Target AMI from AWS Marketplace only (In-Place)** — the target AMI is searched among
  images owned by `aws-marketplace` with the product code of the AMI in use today. An
  image name alone is not accepted.
- **Primary by tag (In-Place)** — the primary is the instance tagged
  `Autoscale Role: Primary`; scale-in protection is only a fallback.
