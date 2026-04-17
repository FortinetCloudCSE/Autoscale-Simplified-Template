---
title: "Upgrade FortiOS"
chapter: true
menuTitle: "Upgrade FortiOS"
weight: 60
---

# Upgrading FortiOS on an Autoscale Group

The `upgrade_fortios/` toolset upgrades a FortiGate autoscale group running in AWS.
Two strategies are available, selected interactively at runtime based on the deployment's
current state and the operator's risk tolerance.

## Upgrade Strategies

| Strategy | Best For | Traffic Impact | Rollback |
|----------|----------|----------------|---------|
| **In-Place** | Same-major-version bumps on healthy deployments | Brief per-instance restart | Manual LT revert |
| **Blue-Green** | Cross-major-version upgrades, config remediation, or when full fallback is required | Near-zero (session interrupt at cutover) | Single script call, < 60 seconds |

---

## In-Place Upgrade Paths

The in-place strategy inspects live ASG state and selects the appropriate path automatically:

| Path | Condition | What Happens |
|------|-----------|-------------|
| **A** | `desired = 0`, no running instances | Update launch templates only — no instance replacement |
| **B** | `desired > 0`, instances running | Rolling replacement: secondaries first, primary last |
| **C** | `desired = 0` + config backup present | Update LTs, launch primary, restore config, scale out |

---

## Blue-Green Upgrade Phases

The blue-green strategy deploys a parallel inspection stack and flips TGW routes at cutover:

| Phase | Action | Duration |
|-------|--------|---------|
| 0 — Discovery | Extract Blue inventory from `terraform.tfstate` | 30 min |
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

### [In-Place Upgrade](6_2_in_place_upgrade/)
Paths A, B, and C — step-by-step procedures for in-place FortiOS upgrades.

### [Blue-Green Upgrade](6_3_blue_green_upgrade/)
Phase-by-phase guide for parallel deployment with TGW route flip cutover.

### [Discovery](6_4_discovery/)
How `discover.py` extracts the Blue environment from Terraform state and the
`blue_inventory.json` schema used by all subsequent phases.

---

## Toolset Location

All upgrade scripts, documentation, and state files live under:

```
upgrade_fortios/
├── scripts/
│   ├── discover.py          — Extract Blue inventory from terraform.tfstate
│   ├── inplace_upgrade.py   — In-place upgrade workflow (Paths A, B, C)
│   ├── cutover.py           — TGW route flip + NAT GW EIP migration
│   ├── rollback.py          — Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh      — Stream Lambda CloudWatch logs during upgrade
├── state/                   — Working directory for tfstate files and backups
└── README.md
```
