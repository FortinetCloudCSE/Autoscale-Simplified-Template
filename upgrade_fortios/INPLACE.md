# In-Place FortiOS Upgrade

## Overview

The in-place upgrade updates the launch template AMI and either updates running
instances via rolling replacement (Path B) or restores the primary config to a fresh
instance (Path C). Run `discover.py` first to build `blue_inventory.json`, then run
`inplace_upgrade.py` — it detects the path automatically from live ASG state.

For a rolling upgrade of running instances, see Path B below.  
For full fallback capability, use blue-green. See BLUE-GREEN-PLAN.md.

The published guide, with the reasoning behind each step, is
`content/6_Upgrade_FortiOS/6_2_In_Place_Upgrade/_index.md`.

---

## When to Use

- Minor or patch version bumps on a group of two or more instances (Path B — rolling;
  the group is one instance short during each replacement and connections through the
  replaced instance are dropped)
- Cross-major-version upgrades where rolling config sync will not work (Path C, or
  Path B with `--restore-config`)
- Deployments where simplicity is preferred over a parallel stack

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

The `upgrade_path` field shows `"A"` (both ASGs at zero) or `"B"` (instances running) as
of discovery. `inplace_upgrade.py` reads the live ASGs again when it starts and decides
for itself:
- both ASGs at zero, no `.conf` in `state/` → Path A, launch template update only
- instances running → Path B, rolling replacement
- both ASGs at zero + a `.conf` in `state/` → Path C, config restore path

Discovery stops with an error if it cannot determine the region or the architecture, or
finds no AWS Marketplace AMI for the target version.

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

**Condition:** One or more instances are running.

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

Save the Phase 1 backup under `backups/`, not `state/`. A `.conf` in `state/` is ignored
by Path B and selects Path C the next time both ASGs are at zero.

Before answering the "Terminate primary" prompt, check on an upgraded secondary that the
configuration has arrived (`get system status`, `get system auto-scale`, firewall policy
count). The script's checks show the replacement is licensed, tagged and passing traffic;
they do not show that config sync from the primary has finished.

### Running Path B

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script runs the pre-flight checks and the rolling replacement. It pauses at each gate
and prompts for confirmation before proceeding. Answering "no" at any prompt stops it and
resumes the suspended ASG processes; running it again skips instances already on the
target AMI.

A single-instance group is refused unless `--allow-single-instance` is given, because
replacing the only instance is an outage.

For a cross-major upgrade add `--restore-config backups/<file>.conf` to restore the backup
to the new primary after the roll (this reboots it).

A config restore (here or in Path C) that crosses a minor or major version stops before
anything is changed, until the script is run with `--upgrade-path-verified`. The version
is read from the first line of the backup file. Check Fortinet's Upgrade Path Tool
(https://docs.fortinet.com/upgrade-tool/fortigate) first: restoring the backup is a
version conversion in one step, so the tool must show a single-step path from the
backup's version to the target. If it lists intermediate versions, upgrade one step at a
time. A backup from a newer version than the target is always refused.

Afterwards set `fortios_version` in `terraform/autoscale_template/terraform.tfvars` to the
new version and run `terraform plan`.

### Interrupted Runs and Expired Credentials

Running the same command again is always safe. Instances already on the target AMI are
skipped and ASG processes left suspended by the earlier run are resumed. When nothing is
left to replace, the script asks for no confirmation: it goes straight to the final checks
and prints the state of every instance.

If the AWS credentials expire during the run, the script pauses and asks for them to be
renewed. Renew them in another terminal (for example `aws sso login`) and press Enter; the
run continues. Credentials exported as environment variables in the shell that started the
script cannot be renewed this way: answer `q`, renew them, and run the same command again.

Replacing an instance takes about ten minutes, so a two-instance group needs credentials
that last about 25 minutes. The pre-flight summary warns when it can see that the
credentials expire sooner.

If the script stops while processes are still suspended, it prints the
`aws autoscaling resume-processes` command that resumes them.

### FortiFlex Serial Check

With FortiFlex licensing the autoscale Lambda issues each FortiGate a serial number and
records it in its DynamoDB table. Every FortiGate needs its own. A serial is valid on one
FortiGate at a time; a FortiGate that shares one shows `License Status: Grace Period` in
`get system status` and asks to be registered.

When an instance is terminated, the Lambda returns its serial to a pool. When an instance
launches, the Lambda issues it the first serial in the pool. It does not check whether
another instance already holds that serial. If two instances share a serial before the
upgrade, replacing them moves the valid license from one to the other and does not fix it.

A new deployment can start in that state. When two instances launch together, the Lambda
handles them in parallel and can issue both the first serial in the pool. The second token
replaces the first, so the first instance's license upload fails, and the Lambda returns
the serial to the pool although the other instance is using it. The unlicensed instance is
later replaced by the ASG, and its replacement is issued the same serial again. Two test
deployments of two instances both ended this way, with one serial ACTIVE in the FortiFlex
portal for two FortiGates. Check for it before the first upgrade.

The script reads the Lambda's record (the serials only, not the API tokens stored beside
them) at three points:

