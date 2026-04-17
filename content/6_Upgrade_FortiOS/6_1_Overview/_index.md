---
title: "Overview"
menuTitle: "Overview"
weight: 61
---

## Purpose

The `upgrade_fortios/` toolset upgrades the FortiOS version on a FortiGate autoscale group
running in AWS. It reads the existing `terraform.tfstate` file to discover the deployment
automatically — no manual resource identification is required.

---

## Entry Points

The toolset has two separate entry points — one for each strategy. Run `discover.py` first
for both strategies to build the inventory file.

**In-Place:**

```bash
cd upgrade_fortios
bash state/refresh.sh
python3 scripts/discover.py --state state/autoscale_template.tfstate \
  --target-version 7.6.2 --output state/blue_inventory.json
python3 scripts/inplace_upgrade.py --inventory state/blue_inventory.json
```

**Blue-Green:**

```bash
cd upgrade_fortios
bash state/refresh.sh
python3 scripts/discover.py --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.2 --output state/blue_inventory.json
# Then follow the six-phase blue-green procedure
```

---

## When to Use Each Strategy

### In-Place Upgrade

Use in-place when:

- Upgrading within the same major version (e.g., 7.2.8 → 7.2.13)
- The deployment is healthy — no known config or licensing issues
- Brief per-instance restart is acceptable
- You want the simplest possible upgrade path

Avoid in-place for:
- Cross-major-version upgrades (e.g., 7.4.x → 7.6.x) — native config sync does not work
  across major versions; use Path C or blue-green instead
- Deployments with misconfigured alarms, license sync issues, or other known problems

### Blue-Green Upgrade

Use blue-green when:

- Upgrading across major versions (e.g., 7.4 → 7.6)
- The existing deployment has known configuration problems (broken alarms, license issues)
- You need full rollback capability — Blue stays live as a fallback until you confirm cleanup
- You want to validate the new version under real traffic before committing

{{% notice info %}}
Blue-green requires approximately 2x license capacity during the monitoring window (Phase 5)
while both Blue and Green ASGs are running simultaneously.
{{% /notice %}}

---

## Strategy Comparison

| | In-Place (Path B) | Blue-Green |
|---|---|---|
| FortiOS versions | Same major (e.g., 7.2.x) | Any (7.4 → 7.6) |
| Config sync during upgrade | Required | Not required |
| Traffic gap | None (rolling) | None (route flip) |
| Rollback | Manual LT revert | Single script, < 60 seconds |
| Cost | Normal | 2x licenses during monitoring window |
| Terraform state | Unchanged | New Green state added |
| Typical duration | ~30 min | Longer (full stack deploy + 24–48h monitoring) |

---

## Prerequisites

### Software

- Python 3.8 or later
- `boto3` library: `pip3 install boto3`
- AWS CLI configured with credentials for the target account

### AWS Permissions

The operator's IAM role or user requires:

| Service | Permissions |
|---------|------------|
| EC2 | `DescribeInstances`, `DescribeImages`, `CreateLaunchTemplateVersion`, `ModifyLaunchTemplate`, `DescribeNetworkInterfaces` |
| AutoScaling | `DescribeAutoScalingGroups`, `DescribeAutoScalingInstances`, `UpdateAutoScalingGroup`, `SuspendProcesses`, `ResumeProcesses`, `TerminateInstanceInAutoScalingGroup` |
| ELBv2 | `DescribeTargetHealth`, `DescribeLoadBalancers`, `DescribeTargetGroups` |
| EC2 Transit Gateway | `DescribeTransitGatewayRouteTables`, `SearchTransitGatewayRoutes`, `ReplaceTransitGatewayRoute` (blue-green only) |
| CloudWatch | `DescribeAlarms` |
| Lambda | `GetFunction` |
| DynamoDB | `DescribeTable` |

### State Files

The scripts read `terraform.tfstate` to discover the Blue environment. Get the state file
into the `upgrade_fortios/state/` directory before running any scripts:

```bash
# Refresh from local Terraform working directories
bash upgrade_fortios/state/refresh.sh

# Or for remote S3 backend, pull state manually
cd terraform/autoscale_template
terraform state pull > ../../upgrade_fortios/state/autoscale_template.tfstate
```

{{% notice warning %}}
Always use a fresh state file. An outdated state file can produce incorrect inventory
results and cause the upgrade scripts to target the wrong resources.
{{% /notice %}}

---

## Toolset Architecture

```
upgrade_fortios/
├── scripts/
│   ├── discover.py          ← Parse terraform.tfstate → blue_inventory.json
│   ├── inplace_upgrade.py   ← In-place upgrade: Paths A, B, C
│   ├── cutover.py           ← TGW route flip + NAT GW EIP migration
│   ├── rollback.py          ← Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh      ← Stream Lambda CloudWatch logs during upgrade
├── state/
│   ├── refresh.sh                          ← Copy fresh tfstate from terraform/ dirs
│   ├── autoscale_template.tfstate          (Blue autoscale state)
│   ├── existing_vpc_resources.tfstate      (VPC/TGW topology)
│   ├── blue_inventory.json                 (output of discover.py)
│   ├── blue_primary_config.conf            (FortiGate backup — Phase 1)
│   ├── green.tfstate                       (Green stack state — blue-green only)
│   └── cutover_progress.json              (written by cutover.py — used by rollback.py)
```

### Data Flow

```
autoscale_template.tfstate ──┐
existing_vpc_resources.tfstate─┤
                               ▼
                          discover.py
                               │
                               ▼
                      blue_inventory.json
                               │
           ┌───────────────────┤
           │                   │
           ▼                   ▼
  inplace_upgrade.py     cutover.py ──→ cutover_progress.json
  (Paths A / B / C)           │                │
                               └───────────────▼
                                          rollback.py

  Blue-Green Phase 2:
  terraform apply (green_inspection_stack) ──→ green.tfstate
  (cutover.py reads green.tfstate outputs for Green attachment ID + NAT GW info)
```

---

## Operator Confirmation Gates

Both strategies require explicit operator confirmation at each significant step. The scripts
will not proceed automatically past a gate — they print the current state, describe the
next action, and wait for `[y/N]` confirmation.

This is intentional: upgrades affect production traffic and should not proceed
unattended past checkpoints.

---

## Next Steps

- **In-place upgrade**: See [In-Place Upgrade](../6_2_in_place_upgrade/)
- **Blue-green upgrade**: See [Blue-Green Upgrade](../6_3_blue_green_upgrade/)
- **Understanding discovery**: See [Discovery](../6_4_discovery/)
