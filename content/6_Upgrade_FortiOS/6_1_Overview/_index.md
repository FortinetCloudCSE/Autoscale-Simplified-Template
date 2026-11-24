---
title: "Overview"
menuTitle: "Overview"
weight: 61
---

## Purpose

The `upgrade_fortios/` toolset upgrades the FortiOS version on a FortiGate autoscale group
running in AWS. It reads the deployment's existing Terraform state to discover it
automatically — no manual resource identification is required.

---

## Why Upgrading an Autoscale Group Is Different

On a standalone FortiGate, an upgrade is an operation on a running instance: you upload new
firmware, the unit reboots into it, and the instance keeps its identity, its disk, and its
configuration. The upgraded version *is* the instance.

In an autoscale group, that model does not apply. FortiGate instances are **disposable and
are created from a template**, not maintained individually. The ASG can terminate any
instance (scale-in, health-check failure, instance refresh) and launch a replacement at any
time — and every replacement is built from whatever the **launch template** says at that
moment.

The launch template is therefore the source of truth for the FortiOS version:

| Component | What it controls |
|-----------|------------------|
| **Launch template AMI** | The FortiOS version every *new* instance boots with |
| **Launch template user-data** | The bootstrap config (license, hostname, sync/HA settings) applied at first boot |
| **Auto Scaling Group** | How many instances exist, and when instances are added or removed |
| **Lifecycle hooks + Lambda** | Holds new instances in `Pending:Wait` until they are configured and joined to the cluster |

### The trap: upgrading the instances but not the template

If you upgrade FortiOS on the running FortiGates (GUI, CLI, or FortiManager) and leave the
launch template alone, the upgrade looks successful — until the next scale-out event or
instance replacement. The new instance launches from the *old* AMI and comes up on the
*old* FortiOS version. The group is now running mixed versions, which can break config
sync with the primary, produce unpredictable behavior, and silently undo the upgrade over
time as upgraded instances are recycled.

### The inverse: upgrading the template but not the instances

Updating the launch template only affects **future launches**. It does not touch instances
that are already running. Until those instances are replaced, the group continues to run
the old version.

### What an autoscale upgrade must therefore do

An upgrade of an autoscale group has two jobs, and both are required:

1. **Update the launch template** (new version with the target AMI) on every ASG that
   launches FortiGates — both BYOL and On-Demand — so all future instances come up on the
   target version.
2. **Replace the running instances** so they are rebuilt from the new template, rather
   than upgrading them in place with firmware.

