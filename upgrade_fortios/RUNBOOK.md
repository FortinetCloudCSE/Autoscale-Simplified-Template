# Operational Runbook: FortiGate Autoscale Blue-Green Redeployment

## Pre-Engagement Checklist

Before starting, confirm the following:

### Customer Information
- [ ] AWS account ID and region confirmed
- [ ] Terraform state file location confirmed (local or S3 backend)
- [ ] Current FortiOS version documented
- [ ] Target FortiOS version confirmed
- [ ] Admin credentials for FortiGate available
- [ ] Change window scheduled (if required by customer)
- [ ] Application team contacts available for validation sign-off

### Access Requirements
- [ ] AWS CLI configured with sufficient permissions (see Permissions section)
- [ ] SSH key for FortiGate instances available
- [ ] FortiGate GUI accessible from operator workstation
- [ ] Terraform installed and initialized

### AWS Permissions Required
The operator account needs:
- EC2: full access (VPC, subnets, security groups, instances, EIPs, route tables)
- AutoScaling: full access
- ElasticLoadBalancingV2: full access
- TransitGateway: full access (ec2:* on TGW resources)
- Lambda: read access
- DynamoDB: read access
- CloudWatch: read access
- IAM: pass role (for Terraform deployments)

---

## Phase 0: Discovery

**Estimated time:** 30 minutes
**Risk:** None — read-only

### Step 0.1 — Get the Terraform state file

```bash
# Option A: Local state
cp /path/to/customer/terraform/autoscale_template/terraform.tfstate ./blue.tfstate

# Option B: Remote S3 state
cd /path/to/customer/terraform/autoscale_template
terraform state pull > ./blue.tfstate
cd -
```

### Step 0.2 — Run discovery

```bash
python3 scripts/discover.py --state blue.tfstate --output blue_inventory.json
```

### Step 0.3 — Review the inventory

```bash
cat blue_inventory.json | python3 -m json.tool | less
```

Verify the following are present and correct:
- [ ] `inspection_vpc.vpc_id` and `inspection_vpc.cidr_block` populated
- [ ] `subnets` list contains entries for public, private, gwlbe, natgw subnets
- [ ] `transit_gateway.tgw_id` and `transit_gateway.inspection_attachment_id` populated
- [ ] `transit_gateway.routes_to_update` list is non-empty (the spoke TGW routes to flip)
- [ ] `vpc_resources.cutover_routes` list is non-empty (requires `--vpc-state` flag)
- [ ] `gwlb.lb_arn` and `gwlb.endpoint_ids` populated
- [ ] `autoscale_groups.byol.asg_name` and instance count correct
- [ ] `autoscale_groups.byol.primary_instance` identified
- [ ] `egress_mode` correctly reflects `nat_gw` or `eip`
- [ ] `nat_gateways` list has EIP allocation IDs (if egress_mode is nat_gw)

### Step 0.4 — Note the broken CloudWatch thresholds

The `cloudwatch_alarms` section of the inventory shows the current (broken) thresholds.
Review them and document the correct values you intend to use in Green:

```bash
cat blue_inventory.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d['cloudwatch_alarms']:
    print(f\"{a['alarm_name']}: {a['comparison']} {a['threshold']} for {a['evaluation_periods']} x {a['period']}s\")
"
```

**GATE — Operator confirms inventory is complete and accurate before proceeding.**

---

## Phase 1: Backup

**Estimated time:** 30-60 minutes
**Risk:** None — read-only

### Step 1.1 — Identify the primary FortiGate instance

```bash
BYOL_ASG=$(cat blue_inventory.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['autoscale_groups']['byol']['asg_name'])")

aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='${BYOL_ASG}' && ProtectedFromScaleIn==\`true\`].{Instance:InstanceId,AZ:AvailabilityZone}" \
  --output table
```

Note the primary instance ID.

### Step 1.2 — Get the primary instance management IP

