---
title: "Blue-Green Upgrade in the Same VPC"
menuTitle: "Blue-Green, Same VPC (Recommended)"
weight: 62
---

## Overview

This blue-green upgrade builds the new FortiGate group (**Green**) next to the one in service
(**Blue**) in the **same inspection VPC, behind the same Gateway Load Balancer (GWLB)**. The
cutover changes one thing: which target group the GWLB listener forwards to.

- The Transit Gateway routes, the GWLB endpoints and every route table stay as they are, for
  centralized egress and for distributed egress alike.
- Green connects to the same GWLB addresses as Blue, so Blue's configuration backup restores
  on Green **without any change**.
- Sessions that are running at the cutover stay on Blue. Only new flows go to Green.
- Rollback is the same step in the other direction.
- Everything is done with `terraform apply` in `terraform/autoscale_template`. There is no
  second template and no second VPC.

```
  spoke VPC / distributed VPC
            |
   GWLB endpoint                   (unchanged)
            |
   endpoint service -> GWLB -> listener --+--> target group "blue"  -> Blue FortiGates (old FortiOS)
                                          |
                                          +--> target group "green" -> Green FortiGates (new FortiOS)
```

{{% notice info %}}
A GWLB has exactly **one** listener (an AWS quota that cannot be raised), and the listener
forwards to **one** target group. New flows follow the listener; established flows keep the
FortiGate they started on.
{{% /notice %}}

---

## How the Template Is Organized

### Slots

`autoscale_template` has two **slots** for FortiGate groups: `blue` and `green`. Normally one
slot is in use. During an upgrade both are. The slots take turns: if Blue is in service, the new
version goes into the green slot; at the next upgrade Green is in service and the new version
goes into the blue slot.

| Part | Where it is defined | Lifetime |
|------|---------------------|----------|
| GWLB, listener | `gwlb.tf` (root of the template) | Whole deployment |
| Endpoint service, GWLB endpoints (inspection and distributed VPCs) | The `blue` module call | Whole deployment — see below |
| Target group of each slot, and its attachment to the slot's autoscale group | `gwlb.tf` | While the slot is in use |
| FortiGate autoscale group, launch template, Lambda functions, DynamoDB table, security groups, alarms | The slot's module call (`spk_tgw_gwlb_asg_fgt_igw` = blue, `spk_tgw_gwlb_asg_fgt_igw_green` = green) | While the slot is in use |

Both module calls are always in the configuration. A slot that is not in use gets empty inputs,
so its module call creates no FortiGate resources. The `blue` module call is special in one way:
it also creates the endpoint service and the GWLB endpoints, and it keeps them when the blue slot
is not in use. This is why removing the blue slot never touches the endpoints.

### Variables

| Variable | Meaning |
|----------|---------|
| `fgt_slots` | The slots in use, with the values that differ per slot. Not set (the default) means one slot, `blue`, built from the usual variables — what every deployment has outside an upgrade. |
| `active_slot` | The slot whose target group the listener forwards to. Changing it is the cutover. Default `"blue"`. |

Each slot can set `fortios_version`, `fgt_instance_type`, `fortiflex_sn_list` and the BYOL /
on-demand group sizes. A value a slot does not set comes from the variable of the same name.

### Names and tags

- The **blue** slot always uses `asg_module_prefix` for its names (for example
  `asg-fgt_byol_asg`). The **green** slot uses `<asg_module_prefix>-green` (for example
  `asg-green-fgt_byol_asg`). The shared GWLB, listener, endpoint service and endpoints keep
  their names for the life of the deployment.
- Every slot resource carries the tag **`Fortinet-Slot = blue`** or **`Fortinet-Slot = green`**.
  Filter on it in the AWS console to see which group a resource belongs to. The shared endpoint
  service and endpoints carry `Fortinet-Slot = blue` because the blue module call manages them.

---

## Before You Start