And one follow-up that is easy to miss: the launch template is a Terraform resource, and
the module chooses its AMI from `fortios_version` in `terraform.tfvars`. After the
upgrade, **set `fortios_version` to the new version** and check `terraform plan`.
Otherwise the next `terraform apply` either fails (AWS Marketplace deprecates the AMIs of
older versions, and the lookup does not return deprecated images) or puts the launch
template back on the old version. See
[Reconcile Terraform](../6_2_in_place_upgrade/#after-the-upgrade-reconcile-terraform).

Replacing instances has its own consequences that a standalone upgrade does not face:

- **Configuration is not carried over.** A replacement boots from bootstrap user-data and
  receives its configuration from the primary via native config sync. Across major
  versions this sync does not work, which is why cross-major upgrades need a config
  restore (Path C) or a parallel stack (blue-green).
- **Licensing is re-evaluated.** Each new instance must obtain a BYOL license or come up
  as PAYGO, so capacity planning matters during the upgrade.
- **Primary election and traffic.** Instances must pass the lifecycle hook and GWLB
  health checks before receiving traffic, and the primary must be handled carefully so
  there is always an elected primary.
- **Connections are not carried over either.** Autoscale members do not share session
  state, so connections through an instance are dropped when it is replaced.

The strategies below are different answers to these problems. The in-place paths update the
launch template and then roll or restore instances. Blue-green builds an entirely new stack
from a new template and cuts traffic over.

{{% notice note %}}
"In-place" in this toolset means *the same ASG and Terraform stack is reused*, not that
FortiOS is upgraded on a running instance. Instances are still replaced; they are just
replaced by the same ASG.
{{% /notice %}}

---

## Entry Points

The toolset has two separate entry points — one for each strategy. Run `discover.py` first
for both strategies to build the inventory file.

**In-Place:**

```bash
cd upgrade_fortios
bash state/refresh.sh
python3 scripts/discover.py --state state/autoscale_template.tfstate \
  --target-version 7.6.8 --output state/blue_inventory.json
python3 scripts/inplace_upgrade.py --inventory state/blue_inventory.json
```

`./upgrade --in-place --fortios-version 7.6.8` runs the same three commands in order.

**Blue-Green:**

```bash
cd upgrade_fortios
bash state/refresh.sh
python3 scripts/discover.py --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.8 --output state/blue_inventory.json
# Then follow the six-phase blue-green procedure
```

---

## When to Use Each Strategy

### In-Place Upgrade

Use in-place when:

- Upgrading within the same major version (e.g., 7.6.7 → 7.6.8)
- The deployment is healthy — no known config or licensing issues
- The group has two or more instances, and the remaining ones can carry the load while
  one is being replaced
- Dropped connections on the instance being replaced are acceptable
- You want the simplest possible upgrade path

Avoid in-place for:
- Cross-major-version upgrades (e.g., 7.4.x → 7.6.x) — native config sync does not work
  across major versions; use Path C, Path B with `--restore-config`, or blue-green instead
- Single-instance groups — replacing the only instance is an outage; scale to two first
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

### Blue-Green in the Same VPC

The [same-VPC variant](../6_5_blue_green_same_vpc/) builds Green as a second FortiGate group
("slot") in the same inspection VPC, behind the same GWLB, and cuts over by changing which
target group the GWLB listener forwards to. Use it when:

- You want the benefits of blue-green without a second VPC, a second template or a Transit
  Gateway route flip
- The deployment uses distributed egress: the GWLB endpoints and their routes do not change
- Running sessions must not be interrupted at the cutover: they stay on Blue until they end

It is done entirely with `terraform apply` in `autoscale_template`, and it needs the same 2x
license capacity while both slots run.

---

## Strategy Comparison

| | In-Place (Path B) | Blue-Green | Blue-Green (Same VPC) |
|---|---|---|---|
| FortiOS versions | Same major (e.g., 7.6.x) | Any (7.4 → 7.6) | Any (single-step upgrade path) |
| Config sync during upgrade | Required | Not required | Not required |
| Traffic impact | One instance short during each replacement; connections through the replaced instance are dropped | Connections are interrupted once, at the route flip | Running sessions stay on Blue; new flows go to Green |
| Rollback | Point the ASGs at the previous launch template version and roll again | Single script, < 60 seconds | `active_slot` back + `terraform apply` |
| Cost | Normal | 2x licenses during monitoring window | 2x licenses while both slots run |
| Terraform state | Unchanged | New Green state added | Same state; slots added and removed |
| Typical duration | ~30 min | Longer (full stack deploy + 24–48h monitoring) | Green build ~10 min + monitoring |

---

## Prerequisites

### Software

- Python 3.8 or later
- `boto3` library: `pip3 install boto3`
- AWS CLI configured with credentials for the target account. The region is read from
  the Terraform state file; `discover.py --region` overrides it

### AWS Permissions

The operator's IAM role or user requires:

| Service | Permissions |
|---------|------------|
| EC2 | `DescribeInstances`, `DescribeImages`, `DescribeLaunchTemplateVersions`, `CreateLaunchTemplateVersion`, `ModifyLaunchTemplate`, `DescribeNetworkInterfaces` |
| AutoScaling | `DescribeAutoScalingGroups`, `DescribeAutoScalingInstances`, `UpdateAutoScalingGroup`, `SuspendProcesses`, `ResumeProcesses`, `TerminateInstanceInAutoScalingGroup` |
| ELBv2 | `DescribeTargetHealth`, `DescribeLoadBalancers`, `DescribeTargetGroups` |
| EC2 Transit Gateway | `DescribeTransitGatewayRouteTables`, `SearchTransitGatewayRoutes`, `ReplaceTransitGatewayRoute` (blue-green only) |
| CloudWatch | `DescribeAlarms` |
| Lambda | `GetFunction` |
| DynamoDB | `DescribeTable`, `GetItem` (FortiFlex serial check) |

### State Files

The scripts discover the Blue environment from copies of the Terraform state, kept in
`upgrade_fortios/state/` under the name of the template they came from:
`autoscale_template.tfstate` (always) and `existing_vpc_resources.tfstate` (blue-green).
Get the state files into that directory before running any scripts:

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
│   ├── discover.py          ← Parse state/*.tfstate → blue_inventory.json
│   ├── inplace_upgrade.py   ← In-place upgrade: Paths A, B, C
│   ├── cutover.py           ← TGW route flip + NAT GW EIP migration
│   ├── rollback.py          ← Revert TGW routes to Blue + EIP rollback
│   └── watch_lambda.sh      ← Stream Lambda CloudWatch logs during upgrade
├── state/
│   ├── refresh.sh                          ← Copy fresh tfstate from terraform/ dirs
│   ├── autoscale_template.tfstate          (Blue autoscale state)
│   ├── existing_vpc_resources.tfstate      (VPC/TGW topology)
│   ├── blue_inventory.json                 (output of discover.py)
│   ├── inplace_rollback.json               (launch template versions before an in-place upgrade)
│   ├── blue_primary_config.conf            (FortiGate backup — Path C and blue-green Phase 1)
│   ├── green.tfstate                       (Green stack state — blue-green only)
│   └── cutover_progress.json              (written by cutover.py — used by rollback.py)
├── backups/                                ← Config backups for a rolling upgrade (not in git)
└── tests/
    └── test_inplace_upgrade.py             ← Tests against a simulated ASG, no AWS calls
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