```bash
PRIMARY_INSTANCE=<instance-id-from-above>

aws ec2 describe-instances \
  --instance-ids ${PRIMARY_INSTANCE} \
  --query "Reservations[0].Instances[0].{PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}" \
  --output table
```

### Step 1.3 — Export FortiGate configuration

**Option A: GUI**
1. Open browser to `https://<management-ip>:<gui-port>`
2. Log in as admin
3. Go to System → Settings → Backup
4. Select Full Configuration backup
5. Save as `blue_primary_config.conf`

**Option B: CLI**
```bash
ssh admin@<management-ip> -p 22
# In FortiGate CLI:
execute backup full-config ftp <ftp-server> <filename> <username> <password>
```

### Step 1.4 — Document current FortiOS version

```bash
ssh admin@<management-ip> -p 22
# In FortiGate CLI:
get system status | grep "Version"
```

Record the version (e.g., `FortiOS v7.4.4 build2662`).

### Step 1.5 — Verify backup is readable

Open `blue_primary_config.conf` in a text editor. Confirm it contains recognizable
FortiGate configuration sections: `config system global`, `config firewall policy`, etc.

**GATE — Operator confirms backup file is complete and readable.**

---

## Phase 2: Deploy Green

**Estimated time:** 30-60 minutes
**Risk:** Medium — new infrastructure deployed, no traffic impact

### Step 2.1 — Prepare Green terraform.tfvars

Create `terraform.tfvars` for the Green stack. Key values come from `blue_inventory.json`
(use `python3 -m json.tool state/blue_inventory.json` to read them):

```hcl
# Must match Blue exactly (from inspection_vpc.cidr_block)
vpc_cidr_inspection   = "<from blue_inventory.json inspection_vpc.cidr_block>"
availability_zone_1   = "<letter suffix of AZ, e.g. 'a'>"
availability_zone_2   = "<letter suffix of AZ, e.g. 'c'>"
aws_region            = "<from blue_inventory.json discovery_metadata.region>"
attach_to_tgw_name    = "<TGW name — find from transit_gateway.tgw_id>"

# Fixed values (corrections from Blue)
fortios_version                  = "<target version, e.g. 7.4.6>"
asg_byol_asg_desired_size        = <correct value>
asg_byol_asg_min_size            = <correct value>
asg_byol_asg_max_size            = <correct value>
asg_ondemand_asg_desired_size    = <correct value>
asg_ondemand_asg_min_size        = <correct value>
asg_ondemand_asg_max_size        = <correct value>
primary_scalein_protection       = true

# Licensing (corrected)
# Set appropriate BYOL/FortiFlex/PAYG configuration

# NAT Gateway EIPs — Green gets NEW temporary EIPs at deploy time.
# Blue EIPs are migrated to Green at cutover by cutover.py.
# Do NOT reference Blue EIP allocation IDs here.
access_internet_mode = "nat_gw"   # or "eip" — must match Blue (from inventory)

# Use a distinct cp/env to avoid tag conflicts with Blue
cp  = "<same as Blue or new value>"
env = "<green or new env tag>"
```

> **Important:** Use a different `cp`/`env` combination from Blue if Blue uses
> Fortinet-Role tags, to avoid tag collision during parallel operation. If Blue
> does not use these tags (manual deployment), any value works.

> **EIP note:** Green intentionally deploys with temporary EIPs on its NAT Gateways.
> Do not attempt to pre-assign Blue EIPs to Green in Terraform — they are still in
> use by Blue. The cutover script handles the handoff atomically.

### Step 2.2 — Initialize and plan

```bash
cd terraform/green_inspection_stack
terraform init
terraform plan -out=green.tfplan
```

Review the plan carefully:
- [ ] Inspection VPC CIDR matches Blue
- [ ] Correct AZs
- [ ] Correct TGW attachment
- [ ] No resources overlap with Blue (check `asg_module_prefix = "green"`)
- [ ] Target FortiOS AMI is correct