| Requirement | Why |
|-------------|-----|
| Licenses for both groups at once | During the upgrade both slots run. With FortiFlex, Green's `fortiflex_sn_list` must contain only serials the active slot does not hold (see [FortiFlex serials](#fortiflex-serials)). BYOL license files: enough files for both groups. On-demand: only cost. |
| Elastic IP quota | Both groups have their public / management addresses at the same time. |
| Free addresses in the inspection subnets | Green's FortiGates use the same subnets as Blue's. |
| Upgrade path | Green is restored from a backup taken on the old version. Check in the [Fortinet Upgrade Path Tool](https://docs.fortinet.com/upgrade-tool/fortigate) that the old version upgrades to the new one in a single step. |
| A copy of the state | `terraform state pull > state-before-upgrade.json` before each apply. |

{{% notice warning %}}
Never run `terraform destroy` in `autoscale_template` to remove an old slot. It destroys both
slots **and** the GWLB, listener and endpoints. Remove a slot by taking it out of `fgt_slots`.
`gwlb_deletion_protection = true` (the default) keeps the GWLB itself, but Terraform deletes the
listener, endpoints and FortiGates before it reaches the GWLB, so it does not make a destroy
safe.
{{% /notice %}}

{{% notice warning %}}
Do not change the listener with `aws elbv2 modify-listener`. The change is not in the Terraform
state, and the next `terraform apply` puts the listener back. Always cut over with
`active_slot` and `terraform apply`.
{{% /notice %}}

---

## One-Time Migration of an Existing Deployment

A deployment made before the slots existed has the GWLB, listener and target group inside the
Fortinet module. The template moves them to their new places in the Terraform state with
`moved` blocks: only the state entries are renamed, nothing in AWS is destroyed or created.

1. Make sure the deployment is on the current template with module release **1.1.7** and that
   `terraform plan` shows **No changes**. Update to that version first if not.
2. Save the state:

   ```bash
   terraform state pull > state-before-slots.json
   ```

3. Update to the template version with slots. `terraform.tfvars` does not need a change.
4. Run `terraform init`, then `terraform plan`. The plan must show:

   - three resources that **have moved**:
     `...security-vpc-gwlb.aws_lb.gwlb[0]` → `aws_lb.gwlb`,
     `...aws_lb_listener.gwlb_ln[0]` → `aws_lb_listener.gwlb`,
     `...aws_lb_target_group.gwlb_tgp[0]` → `aws_lb_target_group.slot["blue"]`
   - **1 to add**: `aws_autoscaling_traffic_source_attachment.slot["blue/byol"]` (2 if the
     on-demand group is enabled)
   - in-place changes: the `Fortinet-Slot` tags, and `enable_deletion_protection` on
     `aws_lb.gwlb` (unless you set `gwlb_deletion_protection = false`)
   - **0 to destroy**, and no "must be replaced"

   If the plan shows anything else, stop and do not apply.

5. `terraform apply`, then `terraform plan` again: it must show **No changes**.

The endpoint service, the GWLB endpoints, the routes and the FortiGate group keep their state
addresses and do not appear in the plan.

---

## Upgrade Procedure

The example upgrades Blue (7.6.8, in service) to 8.0.2 in the green slot.

### 1. Back up the active slot's primary

Export the configuration of the primary FortiGate of the active slot (System → Configuration →
Backup, or the REST API).

### 2. Add the green slot

Add to `terraform.tfvars`:

```hcl
fgt_slots = {
  blue = {}                                   # in service, unchanged
  green = {
    fortios_version   = "8.0.2"
    fortiflex_sn_list = ["FGVMXXXX00000003", "FGVMXXXX00000004"]   # serials blue does not hold
    asg_byol_asg_max_size = 1                 # optional: start Green with one instance
  }
}
active_slot = "blue"
```

`terraform plan` must create only green resources — everything under
`module.spk_tgw_gwlb_asg_fgt_igw_green`, `aws_lb_target_group.slot["green"]` and
`aws_autoscaling_traffic_source_attachment.slot["green/byol"]` — with **0 to change, 0 to
destroy**. Then `terraform apply`.

Green's target in its target group shows **`unused`**. That is correct: the listener does not
forward to Green yet, so the GWLB does not health-check it.

### 3. Prepare Green

On Green's primary FortiGate:

1. `show system geneve` — the remote IPs are the GWLB addresses (the same as on Blue).
2. Restore Blue's backup **unchanged**. The FortiGate reboots.
3. `show system geneve` again — still the GWLB addresses.
4. Give Green its own hostname; the restore copies Blue's:

   ```
   config system global
       set hostname <green-hostname>
   end
   ```

5. `get system status` — license **Valid**, Green's own serial. Check that the policies match
   Blue's.

### 4. Cut over

{{% notice warning %}}
After the cutover all **new** flows go through Green. Sessions that are running stay on Blue
until they end.
{{% /notice %}}

Set `active_slot = "green"`. `terraform plan` must show **1 to change** — `aws_lb_listener.gwlb`,
whose `target_group_arn` changes from Blue's target group to Green's — and nothing else. Then
`terraform apply`.

Green's target goes from `initial` to **`healthy`** in about a minute; Blue's turns `unused`.
From a spoke, start a new flow and check with `diagnose sniffer packet any 'icmp' 4` that it
goes through Green.

### 5. Roll back (if needed)

Set `active_slot = "blue"` and `terraform apply`. New flows go to Blue again; flows that
started on Green stay on Green until they end.

### 6. Remove Blue

Keep Blue for your monitoring period (typically 24–48 hours), then make sure it has no sessions
left. Take `blue` out of `fgt_slots`:

```hcl
fgt_slots = {
  green = {
    fortios_version   = "8.0.2"
    fortiflex_sn_list = ["FGVMXXXX00000003", "FGVMXXXX00000004"]
  }
}
active_slot = "green"
```

`terraform plan` must destroy only blue FortiGate resources —
`module.spk_tgw_gwlb_asg_fgt_igw.module.fgt_asg[...]`, the blue module call's security groups
and alarms, `aws_lb_target_group.slot["blue"]` and `aws_autoscaling_traffic_source_attachment.slot["blue/byol"]`.
It must **not** destroy `gwlb_ep_service`, `gwlb_endps`, `aws_lb.gwlb`, `aws_lb_listener.gwlb`
or any route. Then `terraform apply`.

To list what a plan destroys:

```bash
terraform plan -no-color | grep -E "will be destroyed|must be replaced"
```

### The next upgrade

The same steps in the other direction: Green is in service, so the new version goes into the
blue slot (`fgt_slots = { blue = { fortios_version = "<new>" }, green = { ... } }`), the
cutover sets `active_slot = "blue"`, and the last step removes `green`.

---

## FortiFlex Serials

Each slot has its own Lambda function and its own DynamoDB table, and each Lambda tracks only
its own serials. A serial listed for both slots can therefore be given to a Blue and a Green
FortiGate at the same time. List for the new slot only the serials the active slot does not
hold. The active slot's serials are recorded in its DynamoDB table (item `Category = fortiflex`,
attribute `used_sn_map`):

