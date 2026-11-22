---
title: "Blue-Green Upgrade"
menuTitle: "Blue-Green Upgrade"
weight: 63
---

## Overview

### What a blue-green upgrade is

A blue-green upgrade builds a second, complete inspection stack next to the one in
production and then moves traffic from the old one to the new one. The existing stack is
called **Blue**. The new one, **Green**, has its own inspection VPC, Gateway Load
Balancer, Auto Scaling groups, Lambda and FortiGates, already on the target FortiOS
version. Nothing in Blue is changed while Green is built and checked, and Blue is kept
after the switch until you decide to remove it.

### Why you would choose it

- **It works across major versions.** An [in-place upgrade](../6_2_in_place_upgrade/)
  relies on new FortiGates copying their configuration from old ones, and FortiGates on
  different major versions (7.4 and 7.6) cannot do that. In blue-green, Green's
  FortiGates never talk to Blue's. The configuration moves as a backup file, taken from
  Blue's primary and restored to Green's primary. That restore is itself a version
  conversion, so it only works where Fortinet supports going from the old version to
  the new one in a single step. See [Check the upgrade path first](#check-the-upgrade-path-first).
- **The old environment stays intact.** If Green misbehaves after the switch, one
  command sends traffic back to Blue.
- **Green is deployed fresh.** Problems in the existing stack, such as broken alarms or
  licensing state, are not carried over.

The price is that two stacks run at the same time: roughly twice the licences and AWS
resources for a day or two, and more preparation than an in-place upgrade.

### How it works

The six phases on this page fall into five stages:

1. **Prepare (Phases 0 and 1).** [Discovery](../6_4_discovery/) records what Blue
   consists of, and the configuration of Blue's primary FortiGate is backed up.
2. **Build and check (Phases 2 and 3).** Terraform deploys Green with the same address
   ranges as Blue. The backup is restored to Green's primary, and Green is validated.
   Blue carries all traffic throughout; Green is connected to the Transit Gateway but no
   route points at it.
3. **Switch (Phase 4).** The cutover script changes the Transit Gateway routes of the
   spoke VPCs so they point at Green instead of Blue. This takes under 30 seconds. With
   NAT Gateway egress, it then moves Blue's public IP addresses to Green, so the source
   addresses the outside world sees do not change.
4. **Watch (Phase 5).** Green carries production traffic for 24 to 48 hours. Blue is
   idle but complete, and is the fallback.
5. **Remove Blue (Phase 6).** Once you are satisfied, Blue is destroyed. This is the
   only step that cannot be undone.

### Why Green uses the same addresses

A FortiGate configuration contains the subnet addresses of the VPC it runs in. Because
Green uses the same address ranges as Blue, almost all of the backup restores without
editing. The exception is the Gateway Load Balancer's own addresses, which AWS picks for
each load balancer: a script swaps Blue's for Green's before the restore (see
[Prepare the backup for Green](#prepare-the-backup-for-green)). The two VPCs are not
connected to each other, so the overlap causes no conflict.
[Why the Same CIDR](#why-the-same-cidr) has the detail.

### What you will notice

- **Before the switch:** nothing. Blue is not touched.
- **At the switch:** connections in progress are interrupted once and re-established
  through Green. New connections go to Green at once.
- **With NAT Gateway egress:** for the two to three minutes the public addresses take to
  move, outbound traffic may leave from temporary addresses.
- **In FortiManager:** Green's FortiGates have new serial numbers and must be authorized.

### Your part

You prepare Green's Terraform variables to match Blue, take and restore the backup, work
through the checklists before and after deploying Green, choose the moment for the
switch, and give the sign-off before Blue is removed. Every phase ends with a gate that
waits for you.

### Backing out

| When | How |
|------|-----|
| Before the switch | Nothing to undo. Fix or destroy Green; Blue was never changed |
| After the switch, until Blue is removed | Run `rollback.py`. Traffic returns to Blue in under a minute |
| After Blue is removed | Not possible |

---

## Architecture

### Blue Environment (Existing)

```
Spoke VPCs (East, West, ...)
        │
        ▼
Transit Gateway
        │  TGW route tables → Blue inspection VPC attachment
        ▼
Blue Inspection VPC  (10.0.0.0/16)
    ├── GWLB + Target Group
    ├── FortiGate ASG (BYOL + On-Demand)
    ├── DynamoDB (instance tracking)
    └── Lambda (lifecycle management)
```

### Green Environment (New — deployed in parallel)

```
Transit Gateway
        │  TGW attachment created but routes NOT switched yet
        ▼
Green Inspection VPC  (10.0.0.0/16)  ← SAME CIDR as Blue
    ├── GWLB + Target Group  (new)
    ├── FortiGate ASG (new FortiOS AMI, corrected config)
    ├── DynamoDB (clean state)
    └── Lambda (current version)
```

Green also gets its own Transit Gateway route table. Terraform fills it with the return
routes to the spoke and management VPCs, and gives Green's GWLB endpoint subnets the same
RFC1918 routes to the Transit Gateway that Blue's have. Green can therefore forward and
return traffic as soon as the spoke routes are flipped; the cutover itself only changes
the spoke route tables.

### After Cutover

```
Spoke VPCs
        │
        ▼
Transit Gateway
        │  TGW route tables → Green inspection VPC attachment
        ▼
Green Inspection VPC  (traffic flows here)

Blue Inspection VPC  (suspended — no new instances, kept as rollback target)
```

---

## Why the Same CIDR

Green uses the **same CIDR blocks** as the Blue inspection VPC. This is a deliberate
design choice, not a limitation.

FortiGate configurations contain hard-coded references to inspection VPC CIDRs:
- `vdom-exceptions` — reference management interface subnet CIDRs
- `router static` — one east-west inspection route per spoke CIDR in `spoke_cidrs`
  (defaults to `[vpc_cidr_east, vpc_cidr_west]`), rendered as literal `set dst`
  values via each geneve interface — more entries than before, but the same
  "hard-coded at render time" property applies
- `system interface` — IP addresses derived from subnet assignments
- `firewall address` — objects may reference internal subnets

If Green used different CIDRs, every CIDR reference in the exported Blue config would need
manual editing before restore. Identical CIDRs mean those references restore to Green
unchanged.

The same CIDR does not make the GWLB's addresses the same. AWS assigns each load
balancer its own interface address in each subnet, and the configuration uses them as the
GENEVE tunnel peers (`config system geneve` → `set remote-ip`) and in a /32 static route
to each. `prepare_green_config.py` replaces those, and only those, in a copy of the backup.
See [Prepare the backup for Green](#prepare-the-backup-for-green).

Blue and Green are fully isolated VPCs with no peering between them — having the same CIDR
causes no routing conflict while they coexist.

---

## Check the Upgrade Path First

A blue-green upgrade does not upgrade a FortiGate. It takes a configuration backup on the
version Blue runs and restores it on Green FortiGates that already run the target
version. FortiOS converts the older backup when it is restored, in one step.

Fortinet tests upgrades step by step along a supported upgrade path. When that path has
intermediate versions between Blue's version and the target, a blue-green upgrade skips
them, and the restore can lose or corrupt configuration. Fortinet's own position is
narrower still: restoring a backup is officially supported on the same model and the same
firmware version, and a backup from an older version is converted automatically but
should be checked afterwards.

Before a blue-green upgrade that crosses a minor or major version (7.4 to 7.6, or 7.6 to
8.0):

1. Open the [Upgrade Path Tool](https://docs.fortinet.com/upgrade-tool/fortigate). Select the FortiGate-VM AWS
   model, the version Blue is running and the target version.
2. Continue only if the recommended path is a **single step** from one to the other.
   If the tool lists intermediate versions, upgrade to the last intermediate version
   first — in place, or with a blue-green upgrade per step — and start again from there.
3. Read "Upgrade information" and the special notices in the target version's release
   notes. Some versions must not be skipped even within one minor version.

The tool gives the recommended path and is updated from time to time, so check it close
to the upgrade, not weeks before.

The scripts enforce this. `discover.py` compares the version Blue's primary is running
with `--target-version`. For a blue-green discovery (`--vpc-state`) that crosses a minor
or major version it stops with an error and writes no inventory until it is run with
`--upgrade-path-verified`, which is your statement that step 2 holds. `cutover.py` checks
the same thing again before it moves any traffic, and refuses an inventory that does not
carry the confirmation. A downgrade is always refused: Fortinet supports no downgrade
paths, and a newer backup cannot be restored on older firmware.

A patch upgrade within one minor version (7.6.7 to 7.6.8) is not stopped, but discovery
prints the link as a reminder. An [in-place upgrade](../6_2_in_place_upgrade/) that
restores a configuration backup is held to the same rule.

{{% notice warning %}}
`--upgrade-path-verified` records that you checked; it does not check anything itself.
The restore onto Green is still the real test. Compare Green's configuration with Blue's
during Phase 3 before cutting over. Blue is untouched until then, so a restore that goes
wrong costs only Green.
{{% /notice %}}

---

## Automated Run (Phases 0–3)

`upgrade_fortios/scripts/blue_green.py` runs Phases 0 to 3 on this page in one go, from a
Blue deployed out of this checkout (`terraform/autoscale_template` and
`terraform/existing_vpc_resources`, each with its `terraform.tfstate`). It stops before
the cutover. **It never runs `cutover.py`**: moving production traffic is always a
step you take yourself, and the script ends by printing the commands.

```bash
cd upgrade_fortios
./upgrade --blue-green --fortios-version 8.0.2 --upgrade-path-verified
```

Pass `--upgrade-path-verified` only after the [upgrade path check](#check-the-upgrade-path-first).
The script asks before it writes Green's `terraform.tfvars`, before `terraform apply`,
and before the restore. `--yes` answers those three; there is no option that runs the
cutover.

| Step | What it does |
|------|--------------|
| `preflight` | Checks that Blue's state has an Auto Scaling group, that `terraform` is installed and that the FortiGate admin password is available |
| `discover` | Runs `state/refresh.sh` and `discover.py`; shows where each spoke's default route points and asks to continue if any does not point at Blue |
| `backup` | Logs in to Blue's primary over the REST API and saves `state/blue_primary_config.conf`; stops if the backup's version is not the version Blue runs |
| `tfvars` | Writes `terraform/green_inspection_stack/terraform.tfvars` from Blue's (see below), shows the diff with passwords hidden, keeps the old file as `terraform.tfvars.bak-<time>` |
| `deploy` | `terraform init`, `plan` and `apply` in `green_inspection_stack`; copies the state to `state/green.tfstate` |
| `wait` | Waits for Green's primary to be InService, healthy behind Green's GWLB, and answering a REST login |
| `prepare` | Runs `prepare_green_config.py`: `state/green_primary_config.conf` with Green's GWLB addresses |
| `restore` | Uploads that file to Green's primary; the FortiGate reboots |
| `verify` | Waits for it to come back, then checks that its GENEVE peers are Green's GWLB addresses |

**Green's `terraform.tfvars`** takes every value Green's `variables.tf` declares from
Blue's file, except:

- `asg_module_prefix` and `stack_label`: `green` (`--green-prefix` to change it), and
  `endpoint_name_az1` / `endpoint_name_az2` follow the prefix
- `fortios_version`: the target version
- `access_internet_mode`: `egress_mode` from the inventory, which is the mode Blue's
  inspection VPC actually uses
- with FortiFlex, `asg_byol_asg_min_size` and `asg_byol_asg_desired_size` are set to 1
  (instances that launch together can be given the same serial). Raise them to Blue's
  values once the FortiGate shows License Status: Valid

Values Green declares but Blue's file does not set are kept from the current Green file,
if there is one.

**FortiGate access.** The script logs in as `admin` with `fortigate_asg_password` from
Blue's `terraform.tfvars`, or `FGT_PASSWORD` from the environment when set. A new Green
FortiGate has no API key, so a session login is the only way in without the GUI. It
connects to the public address of each primary's management interface; with
`--use-private-ip` it uses the private address instead, for access over VPN, Direct
Connect or a jump host. `--blue-mgmt-ip` and `--green-mgmt-ip` give the addresses
directly.

**Resuming.** Progress is kept in `state/bluegreen_progress.json`. When a step stops, the
script names the step to resume from, for example `--start-at restore`.

After it finishes, do Phase 3's checks that need a person (policies on Green, license
status), then Phase 4.

---

## Phase 0 — Discovery

**Goal:** Produce a complete inventory of the Blue environment.

**Duration:** ~30 minutes  
**Traffic impact:** None (read-only)

```bash
cd upgrade_fortios
bash state/refresh.sh

python3 scripts/discover.py \
  --state state/autoscale_template.tfstate \
  --vpc-state state/existing_vpc_resources.tfstate \
  --target-version 7.6.2 \
  --output state/blue_inventory.json
```

If the upgrade crosses a minor or major version, this stops with an error. Do the
[upgrade path check](#check-the-upgrade-path-first), then add `--upgrade-path-verified`.

Review the output before proceeding:

```bash
python3 -m json.tool state/blue_inventory.json | less
```

**Gate:** Operator reviews inventory and confirms all resources are identified correctly.
Note the key values you will need for Green `terraform.tfvars`: `inspection_vpc.cidr_block`,
`egress_mode`, `autoscale_groups.byol.desired/min/max`, AZs, and TGW name.

`egress_mode` is `nat_gw` when the Blue inspection VPC has NAT gateways and `eip` when it
does not. The NAT gateways belong to `existing_vpc_resources`, so they are only found when
`--vpc-state` is given. Use this value for Green's `access_internet_mode`, even if
`access_internet_mode` in Blue's `autoscale_template` says otherwise: a Blue inspection
VPC built with NAT gateway subnets sends FortiGate traffic through them whatever the
FortiGate setting is, and only the matching mode gives Green the same subnet CIDRs as Blue.

See [Discovery](../6_4_discovery/) for details on the inventory schema.

---

## Phase 1 — Backup

**Goal:** Export the primary FortiGate configuration before any changes.

**Duration:** 30–60 minutes  
**Traffic impact:** None

{{% notice warning %}}
Do not skip this phase. Green's FortiGates start with the template's bootstrap
configuration only. Everything configured on Blue since it was deployed reaches Green
through this backup and no other way. Cut over without it and traffic moves to FortiGates
that are missing those policies, addresses and routes.
{{% /notice %}}

1. Identify the primary FortiGate instance — it has `ProtectedFromScaleIn: true` in the
   Blue ASG. The `blue_inventory.json` shows the primary instance ID.
2. Log in to the primary FortiGate GUI
3. **System → Settings → Backup → Full Configuration**. Do not encrypt the backup: the
   scripts read its first line to check which FortiOS version it was taken on.
4. Save to `upgrade_fortios/state/blue_primary_config.conf`, replacing any file of that
   name left from an earlier upgrade
5. Confirm the file is the backup you just took:

   ```bash
   head -1 state/blue_primary_config.conf
   ```

   The line begins `#config-version=` and names the version Blue is running, for example
   `#config-version=FGAAWS-7.6.8-FW-build3744-...`.

**Gate:** The backup file is present and its first line names Blue's running version.

`cutover.py` enforces this gate. It stops, before it moves any traffic, when
`state/blue_primary_config.conf` is missing, cannot be read, or was taken on a FortiOS
version other than the one Blue runs. See [Phase 4](#the-backup-check).

### Backup From the Command Line

The backup can be copied with SCP instead of the GUI. SCP is disabled on a FortiGate by
default, so enable it on the primary first:

```
config system global
    set admin-scp enable
end
```

Then, from `upgrade_fortios/`:

```bash
scp -O admin@<primary-management-ip>:sys_config state/blue_primary_config.conf
```

`-O` selects the legacy SCP protocol, which FortiOS requires and current OpenSSH clients
no longer use by default. The administrator account needs read-write access to System
settings.

{{% notice note %}}
`501-Permission Denied` from this command means SCP is still disabled on the FortiGate.
Check with `show full-configuration system global | grep admin-scp`. It is not a reason to
go on without a backup: take it from the GUI.
{{% /notice %}}

### What the Config Backup Contains

| Included | Not Included |
|----------|-------------|
| Security policies (firewall rules) | Interface IP assignments (re-assigned by bootstrap) |
| Address objects and groups | Autoscale-specific dynamic config (pushed by Lambda) |
| Routing customizations | License state (handled by Green's clean licensing) |
| FortiManager connection settings | Session tables (stateful sessions interrupted at cutover — expected) |
| VPN configurations | |
| Custom logging/reporting | |

---

## Pre-Deployment Checklist

Complete this checklist before Phase 2. All items must be confirmed before deploying Green.

**Licensing**
- [ ] Enough licenses available for 2× capacity — Blue and Green run simultaneously during the monitoring window
- [ ] For BYOL: S3 license bucket has sufficient `.lic` files for Green instances
- [ ] For FortiFlex: token pool has capacity for Green desired count
- [ ] For FortiFlex: Green's `fortiflex_sn_list` contains **only serials Blue is not using** — Green has its own Lambda and serial pool, and a serial listed in both stacks can be issued to a Blue and a Green FortiGate at the same time
- [ ] For PAYG: no license action needed

**Capacity**
- [ ] AWS account service limits allow the additional EC2 instances, EIPs, and NAT Gateways
- [ ] NAT Gateway quota allows 2 additional NAT GWs per AZ (Green creates its own temp NAT GWs)
- [ ] Elastic IP quota has room for Green while Blue is still running. Count one per
  Green NAT gateway (`nat_gw` mode), one per Green FortiGate for its dedicated management
  interface, and one more per Green FortiGate in `eip` mode. Compare with what is in use:

  ```bash
  aws ec2 describe-addresses --query 'length(Addresses)'
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value'
  ```

  Terraform does not report a shortfall. The NAT gateway addresses are allocated by
  Terraform, but each FortiGate's addresses are allocated by the autoscale Lambda when the
  instance launches. At the limit the Lambda logs `AddressLimitExceeded` and the FortiGate
  comes up with no public address on that interface, reachable only from inside the
  management VPC.

**Credentials and Access**
- [ ] AWS credentials have IAM permissions to create VPC, subnets, NAT GWs, TGW attachments, ASG, GWLB, Lambda, DynamoDB
- [ ] FortiGate API key ready for the Green primary (needed for config restore)
- [ ] FortiManager access available to re-authorize Green serial numbers (if FortiManager is enabled)

**Upgrade Path**
- [ ] Fortinet's Upgrade Path Tool gives a single-step path from Blue's running version to the target version
- [ ] Target version's release notes read for upgrade information and special notices

**Config and State**
- [ ] Phase 0 (Discovery) complete — `state/blue_inventory.json` exists and reviewed
- [ ] Phase 1 (Backup) complete — `state/blue_primary_config.conf` exists and readable
- [ ] Green `terraform.tfvars` prepared — `fortios_version` set, all required fields populated
- [ ] `vpc_cidr_inspection` in Green tfvars **matches Blue exactly** (required for config restore)
- [ ] `access_internet_mode` in Green tfvars matches `egress_mode` in `blue_inventory.json`
- [ ] `asg_module_prefix` set to `"green"` (avoids resource name collisions with Blue)
- [ ] `vpc_cidr_sg` in Green tfvars is the same list as Blue's — it is the only thing allowed to reach the Green FortiGates' management interfaces, and `terraform plan` stops if it is empty
- [ ] `asg_license_directory` points to a valid directory (create empty `asg_license/` for FortiFlex/PAYG)

**FortiManager (if enabled)**
- [ ] FortiManager version 7.6.3+ has `fgfm-allow-vm enable` configured
- [ ] Operator prepared to authorize new Green serial numbers in FortiManager after config restore

---

## Phase 2 — Deploy Green

**Goal:** Deploy a correctly configured FortiGate ASG in a new inspection VPC.

**Duration:** 30–60 minutes  
**Traffic impact:** None — TGW routes unchanged, Blue still handles all traffic

### Prepare Green tfvars

The Green deployment uses a dedicated Terraform module at `terraform/green_inspection_stack/`.
Start from the provided example:

```bash
cd terraform/green_inspection_stack
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the required fields. Values should match your Blue
deployment — the `blue_inventory.json` provides a reference for all discovered parameters:

```hcl
# ── Required manual inputs ─────────────────────────────
fortios_version        = "7.6.2"      # Target FortiOS version
fortigate_asg_password = "..."        # FortiGate admin password
keypair                = "my-keypair" # EC2 key pair name

# ── Must match Blue exactly ───────────────────────────
cp                   = "acme"
env                  = "test"
aws_region           = "us-west-2"
availability_zone_1  = "a"
availability_zone_2  = "c"
vpc_cidr_inspection  = "10.0.0.0/16"   # MUST match Blue
subnet_bits          = 8               # MUST match Blue
firewall_policy_mode = "2-arm"         # MUST match Blue
access_internet_mode = "nat_gw"        # MUST match egress_mode in blue_inventory.json

# ── Green-specific ─────────────────────────────────────
asg_module_prefix    = "green"         # REQUIRED: different from Blue

# ── Capacity ───────────────────────────────────────────
# With FortiFlex start at one instance: two instances that launch together can be
# issued the same serial. Raise min/desired to Blue's values once the first FortiGate
# shows License Status: Valid.
asg_byol_asg_min_size     = 1
asg_byol_asg_max_size     = 2
asg_byol_asg_desired_size = 1

# On-demand (PAYG) burst ASG: max 0 means none is created, as in autoscale_template.
# Match Blue's values.
asg_ondemand_asg_min_size     = 0
asg_ondemand_asg_max_size     = 0
asg_ondemand_asg_desired_size = 0

# ── Licensing ──────────────────────────────────────────
# asg_license_directory MUST point to a directory, even if empty.
# Setting it to "" causes the module to scan the current directory and
# attempt to upload every file it finds as a license — which will fail.
# For FortiFlex or PAYG: create an empty directory and point to it.
asg_license_directory = "asg_license"  # directory exists but is empty for FortiFlex/PAYG

# FortiFlex: only serials Blue is NOT using (see the pre-deployment checklist)
fortiflex_sn_list = ["FGVMXXXX00000003", "FGVMXXXX00000004"]
```

#### Transit Gateway return routes

Green's own Transit Gateway route table needs a route to every VPC the FortiGates
forward to, as Blue's inspection route table has. By default Terraform derives them from
the Transit Gateway: one static route per CIDR of every attached VPC, pointing at that
VPC's attachment. VPCs whose primary CIDR equals `vpc_cidr_inspection` (Blue's inspection
VPC, and Green's own) are skipped.

Set `tgw_return_routes` to list the routes yourself when a destination is not a VPC in
the same account and region — a VPN, Direct Connect, a peering attachment, or a VPC
attached from another account — because those cannot be looked up:

```hcl
tgw_return_routes = {
  "192.168.0.0/24" = "tgw-attach-0123456789abcdef0"
  "192.168.1.0/24" = "tgw-attach-0fedcba9876543210"
}
```

Compare the result with Blue's inspection route table in `terraform plan` before applying:
the `aws_ec2_transit_gateway_route.green_return` entries should match it route for route.

{{% notice warning %}}
`asg_license_directory` must always point to a valid directory path, even when using
FortiFlex or PAYG licensing. Setting it to `""` causes the module to scan the working
directory and fail. Create an empty `asg_license/` directory in
`terraform/green_inspection_stack/` if you are not using BYOL license files.
{{% /notice %}}

### Apply Green

```bash
cd terraform/green_inspection_stack
terraform init
terraform apply
```

{{% notice info %}}
Green's TGW attachment is created by `terraform apply` but TGW routes are **not** modified.
Blue continues handling all traffic.
{{% /notice %}}

Note the key outputs after apply — you will need them for verification:

```bash
terraform output green_tgw_attachment_id
terraform output green_natgw_az1_temp_eip
terraform output green_natgw_az2_temp_eip
```

Save the state file for the cutover script:

```bash
cp terraform.tfstate ../../upgrade_fortios/state/green.tfstate
```

### Restore Config to Green Primary

After Green FortiGates are running and the Lambda has initialized them, restore the Blue
config to the Green primary FortiGate.

#### Prepare the backup for Green

Do not restore `state/blue_primary_config.conf` as it is. Each FortiGate reaches the
Gateway Load Balancer through one GENEVE tunnel per availability zone, and the tunnel's
peer (`config system geneve` → `set remote-ip`) is the GWLB's address in that zone, with a
/32 static route to it. Blue's backup carries **Blue's** GWLB addresses. Restored as it is,
Green's tunnels point at Blue's GWLB: the GWLB health check still shows Green healthy,
because it only probes a port, but no traffic passes through Green after cutover. FortiOS
will not change a tunnel peer while routes, policy routes or a zone use the tunnel, so it
cannot be fixed with one command afterwards.

Write a copy of the backup with Green's GWLB addresses:

```bash
cd upgrade_fortios
python3 scripts/prepare_green_config.py \
  --inventory   state/blue_inventory.json \
  --green-state state/green.tfstate
```

The script looks up both GWLBs' addresses in AWS, pairs them by availability zone, and
writes `state/green_primary_config.conf` with only the GENEVE peers and their /32 routes
changed. It prints each line it changed. It stops and writes nothing when a GENEVE peer in
the backup is not one of Blue's GWLB addresses (the backup is of another stack, or was
rewritten already) or when the two GWLBs are not in the same zones. The original backup is
left unchanged: `cutover.py` still checks it.

**Option A — via FortiGate GUI (manual):**

1. Identify the Green primary instance — it has `ProtectedFromScaleIn: true` in the
   Green BYOL ASG
2. Open the Green primary FortiGate GUI at `https://<management-ip>/`
3. **System → Settings → Restore → Upload** `state/green_primary_config.conf`
4. FortiGate reboots after restore (allow up to 10 minutes)
5. Log in again and verify security policies are present

**Option B — via FortiGate REST API:**

```bash
# Get Green primary management IP from AWS
aws ec2 describe-instances \
  --instance-ids <green-primary-instance-id> \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text

# POST config backup to Green primary
curl -k -X POST \
  "https://<green-primary-ip>/api/v2/monitor/system/config/restore" \
  -H "Authorization: Bearer <api-key>" \
  -F "source=upload" \
  -F "scope=global" \
  -F "file=@state/green_primary_config.conf"
```

After restore, the FortiGate reboots. Poll until it returns to GWLB healthy state
(~5–10 minutes). The Green secondary will receive config from the Green primary
automatically via the Lambda once the primary is back online.

Then check the tunnel peers on Green's primary. `show system geneve` must list Green's GWLB
addresses, the ones `prepare_green_config.py` printed on the right of each arrow.

**Gate:** Terraform apply completes. Green ASG instances are healthy.

---

## Post-Deployment Verification Checklist

Complete this checklist after Phase 2 and before proceeding to Phase 3 (Validate Green).
These checks confirm that Green is structurally sound before automated validation runs.

**Infrastructure**
- [ ] `terraform apply` completed with no errors
- [ ] `state/green.tfstate` saved to `upgrade_fortios/state/`
- [ ] Green TGW attachment visible in AWS Console → Transit Gateway → Attachments
- [ ] Green inspection VPC created with correct CIDR (matches Blue)
- [ ] Green NAT Gateways created in both AZs (will have temporary EIPs)
- [ ] Green GWLB created and GWLB endpoints are in "Available" state
- [ ] Green TGW route table has the same routes as Blue's inspection TGW route table (spoke and management CIDRs)
- [ ] Green GWLB endpoint route tables have the RFC1918 routes to the Transit Gateway and a default route to the internet gateway
- [ ] Green public route tables default-route to the Green NAT gateways (`nat_gw` mode) or the internet gateway (`eip` mode)

**FortiGate Health**
- [ ] Green ASG instances launched and in `InService` lifecycle state
- [ ] `get system status` on each Green FortiGate shows `License Status: Valid`, and each has its own serial
- [ ] Each Green FortiGate's management interface has the public address you expect. If one has none, look for `AddressLimitExceeded` in the Green autoscale Lambda's log
- [ ] Green ASG raised from one instance to its final size once the first instance is licensed (FortiFlex)
- [ ] One Green instance has `ProtectedFromScaleIn: true` (primary elected)
- [ ] Green primary FortiGate accessible via HTTPS on management port
- [ ] Config restore completed without errors (check FortiGate event log)
- [ ] Green primary FortiGate shows expected security policies after restore

**Config Validation**
- [ ] Green primary `get system status` shows target FortiOS version
- [ ] `get router info routing-table all` shows expected routes (VPC subnets present)
- [ ] Security policies visible and match Blue (spot check 3–5 critical policies)
- [ ] FortiGate HA synchronization status shows secondary in sync (if applicable)

**FortiManager (if enabled)**
- [ ] Green serial numbers visible in FortiManager → Device Manager → Unauthorized Devices
- [ ] Green serial numbers authorized in FortiManager before proceeding to cutover
- [ ] Policy packages pushed to Green devices from FortiManager

**TGW Routing (confirm Blue still active)**
- [ ] Spoke VPC traffic still flows through Blue (verify via CloudWatch or FortiGate session logs)
- [ ] Green TGW attachment does **not** appear in spoke route tables (routes still point to Blue)

---

## Phase 3 — Validate Green

**Goal:** Confirm Green is healthy and ready for production traffic before cutover.

**Duration:** 30–60 minutes  
**Traffic impact:** None — Blue still handling all traffic

Manually verify each of the following before proceeding to cutover:

| Check | How to Verify |
|-------|--------------|
| ASG instances healthy | AWS Console → EC2 Auto Scaling → confirm all Green instances `InService` |
| GWLB targets healthy | AWS Console → EC2 → Load Balancers → Target Groups → confirm all targets healthy |
| Primary elected | Check for one instance with `ProtectedFromScaleIn: true` in Green BYOL ASG |
| Config restored | Log in to Green primary FortiGate → confirm expected security policies present |
| GENEVE peers | Green primary CLI: `show system geneve` lists Green's GWLB addresses, not Blue's |
| CloudWatch alarms | AWS Console → CloudWatch → Alarms → confirm Green alarms in `OK` state |
| Lambda operating | AWS Console → Lambda → confirm recent successful invocations in CloudWatch metrics |
| DynamoDB state | AWS Console → DynamoDB → scan `fgt_asg_track_table` → confirm Green instances registered |
| Licenses valid | FortiGate CLI: `get system status | grep -i license` — confirm valid |

**Gate:** All checks pass. Operator reviews results and confirms cutover can proceed.

{{% notice warning %}}
Do not proceed to cutover until all validation checks pass. A failed validation check
indicates Green is not ready to handle production traffic.
{{% /notice %}}

---

## Phase 4 — Cutover

**Goal:** Redirect production traffic from Blue to Green with minimum downtime.

**Duration:** Phase 1 (TGW flip) < 30 seconds. Phase 2 (EIP migration, nat_gw only) ~2–3 minutes.  
**Traffic impact:** Active sessions interrupted at TGW route flip. New sessions immediately
go through Green. Outbound source IPs are preserved after EIP migration completes.

### Pre-Cutover Checklist

Before running the cutover script, confirm:

- [ ] Phase 1 (Backup) complete — `state/blue_primary_config.conf` exists and was taken on the version Blue is running (`cutover.py` refuses to run otherwise)
- [ ] That backup, prepared with `prepare_green_config.py`, was restored to Green's primary, and Green's policies and GENEVE peers were checked (the script cannot see this)
- [ ] Phase 3 (Validate Green) passed — all automated checks green
- [ ] Post-deployment verification checklist complete
- [ ] Spoke VPC connectivity confirmed through Blue (last health check before cutover)
- [ ] Change window open (if required by your organization)
- [ ] Application teams notified of brief session interruption
- [ ] `state/green.tfstate` present in `upgrade_fortios/state/` directory
- [ ] `blue_inventory.json` was produced with `--upgrade-path-verified` if the upgrade crosses a minor or major version (`cutover.py` refuses to run otherwise)

### Preview the Cutover Plan

Always run dry-run first to confirm what `cutover.py` will do:

```bash
cd upgrade_fortios

python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate \
  --dry-run
```

Dry-run output shows:

- Which TGW route tables will be updated (route table IDs and CIDRs)
- Blue attachment ID → Green attachment ID
- Which Blue NAT Gateways will be deleted (EIPs shown)
- Which Green NAT Gateways will be recreated with Blue EIPs
- The configuration backup it checked: its FortiOS version, when it was saved, and a
  warning if it is more than a day old

Review this output carefully before proceeding.

### The Backup Check

Before anything else, in a dry run as well, `cutover.py` looks at the backup of Blue's
primary (`state/blue_primary_config.conf`, or the file given with `--config-backup`). It
stops with an error and changes nothing when:

| Condition | Why it stops |
|-----------|--------------|
| The file is missing | Phase 1 was skipped, so Green has only its bootstrap configuration |
| The first line is not `#config-version=...` | The file is encrypted or is not a FortiGate backup |
| The backup's version is not the version Blue runs | The file is left over from an earlier upgrade and is not a backup of Blue as it runs now |

The check covers what a script can see. It cannot tell whether the backup was restored to
Green's primary: that is the operator's check in
[Restore Config to Green Primary](#restore-config-to-green-primary).

`--skip-backup-check` runs the cutover without a backup. Use it only when Green gets its
whole configuration another way: FortiManager pushes it, or Blue has never been changed
from the template's bootstrap configuration. The script prints a warning saying so.

### Execute the Cutover

```bash
python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate
```

The script prompts for confirmation before executing. The cutover sequence:

**Phase 1 — TGW Route Flip** (< 30 seconds)

```
For each spoke TGW route table:
  Replace: 0.0.0.0/0 → Blue attachment
      with: 0.0.0.0/0 → Green attachment

→ Traffic immediately routes to Green FortiGates
```

**Phase 2 — NAT Gateway EIP Migration** (nat_gw mode only, ~2–3 minutes)

```
Step 2a  Delete Blue NAT Gateways          → Blue EIPs released
Step 2b  Wait for deletion                  (~60 s)
Step 2c  Create new Green NAT GWs           using Blue EIP allocation IDs
Step 2d  Wait for new NAT GWs available     (~60 s)
Step 2e  Update Green VPC route tables      old Green natgw IDs → new natgw IDs
Step 2f  Delete original Green NAT GWs      (temp EIPs)
Step 2g  Release Green temp EIP allocations

→ Outbound source IPs preserved — external firewall rules and IP allowlists unchanged
```

Progress is written to `state/cutover_progress.json` after each phase so that
`rollback.py` can undo exactly what was done.

{{% notice info %}}
**EIP mode** (`access_internet_mode = "eip"`): EIPs are attached to ephemeral FortiGate
instances and are already non-deterministic. No EIP migration is needed — Phase 2 is
skipped automatically when `egress_mode: eip` is set in the inventory. Total cutover
duration is under 30 seconds.
{{% /notice %}}

### Post-Cutover Verification

After `cutover.py` completes, verify immediately:

```bash
# Confirm spoke route tables point to Green attachment
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <spoke-rtb-id> \
  --filters "Name=type,Values=static"

# Check Green ASG instance health
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <green-byol-asg-name>
```

- [ ] Spoke TGW route tables show Green attachment ID
- [ ] Test traffic from East/West spoke VPCs passes through Green (check FortiGate session logs)
- [ ] Green GWLB target health: all targets healthy
- [ ] Green CloudWatch alarms in OK state
- [ ] For nat_gw mode: new Green NAT GWs show Blue EIPs (verify in AWS Console)
- [ ] Outbound connectivity from spoke VPCs uses expected public source IPs

### Rollback From Cutover

If traffic issues are detected immediately after cutover:

```bash
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json
```

`rollback.py` reads `cutover_progress.json` to determine exactly what ran and performs
the inverse:

- **TGW routes** are immediately restored to Blue attachment (< 30 seconds)
- **NAT Gateway EIPs** — if Phase 2 completed, `rollback.py` deletes the new Green
  NAT GWs holding Blue EIPs, recreates Blue NAT GWs in the original Blue subnets with
  the original EIP allocation IDs, and updates Blue VPC route tables. Allow 2–3 minutes.

```bash
# Preview rollback before executing
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json \
  --dry-run
```

{{% notice warning %}}
Rollback after EIP migration requires recreating Blue NAT Gateways, which takes ~2 minutes.
During this window Blue instances handle traffic but outbound traffic may use different
source IPs until the new Blue NAT GWs are ready.
{{% /notice %}}

**Gate:** Traffic confirmed flowing through Green (or Blue if rolled back). Connectivity
to all spoke VPCs verified.

---

## Phase 5 — Monitor

**Goal:** Confirm Green stability under production traffic before destroying Blue.

**Duration:** 24–48 hours  
**Traffic impact:** None — operating normally on Green

During this phase:
- Blue ASG is **suspended** (no new instances launch or terminate)
- All existing Blue instances remain running
- TGW routes point to Green
- Rollback is still possible via `rollback.py`

### Monitoring

| Source | What to Watch |
|--------|--------------|
| CloudWatch | Green ASG instance health, CPU utilization, scaling events |
| FortiGate | Session counts, policy hit counts, threat logs |
| Application teams | Application connectivity and performance |

### Rollback During Monitoring Window

If issues are found during the monitoring period:

```bash
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json
```

Traffic returns to Blue immediately. Investigate and fix Green before attempting
another cutover.

**Gate:** 24–48 hours of stable operation. Application teams confirm no issues.
Operator explicitly approves Blue teardown before proceeding.

---

## Phase 6 — Cleanup

**Goal:** Destroy Blue environment and release resources.

**Duration:** 1–2 hours  
**Reversibility:** None — Blue is permanently destroyed

{{% notice warning %}}
**Irreversible.** Once Phase 6 completes, Blue is gone. Confirm Green is stable and
application teams have signed off before proceeding.
{{% /notice %}}

Blue's ASG, GWLB, Lambda, DynamoDB, and inspection VPC were created across two Terraform
state files (`autoscale_template` and `existing_vpc_resources`). The inspection VPC itself
is in `existing_vpc_resources` alongside shared infrastructure (TGW, management VPC,
spokes) — **do not run `terraform destroy` on `existing_vpc_resources`.**

Destroy the `autoscale_template` resources (ASG, GWLB, Lambda, DynamoDB, launch templates)
with Terraform, after taking the spoke default routes out of its state.

{{% notice warning %}}
With `create_tgw_routes_for_existing = true`, Blue's `autoscale_template` state owns the
spoke route tables' default routes. After cutover those routes point at **Green**.
`terraform destroy` deletes a Transit Gateway route by route table and destination,
whatever it points at, so destroying Blue as it stands removes the routes that send
spoke traffic to Green. Remove them from the state first.
{{% /notice %}}

```bash
cd terraform/autoscale_template

# The spoke default routes this state owns
terraform state list | grep aws_ec2_transit_gateway_route

# Stop Terraform managing them. This changes nothing in AWS.
terraform state rm \
  'aws_ec2_transit_gateway_route.east-default-route-to-inspection[0]' \
  'aws_ec2_transit_gateway_route.west-default-route-to-inspection[0]'

# Review what will be destroyed. No aws_ec2_transit_gateway_route may be listed,
# and nothing outside the Blue inspection VPC and the Blue ASG stack.
terraform plan -destroy

terraform destroy
```

The two spoke default routes keep pointing at Green and are no longer managed by any
Terraform state. Blue's inspection VPC, its Transit Gateway attachment and its inspection
route table are not touched by this. They belong to `existing_vpc_resources` and stay in place, unused,
until they are removed there. `cutover.py` flips routes; it does not delete the Blue
attachment.

{{% notice note %}}
In `nat_gw` mode the cutover deleted Blue's NAT gateways and moved their Elastic IPs to
Green, but the `existing_vpc_resources` state still records both. Read `terraform plan`
in `terraform/existing_vpc_resources` before any later apply there: it will propose
recreating the Blue NAT gateways with Elastic IPs that Green is now using.
{{% /notice %}}

After destroy completes:
- Archive `blue_primary_config.conf` and `blue_inventory.json` for audit purposes
- Green is now the production inspection stack
- On the next upgrade cycle, the current Green becomes Blue, and a new Green is deployed

### Optional: Remove "green" from Tags

Green's VPC resources carry `{cp}-{env}-green-inspection-*` tags to prevent collision with
Blue during the cutover window. After Blue is gone those tags can be renamed to the bare
`{cp}-{env}-inspection-*` pattern that `autoscale_template` data sources expect — making
the stack discoverable by a future `autoscale_template` deployment without modification.

Set `stack_label = ""` in `terraform/green_inspection_stack/terraform.tfvars` and run:

```bash
cd terraform/green_inspection_stack
terraform apply
```

This is a **pure tag update** — no VPC resources are recreated. All Name and Fortinet-Role
tags on the VPC, subnets, route tables, NAT Gateways, internet gateway, and TGW attachment
are renamed in a single apply.

{{% notice note %}}
`asg_module_prefix` controls ASG, GWLB, Lambda, and DynamoDB resource names — those
are not affected by `stack_label` and cannot be renamed without recreating the resources.
Set `asg_module_prefix = ""` (matching the Blue default) only when deploying a fresh stack
for the next upgrade cycle.
{{% /notice %}}

---

## Rollback Decision Tree

```
Phase 2 (Deploy Green) fails
  → Fix terraform.tfvars or Green config, re-run terraform apply
  → Blue is completely unaffected

Phase 3 (Validate Green) fails
  → Debug Green; destroy Green if needed, fix, and redeploy
  → Blue is completely unaffected

Phase 4 (Cutover) — traffic issues detected
  → Run rollback.py immediately (< 60 seconds)
  → Blue resumes all traffic
  → Investigate Green before re-attempting cutover

Phase 5 (Monitor) — issues found
  → Run rollback.py
  → Blue resumes all traffic
  → Investigate and fix Green

Phase 6 (Cleanup) — no rollback possible
  → Blue has been destroyed
```

---

## FortiManager / FortiAnalyzer Considerations

Green FortiGates have different serial numbers from Blue. If FortiManager or FortiAnalyzer
integration is enabled:

1. The config backup will carry FortiManager connection settings — Green FortiGates will
   attempt to connect to FortiManager after config restore
2. FortiManager must authorize the new serial numbers:
   **Device Manager → Device & Groups → right-click unauthorized device → Authorize**
3. If FortiManager is running version 7.6.3+, ensure `fgfm-allow-vm` is enabled:
   ```
   config system global
       set fgfm-allow-vm enable
   end
   ```

---

## Risk Considerations

| Risk | Mitigation |
|------|-----------|
| Same-CIDR conflict during parallel operation | Blue and Green are isolated VPCs — no routing between them |
| Session interruption at cutover | Expected and accepted; new sessions route to Green immediately |
| Green config restore fails | Test restore on one instance before full cutover; fallback to manual GUI restore |
| License capacity during monitoring | Ensure FortiFlex pool has capacity for 2x licenses during monitoring window |
| TGW route update fails mid-cutover | Script checks each route update; partial failure leaves some spokes on Blue — run rollback.py |
| FortiManager loses sync | Re-authorize Green serial numbers in FortiManager post-cutover |
| NAT Gateway EIP migration window | Brief period (seconds) where outbound uses temporary IPs — minimize by not interrupting cutover.py |
