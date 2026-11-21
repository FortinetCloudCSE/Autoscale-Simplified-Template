---
title: "In-Place Upgrade"
menuTitle: "In-Place Upgrade"
weight: 62
---

## Overview

### What an in-place upgrade is

An in-place upgrade keeps everything you already run (the inspection VPC, the Gateway
Load Balancer, the Auto Scaling groups, the Lambda and the Terraform stack) and changes
only the FortiGate instances inside it. "In place" describes the stack, not the
instances: FortiOS is never upgraded on a running FortiGate. Each FortiGate is removed
and a new one, built from the new version, takes its place.

It is the right choice for a patch or minor upgrade within one major version, such as
7.6.7 to 7.6.8, on a deployment that is healthy and has at least two FortiGates.

### How it works

Three things happen, in this order:

1. **The launch templates are pointed at the new version.** A launch template is the
   recipe the Auto Scaling group uses to build a FortiGate. Once it names the AMI of the
   target version, every FortiGate launched from then on boots that version. Nothing
   that is running changes yet.
2. **The running FortiGates are replaced one at a time.** The script removes one
   FortiGate, the Auto Scaling group launches its replacement from the updated recipe,
   and the Lambda licenses and configures it. The new FortiGate then copies the rest of
   the configuration (policies, addresses, routes) from the primary. Only when it is in
   service and healthy does the script move on to the next one.
3. **Terraform is brought back in step.** The version recorded in `terraform.tfvars` is
   changed to match, so the next Terraform run does not undo the upgrade.

### Why the primary goes last

One FortiGate in the group is the primary. It holds the authoritative configuration, and
the others (secondaries) copy from it. The secondaries are replaced first, so that
before the original primary is removed there is already an upgraded FortiGate holding a
full copy of the configuration. When the primary is then removed, the Lambda promotes
one of those upgraded secondaries to primary.

This is the one moment that needs care, and the script stops and asks before it. Until
you answer, the old primary is the only place the complete configuration exists. You
check on an upgraded secondary that the configuration has arrived, and then confirm.

### What you will notice

- **Reduced capacity.** While a FortiGate is being replaced, the group has one fewer
  than normal. Plan the window so the remaining FortiGates can carry the traffic.
- **Dropped connections.** FortiGates in an autoscale group do not share session state.
  Connections passing through the FortiGate being replaced are cut and have to be
  re-established. New connections are sent to the remaining FortiGates.
- **Nothing else moves.** Routing, the Transit Gateway, the load balancer, its endpoints
  and the subnets are untouched. With NAT Gateway egress the public source addresses stay
  the same. With per-instance elastic IPs, a replaced FortiGate gets a new public
  address, as it does on any scale event.

### What it depends on

- **Old and new versions can sync configuration.** This holds within a major version. It
  does not hold across major versions (7.4 to 7.6), which is why those upgrades need a
  configuration restore or the [blue-green](../6_3_blue_green_upgrade/) strategy.
- **At least two FortiGates.** With one, there is no secondary to carry traffic or to
  hold the configuration while it is replaced.
- **A healthy group.** The script checks the group before it starts and changes nothing
  if an instance is unhealthy or the primary cannot be identified.

### Your part

You take a configuration backup first, answer the script's prompts, check the
configuration on an upgraded secondary before the primary is replaced, and update
`terraform.tfvars` afterwards. The script does the AWS work and waits at each step.

### If something goes wrong

You can stop at any prompt. The script puts the Auto Scaling group back to normal
operation on every exit, and running it again continues with the FortiGates that are
still on the old version. To go back, the Auto Scaling groups are pointed at the launch
template version they used before, which the script records, and the FortiGates are
replaced again. The backup is the fallback for the configuration.

### The three paths

The script picks one of three paths from the state of the group. **Path B**, the rolling
replacement described above, is the normal case. **Path A** and **Path C** apply only
when the group has been scaled to zero: A just updates the launch templates, and C also
brings up one FortiGate and restores a configuration backup to it. The rest of this page
is the detail of each.

{{% notice warning %}}
**Cross-major-version upgrades** (e.g., 7.4.x → 7.6.x) need a config restore: FortiGate
native config sync does not work across major versions. Use Path C, or Path B with
`--restore-config`. Same-major upgrades (e.g., 7.6.7 → 7.6.8) use Path B as it is.
{{% /notice %}}

---

## Path Selection

`inplace_upgrade.py` reads the desired capacity and instance list of both ASGs when it
starts (not from the inventory, which may be old) and selects the path:

```
BYOL desired=0 AND On-Demand desired=0, no instances?
    ├─ YES, and a .conf backup is present in state/ → Path C
    ├─ YES, no .conf backup                         → Path A
    └─ NO  (instances running)                      → Path B
```

| Path | Condition | Downtime | Use When |
|------|-----------|----------|---------|
| **A** | desired=0, no backup | None — no instances | ASG is already scaled to zero |
| **B** | instances running | Capacity is one instance short during each replacement; connections through the instance being replaced are dropped | Same-major-version, healthy deployment with two or more instances |
| **C** | desired=0 + backup | Yes — ASG starts at zero, scales up | Cross-major-version or any desired=0 upgrade with config restore |

---

## Before You Start

These apply to every path that touches running instances.

1. **Read the release notes of the target version**, including Special notices, Known
   issues and the FortiGate-VM upgrade notes.
2. **Confirm the target AMI is published in the deployment's region.** Discovery does
   this and stops if it is not.
3. **Check the group has two or more healthy instances.** With one instance, replacing
   it is an outage, and configuration held only on that FortiGate is lost. Raise the
   desired capacity to 2 and wait for the second instance to sync first. The script
   refuses to roll a single-instance group unless `--allow-single-instance` is given.
4. **Back up the primary's configuration** (**System → Settings → Backup**) and save it
   under `upgrade_fortios/backups/`. Do not save it under `state/` unless you intend
   Path C: a `.conf` file there selects Path C the next time the ASGs are at zero.
5. **Record a baseline on the primary:** `get system status`, `get system auto-scale`,
   the number of firewall policies, and the GWLB target health.

The launch template version each ASG used before the upgrade is the rollback target. The
script prints it and saves it to `state/inplace_rollback.json` when it changes it.

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
  --target-version 7.6.8 \
  --output state/blue_inventory.json

# Step 2: Upgrade
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

