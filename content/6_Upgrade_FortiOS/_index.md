---
title: "Upgrade FortiOS"
chapter: true
menuTitle: "Upgrade FortiOS"
weight: 60
---

# Upgrading FortiOS on an Autoscale Group

Three strategies are available. **Blue-green in the same VPC is the recommended one** for
every upgrade, minor and major: it is done entirely with `terraform apply`, running sessions are
not interrupted at the cutover, and rollback is one apply. The other two remain for deployments
that cannot run two FortiGate groups at once (licenses, quotas) or that prefer a separate stack.

## Upgrade Strategies

| Strategy | Best For | Traffic Impact | Rollback |
|----------|----------|----------------|---------|
| **Blue-Green, Same VPC (recommended)** | Any upgrade with a single-step upgrade path; centralized and distributed egress | Running sessions stay on Blue; new flows go to Green | `active_slot` back + `terraform apply` |
| **In-Place** | Same-major-version bumps when two FortiGate groups cannot run at once | One instance short during each replacement; its connections are dropped | Previous launch template version, then roll again |
| **Blue-Green, Separate VPC** | When the new version must run in a separate inspection VPC | Near-zero (session interrupt at cutover) | Single script call, < 60 seconds |

---

## Blue-Green in the Same VPC

The new FortiGate group is built as a second "slot" in the same inspection VPC, behind the same
Gateway Load Balancer. All steps are `terraform.tfvars` edits followed by `terraform apply` in
`terraform/autoscale_template`:

| Step | Change | What the plan does |
|------|--------|--------------------|
| 1 — Add the new slot | `fgt_slots` gets the new slot with the new `fortios_version` | Creates only the new slot |
| 2 — Restore | Restore the old slot's backup on the new primary (unchanged) | — |
| 3 — Cutover | `active_slot` = the new slot | Changes only the GWLB listener |
| 4 — Monitor | Keep the old slot as a fallback | — |
| 5 — Remove the old slot | Take it out of `fgt_slots` | Destroys only the old slot's FortiGate resources |

## In-Place Upgrade Paths

The in-place strategy inspects live ASG state and selects the appropriate path automatically:

| Path | Condition | What Happens |
|------|-----------|-------------|
| **A** | `desired = 0`, no running instances | Update launch templates only — no instance replacement |
| **B** | Instances running | Rolling replacement in both ASGs: secondaries first, primary last |
| **C** | `desired = 0` + config backup present | Update LTs, launch primary, restore config, scale out |

---

## Blue-Green (Separate VPC) Phases

This strategy deploys a parallel inspection stack and flips TGW routes at cutover:

| Phase | Action | Duration |
|-------|--------|---------|
| 0 — Discovery | Extract Blue inventory from the Terraform state files | 30 min |
| 1 — Backup | Export primary FortiGate configuration | 30–60 min |
| 2 — Deploy Green | `terraform apply` with new FortiOS AMI | 30–60 min |
| 3 — Validate Green | Health checks, config verification | 30–60 min |
| 4 — Cutover | Atomic TGW route flip + EIP migration | 5–10 min |
| 5 — Monitor | Blue suspended as fallback | 24–48 hours |
| 6 — Cleanup | `terraform destroy` Blue (irreversible) | 1–2 hours |

---

## Contents

### [Overview](6_1_overview/)
Strategy selection guide, toolset architecture, and prerequisites.

### [Blue-Green, Same VPC (Recommended)](6_5_blue_green_same_vpc/)
Second FortiGate slot behind the same GWLB; cutover by changing the GWLB listener with
`terraform apply`.

### [In-Place Upgrade](6_2_in_place_upgrade/)
Paths A, B, and C — step-by-step procedures for in-place FortiOS upgrades.

### [Blue-Green, Separate VPC](6_3_blue_green_upgrade/)
Phase-by-phase guide for parallel deployment with TGW route flip cutover.

### [Discovery](6_4_discovery/)
How `discover.py` extracts the Blue environment from Terraform state and the
`blue_inventory.json` schema used by the in-place and separate-VPC procedures.

---

## Toolset Location

All upgrade scripts, documentation, and state files live under:

```
upgrade_fortios/
├── scripts/
│   ├── discover.py          — Extract Blue inventory from the Terraform state files
│   ├── inplace_upgrade.py   — In-place upgrade workflow (Paths A, B, C)
│   ├── cutover.py           — TGW route flip + NAT GW EIP migration
│   ├── rollback.py          — Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh      — Stream Lambda CloudWatch logs during upgrade
├── state/                   — Working directory for tfstate files and the inventory
├── backups/                 — Config backups taken before a rolling upgrade (not in git)
├── tests/                   — Tests against a simulated ASG (no AWS calls)
└── README.md
```
