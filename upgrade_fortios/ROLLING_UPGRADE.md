# Rolling Upgrade — How It Works

## Overview

The rolling upgrade (Path B) replaces instances one at a time within the existing ASG,
secondaries first and primary last. At no point are all instances on the old version
simultaneously unavailable — secondaries handle traffic while the primary is replaced.

---

## Instance Roles

The FortiGate autoscale Lambda assigns roles to instances:

| Role | ASG attribute | EC2 tag |
|---|---|---|
| Primary | `ProtectedFromScaleIn: true` | `Autoscale Role: Primary` |
| Secondary | `ProtectedFromScaleIn: false` | `Autoscale Role: Secondary` |

The primary holds the authoritative config. Secondaries sync from the primary.
The Lambda elects a new primary from existing secondaries when the primary is terminated.

---

## Replacement Sequence

```
Start:   [Primary 7.2.8] [Secondary 7.2.8]   ← both in service, config sync'd

Step 1:  Terminate secondary
         [Primary 7.2.8] [Secondary TERMINATED]

Step 2:  ASG launches replacement
         [Primary 7.2.8] [New Secondary 7.2.13 — initializing]

Step 3:  Wait: GWLB healthy + Autoscale Role: Secondary
         [Primary 7.2.8] [New Secondary 7.2.13 — ready]

Step 4:  Terminate primary (operator confirms)
         [Primary TERMINATED] [New Secondary 7.2.13 — handling all traffic]

Step 5:  Lambda elects new primary from existing secondaries
         [New Primary 7.2.13] [slot vacant]

Step 6:  ASG launches replacement for vacated slot
         [New Primary 7.2.13] [New Secondary 7.2.13 — initializing]

Step 7:  Wait: GWLB healthy + Autoscale Role: Secondary
         [New Primary 7.2.13] [New Secondary 7.2.13 — ready]

Done:    Both instances on 7.2.13, config sync'd
```

For deployments with more than one secondary, Step 1–3 repeats for each secondary
before the primary is replaced.

---

## Secondary Readiness Check

After a new instance is launched, the script waits for three conditions before
proceeding:

1. **ASG InService** — instance passed EC2 health checks and ASG lifecycle hook
2. **GWLB healthy** — instance is passing GWLB health checks on port 6081 (GENEVE)
3. **`Autoscale Role: Secondary` tag** — Lambda completed initialization: license
   assigned, config pushed from primary, instance registered in DynamoDB

All three must be true before the script prompts to terminate the primary.

### Known Issue: GWLB Healthy Before Config Sync Complete

The GWLB health check runs on port 6081 (GENEVE) and reflects whether the FortiGate
is up and passing traffic — **not** whether config sync from the primary is complete.
A new instance will pass GWLB health checks before config sync finishes.

The `Autoscale Role: Secondary` tag is set by the Lambda after it completes its
initialization sequence (license assignment, config upload). However, native
FortiGate-to-FortiGate config sync may still be in progress when the tag appears.

**In practice for same-major-version upgrades (e.g. 7.2.8 → 7.2.13):**
Config sync completes quickly after Lambda initialization. The tag is a reliable
enough signal — by the time the operator reads the prompt and responds, sync is done.

**For cross-major-version upgrades (e.g. 7.4.x → 7.6.x):**
Native config sync does not work between major versions. The Lambda pushes the
DynamoDB bootstrap config to the new secondary instead. The Secondary tag will appear,
but the secondary will not have the primary's runtime config. This is why cross-major
upgrades require Phase 5 config restore — see INPLACE.md.

---

## Lambda Role During Replacement

When a new instance launches, the ASG lifecycle hook triggers the Lambda:

1. Instance enters `Pending:Wait` lifecycle state
2. Lambda fires on `EC2 Instance-launch Lifecycle Action` event
3. Lambda:
   - Adds instance to DynamoDB
   - Retrieves available FortiFlex license, assigns to instance
   - Gets primary IP from DynamoDB
   - Pushes config from primary to new instance via FortiGate API
   - Completes lifecycle action → instance moves to `InService`
   - Tags instance `Autoscale Role: Secondary`
4. FortiGate performs native config sync from primary (same-version only)

When the primary is terminated:

1. Lambda fires on `EC2 Instance-terminate Lifecycle Action`
2. Lambda elects a new primary from remaining InService instances
3. Sets `ProtectedFromScaleIn: true` on the elected instance
4. Tags elected instance `Autoscale Role: Primary`
5. Returns FortiFlex license of terminated instance to pool

---

## ASG Process Suspension

During rolling replacement the script suspends three ASG processes to prevent
interference:

| Process | Why suspended |
|---|---|
| `ReplaceUnhealthy` | Prevents ASG from replacing instances the script is managing |
| `AZRebalance` | Prevents ASG from launching/terminating instances for AZ balance |
| `ScheduledActions` | Prevents scheduled scaling from changing capacity mid-upgrade |

Processes are resumed after rolling replacement completes (or on error).

---

## Primary Termination Gate

The script will not prompt to terminate the primary until **all** secondaries are:
- GWLB healthy
- Tagged `Autoscale Role: Secondary`

This ensures there is always a healthy secondary ready to become primary and forward
traffic the moment the primary is terminated.