The script detects `desired=0`, updates launch templates, and exits. When the ASG is
later scaled up (manually or by CloudWatch alarms), new instances launch with the
target FortiOS version. Then [reconcile Terraform](#after-the-upgrade-reconcile-terraform).

---

## Path B — Rolling Replacement

**Condition:** One or more instances are running.

```
Phase 0: Discovery    — Read state, detect architecture
         Pre-flight   — Live checks; nothing is changed if any of them fails
Phase 1: Backup       — Operator exports the primary's config
Phase 2: Update LTs   — Target AMI on the launch templates of both ASGs
Phase 3: Rolling      — Replace secondaries one at a time, in both ASGs
                        Replace the primary last, after the operator confirms
                        Lambda promotes one of the upgraded secondaries
Phase 4: Verify       — All instances on the target AMI, GWLB healthy, one primary,
                        ASG launches the target AMI, no ASG process left suspended
Phase 5: Restore      — Only with --restore-config (cross-major upgrades)
```

### Pre-flight Checks

Before the first prompt the script checks the live group. If any check fails it lists
what is wrong and exits without changing anything.

| Check | Why |
|-------|-----|
| Every instance in both ASGs is `InService` | A launch or terminate already in progress would be mistaken for the script's own |
| Every GWLB target is healthy | The roll takes one instance out at a time; it must not start one short |
| Exactly one instance is the primary | The primary must be replaced last |
| Two or more instances | See [Before You Start](#before-you-start) |

The primary is the instance tagged `Autoscale Role: Primary`. If no instance carries the
tag, the script falls back to scale-in protection, and only when exactly one instance
has it (`primary_scalein_protection = true`).

### Replacement Sequence

For a 2-instance deployment (1 primary, 1 secondary):

```
Start:   [Primary 7.6.7] [Secondary 7.6.7]   ← both in service, config synced

Step 1:  Terminate secondary
         [Primary 7.6.7] [Secondary TERMINATED]      ← primary carries all traffic

Step 2:  ASG launches replacement
         [Primary 7.6.7] [New Secondary 7.6.8 — initializing]

Step 3:  Wait: InService + GWLB healthy + Autoscale Role: Secondary tag
         [Primary 7.6.7] [New Secondary 7.6.8 — in service]

Step 4:  Operator checks the config on the new secondary, then confirms
         [Primary TERMINATED] [New Secondary 7.6.8 — carries all traffic]

Step 5:  Lambda promotes the surviving instance
         [New Primary 7.6.8] [slot vacant]

Step 6:  ASG launches replacement for vacated slot
         [New Primary 7.6.8] [New Secondary 7.6.8 — initializing]

Step 7:  Wait: InService + GWLB healthy + Autoscale Role: Secondary tag
         [New Primary 7.6.8] [New Secondary 7.6.8 — in service]

Done:    Both instances on 7.6.8
```

For deployments with more secondaries, Steps 1–3 repeat for each one before the primary
is touched. Each replacement is identified by its new instance ID, and the next instance
is not terminated until that replacement has passed the checks below. Secondaries in the
On-Demand ASG are replaced the same way, from the On-Demand launch template.

Instances already on the target AMI are skipped. A run that was stopped part-way can be
started again and continues with the instances that are left.

### Traffic Impact

The roll is not hitless.

- **Capacity:** each replacement terminates the old instance before the ASG launches the
  new one, so the group runs one instance short until the replacement is in service.
  Size the maintenance window for the remaining instances to carry the load.
- **Existing connections:** autoscale members do not share session state. Connections
  that were flowing through the instance being replaced are dropped and must be
  re-established by the client. New connections go to the remaining healthy targets.

### Replacement Readiness Checks

After a replacement launches, the script waits for:

1. **ASG `InService`** on the target AMI. This means the launch lifecycle hook has
   completed, which happens once the Lambda has attached the extra network interfaces.
   The instance is not yet licensed or configured at this point.
2. **GWLB healthy.** The FortiGate is answering the target group's health check.
3. **`Autoscale Role: Secondary` tag.** The Lambda has generated the instance's
   bootstrap configuration and sent it.

{{% notice warning %}}
None of these shows that config sync from the primary has finished. The Lambda writes
the Secondary tag when it generates the bootstrap configuration, and the FortiGate then
pulls the rest of the configuration from the primary on its own. The script cannot see
that step, so it is checked by the operator at the primary gate.
{{% /notice %}}

### The Primary Gate

Before it terminates the primary, the script lists the instances that will stay in
service and asks for confirmation. Until you answer, the old primary holds the only
complete copy of the running configuration. On one of the upgraded secondaries, check:

```
get system status                         # target version and build, licence valid
get system auto-scale                     # role secondary, primary-ip is the primary
show firewall policy | grep -c "edit "    # same count as the baseline on the primary
```

Compare anything else that only exists in the running configuration (addresses, routes,
VPNs). If the configuration has not arrived, answer **N**. The script resumes the ASG
processes and exits; nothing has been lost, because the primary is untouched.

### ASG Process Suspension

During rolling replacement, the script suspends three processes on both ASGs:

| Process | Why Suspended |
|---------|--------------|
| `ReplaceUnhealthy` | Prevents ASG from replacing instances the script is managing |
| `AZRebalance` | Prevents unwanted launches/terminates for AZ balance |
| `ScheduledActions` | Prevents scheduled scaling changes during upgrade |

They are resumed when the roll finishes, when it fails, when the operator answers **N**
at a prompt, and on Ctrl-C. Phase 4 checks that none is left suspended.

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

### Running Path B

```bash
cd upgrade_fortios
bash state/refresh.sh

# Step 1: Discovery (sets target AMI in inventory)
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.8 \
  --output state/blue_inventory.json

# Step 2: Upgrade
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json
```

`./upgrade --in-place --fortios-version 7.6.8` runs the same three steps in order.

The script pauses at each gate and prompts for confirmation before proceeding. When it
finishes, [reconcile Terraform](#after-the-upgrade-reconcile-terraform).

### Config Restore After the Roll (Cross-Major Only)

For a cross-major upgrade the new secondaries cannot sync from the old primary, so the
new primary ends up without the running configuration. Pass the backup explicitly to
have it restored once every instance has been replaced:

```bash
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --restore-config backups/primary.conf \
  --fgt-api-key <api-key>   # optional — otherwise the script prompts for a GUI restore
```

The restore reboots the new primary. It never happens unless `--restore-config` is
given; a `.conf` file lying in `state/` is reported and ignored.

The script reaches the new primary's management interface on HTTPS port 443, the FortiOS
default and what these templates deploy. If the admin HTTPS port has been changed
(`set admin-sport` under `config system global`), add `--fgt-mgmt-port <port>`. It sets
the port for the REST API call and for the GUI address the script prints for a manual
restore. The same option applies to the Path C restore.

---

## Path C — Restore Config to Fresh Instance

**Condition:** `desired=0` on both ASGs AND a `.conf` backup file is present in the
`state/` directory.

Path C is used for:
- Cross-major-version upgrades where config sync will not work
- Any upgrade where the operator wants to start from a clean instance with a known-good config

```
Phase 0: Discovery    — Read state, detect architecture, detect Path C
Phase 1: Update LTs   — New launch template version with target AMI on both ASGs
Phase 2: Launch       — Set BYOL ASG min=1, desired=1; wait for instance running,
                        GWLB healthy, and Autoscale Role: Primary tag
Phase 3: Config       — Restore the backup to the new primary
                        (via FortiGate REST API if --fgt-api-key provided,
                         otherwise operator restores via GUI and confirms)
Phase 4: Wait         — Poll until primary recovers from reboot after restore
Phase 5: Scale out    — Set BYOL ASG to min=2, desired=2 (or its max, if lower)
                        Secondary launches; Lambda licenses and configures it
```

### Step-by-Step Procedure

#### Step 1: Back Up Primary Config

{{% notice warning %}}
Do this **before** scaling to zero. Once the instances terminate, the running
configuration is gone.
{{% /notice %}}

1. Log in to the primary FortiGate GUI
2. **System → Settings → Backup → Full Configuration**
3. Save the file to `upgrade_fortios/state/blue_primary_config.conf`

#### Step 2: Scale the ASGs to Zero

Lower the minimum and desired capacity. Leave the maximum as it is: the script scales
back up within it and stops if it finds a maximum of zero.

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <byol_asg_name> \
  --min-size 0 \
  --desired-capacity 0
```

Do the same for the On-Demand ASG if it has instances. Wait for all instances to
terminate.

#### Step 3: Run the Script

```bash
cd upgrade_fortios
bash state/refresh.sh

# Step 3a: Discovery (sets target AMI in inventory)
python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --target-version 7.6.8 \
  --output state/blue_inventory.json

# Step 3b: Upgrade (detects Path C from desired=0 + backup file)
python3 scripts/inplace_upgrade.py \
  --inventory state/blue_inventory.json \
  --fgt-api-key <api-key>   # optional — enables automated config restore
```

With `--fgt-api-key`, the script posts the config backup to the FortiGate REST API:

```
POST /api/v2/monitor/system/config/restore
```

The request goes to the primary's management address on HTTPS port 443. Add
`--fgt-mgmt-port <port>` if the FortiGate's admin HTTPS port has been changed.

Without `--fgt-api-key`, or if the API call fails, the script pauses at Phase 3 and prompts the
operator to restore the config manually via the FortiGate GUI:

**System → Settings → Restore → Upload `blue_primary_config.conf`**

After confirming the restore, the FortiGate reboots and the script resumes polling.

#### Step 4: Verify

After scale-out completes, verify:
- Both instances are GWLB healthy
- Primary is tagged `Autoscale Role: Primary`
- Secondary is tagged `Autoscale Role: Secondary`
- FortiGate GUI shows the target FortiOS version and the expected configuration

Then remove the `.conf` file from `state/` and
[reconcile Terraform](#after-the-upgrade-reconcile-terraform).

---

## After the Upgrade: Reconcile Terraform

The launch template belongs to Terraform. The Fortinet module looks the AMI up from
`fortios_version` in `terraform.tfvars`, so after the scripts have changed the launch
template, Terraform still describes the old version.

1. Set `fortios_version` to the new version in
   `terraform/autoscale_template/terraform.tfvars`.
2. Run `terraform plan` and read it before applying anything. The launch template should
   show no change of AMI.

{{% notice warning %}}
Do not skip this. AWS Marketplace deprecates the AMIs of older FortiOS versions, and the
module's AMI lookup does not return deprecated images, so a `terraform plan` that still
names the old version fails with "Your query returned no results". Where the old AMI is
still listed, the next `terraform apply` puts the launch template back on the old
version, and every instance launched after that comes up on it.
{{% /notice %}}

The plan also compares `asg_*_desired_size` with the live group. If the group was scaled
by hand or by an alarm, an apply sets the desired capacity back to the tfvars value.

The same change can be made the other way round: set `fortios_version`, apply, then run
the scripts. `inplace_upgrade.py` finds the target AMI already on the newest launch
template version and reuses it instead of creating another.

---

## Target AMI Selection

Discovery reads the AMI the launch template uses today and takes two things from it: the
architecture and the AWS Marketplace product code.

| AMI Name Contains | Architecture |
|-------------------|-------------|
| `VMARM64-AWS` | ARM64 (BYOL) |
| `VM64-AWS` | x86 (BYOL) |
| `VMARM64-AWSONDEMAND` | ARM64 (On-Demand) |
| `VM64-AWSONDEMAND` | x86 (On-Demand) |

The target AMI is then searched among images owned by AWS Marketplace, with the same
product code, whose name contains the target version. A name match alone is not accepted,
because anyone can publish a public AMI with a FortiGate-looking name. If no AMI is found
for a launch template, discovery stops with an error.

---

## What the Lambda Does During Replacement

When the ASG launches an instance:

1. The instance enters `Pending:Wait`. On `EC2 Instance-launch Lifecycle Action` the
   Lambda creates and attaches the additional network interfaces and completes the
   lifecycle action. The instance moves to `InService`.
2. On `EC2 Instance Launch Successful` the Lambda:
   - Sets the admin password and adds the instance to DynamoDB
   - Assigns a licence (BYOL file or FortiFlex token)
   - Generates the bootstrap configuration: GENEVE tunnels, the `config system
     auto-scale` settings (role and, for a secondary, the primary's IP) and the user
     configuration from the Terraform template
   - Tags the instance `Autoscale Role: Secondary` (or `Primary` if there is none)
   - Sends that configuration to the FortiGate
3. The FortiGate, now a secondary, syncs the rest of the configuration from the primary
   itself. The Lambda does not copy the primary's configuration.

When an instance is terminated (`EC2 Instance-terminate Lifecycle Action`), the Lambda:

1. Releases its licence and removes it from DynamoDB
2. If it was the primary, promotes the first running instance in its list: sets
   `config system auto-scale` role to primary on it, tags it `Autoscale Role: Primary`,
   sets scale-in protection if `primary_scalein_protection` is true, and points the
   remaining secondaries at the new primary

---

## Rollback

The rollback target is the launch template **version** each ASG used before the upgrade,
recorded in `state/inplace_rollback.json` and printed in Phase 2. Use the version number,
not a new search for the old FortiOS version: the old AMI may be deprecated and hidden
from searches while still being launchable from the launch template version that names it.

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg_name> \
  --launch-template LaunchTemplateId=<lt_id>,Version=<previous_version>
```

### Path A
Point both ASGs back at the previous version. No instances were affected.

### Path B
If replacement fails mid-rolling:

1. Check that the ASG processes were resumed (`ReplaceUnhealthy`, `AZRebalance`,
   `ScheduledActions`); the script resumes them on every exit
2. Assess current instance state — determine which instances are on old vs new AMI
3. If an instance is stuck: terminate it; the ASG will launch a replacement using
   the current launch template version
4. To go forward, run the script again: it skips instances already on the target AMI
5. To revert to the previous FortiOS version entirely: point both ASGs back at the
   previous version and replace the instances again, secondaries first

A configuration that has run on the newer version is a downgrade for the older one. If
the old version does not accept it, restore the backup taken before the upgrade.

### Path C
If the upgrade fails after config restore and the instance is unrecoverable:

1. Terminate the failed instance
2. Point the ASGs back at the previous launch template version
3. Scale ASG to `min=1, desired=1`
4. Restore the config backup to the new instance
5. Scale out to full capacity

---

## Monitoring Lambda During Upgrade

Tail Lambda logs in a separate terminal while the upgrade runs:

```bash
bash upgrade_fortios/scripts/watch_lambda.sh
```

The function name and region are read from `state/blue_inventory.json`, so run discovery
first. It follows the BYOL ASG's handler by default; pass another function name (for
example the On-Demand ASG's handler) as the first argument.

---

## Verified

- `python3 upgrade_fortios/tests/test_inplace_upgrade.py` runs the pre-flight, the launch
  template update and the rolling replacement against a simulated ASG and Lambda: groups
  of one, two and three instances, a hybrid BYOL and On-Demand group, an abort at the
  primary prompt, a failure mid-roll, and a second run after an abort. It also covers the
  AMI lookup filters, primary detection and region detection in `discover.py`, expired
  credentials, interrupted runs and the FortiFlex serial check.
- A rolling replacement has been run once against a live group: two BYOL instances
  licensed with FortiFlex, 7.6.7 to 7.6.8. Discovery, the pre-flight, the launch template
  update, the secondary replacement, the primary gate and the Lambda's promotion of the
  new primary completed, and both instances ended on the target AMI, healthy in the GWLB,
  with one primary. The operator's AWS credentials expired during the last wait, so the
  final checks were run afterwards and not by that run.

## Not Covered

- Pausing on expired credentials, and finishing an interrupted run by running the command
  again, have only been run against the simulator.
- A rolling replacement of a FortiFlex group whose serials were all distinct at the start
  has not been observed live. Both test builds came up with two instances on one serial.
- Config sync between a secondary on the target patch version and a primary on the
  previous one (for example 7.6.8 from 7.6.7) has not been tested here. The primary gate
  exists so the operator confirms it on the FortiGate.
- The REST API config restore (`--fgt-api-key`) has not been tested against a live
  FortiGate.