### Step 2.3 — Apply

```bash
terraform apply green.tfplan
```

Monitor the apply. Expected duration: 15–30 minutes.

After apply, save the state file:

```bash
cp terraform.tfstate ../../upgrade_fortios/state/green.tfstate
```

### Step 2.4 — Verify Green ASG instances are healthy

```bash
GREEN_BYOL_ASG=<from terraform output or green inventory>

aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ${GREEN_BYOL_ASG} \
  --query "AutoScalingGroups[0].Instances[*].{ID:InstanceId,Health:HealthStatus,State:LifecycleState}" \
  --output table
```

All instances should be `InService` and `Healthy`.

### Step 2.5 — Restore FortiGate configuration to Green primary

1. Identify the Green primary instance (same method as Step 1.1, using Green ASG name)
2. Get its management IP
3. Log in to Green primary FortiGate GUI
4. Go to System → Settings → Restore
5. Upload `blue_primary_config.conf`
6. FortiGate will restart after restore

After restart, verify:
- [ ] FortiGate is accessible
- [ ] Security policies are present
- [ ] Routing table looks correct
- [ ] FortiManager connection (if applicable) is re-established

> **Note:** After config restore, the FortiGate will have Blue's interface IPs
> as reference points in the config, but the actual interface IPs will be
> re-assigned by the bootstrap process. Verify interface assignments are correct.

**GATE — Green ASG healthy, config restored, FortiGate accessible.**

---

## Phase 3: Validate Green

**Estimated time:** 30-60 minutes
**Risk:** Low — Green is not handling production traffic yet

### Step 3.1 — Verify Green health

```bash
GREEN_BYOL_ASG=<from terraform output or green.tfstate>

# All instances InService
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ${GREEN_BYOL_ASG} \
  --query "AutoScalingGroups[0].Instances[*].{ID:InstanceId,Health:HealthStatus,State:LifecycleState}" \
  --output table

# Primary elected
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='${GREEN_BYOL_ASG}' && ProtectedFromScaleIn==\`true\`]" \
  --output table
```

Expected checks:
- [ ] GWLB target group: all targets healthy (AWS Console → Load Balancers → Target Groups)
- [ ] ASG: all instances InService
- [ ] CloudWatch alarms: Green alarms in OK state
- [ ] Lambda: recent successful invocations in CloudWatch metrics
- [ ] DynamoDB: table exists with correct instance entries
- [ ] License: instances registered (`get system status | grep -i license` on Green FortiGate)

### Step 3.2 — Manual FortiGate validation

SSH or GUI to Green primary:

```bash
# Check FortiOS version
get system status

# Verify interfaces are up
get system interface | grep -A2 "port1\|port2\|port3"

# Check FortiGate can reach spoke VPC supernet routes
get router info routing-table all

# Verify firewall policies loaded
show firewall policy | grep "edit"

# Check license status
get system status | grep -i license
```

### Step 3.3 — Optional: Send test traffic through Green

If the environment allows, temporarily route a non-production spoke VPC through Green
to validate end-to-end traffic inspection before the full cutover. Restore the route
after testing.

**GATE — All validation checks pass. Operator confirms Green is ready.**

---

## Phase 4: Cutover

**Estimated time:** 5-10 minutes
**Risk:** High — production traffic impact. Active sessions will be interrupted briefly.

### Pre-cutover final checklist

- [ ] Phase 1 backup confirmed
- [ ] Phase 3 validation passed
- [ ] Application team notified (if required)
- [ ] Rollback procedure reviewed and `rollback.py` tested in dry-run
- [ ] Both operators (if applicable) ready

### Step 4.1 — Dry-run the cutover

```bash
cd upgrade_fortios
python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate \
  --dry-run
```

Review the output. Confirm:
- Correct TGW route table IDs and CIDRs are listed
- Blue attachment ID → Green attachment ID is correct
- For nat_gw mode: correct Blue NAT GW IDs and EIPs are listed