```bash
aws dynamodb get-item --table-name asg-fgt_asg_track_table \
  --key '{"Category":{"S":"fortiflex"}}' --attributes-to-get used_sn_map
```

(For the green slot the table is `<asg_module_prefix>-green-fgt_asg_track_table`.)

---

## Reading a Plan During the Upgrade

| Step | Expected plan |
|------|---------------|
| Migration (once) | 3 moved, 1–2 to add (attachments), in-place tag and deletion-protection changes, **0 to destroy** |
| Add the new slot | Only the new slot's resources added, **0 to change, 0 to destroy** |
| Cutover / rollback | **1 to change** (the listener) |
| Remove the old slot | Only the old slot's FortiGate resources, target group and attachment destroyed |

Blocks that start with `<= data` are lookups, not changes. Stop if a plan shows a change,
destroy or replacement (`~`, `-`, `-/+`) of something outside the step.

---

## Validated Configurations

The procedure has been run end to end (migration, new slot, cutover, removal of the old slot)
with: `eip` egress mode, 2-arm, dedicated management VPC, two availability zones, BYOL with
FortiFlex, one FortiGate per slot, centralized egress through the Transit Gateway plus two
distributed-egress VPCs, FortiOS 7.6.8 → 8.0.2.

Not yet validated: `nat_gw` egress mode, the on-demand autoscale group, 1-arm mode, three
availability zones, FortiManager integration.
