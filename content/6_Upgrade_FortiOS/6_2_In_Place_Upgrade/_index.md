---
title: "In-Place Upgrade"
menuTitle: "In-Place Upgrade"
weight: 62
---

## Overview

The in-place upgrade updates the launch template AMI and replaces running instances
without deploying a parallel environment. The script reads live ASG state from AWS and
selects the appropriate path automatically.

{{% notice warning %}}
**Cross-major-version upgrades** (e.g., 7.4.x → 7.6.x) require Path C — FortiGate
native config sync does not work across major versions. Rolling replacement (Path B)
alone is not sufficient; a config restore must follow.
{{% /notice %}}

---

## Path Selection

The script detects the current ASG desired capacity to determine the path:

```
BYOL desired=0 AND On-Demand desired=0?
    ├─ YES, and .conf backup present in state/ → Path C
    ├─ YES, no .conf backup               → Path A
    └─ NO  (instances running)            → Path B
```

| Path | Condition | Downtime | Use When |
|------|-----------|----------|---------|
| **A** | desired=0, no backup | None — no instances | ASG is already scaled to zero |
| **B** | desired>0 | Per-secondary restart; brief at primary | Same-major-version, healthy deployment |
| **C** | desired=0 + backup | Yes — ASG starts at zero, scales up | Cross-major-version or any desired=0 upgrade with config restore |

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
cd upgrade_fortios
bash state/refresh.sh

# Step 1: Discovery (sets target AMI in inventory)
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.4.6 \
  --output state/blue_inventory.json

# Step 2: Upgrade
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script detects `desired=0`, updates launch templates, and exits. When the ASG is
later scaled up (manually or by CloudWatch alarms), new instances launch with the
target FortiOS version.

---

## Path B — Rolling Replacement

**Condition:** One or more instances are running (`desired > 0`).

```
Phase 0: Discovery    — Read state, detect architecture, detect path
Phase 1: Backup       — Export primary FortiGate config (safety net)
Phase 2: Update LTs   — New launch template version with target AMI on both ASGs
Phase 3: Rolling      — Terminate secondaries one at a time, wait for replacement
                        Terminate primary last — secondaries cover traffic, no gap
                        Lambda elects new primary from surviving secondaries
Phase 4: Verify       — All instances on new AMI, GWLB healthy, primary elected
```

### Replacement Sequence

For a 2-instance deployment (1 primary, 1 secondary):

```
Start:   [Primary 7.2.8] [Secondary 7.2.8]   ← both in service, config synced

Step 1:  Terminate secondary
         [Primary 7.2.8] [Secondary TERMINATED]

Step 2:  ASG launches replacement
         [Primary 7.2.8] [New Secondary 7.2.13 — initializing]

Step 3:  Wait: GWLB healthy + Autoscale Role: Secondary tag
         [Primary 7.2.8] [New Secondary 7.2.13 — ready]

Step 4:  Operator confirms → terminate primary
         [Primary TERMINATED] [New Secondary 7.2.13 — handling traffic]

Step 5:  Lambda elects new primary
         [New Primary 7.2.13] [slot vacant]

Step 6:  ASG launches replacement for vacated slot
         [New Primary 7.2.13] [New Secondary 7.2.13 — initializing]

Step 7:  Wait: GWLB healthy + Autoscale Role: Secondary tag
         [New Primary 7.2.13] [New Secondary 7.2.13 — ready]

Done:    Both instances on 7.2.13, config synced
```

For deployments with multiple secondaries, Steps 1–3 repeat for each secondary
before the primary is touched.

### Secondary Readiness Checks

After a replacement instance launches, the script waits for all three conditions:

1. **ASG InService** — passed EC2 health checks and ASG lifecycle hook
2. **GWLB healthy** — passing GWLB health checks on port 6081 (GENEVE)
3. **`Autoscale Role: Secondary` tag** — Lambda completed initialization: license
   assigned, config pushed from primary, instance registered in DynamoDB

The primary is not terminated until all secondaries satisfy all three conditions.

{{% notice info %}}
**Known limitation:** The GWLB health check passes before native FortiGate-to-FortiGate
config sync completes. For same-major-version upgrades, this gap is small — by the time
the operator reads the confirmation prompt and responds, sync is complete in practice.
For cross-major-version upgrades, native sync does not work at all — use Path C.
{{% /notice %}}

### ASG Process Suspension

During rolling replacement, the script suspends three ASG processes to prevent
interference:

| Process | Why Suspended |
|---------|--------------|
| `ReplaceUnhealthy` | Prevents ASG from replacing instances the script is managing |
| `AZRebalance` | Prevents unwanted launches/terminates for AZ balance |
| `ScheduledActions` | Prevents scheduled scaling changes during upgrade |

Processes are automatically resumed after completion or on error.

### Running Path B