### Step 4.2 — Execute cutover

```bash
python3 scripts/cutover.py \
  --inventory  state/blue_inventory.json \
  --green-state state/green.tfstate
```

The script:
1. Displays a summary and prompts for confirmation
2. **Phase 1** — Replaces all TGW spoke routes: Blue attachment → Green attachment
3. **Phase 2** (nat_gw mode) — Migrates Blue EIPs to Green NAT Gateways:
   - Deletes Blue NAT Gateways (releases EIPs)
   - Creates new Green NAT Gateways with Blue EIP allocation IDs
   - Updates Green VPC route tables
   - Deletes original Green temp NAT Gateways and releases temp EIPs
4. Writes progress to `state/cutover_progress.json`

### Step 4.3 — Immediate post-cutover validation

```bash
# Confirm TGW routes now point to Green attachment
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <spoke-rtb-id> \
  --filters "Name=type,Values=static" \
  --output table
```

Within 1-2 minutes:
- [ ] Confirm traffic is flowing through Green FortiGate instances (check session count)
- [ ] Confirm spoke VPC connectivity from application team
- [ ] Check Green GWLB target group: targets should be receiving traffic
- [ ] If nat_gw mode: confirm Green NAT Gateways now have the original Blue EIPs

```bash
# Verify EIPs are on Green NAT Gateways
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=<green-vpc-id>" \
  --query "NatGateways[*].{ID:NatGatewayId,EIP:NatGatewayAddresses[0].PublicIp}" \
  --output table
```

### Step 4.5 — Suspend Blue ASG

Prevent Blue from launching new instances during the monitoring period:

```bash
BLUE_BYOL_ASG=$(cat blue_inventory.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['autoscale_groups']['byol']['asg_name'])")

aws autoscaling suspend-processes \
  --auto-scaling-group-name ${BLUE_BYOL_ASG} \
  --scaling-processes Launch Terminate HealthCheck
```

Repeat for the On-Demand ASG if applicable.

**GATE — Traffic confirmed on Green. Application team confirms connectivity.**

---

## Phase 5: Monitor

**Estimated time:** 24-48 hours
**Risk:** Low — Blue is available for immediate rollback

### Monitoring checklist (check every few hours)

- [ ] Green ASG instance health (all InService)
- [ ] GWLB target group health
- [ ] CloudWatch CPU alarms firing correctly
- [ ] No unexpected scaling events
- [ ] FortiGate threat logs show expected traffic patterns
- [ ] No license expiry warnings on Green instances
- [ ] Application team: no reported connectivity issues

### Rollback procedure (if needed)

```bash
cd upgrade_fortios
python3 scripts/rollback.py \
  --inventory state/blue_inventory.json \
  --progress  state/cutover_progress.json
```

The rollback script reads `cutover_progress.json` to determine what ran, then:
1. Restores TGW routes to Blue attachment ID (< 30 seconds)
2. If EIP migration ran: deletes Green NAT GWs holding Blue EIPs, recreates Blue NAT
   GWs in original subnets with original EIP allocation IDs, updates Blue VPC routes
   (~2–3 minutes for NAT GW recreation)

Blue ASG processes should be resumed before or immediately after:

```bash
BLUE_BYOL_ASG=<from inventory>
aws autoscaling resume-processes \
  --auto-scaling-group-name ${BLUE_BYOL_ASG} \
  --scaling-processes Launch Terminate HealthCheck
```

> **Note:** NAT Gateway recreation takes 60-90 seconds. There will be a brief
> egress interruption during rollback while the Blue NAT Gateways are recreated.
> This is unavoidable given the EIP-per-NAT-GW constraint.

**GATE — 24-48 hours stable. Application team signs off. Operator approves cleanup.**

---

## Phase 6: Cleanup

**Estimated time:** 1-2 hours
**Risk:** HIGH and IRREVERSIBLE — Blue environment will be destroyed

