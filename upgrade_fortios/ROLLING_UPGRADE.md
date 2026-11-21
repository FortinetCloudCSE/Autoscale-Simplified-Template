# Rolling Upgrade — How It Works

## Overview

The rolling upgrade (Path B) replaces instances one at a time within the existing ASGs
(BYOL and On-Demand), secondaries first and primary last. Only one instance is ever out
of service: each replacement must be in service and healthy before the next instance is
touched.

It is not hitless. The group is one instance short during each replacement, and
connections through the instance being replaced are dropped, because autoscale members do
not share session state. It needs two or more instances; the script refuses a
single-instance group unless `--allow-single-instance` is given.

---

## Instance Roles

The FortiGate autoscale Lambda assigns roles to instances:

| Role | ASG attribute | EC2 tag |
|---|---|---|
| Primary | `ProtectedFromScaleIn: true` (only with `primary_scalein_protection = true`) | `Autoscale Role: Primary` |
| Secondary | `ProtectedFromScaleIn: false` | `Autoscale Role: Secondary` |

The scripts identify the primary by the tag, which the Lambda always writes, and fall back
to scale-in protection only when exactly one instance has it.

The primary holds the authoritative config. Secondaries sync from the primary.
The Lambda elects a new primary from existing secondaries when the primary is terminated.

---

## Replacement Sequence

```
Start:   [Primary 7.6.7] [Secondary 7.6.7]   ← both in service, config sync'd

Step 1:  Terminate secondary
         [Primary 7.6.7] [Secondary TERMINATED]

Step 2:  ASG launches replacement
         [Primary 7.6.7] [New Secondary 7.6.8 — initializing]

Step 3:  Wait: GWLB healthy + Autoscale Role: Secondary
         [Primary 7.6.7] [New Secondary 7.6.8 — ready]

Step 4:  Terminate primary (operator confirms)
         [Primary TERMINATED] [New Secondary 7.6.8 — handling all traffic]

Step 5:  Lambda elects new primary from existing secondaries
         [New Primary 7.6.8] [slot vacant]

Step 6:  ASG launches replacement for vacated slot
         [New Primary 7.6.8] [New Secondary 7.6.8 — initializing]

Step 7:  Wait: GWLB healthy + Autoscale Role: Secondary
         [New Primary 7.6.8] [New Secondary 7.6.8 — ready]

Done:    Both instances on 7.6.8, config sync'd
```

For deployments with more than one secondary, Step 1–3 repeats for each secondary
before the primary is replaced.

---

## Replacement Readiness Check

Before each terminate call the script records the instance IDs in the ASG. The
replacement is the instance whose ID is new. The script then waits for it to be:

1. **ASG InService, on the target AMI** — the launch lifecycle hook has completed, which
   happens once the Lambda has attached the extra network interfaces. The instance is not
   yet licensed or configured.
2. **GWLB healthy** — the FortiGate answers the target group's health check.
3. **Tagged `Autoscale Role: Secondary`** — the Lambda has generated the instance's
   bootstrap configuration and sent it.

### What These Checks Do Not Show

None of them shows that config sync from the primary has finished. The Lambda writes the
Secondary tag while it generates the bootstrap configuration; the FortiGate then pulls the
rest of the configuration from the primary by itself, and the script cannot see that.

So the check is made by the operator at the primary gate. On an upgraded secondary:

```
get system status                         # target version and build, licence valid
get system auto-scale                     # role secondary, primary-ip is the primary
show firewall policy | grep -c "edit "    # same count as on the primary
```

**Same-major-version upgrades (e.g. 7.6.7 → 7.6.8):** the design assumes native config
sync works between the two patch versions. This has not been tested here, which is one
more reason the gate is a manual check.

**Cross-major-version upgrades (e.g. 7.4.x → 7.6.x):** native config sync does not work.
The new secondaries come up with the bootstrap configuration only. Run the roll with
`--restore-config FILE` to restore the primary's backup to the new primary afterwards, or
use Path C. Either restore is refused across a minor or major version until the upgrade
path has been checked and `--upgrade-path-verified` is given. See INPLACE.md.

---

## Lambda Role During Replacement

When the ASG launches an instance:

1. The instance enters `Pending:Wait`. On `EC2 Instance-launch Lifecycle Action` the
   Lambda creates and attaches the additional network interfaces and completes the
   lifecycle action. The instance moves to `InService`.
2. On `EC2 Instance Launch Successful` the Lambda:
   - Sets the admin password and adds the instance to DynamoDB
   - Assigns a licence (BYOL file or FortiFlex token)
   - Generates the bootstrap configuration: GENEVE tunnels, `config system auto-scale`
     (role, and the primary's IP for a secondary), and the template's user configuration
   - Tags the instance `Autoscale Role: Secondary` (or `Primary` if there is none)
   - Sends that configuration to the FortiGate
3. The FortiGate syncs the rest of the configuration from the primary itself
   (same-major-version only). The Lambda does not copy the primary's configuration.

When an instance is terminated (`EC2 Instance-terminate Lifecycle Action`), the Lambda:

1. Releases its licence and removes it from DynamoDB
2. If it was the primary, promotes the first running instance in its list: sets it to
   role primary, tags it `Autoscale Role: Primary`, sets `ProtectedFromScaleIn` if
   `primary_scalein_protection` is true, and points the remaining secondaries at it

---

## ASG Process Suspension

During rolling replacement the script suspends three processes on both ASGs to prevent
interference:

| Process | Why suspended |
|---|---|
| `ReplaceUnhealthy` | Prevents ASG from replacing instances the script is managing |
| `AZRebalance` | Prevents ASG from launching/terminating instances for AZ balance |
| `ScheduledActions` | Prevents scheduled scaling from changing capacity mid-upgrade |

Processes are resumed when the roll completes, when it fails, when the operator answers
"no" at a prompt, and on Ctrl-C. The verification phase checks that none is left suspended.

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

## Primary Termination Gate

The script does not prompt to terminate the primary until every secondary has been
replaced and each replacement is InService, GWLB healthy and tagged
`Autoscale Role: Secondary`. It then lists the instances that will stay in service and
waits for the operator, who checks the configuration on one of them (see above).

Until the operator answers, the old primary holds the only complete copy of the running
configuration. Answering "no" leaves it untouched; running the script again later skips
the secondaries already replaced and returns to this prompt.

---

## Tests

`python3 tests/test_inplace_upgrade.py` runs this sequence against a simulated ASG and
Lambda (no AWS calls): groups of one, two and three instances, a hybrid BYOL and On-Demand
group, an abort at the primary gate, a failure mid-roll and a second run after an abort.
It also covers expired credentials, interrupted runs and the FortiFlex serial check.

A rolling replacement has been run once against a live group: two BYOL instances
licensed with FortiFlex, 7.6.7 to 7.6.8. Discovery, the pre-flight, the launch template
update, the secondary replacement, the primary gate and the Lambda's promotion of the
new primary completed, and both instances ended on the target AMI, healthy in the GWLB,
with one primary. The operator's AWS credentials expired during the last wait, so the
final checks were run afterwards and not by that run.

- Pausing on expired credentials, and finishing an interrupted run by running the command
  again, have only been run against the simulator.
- A rolling replacement of a FortiFlex group whose serials were all distinct at the start
  has not been observed live. Both test builds came up with two instances on one serial.