| When | What happens |
|---|---|
| Pre-flight | Refuses to start if a serial is issued to two running instances, or is in use and also in the Lambda's pool |
| After each secondary is replaced | Stops the roll, before the primary is touched, if the replacement was issued a serial another instance holds |
| Final checks | Fails the check and lists the serial of each instance |

To repair a shared serial: in the FortiFlex portal generate a token for an unused serial,
apply it on one FortiGate with `execute vm-license <token>` (the FortiGate reboots), and
correct `used_sn_map` and `available_sn_list` in the Lambda's DynamoDB table to match.

Groups licensed with license files or PAYG are not checked. If the table cannot be read
(the check needs `dynamodb:GetItem`), the check is reported as skipped and the roll
continues.

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
Phase 5: Scale out    — Set BYOL ASG to min=2, desired=2 (or its max, if lower)
                        Secondary launches; Lambda licenses and configures it, then it
                        syncs from the primary
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
  --desired-capacity 0
```

Leave the maximum as it is: the script scales back up within it and stops if the maximum
is zero. Wait for all instances to terminate.

#### Step 3: Run the Script

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --fgt-api-key <api-key>   # optional — enables automated config restore
```

With `--fgt-api-key`, the script posts the config backup to the FortiGate REST API
automatically. Without it, the script pauses at Phase 3 and prompts the operator to
restore manually via **System → Settings → Restore → Upload**.

Either way the script addresses the primary's management interface on HTTPS port 443.
Add `--fgt-mgmt-port <port>` if the FortiGate's admin HTTPS port (`admin-sport`) has been
changed. The option also applies to a Path B restore (`--restore-config`).

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

After the primary restore and scale-out, the Lambda licenses the secondary and sends it
its bootstrap configuration (GENEVE tunnels, `config system auto-scale` with the primary's
IP, the template's user configuration). The secondary then syncs the rest from the primary
itself — no manual secondary restore needed.

---

## Monitoring Lambda During Upgrade

Tail Lambda logs in a separate terminal while the upgrade runs:

```bash
bash scripts/watch_lambda.sh
```

This streams CloudWatch logs from the BYOL ASG's Lambda handler, showing license
assignment and instance initialization. The function name and region come from
`state/blue_inventory.json`; pass another function name as the first argument to watch a
different one.

---

## Rollback

The rollback target is the launch template **version** each ASG used before, recorded in
`state/inplace_rollback.json` and printed in Phase 2. Use the version number rather than
searching for the old FortiOS version again: AWS Marketplace deprecates old AMIs, which
hides them from searches while the launch template version that names them still works.

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg_name> \
  --launch-template LaunchTemplateId=<lt_id>,Version=<previous_version>
```

**Path A:** Point both ASGs back at the previous version. No instances were affected.

**Path B:** If replacement fails mid-rolling:
1. Check the ASG processes were resumed (the script resumes them on every exit)
2. Assess current instance state — determine which are on old vs new AMI
3. To go forward: run the script again; it skips instances already on the target AMI
4. To revert: point both ASGs back at the previous version and replace the instances
   again, secondaries first. Restore the pre-upgrade backup if the old version does not
   accept the newer configuration.

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
pages = paginator.paginate(Owners=['aws-marketplace'],
                           Filters=[{'Name': 'name', 'Values': ['FortiGate-VM*(7.6.*']}])
images = []
for page in pages:
    images.extend(page['Images'])
images.sort(key=lambda x: x['CreationDate'])
for img in images:
    print(f"{img['CreationDate'][:10]}  {img['ImageId']}  {img['Name']}")
```