> **Warning:** There is no rollback after this phase. Confirm all parties have
> signed off before proceeding.

### Step 6.1 — Final confirmation

```bash
echo "You are about to PERMANENTLY DESTROY the Blue FortiGate deployment."
echo "This cannot be undone. Type CONFIRM to proceed:"
read confirmation
```

### Step 6.2 — Archive Blue artifacts

```bash
mkdir -p blue_archive
cp blue.tfstate blue_archive/
cp blue_inventory.json blue_archive/
cp blue_primary_config.conf blue_archive/
tar czf blue_archive_$(date +%Y%m%d).tar.gz blue_archive/
```

Store the archive in a safe location before proceeding.

### Step 6.3 — Destroy Blue infrastructure

Blue's autoscale resources (ASG, GWLB, Lambda, DynamoDB, launch templates) were
created by `terraform/autoscale_template`. The inspection VPC itself is in
`existing_vpc_resources` alongside shared infrastructure — do NOT destroy that module.

```bash
cd terraform/autoscale_template
terraform plan -destroy
# Review: confirm only ASG/GWLB/Lambda/DDB resources are listed, NOT TGW or management VPC
terraform destroy
```

After autoscale resources are destroyed, delete the Blue inspection VPC and its subnets
manually via AWS Console or CLI if they are no longer needed.

### Step 6.4 — Verify cleanup

```bash
# Confirm Blue VPC is gone
aws ec2 describe-vpcs --vpc-ids <blue-vpc-id>
# Should return: An error occurred (InvalidVpcID.NotFound)

# Confirm Blue TGW attachment is gone
aws ec2 describe-transit-gateway-vpc-attachments \
  --transit-gateway-attachment-ids <blue-tgw-attachment-id>
# Should show: deleted state
```

### Step 6.5 — Optional: Remove "green" from tags

Green's VPC resources still carry `{cp}-{env}-green-inspection-*` tags. Now that Blue is
gone, rename them to the bare `{cp}-{env}-inspection-*` pattern so `autoscale_template`
data sources can discover this stack on the next upgrade cycle without modification.

In `terraform/green_inspection_stack/terraform.tfvars`, set:

```hcl
stack_label = ""
```

Then apply:

```bash
cd terraform/green_inspection_stack
terraform apply
```

This is a pure tag update — no resources are recreated. Only Name and Fortinet-Role tags
on VPC, subnets, route tables, NAT Gateways, IGW, and TGW attachment are renamed.

### Step 6.6 — Close the change record

Document:
- Date and time of each phase completion
- Pre-upgrade FortiOS version
- Post-upgrade FortiOS version
- Any issues encountered and resolutions
- Final sign-off from application team and operator

---

## Troubleshooting

### Discovery finds incomplete resources
- Check if state file is current: `terraform refresh` then re-pull
- Resources created outside Terraform will not appear in state — find manually

### Green terraform apply fails
- Check IAM permissions
- Verify TGW attachment limit not exceeded (default: 5 per TGW)
- Check CIDR conflict: Blue and Green inspection VPCs have same CIDR but different VPC IDs — this is fine within the same account

### Config restore fails on Green FortiGate
- Verify the backup file is not corrupted (should start with `#config-version=`)
- Try restoring to a fresh instance rather than one that has already been auto-configured
- Check FortiOS version compatibility between backup and target

### Cutover script fails mid-way
- Check which spoke VPCs were updated vs not updated
- Some spokes may be on Green, some still on Blue — check each TGW route table
- Manually complete remaining route updates or run rollback to revert all

### Traffic not flowing after cutover
- Verify GWLB endpoints are in correct subnets
- Check security group allows traffic from TGW attachment subnets
- Check FortiGate firewall policies
- Verify VPC route tables in spoke VPCs have routes to TGW

### Rollback not working
- Confirm Blue ASG processes are not suspended (resume if needed)
- Verify Blue GWLB endpoints are still `available`
- Manually update TGW routes if script fails