```bash
cd upgrade_fortios
bash state/refresh.sh

# Step 1: Discovery (sets target AMI in inventory)
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.4.6 \
  --output state/blue_inventory.json

# Step 2: Upgrade
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script pauses at each gate and prompts for confirmation before proceeding.

---

## Path C — Restore Config to Fresh Instance

**Condition:** `desired=0` AND a `.conf` backup file is present in the `state/` directory.

Path C is used for:
- Cross-major-version upgrades where config sync will not work
- Any upgrade where the operator wants to start from a clean instance with a known-good config

```
Phase 0: Discovery    — Read state, detect architecture, detect Path C
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

#### Step 1: Scale ASG to Zero

Before running the script, scale the BYOL ASG down manually:

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <byol_asg_name> \
  --min-size 0 \
  --desired-capacity 0 \
  --max-size 0
```

Wait for all instances to terminate.

#### Step 2: Back Up Primary Config

{{% notice warning %}}
Back up the primary FortiGate config **before** scaling to zero if the ASG is currently
running. Once instances terminate, the config is gone.
{{% /notice %}}

1. Log in to the primary FortiGate GUI
2. **System → Settings → Backup → Full Configuration**
3. Save the file to `upgrade_fortios/state/blue_primary_config.conf`

#### Step 3: Run the Script

```bash
cd upgrade_fortios
bash state/refresh.sh

# Step 3a: Discovery (sets target AMI in inventory)
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json

# Step 3b: Upgrade (detects Path C from desired=0 + backup file)
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --fgt-api-key <api-key>   # optional — enables automated config restore
```

With `--fgt-api-key`, the script posts the config backup to the FortiGate REST API
automatically:

```
POST /api/v2/monitor/system/config/restore
```

Without it, the script pauses at Phase 3 and prompts the operator to restore the
config manually via the FortiGate GUI:

**System → Settings → Restore → Upload `blue_primary_config.conf`**

After confirming the restore, the FortiGate reboots and the script resumes polling.

#### Step 4: Verify

After scale-out completes, verify:
- Both instances are GWLB healthy
- Primary is tagged `Autoscale Role: Primary`
- Secondary is tagged `Autoscale Role: Secondary`
- FortiGate GUI shows the target FortiOS version and the expected configuration

---

## Architecture Detection

The script determines whether the existing ASG uses x86 or ARM64 instances by
inspecting the current launch template AMI name:

| AMI Name Contains | Architecture |
|-------------------|-------------|
| `VMARM64-AWS` | ARM64 (BYOL) |
| `VM64-AWS` | x86 (BYOL) |
| `VMARM64-AWSONDEMAND` | ARM64 (On-Demand) |
| `VM64-AWSONDEMAND` | x86 (On-Demand) |

The target AMI lookup uses the detected architecture to find the correct AMI for the
target FortiOS version.

---

## Lambda Role During Replacement

When a new instance launches, the ASG lifecycle hook triggers the Lambda function:

1. Instance enters `Pending:Wait` lifecycle state
2. Lambda fires on `EC2 Instance-launch Lifecycle Action`
3. Lambda:
   - Adds instance to DynamoDB
   - Retrieves available FortiFlex license and assigns it
   - Gets primary IP from DynamoDB
   - Pushes config from primary to new instance via FortiGate API
   - Completes lifecycle action → instance moves to `InService`
   - Tags instance `Autoscale Role: Secondary`

When the primary is terminated:
1. Lambda fires on `EC2 Instance-terminate Lifecycle Action`
2. Lambda elects a new primary from remaining InService instances
3. Sets `ProtectedFromScaleIn: true` on the elected instance
4. Tags elected instance `Autoscale Role: Primary`
5. Returns FortiFlex license of terminated instance to the pool

---

## Rollback

### Path A
Update the launch template back to the previous AMI version. No instances were affected.

### Path B
If replacement fails mid-rolling:

1. Resume suspended ASG processes: `ReplaceUnhealthy`, `AZRebalance`, `ScheduledActions`
2. Assess current instance state — determine which instances are on old vs new AMI
3. If an instance is stuck: terminate it; the ASG will launch a replacement using
   the current (new) launch template
4. To revert to the previous FortiOS version entirely: update both launch templates
   back to the previous AMI version and re-run rolling replacement

### Path C
If the upgrade fails after config restore and the instance is unrecoverable:

1. Terminate the failed instance
2. Update the launch template back to the previous AMI version
3. Scale ASG to `min=1, desired=1`
4. Restore the config backup to the new instance
5. Scale out to full capacity

---

## Monitoring Lambda During Upgrade

Tail Lambda logs in a separate terminal while the upgrade runs:

```bash
bash upgrade_fortios/scripts/watch_lambda.sh
```

This streams CloudWatch logs from the ASG Lambda function, showing license assignment,
instance initialization, and config sync events in real time.
