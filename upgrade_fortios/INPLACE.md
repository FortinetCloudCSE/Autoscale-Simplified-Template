# In-Place FortiOS Upgrade

## Overview

The in-place upgrade updates the launch template AMI and either updates running
instances via rolling replacement (Path B) or restores the primary config to a fresh
instance (Path C). Run `discover.py` first to build `blue_inventory.json`, then run
`inplace_upgrade.py` — it detects the path automatically from live ASG state.

For a no-downtime rolling upgrade, see Path B below.  
For full fallback capability, use blue-green. See BLUE-GREEN-PLAN.md.

---

## When to Use

- Minor or patch version bumps (Path B — rolling, no downtime)
- Cross-major-version upgrades where rolling config sync will not work (Path C)
- Deployments where simplicity is preferred over zero-downtime

---

## Step 1: Run Discovery

```bash
cd upgrade_fortios
bash state/refresh.sh

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version <target-version> \
  --output state/blue_inventory.json
```

Review the output before proceeding:

```bash
python3 -m json.tool state/blue_inventory.json | less
```

The `upgrade_path` field in the output tells you which path the script will use:
- `"A"` — desired=0, no backup file → launch template update only
- `"B"` — instances running → rolling replacement
- `"C"` — desired=0 + `state/blue_primary_config.conf` present → config restore path

---

## Path A — Launch Template Update Only

**Condition:** Both BYOL and On-Demand ASGs have `desired=0`. No instances running.

```
Phase 0: Discovery    — Read state, detect architecture, confirm path
Phase 1: Update LTs   — Create new launch template version with target AMI
                        Update both BYOL and On-Demand ASGs to use new version
                        Done — all future instance launches use the new FortiOS.
```

### Running Path A

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script detects `desired=0` and no backup file, updates launch templates, and exits.
When the ASG is later scaled up, new instances launch with the target FortiOS version.

---

## Path B — Rolling Replacement

**Condition:** One or more instances are running (`desired > 0`).

```
Phase 0: Discovery    — Read state, detect architecture, detect path
Phase 1: Backup       — Export primary FortiGate config (safety net)
Phase 2: Update LTs   — New launch template version with target AMI on both ASGs
Phase 3: Rolling      — Terminate secondaries one at a time, wait for replacement
                        Terminate primary last — secondaries cover traffic, no gap
                        Lambda elects new primary from existing secondaries
Phase 4: Verify       — All instances on new AMI, GWLB healthy, primary elected
```

### Running Path B

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script detects `desired > 0` and runs rolling replacement. It pauses at each gate
and prompts for confirmation before proceeding.

---

## Path C — Restore Config to Fresh Instance

**Condition:** `desired=0` AND `state/blue_primary_config.conf` is present.

Path C is used for:
- Cross-major-version upgrades where config sync will not work
- Any upgrade where the operator wants a clean instance with a known-good config

```
Phase 0: Discovery    — Detect path (desired=0 and .conf present)
Phase 1: Update LTs   — New launch template version with target AMI on both ASGs
Phase 2: Launch       — Set ASG min=1, desired=1; wait for instance running,
                        GWLB healthy, and Autoscale Role: Primary tag
Phase 3: Config       — Restore blue_primary_config.conf to new primary
                        (via FortiGate REST API if --fgt-api-key provided,
                         otherwise operator restores via GUI and confirms)
Phase 4: Wait         — Poll until primary recovers from reboot after restore
Phase 5: Scale out    — Set ASG to original min/desired/max capacity
                        Secondary launches; Lambda assigns license and syncs config
```

### Step-by-Step Procedure

#### Step 1: Back Up Primary Config

Before scaling to zero, export the full configuration from the running primary FortiGate:

1. Log in to primary FortiGate GUI
2. **System → Settings → Backup → Full Configuration**
3. Save as `upgrade_fortios/state/blue_primary_config.conf`

#### Step 2: Scale ASG to Zero

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <byol_asg_name> \
  --min-size 0 \
  --desired-capacity 0 \
  --max-size 0
```

Wait for all instances to terminate.

#### Step 3: Run the Script

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --fgt-api-key <api-key>   # optional — enables automated config restore
```

With `--fgt-api-key`, the script posts the config backup to the FortiGate REST API
automatically. Without it, the script pauses at Phase 3 and prompts the operator to
restore manually via **System → Settings → Restore → Upload**.

#### Step 4: Verify

After scale-out completes:
- Both instances GWLB healthy
- Primary tagged `Autoscale Role: Primary`
- Secondary tagged `Autoscale Role: Secondary`
- FortiGate GUI reflects correct FortiOS version and config

---

## Architecture Detection

The script detects x86 vs ARM64 from the current launch template AMI name:

| AMI name contains | Architecture |
|---|---|
| `VMARM64-AWS` | ARM64 |
| `VM64-AWS` | x86 |
| `VMARM64-AWSONDEMAND` | ARM64 (On-Demand) |
| `VM64-AWSONDEMAND` | x86 (On-Demand) |

---

## Config Restore Note

The config backup is a full FortiGate configuration export. When restored to a new
instance in the same deployment, interface-specific settings (IP addresses, routes)
are compatible because the new instance lands in the same VPC and subnets.

After the primary restore and scale-out, the secondary receives its config via the
Lambda (config pushed from primary with vdom-exceptions applied for AZ/subnet
differences) — no manual secondary restore needed.

---

## Monitoring Lambda During Upgrade

Tail Lambda logs in a separate terminal while the upgrade runs:

```bash
bash scripts/watch_lambda.sh
```

This streams CloudWatch logs from the ASG Lambda function, showing license assignment,
instance initialization, and config sync events in real time.

---

## Rollback

**Path A:** Update the launch template back to the previous AMI version. No instances
were affected.

**Path B:** If replacement fails mid-rolling:
1. Resume suspended ASG processes: `ReplaceUnhealthy`, `AZRebalance`, `ScheduledActions`
2. Assess current instance state — determine which are on old vs new AMI
3. To revert: update both launch templates back to the previous AMI version and
   re-run rolling replacement

**Path C:** If the upgrade fails after config restore:
1. Terminate the failed instance
2. Update the launch template back to the previous AMI version
3. Scale ASG to `min=1, desired=1`
4. Restore config backup to the new instance
5. Scale out to full capacity

---

## Finding Available AMIs

```python
import boto3
ec2 = boto3.client('ec2', region_name='us-west-2')
paginator = ec2.get_paginator('describe_images')
pages = paginator.paginate(Filters=[{'Name': 'name', 'Values': ['*FortiGate*7.6*']}])
images = []
for page in pages:
    images.extend(page['Images'])
images.sort(key=lambda x: x['CreationDate'])
for img in images:
    print(f"{img['CreationDate'][:10]}  {img['ImageId']}  {img['Name']}")
```
