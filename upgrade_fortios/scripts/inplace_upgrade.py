#!/usr/bin/env python3
"""
inplace_upgrade.py — In-place FortiOS upgrade via rolling instance replacement

Reads blue_inventory.json produced by discover.py, re-reads the live ASG state,
and performs one of:

  Path A (desired=0, no conf file in the state directory):
      Update launch templates with the target AMI. Done.

  Path C (desired=0, conf file present in the state directory):
      Update launch templates, launch a single primary, wait for it to be
      healthy, restore the config backup (REST API with --fgt-api-key, otherwise
      the operator restores it in the GUI), wait for the reboot, then scale out.

  Path B (instances running):
      Update launch templates, then replace instances one at a time across the
      BYOL and On-Demand ASGs: secondaries first, primary last. Each replacement
      is identified by its new instance ID, and the script waits for it to be
      InService, healthy in the GWLB target group and tagged Secondary before
      it touches the next instance. Instances already on the target AMI are
      skipped, so a run that was aborted can simply be started again.

      A config restore after the roll is opt-in (--restore-config FILE). It is
      meant for cross-major-version upgrades, where native config sync between
      the old primary and the new secondaries does not work. It reboots the new
      primary. Same-major upgrades do not need it.

ASG processes suspended for the roll are always resumed, including when the
operator answers "no" at a prompt or presses Ctrl-C.

If the AWS credentials expire mid-run the script pauses and asks for them to be
renewed. If they are not, it stops and prints how to resume the ASG processes.
Running it again is always safe: it resumes processes an interrupted run left
suspended and, when nothing is left to replace, only prints the final status.
"""

import argparse
import boto3
import glob
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import discover


POLL_INTERVAL = 15   # seconds between status polls
MAX_WAIT_MINS = 10   # minutes to wait for replacement to become InService
MINS_PER_REPLACEMENT = 12   # observed: about 10 minutes from terminate to GWLB healthy

# Appended to every AWS CLI command the script prints, so a command pasted into a
# shell whose default region differs from the deployment's still hits the right one.
CLI_REGION = ''


# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

def load_inventory(path):
    with open(path) as f:
        return json.load(f)


def confirm(prompt):
    """Prompt operator for explicit confirmation. Exit on anything other than y/yes."""
    resp = input(f"\n{prompt} [y/N]: ").strip().lower()
    if resp not in ('y', 'yes'):
        print("Aborted.")
        sys.exit(0)


def elapsed_mins(start):
    return (time.time() - start) / 60


def ts():
    return datetime.now(timezone.utc).strftime('%H:%M:%S')


def banner(msg):
    width = 60
    print()
    print("─" * width)
    print(f"  {msg}")
    print("─" * width)


# ─────────────────────────────────────────────
# AWS credentials
# ─────────────────────────────────────────────

class CredentialsExpired(BaseException):
    """
    The AWS credentials expired and the operator chose not to renew them.

    Derived from BaseException, like KeyboardInterrupt: it means "stop the run"
    and has to pass through the `except Exception` handlers of the polling loops.
    """


_EXPIRED_ERROR_CODES = {'ExpiredToken', 'ExpiredTokenException', 'RequestExpired',
                        'TokenRefreshRequired'}
_EXPIRED_ERROR_TYPES = {'UnauthorizedSSOTokenError', 'TokenRetrievalError', 'SSOTokenLoadError',
                        'CredentialRetrievalError', 'NoCredentialsError'}


def is_expired_credentials_error(exc):
    """True if an AWS call failed because the credentials are expired or gone."""
    code = (getattr(exc, 'response', None) or {}).get('Error', {}).get('Code', '')
    if code in _EXPIRED_ERROR_CODES or type(exc).__name__ in _EXPIRED_ERROR_TYPES:
        return True
    # botocore raises a bare RuntimeError when a refresh hands back credentials
    # that are already expired (credential_process, exported session variables).
    return isinstance(exc, RuntimeError) and 'credentials are still expired' in str(exc)


def ask_to_renew_credentials(exc):
    """Pause the run on expired credentials. Returns True to retry, False to stop."""
    print()
    print(f"  [{ts()}] AWS credentials have expired: {exc}")
    print("  The upgrade is paused. AWS carries on with whatever was already started.")
    print("  Renew the credentials in another terminal (for example 'aws sso login'),")
    print("  then press Enter here to continue.")
    print("  If your credentials are environment variables exported in this shell, this")
    print("  process cannot see new ones: answer q, renew them, and run the same command")
    print("  again. It continues from where it stopped.")
    try:
        resp = input("\nPress Enter to retry, or q to stop: ").strip().lower()
    except EOFError:
        return False
    return resp not in ('q', 'quit', 'n', 'no')


def new_aws_client(service, region):
    """A client from a new session, so that renewed credentials are picked up."""
    return boto3.session.Session().client(service, region_name=region)


class RenewingClient:
    """
    A boto3 client that survives its credentials expiring mid-run.

    When a call fails because the credentials have expired, the operator is asked
    to renew them, the client is rebuilt from a new session and the call is
    repeated. If the operator declines, CredentialsExpired is raised, once, and
    every later call raises it without asking again.
    """
    generation = 0      # bumped on every renewal, so the sibling clients rebuild too
    gave_up = False

    def __init__(self, service, region, factory=new_aws_client):
        self._service, self._region, self._factory = service, region, factory
        self._generation = RenewingClient.generation
        self._client = factory(service, region)

    def _current(self):
        if self._generation != RenewingClient.generation:
            self._client = self._factory(self._service, self._region)
            self._generation = RenewingClient.generation
        return self._client

    def __getattr__(self, name):
        if name.startswith('_'):
            raise AttributeError(name)
        if not callable(getattr(self._client, name)):
            return getattr(self._client, name)

        def call(*args, **kwargs):
            while True:
                try:
                    return getattr(self._current(), name)(*args, **kwargs)
                except Exception as e:
                    if not is_expired_credentials_error(e):
                        raise
                    if RenewingClient.gave_up or not ask_to_renew_credentials(e):
                        RenewingClient.gave_up = True
                        raise CredentialsExpired(str(e)) from e
                    RenewingClient.generation += 1
        return call


def credentials_expiry():
    """When the current AWS credentials expire (aware datetime), or None if unknown or never."""
    try:
        return getattr(boto3.session.Session().get_credentials(), '_expiry_time', None)
    except Exception:
        return None


def credentials_warning(replacements, now=None, expiry=None):
    """
    Return warning lines if the credentials expire before `replacements` instance
    replacements can finish, else an empty list.
    """
    expiry = expiry or credentials_expiry()
    if not expiry or not replacements:
        return []
    now = now or datetime.now(timezone.utc)
    left = (expiry - now).total_seconds() / 60
    needed = replacements * MINS_PER_REPLACEMENT
    if left >= needed:
        return []
    return [
        f"AWS credentials expire at {expiry.astimezone(timezone.utc).strftime('%H:%M')} UTC, "
        f"in {max(0, int(left))} min. Replacing {replacements} instance(s) takes about {needed} min.",
        "If they cannot renew themselves (SSO and assumed roles usually can), renew them before",
        "you continue. If they expire mid-run, the script pauses and asks you to renew them.",
    ]


# ─────────────────────────────────────────────
# Live state
# ─────────────────────────────────────────────

def asg_targets_from_inventory(inventory):
    """
    Return one entry per ASG in the inventory:
      {license_type, asg_name, target_ami_id, lt}
    target_ami_id is the AMI every instance of that ASG must end up on.
    """
    lts = inventory.get('launch_templates', {})
    targets = []
    for lic, asg in inventory.get('autoscale_groups', {}).items():
        lt = lts.get(lic, {})
        targets.append({
            'license_type': lic,
            'asg_name': asg['asg_name'],
            'target_ami_id': lt.get('target_ami_id'),
            'lt': lt,
        })
    return targets


def get_live_asg(autoscaling, asg_name):
    """Return the live ASG description, or None if it does not exist."""
    resp = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    if not resp['AutoScalingGroups']:
        return None
    return resp['AutoScalingGroups'][0]


def get_asg_instances(autoscaling, asg_name):
    """Return list of instance dicts currently in the ASG."""
    asg = get_live_asg(autoscaling, asg_name)
    return asg.get('Instances', []) if asg else []


def get_instance_details(ec2, instance_ids):
    """Return {instance_id: {ami, state, role}} read from EC2."""
    details = {}
    if not instance_ids:
        return details
    resp = ec2.describe_instances(InstanceIds=list(instance_ids))
    for res in resp['Reservations']:
        for inst in res['Instances']:
            tags = {t['Key']: t['Value'] for t in inst.get('Tags', [])}
            details[inst['InstanceId']] = {
                'ami': inst.get('ImageId'),
                'state': inst['State']['Name'],
                'role': tags.get('Autoscale Role', ''),
            }
    return details


def get_instance_ami(ec2, instance_id):
    """Return the AMI ID of an EC2 instance, or None."""
    try:
        return get_instance_details(ec2, [instance_id])[instance_id]['ami']
    except Exception:
        return None


def live_members(autoscaling, ec2, asg_targets):
    """
    Return every instance in every FortiGate ASG, read live from AWS:
      {instance_id, asg_name, license_type, lifecycle, health, protected,
       role, ami, state, target_ami_id}
    """
    members = []
    for t in asg_targets:
        for inst in get_asg_instances(autoscaling, t['asg_name']):
            members.append({
                'instance_id': inst['InstanceId'],
                'asg_name': t['asg_name'],
                'license_type': t['license_type'],
                'lifecycle': inst['LifecycleState'],
                'health': inst['HealthStatus'],
                'protected': inst.get('ProtectedFromScaleIn', False),
                'target_ami_id': t['target_ami_id'],
            })
    details = get_instance_details(ec2, [m['instance_id'] for m in members])
    for m in members:
        d = details.get(m['instance_id'], {})
        m['ami'] = d.get('ami')
        m['state'] = d.get('state', 'unknown')
        m['role'] = d.get('role', '')
    return members


def find_primary(members):
    """
    Return the primary member, or None if it cannot be identified.

    The Lambda always tags the elected primary 'Autoscale Role: Primary'.
    Scale-in protection is only set when primary_scalein_protection is true, so
    it is the fallback, and only when exactly one instance carries it.
    """
    tagged = [m for m in members if m['role'] == 'Primary']
    if len(tagged) == 1:
        return tagged[0]
    if len(tagged) > 1:
        return None
    protected = [m for m in members if m['protected']]
    if len(protected) == 1:
        return protected[0]
    return None


def is_gwlb_healthy(elbv2, tg_arn, instance_id):
    """Return True if instance is healthy in the GWLB target group."""
    try:
        resp = elbv2.describe_target_health(
            TargetGroupArn=tg_arn,
            Targets=[{'Id': instance_id}]
        )
        for t in resp['TargetHealthDescriptions']:
            if t['TargetHealth']['State'] == 'healthy':
                return True
        return False
    except Exception:
        return False


def unhealthy_gwlb_targets(elbv2, tg_arn):
    """Return [(instance_id, state)] for every target that is not healthy."""
    resp = elbv2.describe_target_health(TargetGroupArn=tg_arn)
    return [(t['Target']['Id'], t['TargetHealth']['State'])
            for t in resp['TargetHealthDescriptions']
            if t['TargetHealth']['State'] != 'healthy']


# ─────────────────────────────────────────────
# FortiFlex serial numbers
# ─────────────────────────────────────────────

class FlexSerials:
    """
    Reads the FortiFlex bookkeeping the autoscale Lambda keeps in its DynamoDB
    table: which serial number it issued to which instance (used_sn_map) and
    which serials it considers free (available_sn_list).

    Only those two attributes are requested. The same item also holds the
    Lambda's FortiFlex API tokens, which are never read.
    """

    def __init__(self, dynamodb, table_name):
        self.dynamodb, self.table_name = dynamodb, table_name
        self.skipped = None     # why the last read could not be done, if it could not

    def read(self):
        """Return ({instance_id: serial}, {available serials}), or None if unreadable."""
        self.skipped = None
        try:
            item = self.dynamodb.get_item(
                TableName=self.table_name,
                Key={'Category': {'S': 'fortiflex'}},
                ProjectionExpression='available_sn_list, used_sn_map',
            ).get('Item') or {}
        except Exception as e:
            self.skipped = f"could not read {self.table_name}: {e}"
            return None
        used = {iid: v.get('S', '') for iid, v in item.get('used_sn_map', {}).get('M', {}).items()}
        return used, set(item.get('available_sn_list', {}).get('SS', []))


def flex_serial_report(flex, instance_ids):
    """
    Check that every running instance has its own FortiFlex serial.

    Returns (problems, serials): problems is a list of sentences, empty when the
    licensing is consistent or FortiFlex is not in use; serials is
    {instance_id: serial} for the running instances the Lambda has a record of.
    """
    state = flex.read() if flex else None
    if not state:
        return [], {}
    used, available = state
    serials = {i: used[i] for i in instance_ids if used.get(i)}
    by_serial = {}
    for iid, sn in serials.items():
        by_serial.setdefault(sn, []).append(iid)

    problems = []
    for sn, ids in sorted(by_serial.items()):
        if len(ids) > 1:
            problems.append(
                f"FortiFlex serial {sn} is issued to {len(ids)} instances ({', '.join(sorted(ids))}). "
                "Only one FortiGate can hold a valid license for a serial.")
        if sn in available:
            problems.append(
                f"FortiFlex serial {sn} is in use by {', '.join(sorted(ids))} but the Lambda also "
                "lists it as available, so it will issue it again to the next instance that launches.")
    return problems, serials


FLEX_FIX_HINT = [
    "To give each FortiGate its own serial: in the FortiFlex portal generate a",
    "token for an unused serial, apply it on one FortiGate with 'execute vm-license <token>',",
    "and correct used_sn_map and available_sn_list in the Lambda's DynamoDB table to match.",
]


# ─────────────────────────────────────────────
# Launch template update
# ─────────────────────────────────────────────

def ensure_launch_template(ec2, autoscaling, lt, asg_name):
    """
    Make the ASG launch the target AMI.

    If the newest launch template version already carries the target AMI (for
    example because fortios_version was changed in terraform.tfvars and applied
    first), that version is reused. Otherwise a new version is created from
    $Latest with only the AMI changed. The ASG is then pointed at that version.

    Returns {asg_name, lt_id, previous_version, new_version} so the change can
    be rolled back to the version the ASG used before.
    """
    lt_id, lt_name, target_ami_id = lt['id'], lt['name'], lt['target_ami_id']
    license_type = lt.get('license_type', '')

    live = get_live_asg(autoscaling, asg_name)
    previous_version = None
    if live and live.get('LaunchTemplate'):
        previous_version = str(live['LaunchTemplate'].get('Version'))

    latest = ec2.describe_launch_template_versions(
        LaunchTemplateId=lt_id, Versions=['$Latest']
    )['LaunchTemplateVersions'][0]

    if latest['LaunchTemplateData'].get('ImageId') == target_ami_id:
        new_version = str(latest['VersionNumber'])
        print(f"  {lt_name} ({license_type}): version {new_version} already uses {target_ami_id} — reusing it.")
    else:
        print(f"  Creating new version of {lt_name} ({license_type}) with AMI {target_ami_id}...")
        resp = ec2.create_launch_template_version(
            LaunchTemplateId=lt_id,
            SourceVersion='$Latest',
            LaunchTemplateData={'ImageId': target_ami_id},
            VersionDescription=f'FortiOS upgrade to {target_ami_id}',
        )
        new_version = str(resp['LaunchTemplateVersion']['VersionNumber'])
        print(f"    Created version {new_version}")

    if previous_version == new_version:
        print(f"  {asg_name} already launches version {new_version}.")
    else:
        print(f"  Updating {asg_name}: launch template version {previous_version} → {new_version}...")
        autoscaling.update_auto_scaling_group(
            AutoScalingGroupName=asg_name,
            LaunchTemplate={'LaunchTemplateId': lt_id, 'Version': new_version},
        )
        print("    Done.")

    return {
        'asg_name': asg_name,
        'lt_id': lt_id,
        'previous_version': previous_version,
        'new_version': new_version,
    }


def update_all_launch_templates(ec2, autoscaling, inventory, state_dir):
    """Update the launch template of every ASG and record how to roll back."""
    changes = []
    for t in asg_targets_from_inventory(inventory):
        lt = t['lt']
        if not lt.get('target_ami_id'):
            print(f"  Skipping {t['asg_name']} — no target AMI in the inventory")
            continue
        changes.append(ensure_launch_template(ec2, autoscaling, lt, t['asg_name']))

    changed = [c for c in changes if c['previous_version'] not in (None, c['new_version'])]
    if changed:
        path = os.path.join(state_dir, 'inplace_rollback.json')
        try:
            with open(path, 'w') as f:
                json.dump({'recorded_at': datetime.now(timezone.utc).isoformat(),
                           'launch_templates': changed}, f, indent=2)
            print()
            print(f"  Previous launch template versions saved to {path}")
        except OSError as e:
            print(f"  Warning: could not write {path}: {e}")
        print("  To roll back, point each ASG at its previous version and replace the instances again:")
        for c in changed:
            print(f"    aws autoscaling update-auto-scaling-group "
                  f"--auto-scaling-group-name {c['asg_name']} "
                  f"--launch-template LaunchTemplateId={c['lt_id']},Version={c['previous_version']}"
                  f"{CLI_REGION}")
    return changes


# ─────────────────────────────────────────────
# ASG process suspension
# ─────────────────────────────────────────────

SUSPEND_PROCESSES = ['ReplaceUnhealthy', 'AZRebalance', 'ScheduledActions']


def suspend_asg_processes(autoscaling, asg_name):
    print(f"  Suspending ASG processes on {asg_name}: {', '.join(SUSPEND_PROCESSES)}")
    try:
        autoscaling.suspend_processes(
            AutoScalingGroupName=asg_name,
            ScalingProcesses=SUSPEND_PROCESSES,
        )
    except Exception as e:
        print(f"  Warning: could not suspend processes on {asg_name}: {e}")


def resume_command(asg_name):
    return (f"aws autoscaling resume-processes --auto-scaling-group-name {asg_name} "
            f"--scaling-processes {' '.join(SUSPEND_PROCESSES)}{CLI_REGION}")


def resume_asg_processes(autoscaling, asg_name):
    print(f"  Resuming ASG processes on {asg_name}: {', '.join(SUSPEND_PROCESSES)}")
    try:
        autoscaling.resume_processes(
            AutoScalingGroupName=asg_name,
            ScalingProcesses=SUSPEND_PROCESSES,
        )
    except (Exception, CredentialsExpired) as e:
        # CredentialsExpired is caught here too: the run is already stopping, and
        # the operator needs the command below more than a second traceback.
        print(f"  WARNING: could not resume processes on {asg_name}: {e}")
        print("  They are still suspended. Running the same upgrade command again resumes them,")
        print("  or resume them by hand:")
        print(f"    {resume_command(asg_name)}")


def upgrade_suspended_processes(autoscaling, asg_name):
    """The processes this script suspends that are currently suspended on the ASG."""
    live = get_live_asg(autoscaling, asg_name)
    return [p['ProcessName'] for p in (live or {}).get('SuspendedProcesses', [])
            if p['ProcessName'] in SUSPEND_PROCESSES]


# ─────────────────────────────────────────────
# Instance replacement polling
# ─────────────────────────────────────────────

def wait_for_replacement(autoscaling, ec2, asg_name, before_ids, target_ami_id):
    """
    Poll the ASG until an instance that was not in the ASG before the terminate
    call (before_ids) is InService and Healthy. Returns the new instance ID.

    The replacement is identified by its instance ID being new. An instance that
    was already in the group, upgraded or not, is never mistaken for it.
    """
    print(f"    [{ts()}] Waiting for the ASG to launch a replacement in {asg_name}...")
    start = time.time()
    last_status = None
    while elapsed_mins(start) < MAX_WAIT_MINS:
        new = [i for i in get_asg_instances(autoscaling, asg_name)
               if i['InstanceId'] not in before_ids]
        for inst in new:
            if inst['LifecycleState'] == 'InService' and inst['HealthStatus'] == 'Healthy':
                ami = get_instance_ami(ec2, inst['InstanceId'])
                if ami != target_ami_id:
                    raise RuntimeError(
                        f"Replacement {inst['InstanceId']} launched from AMI {ami}, "
                        f"expected {target_ami_id}. Check the ASG's launch template version.")
                print(f"    [{ts()}] Replacement {inst['InstanceId']} is InService on target AMI.")
                return inst['InstanceId']
        status = ', '.join(f"{i['InstanceId']}={i['LifecycleState']}" for i in new) or 'not launched yet'
        if status != last_status:
            print(f"    [{ts()}] Replacement: {status}")
            last_status = status
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"No replacement became InService in {asg_name} within {MAX_WAIT_MINS} minutes")


def wait_for_secondary_ready(ec2, elbv2, tg_arn, instance_id):
    """
    Poll until a replacement instance has been initialized by the Lambda:
      - EC2 state: running
      - GWLB target group: healthy
      - EC2 tag 'Autoscale Role': Secondary

    These show the instance is licensed, configured as a secondary and passing
    traffic. They do not show that config sync from the primary has finished:
    that is checked on the FortiGate before the primary is terminated.
    """
    print(f"    [{ts()}] Waiting for {instance_id}: running, GWLB healthy, tagged Secondary...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS * 3:
        try:
            d = get_instance_details(ec2, [instance_id])[instance_id]
            gwlb_ok = is_gwlb_healthy(elbv2, tg_arn, instance_id)
            status = (f"ec2={d['state']}, gwlb={'healthy' if gwlb_ok else 'unhealthy'}, "
                      f"role={d['role'] or 'unset'}")
            if d['state'] == 'running' and gwlb_ok and d['role'] == 'Secondary':
                print(f"    [{ts()}] {instance_id}: {status} — ready.")
                return
            print(f"    [{ts()}] {instance_id}: {status} — waiting...")
        except Exception as e:
            print(f"    [{ts()}] Warning: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"{instance_id} did not become a healthy secondary within {MAX_WAIT_MINS * 3} minutes")


def wait_for_new_primary(autoscaling, ec2, asg_targets, old_primary_id):
    """Poll until the Lambda has tagged another InService instance as Primary."""
    print(f"    [{ts()}] Waiting for Lambda to elect new primary...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS:
        for m in live_members(autoscaling, ec2, asg_targets):
            if (m['instance_id'] != old_primary_id and m['role'] == 'Primary'
                    and m['lifecycle'] == 'InService'):
                print(f"    [{ts()}] New primary elected: {m['instance_id']}")
                return m['instance_id']
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"New primary not elected within {MAX_WAIT_MINS} minutes")


# ─────────────────────────────────────────────
# Rolling replacement (Path B)
# ─────────────────────────────────────────────

def preflight_rolling(autoscaling, ec2, elbv2, asg_targets, tg_arn, allow_single=False,
                      flex=None):
    """
    Check the group is in a state that can be rolled safely. Nothing is changed.
    Returns (primary, secondaries_to_replace, already_on_target, problems).
    A non-empty problems list means the roll must not start.
    """
    members = live_members(autoscaling, ec2, asg_targets)
    problems = []

    not_in_service = [m for m in members if m['lifecycle'] != 'InService']
    if not_in_service:
        problems.append("Instances not InService: " + ', '.join(
            f"{m['instance_id']} ({m['lifecycle']})" for m in not_in_service))

    try:
        bad = unhealthy_gwlb_targets(elbv2, tg_arn)
        if bad:
            problems.append("GWLB targets not healthy: " + ', '.join(f"{i} ({s})" for i, s in bad))
    except Exception as e:
        problems.append(f"Could not read GWLB target health: {e}")

    primary = find_primary(members)
    if not primary:
        tagged = [m['instance_id'] for m in members if m['role'] == 'Primary']
        problems.append(
            f"Cannot identify the primary (instances tagged 'Autoscale Role: Primary': {tagged or 'none'}). "
            "Exactly one is required.")

    if len(members) < 2 and not allow_single:
        problems.append(
            f"Only {len(members)} instance in the group. Replacing it means an outage until its "
            "replacement boots, and any configuration held only on that FortiGate is lost. "
            "Raise desired capacity to 2 and wait for the second instance to sync, or pass "
            "--allow-single-instance to accept the outage.")

    # Replacing instances re-issues FortiFlex tokens. If two instances already
    # share a serial, every replacement moves the valid license from one to the
    # other, so the roll must not start until each has its own.
    # With nothing left to replace there is no roll to refuse: the final status
    # reports the serials instead.
    on_target = [m for m in members if m['ami'] == m['target_ami_id']]
    secondaries = [m for m in members
                   if m is not primary and m['ami'] != m['target_ami_id']]
    if len(on_target) < len(members):
        flex_problems, _ = flex_serial_report(flex, [m['instance_id'] for m in members])
        problems.extend(flex_problems)
    return primary, secondaries, on_target, problems


def terminate_instance(autoscaling, instance_id):
    """Terminate instance via ASG — keeps desired capacity, ASG launches replacement."""
    print(f"    [{ts()}] Terminating {instance_id} (ASG will launch replacement)...")
    autoscaling.terminate_instance_in_auto_scaling_group(
        InstanceId=instance_id,
        ShouldDecrementDesiredCapacity=False,
    )


def replace_instance(autoscaling, ec2, elbv2, tg_arn, member):
    """Terminate one instance and wait for its replacement to be a ready secondary."""
    asg_name = member['asg_name']
    before_ids = {i['InstanceId'] for i in get_asg_instances(autoscaling, asg_name)}
    terminate_instance(autoscaling, member['instance_id'])
    new_id = wait_for_replacement(autoscaling, ec2, asg_name, before_ids, member['target_ami_id'])
    wait_for_secondary_ready(ec2, elbv2, tg_arn, new_id)
    return new_id


def check_serial_after_replacement(flex, autoscaling, ec2, asg_targets, new_id):
    """
    After a replacement is licensed, confirm the Lambda gave it a serial no other
    running instance holds. Raises RuntimeError if not, which stops the roll
    before the next instance (and before the primary) is touched.
    """
    if not flex:
        return
    ids = [m['instance_id'] for m in live_members(autoscaling, ec2, asg_targets)]
    problems, serials = flex_serial_report(flex, ids)
    if flex.skipped:
        print(f"    [{ts()}] FortiFlex serial check skipped: {flex.skipped}")
    elif problems:
        raise RuntimeError(
            f"FortiFlex licensing is inconsistent after replacing an instance with {new_id}: "
            + ' '.join(problems) + ' ' + ' '.join(FLEX_FIX_HINT))
    elif new_id in serials:
        print(f"    [{ts()}] FortiFlex serial of {new_id}: {serials[new_id]} (not shared)")
    elif serials:
        print(f"    [{ts()}] WARNING: the Lambda has no FortiFlex serial recorded for {new_id}. "
              "Check its license status on the FortiGate.")


def rolling_replacement(autoscaling, ec2, elbv2, asg_targets, tg_arn, primary, secondaries,
                        flex=None):
    """Replace instances one at a time: secondaries first, primary last."""
    print(f"  Primary:     {primary['instance_id']}  ({primary['asg_name']})")
    print(f"  Secondaries: {[m['instance_id'] for m in secondaries] or 'none to replace'}")

    # ── Replace secondaries ───────────────────
    for n, sec in enumerate(secondaries, 1):
        banner(f"Phase 3.{n}: Replacing secondary {sec['instance_id']} "
               f"({n}/{len(secondaries)}, {sec['asg_name']})")
        new_id = replace_instance(autoscaling, ec2, elbv2, tg_arn, sec)
        check_serial_after_replacement(flex, autoscaling, ec2, asg_targets, new_id)
        print(f"    [{ts()}] Secondary replacement complete: {new_id}")

    # ── Replace primary (last) ────────────────
    if primary['ami'] == primary['target_ami_id']:
        print()
        print(f"  Primary {primary['instance_id']} is already on the target AMI — not replaced.")
        return primary['instance_id']

    banner(f"Phase 3.{len(secondaries) + 1}: Replacing primary {primary['instance_id']}")

    members = live_members(autoscaling, ec2, asg_targets)
    survivors = [m for m in members if m['instance_id'] != primary['instance_id']]
    if survivors:
        print("  Instances that stay in service while the primary is replaced:")
        for m in survivors:
            on_target = 'target AMI' if m['ami'] == m['target_ami_id'] else f"AMI {m['ami']}"
            print(f"    {m['instance_id']}  role={m['role'] or 'unset'}  {on_target}")
        print()
        print("  Before answering, check on one of those FortiGates that the configuration has")
        print("  arrived from the primary (firmware version, firewall policy count, routes)")
        print("  and that 'get system status' shows License Status: Valid.")
        print("  Once the primary is terminated, a secondary's copy is the only copy.")
        confirm(f"Terminate primary {primary['instance_id']}?")
    else:
        print("  WARNING: there is no other instance. Traffic stops until the replacement is in")
        print("  service, and the replacement starts from the bootstrap configuration only.")
        confirm(f"Terminate the only instance {primary['instance_id']} and accept the outage?")

    asg_name = primary['asg_name']
    before_ids = {i['InstanceId'] for i in get_asg_instances(autoscaling, asg_name)}
    terminate_instance(autoscaling, primary['instance_id'])

    if survivors:
        # The Lambda promotes a surviving secondary; the ASG launches a new
        # instance for the vacated slot, which joins as a secondary.
        new_primary_id = wait_for_new_primary(autoscaling, ec2, asg_targets, primary['instance_id'])
        new_id = wait_for_replacement(autoscaling, ec2, asg_name, before_ids, primary['target_ami_id'])
        wait_for_secondary_ready(ec2, elbv2, tg_arn, new_id)
    else:
        new_id = wait_for_replacement(autoscaling, ec2, asg_name, before_ids, primary['target_ami_id'])
        new_primary_id = wait_for_new_primary(autoscaling, ec2, asg_targets, primary['instance_id'])
        wait_for_instance_recovery(ec2, elbv2, tg_arn, new_id)

    print(f"    [{ts()}] Primary replacement complete.")
    print(f"    New primary (by Lambda election): {new_primary_id}")
    return new_primary_id


# ─────────────────────────────────────────────
# Verification (Phase 4)
# ─────────────────────────────────────────────

def verify(autoscaling, ec2, elbv2, asg_targets, tg_arn, title="Phase 4: Verification",
           flex=None):
    """Verify every instance in every ASG is on its target AMI, GWLB healthy, one primary."""
    banner(title)

    members = live_members(autoscaling, ec2, asg_targets)
    passed = True

    def check(ok, text, details=()):
        nonlocal passed
        print(f"  [{'✓' if ok else '✗'}] {text}")
        for d in details:
            print(f"      {d}")
        if not ok:
            passed = False

    not_in_service = [m for m in members if m['lifecycle'] != 'InService']
    check(not not_in_service, f"All ASG instances InService  ({len(members)} total)",
          [f"{m['instance_id']}: {m['lifecycle']}" for m in not_in_service])

    wrong_ami = [m for m in members if m['ami'] != m['target_ami_id']]
    check(not wrong_ami, "All instances running their target AMI",
          [f"{m['instance_id']} ({m['asg_name']}): AMI {m['ami']} (expected {m['target_ami_id']})"
           for m in wrong_ami])

    try:
        bad = unhealthy_gwlb_targets(elbv2, tg_arn)
        check(not bad, "GWLB target group: all targets healthy", [f"{i}: {s}" for i, s in bad])
    except Exception as e:
        check(False, f"GWLB health check failed: {e}")

    primaries = [m['instance_id'] for m in members if m['role'] == 'Primary']
    check(len(primaries) == 1, f"Exactly one primary: {primaries or 'NONE'}")

    for t in asg_targets:
        if not t['target_ami_id']:
            continue
        try:
            launches = asg_launch_ami(autoscaling, ec2, t['asg_name'])
            check(launches == t['target_ami_id'],
                  f"{t['asg_name']} launches new instances from the target AMI",
                  [] if launches == t['target_ami_id']
                  else [f"its launch template version uses {launches} (expected {t['target_ami_id']})"])
        except Exception as e:
            check(False, f"Could not read the launch template version of {t['asg_name']}: {e}")

    for t in asg_targets:
        suspended = upgrade_suspended_processes(autoscaling, t['asg_name'])
        check(not suspended, f"No upgrade-suspended processes left on {t['asg_name']}",
              [f"still suspended: {', '.join(suspended)}",
               f"resume: {resume_command(t['asg_name'])}"] if suspended else [])

    serials = {}
    if flex:
        flex_problems, serials = flex_serial_report(flex, [m['instance_id'] for m in members])
        if flex.skipped:
            print(f"  [-] FortiFlex serial check skipped: {flex.skipped}")
        elif serials:
            check(not flex_problems, "Each instance has its own FortiFlex serial",
                  flex_problems + (FLEX_FIX_HINT if flex_problems else []))

    print()
    print("  Instances:")
    for m in members:
        serial = f"  serial={serials[m['instance_id']]}" if m['instance_id'] in serials else ''
        print(f"    {m['instance_id']}  {m['asg_name']}  {m['lifecycle']}  "
              f"role={m['role'] or 'unset'}  ami={m['ami']}{serial}")

    return passed


def asg_launch_ami(autoscaling, ec2, asg_name):
    """The AMI of the launch template version the ASG currently launches from."""
    lt = (get_live_asg(autoscaling, asg_name) or {}).get('LaunchTemplate') or {}
    if not lt:
        return None
    versions = ec2.describe_launch_template_versions(
        LaunchTemplateId=lt['LaunchTemplateId'], Versions=[str(lt['Version'])]
    )['LaunchTemplateVersions']
    return versions[0]['LaunchTemplateData'].get('ImageId') if versions else None


# ─────────────────────────────────────────────
# Path C helpers
# ─────────────────────────────────────────────

def find_conf_file(state_dir):
    """Return path to .conf file in state directory, or None if not found."""
    matches = glob.glob(os.path.join(state_dir, '*.conf'))
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    # Multiple — prefer blue_primary_config.conf
    for m in matches:
        if 'blue_primary_config' in os.path.basename(m):
            return m
    return matches[0]


def scale_asg(autoscaling, asg_name, min_size, desired, max_size):
    """Update ASG min/desired/max capacity."""
    print(f"  Setting {asg_name}: min={min_size}, desired={desired}, max={max_size}")
    autoscaling.update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        MinSize=min_size,
        MaxSize=max_size,
        DesiredCapacity=desired,
    )


def get_instance_management_ip(ec2, instance_id, intf_index=0):
    """Return the private IP of the management network interface."""
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        inst = resp['Reservations'][0]['Instances'][0]
        for eni in inst.get('NetworkInterfaces', []):
            if eni['Attachment']['DeviceIndex'] == intf_index:
                return eni['PrivateIpAddress']
        return inst.get('PrivateIpAddress')
    except Exception as e:
        print(f"    Warning: could not get management IP for {instance_id}: {e}")
        return None


def wait_for_primary_instance(autoscaling, ec2, elbv2, asg_name, tg_arn, target_ami_id):
    """
    Poll until an instance is:
      - EC2 state: running
      - ASG lifecycle: InService
      - GWLB target group: healthy
      - EC2 tag Autoscale Role: Primary
      - Running the target AMI
    Returns the instance ID.
    """
    print(f"    [{ts()}] Waiting for instance: running + GWLB healthy + tagged Primary...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS * 3:  # allow up to 30 min for fresh launch
        instances = get_asg_instances(autoscaling, asg_name)
        for inst in instances:
            if inst['LifecycleState'] != 'InService':
                continue
            instance_id = inst['InstanceId']
            try:
                resp = ec2.describe_instances(InstanceIds=[instance_id])
                ec2_inst = resp['Reservations'][0]['Instances'][0]
                state = ec2_inst['State']['Name']
                if state != 'running':
                    print(f"    [{ts()}] {instance_id}: ec2={state} — waiting...")
                    continue
                tags = {t['Key']: t['Value'] for t in ec2_inst.get('Tags', [])}
                role = tags.get('Autoscale Role', '')
                ami = ec2_inst.get('ImageId')
                gwlb_ok = is_gwlb_healthy(elbv2, tg_arn, instance_id)
                status = f"ec2={state}, gwlb={'healthy' if gwlb_ok else 'unhealthy'}, role={role or 'unset'}"
                if state == 'running' and gwlb_ok and role == 'Primary' and ami == target_ami_id:
                    print(f"    [{ts()}] {instance_id}: {status} — ready.")
                    return instance_id
                print(f"    [{ts()}] {instance_id}: {status} — waiting...")
            except Exception as e:
                print(f"    [{ts()}] Warning: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"No Primary instance appeared within 30 minutes")


def wait_for_primary_after_reboot(autoscaling, ec2, elbv2, asg_name, tg_arn, instance_id):
    """
    After config restore and reboot, wait for the same instance to be:
      - EC2 state: running
      - GWLB target group: healthy
      - EC2 tag Autoscale Role: Primary
    """
    print(f"    [{ts()}] Waiting for {instance_id}: running + GWLB healthy + tagged Primary...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS * 2:
        try:
            resp = ec2.describe_instances(InstanceIds=[instance_id])
            inst = resp['Reservations'][0]['Instances'][0]
            state = inst['State']['Name']
            tags = {t['Key']: t['Value'] for t in inst.get('Tags', [])}
            role = tags.get('Autoscale Role', '')
            gwlb_ok = is_gwlb_healthy(elbv2, tg_arn, instance_id)
            status = f"ec2={state}, gwlb={'healthy' if gwlb_ok else 'unhealthy'}, role={role or 'unset'}"
            if state == 'running' and gwlb_ok and role == 'Primary':
                print(f"    [{ts()}] {instance_id}: {status} — ready.")
                return
            print(f"    [{ts()}] {instance_id}: {status} — waiting...")
        except Exception as e:
            print(f"    [{ts()}] Warning: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"{instance_id} did not recover within 20 minutes")


# ─────────────────────────────────────────────
# Config restore via FortiGate REST API
# ─────────────────────────────────────────────

def restore_config_via_api(mgmt_ip, api_key, conf_file, port=443):
    """
    Push conf_file to FortiGate via REST API config restore endpoint.
    Returns True if the request was accepted, False on error.
    The FGT will reboot immediately after a successful restore.
    """
    url = f"https://{mgmt_ip}:{port}/api/v2/monitor/system/config/restore"

    with open(conf_file, 'rb') as f:
        config_data = f.read()

    boundary = 'FortiGateUpgradeBoundary'
    filename = os.path.basename(conf_file)
    body = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="source"\r\n\r\nupload\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="scope"\r\n\r\nglobal\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f'Content-Type: application/octet-stream\r\n\r\n'
    ).encode() + config_data + f'\r\n--{boundary}--\r\n'.encode()

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': f'multipart/form-data; boundary={boundary}',
    }

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        req = urllib.request.Request(url, data=body, headers=headers, method='POST')
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            result = json.loads(resp.read())
            return result.get('status') == 'success'
    except urllib.error.HTTPError as e:
        body_text = e.read().decode('utf-8', errors='replace')
        print(f"    HTTP {e.code}: {body_text[:200]}")
        return False
    except Exception as e:
        print(f"    API error: {e}")
        return False


def restore_config(mgmt_ip, conf_file, api_key=None, mgmt_port=443):
    """
    Restore conf_file to the FortiGate at mgmt_ip: through the REST API when an
    API key is given, otherwise (or if the API call fails) by asking the
    operator to do it in the GUI. Returns once the restore has been started.
    """
    restored_via_api = False

    if api_key and mgmt_ip:
        print(f"  Attempting API restore to https://{mgmt_ip}:{mgmt_port}...")
        restored_via_api = restore_config_via_api(mgmt_ip, api_key, conf_file, port=mgmt_port)
        if restored_via_api:
            print(f"  [{ts()}] Config restore accepted — FortiGate will reboot now.")
        else:
            print("  API restore failed — falling back to manual restore.")

    if not restored_via_api:
        print("  Restore the FortiGate configuration manually:")
        print(f"    1. Log in to FortiGate GUI at https://{mgmt_ip}:{mgmt_port}")
        print("    2. System → Settings → Restore → Upload")
        print(f"    3. Select {conf_file}")
        print("    4. Confirm restore — the FortiGate will reboot")
        print()
        confirm("Config restore initiated and FortiGate is rebooting?")


def wait_for_instance_recovery(ec2, elbv2, tg_arn, instance_id):
    """Wait for instance to be EC2-running and GWLB-healthy after a reboot."""
    print(f"    [{ts()}] Waiting for {instance_id} to recover (running + GWLB healthy)...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS * 2:
        try:
            resp = ec2.describe_instances(InstanceIds=[instance_id])
            state = resp['Reservations'][0]['Instances'][0]['State']['Name']
        except Exception:
            state = 'unknown'
        gwlb_ok = is_gwlb_healthy(elbv2, tg_arn, instance_id)
        status = f"ec2={state}, gwlb={'healthy' if gwlb_ok else 'unhealthy'}"
        if state == 'running' and gwlb_ok:
            print(f"    [{ts()}] {instance_id}: {status} — recovered.")
            return
        print(f"    [{ts()}] {instance_id}: {status} — waiting...")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"{instance_id} did not recover within {MAX_WAIT_MINS * 2} minutes")


def config_restore_phase(ec2, elbv2, tg_arn, new_primary_id, conf_file, api_key=None, mgmt_port=443):
    """Phase 5 (Path B, opt-in): restore a config backup to the new primary."""
    banner("Phase 5: Config Restore")

    mgmt_ip = get_instance_management_ip(ec2, new_primary_id)
    print(f"  New primary: {new_primary_id}")
    print(f"  Management IP: {mgmt_ip}")
    print(f"  Config file: {conf_file}")
    print()
    print("  This reboots the primary. Traffic it carries is interrupted until it is back.")
    confirm(f"Restore {os.path.basename(conf_file)} to the new primary?")

    restore_config(mgmt_ip, conf_file, api_key=api_key, mgmt_port=mgmt_port)

    banner("Phase 5.1: Waiting for Primary Recovery")
    print(f"  [{ts()}] Pausing 60s for reboot to begin...")
    time.sleep(60)

    wait_for_instance_recovery(ec2, elbv2, tg_arn, new_primary_id)
    print(f"  [{ts()}] Primary recovered. Config restore complete.")


# ─────────────────────────────────────────────
# Path A: No running instances
# ─────────────────────────────────────────────

def run_path_a(ec2, autoscaling, inventory, state_dir):
    banner("Phase 1: Update Launch Templates (Path A — desired=0)")

    update_all_launch_templates(ec2, autoscaling, inventory, state_dir)

    print()
    print("  Launch templates updated. All future instances will launch with the new FortiOS.")
    print("  Path A complete.")


# ─────────────────────────────────────────────
# Path C: Config restore (desired=0 + conf file)
# ─────────────────────────────────────────────

def run_path_c(ec2, autoscaling, elbv2, inventory, conf_file, state_dir,
               api_key=None, mgmt_port=443):
    byol_asg = inventory['autoscale_groups']['byol']
    asg_name = byol_asg['asg_name']
    original_max = byol_asg['max']
    target_ami_id = inventory['target']['byol_ami_id']
    tg_arn = inventory['gwlb']['target_group_arn']

    if original_max < 1:
        print()
        print(f"  ERROR: {asg_name} has max size {original_max}. Path C launches one instance and then")
        print("  scales out, so the ASG needs its normal maximum. Set it back before running, e.g.:")
        print(f"    aws autoscaling update-auto-scaling-group --auto-scaling-group-name {asg_name} "
              f"--max-size <normal max>")
        sys.exit(1)
    scale_out_size = min(2, original_max)

    # ── Phase 1: Update launch templates ──────
    banner("Phase 1: Update Launch Templates")
    update_all_launch_templates(ec2, autoscaling, inventory, state_dir)

    # ── Phase 2: Launch single primary ────────
    banner("Phase 2: Launch Single Primary Instance")
    print(f"  Setting {asg_name} to min=1, desired=1, max={original_max}")
    scale_asg(autoscaling, asg_name, min_size=1, desired=1, max_size=original_max)

    print()
    primary_id = wait_for_primary_instance(autoscaling, ec2, elbv2, asg_name, tg_arn, target_ami_id)

    mgmt_ip = get_instance_management_ip(ec2, primary_id)
    print()
    print(f"  Primary instance: {primary_id}")
    print(f"  Management IP:    {mgmt_ip}")

    # ── Phase 3: Config restore ────────────────
    banner("Phase 3: Config Restore")
    print(f"  Config file: {conf_file}")
    print()
    restore_config(mgmt_ip, conf_file, api_key=api_key, mgmt_port=mgmt_port)

    # ── Phase 4: Wait for reboot ───────────────
    banner("Phase 4: Waiting for Reboot")
    # Brief pause to allow the instance to go down before we start polling
    print(f"  [{ts()}] Pausing 60s for reboot to initiate...")
    time.sleep(60)

    wait_for_primary_after_reboot(autoscaling, ec2, elbv2, asg_name, tg_arn, primary_id)

    # ── Phase 5: Scale out ─────────────────────
    banner("Phase 5: Scale Out")
    if scale_out_size < 2:
        print(f"  {asg_name} has max size {original_max} — staying at one instance.")
        print("  Path C complete.")
        return
    confirm(f"Primary is up and healthy. Scale out to min={scale_out_size}, "
            f"desired={scale_out_size}, max={original_max}?")

    scale_asg(autoscaling, asg_name, min_size=scale_out_size, desired=scale_out_size,
              max_size=original_max)

    print()
    print(f"  [{ts()}] ASG scaling out. Secondary instance will launch and sync from primary.")
    print("  Monitor CloudWatch logs: bash scripts/watch_lambda.sh")
    print()
    print("  Path C complete.")


# ─────────────────────────────────────────────
# Path B: Rolling replacement
# ─────────────────────────────────────────────

def run_path_b(ec2, autoscaling, elbv2, inventory, asg_targets, primary, secondaries,
               state_dir, restore_conf=None, api_key=None, mgmt_port=443, flex=None):
    tg_arn = inventory['gwlb']['target_group_arn']

    # ── Phase 1: Backup prompt ─────────────────
    banner("Phase 1: Backup")
    print(f"  Primary instance: {primary['instance_id']}")
    print()
    print("  Before proceeding, export the primary FortiGate configuration:")
    print("    1. Log in to primary FortiGate GUI")
    print("    2. System → Settings → Backup → Full Configuration")
    print("    3. Save it under backups/ (not under state/: a .conf file there selects")
    print("       the config-restore path the next time the ASG is at zero)")
    print()
    print("  The backup is the fallback if a replacement comes up without the configuration.")
    confirm("Backup complete?")

    # ── Phase 2: Update launch templates ──────
    banner("Phase 2: Update Launch Templates")
    update_all_launch_templates(ec2, autoscaling, inventory, state_dir)

    confirm("Launch templates updated. Proceed with rolling replacement?")

    # ── Phase 3: Rolling replacement ──────────
    banner("Phase 3: Rolling Replacement")
    asg_names = [t['asg_name'] for t in asg_targets]
    for name in asg_names:
        suspend_asg_processes(autoscaling, name)

    # finally also runs when the operator answers "no" at a prompt (SystemExit)
    # or presses Ctrl-C, so the ASG is never left with processes suspended.
    try:
        new_primary = rolling_replacement(autoscaling, ec2, elbv2, asg_targets, tg_arn,
                                          primary, secondaries, flex=flex)
    except Exception as e:
        print(f"\n  ERROR during rolling replacement: {e}")
        raise
    finally:
        print()
        for name in asg_names:
            resume_asg_processes(autoscaling, name)

    # ── Phase 4: Verify ────────────────────────
    passed = verify(autoscaling, ec2, elbv2, asg_targets, tg_arn, flex=flex)

    if not passed:
        print()
        print("  WARNING: Some checks failed. Review above before proceeding.")
        sys.exit(1)

    # ── Phase 5: Config restore (opt-in) ───────
    if restore_conf:
        config_restore_phase(ec2, elbv2, tg_arn, new_primary, restore_conf,
                             api_key=api_key, mgmt_port=mgmt_port)

    print()
    print("  All checks passed. In-place upgrade complete.")
    print()
    print("  Next: set fortios_version to the new version in terraform.tfvars and run")
    print("  'terraform plan'. Until that is done, Terraform still describes the old version.")


# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='In-place FortiOS upgrade via rolling instance replacement')
    parser.add_argument('--inventory', default='state/blue_inventory.json',
                        help='Path to blue_inventory.json (default: state/blue_inventory.json)')
    parser.add_argument('--state-dir', default='state',
                        help='Directory containing state files and, for Path C, the conf backup (default: state)')
    parser.add_argument('--restore-config', metavar='FILE',
                        help='Path B only: after every instance is replaced, restore this config '
                             'backup to the new primary (which reboots it). For cross-major-version '
                             'upgrades, where native config sync does not work. Off by default.')
    parser.add_argument('--fgt-api-key',
                        help='FortiGate REST API key for automated config restore '
                             '(Path C, or Path B with --restore-config). '
                             'Generate via: System → Administrators → REST API Admin. '
                             'If omitted, the restore falls back to a manual prompt.')
    parser.add_argument('--fgt-mgmt-port', type=int, default=443,
                        help='FortiGate management HTTPS port (default: 443)')
    parser.add_argument('--upgrade-path-verified', action='store_true',
                        help='Confirm that Fortinet\'s Upgrade Path Tool gives a single-step path '
                             'from the version the config backup was taken on to the target '
                             'version. Required when a config restore (Path C, or Path B with '
                             '--restore-config) crosses a minor or major version.')
    parser.add_argument('--allow-single-instance', action='store_true',
                        help='Path B: allow replacing the only instance in the group. '
                             'This is an outage until the replacement is in service.')
    args = parser.parse_args()

    inventory = load_inventory(args.inventory)

    if not inventory.get('target', {}).get('byol_ami_id'):
        print("Error: the inventory has no target AMI. Run discover.py with --target-version first.")
        sys.exit(1)
    if args.restore_config and not os.path.isfile(args.restore_config):
        print(f"Error: --restore-config file not found: {args.restore_config}")
        sys.exit(1)

    global CLI_REGION
    region = inventory['discovery_metadata']['region']
    CLI_REGION = f" --region {region}"
    ec2 = RenewingClient('ec2', region)
    autoscaling = RenewingClient('autoscaling', region)
    elbv2 = RenewingClient('elbv2', region)
    dynamodb = RenewingClient('dynamodb', region)

    try:
        run(args, inventory, region, ec2, autoscaling, elbv2, dynamodb)
    except CredentialsExpired:
        print()
        print("  Stopped: the AWS credentials expired and were not renewed.")
        print("  Renew them and run the same command again. Instances already replaced are")
        print("  skipped, suspended ASG processes are resumed, and the final checks are run.")
        sys.exit(1)


def restore_upgrade_path_errors(inventory, conf_file, verified):
    """
    Why this run must not restore conf_file, as lines of text. Empty when it may.

    The version the backup was taken on is read from the backup itself; if it cannot be
    (an encrypted backup), the version discovery found running is used. A restore that
    crosses a minor or major version is refused until the operator has confirmed the
    upgrade path, here with --upgrade-path-verified or at discovery.
    """
    change = inventory.get('version_change') or {}
    arch = inventory.get('architecture', {})
    target = inventory.get('target', {}).get('fortios_version')
    backup_version = discover.backup_fortios_version(conf_file)
    source = backup_version
    if source == 'unknown':
        source = (change.get('from') or arch.get('running_fortios_version')
                  or arch.get('current_fortios_version') or 'unknown')
    name = os.path.basename(conf_file)
    taken_on = (f"taken on {backup_version}" if backup_version != 'unknown'
                else f"whose version could not be read (assumed {source})")
    return discover.restore_path_errors(
        source, target, verified or change.get('upgrade_path_verified'),
        upgrade='in-place upgrade with a config restore',
        restores=(f"This run restores {name}, a configuration backup {taken_on}, onto a\n"
                  f"  FortiGate running {target}."),
        confirm='Then run this again with --upgrade-path-verified.')


def run(args, inventory, region, ec2, autoscaling, elbv2, dynamodb=None):
    arch = inventory.get('architecture', {})
    table_name = (inventory.get('dynamodb') or {}).get('table_name')
    flex = FlexSerials(dynamodb, table_name) if dynamodb and table_name else None
    target = inventory.get('target', {})
    asg_targets = asg_targets_from_inventory(inventory)
    tg_arn = inventory['gwlb']['target_group_arn']

    # ── Live ASG state (the inventory may be minutes or days old) ──
    total_desired = 0
    total_instances = 0
    for t in asg_targets:
        live = get_live_asg(autoscaling, t['asg_name'])
        if not live:
            print(f"Error: ASG {t['asg_name']} not found in {region}. Is the inventory current?")
            sys.exit(1)
        inv_asg = inventory['autoscale_groups'][t['license_type']]
        inv_asg['desired'] = live['DesiredCapacity']
        inv_asg['min'] = live['MinSize']
        inv_asg['max'] = live['MaxSize']
        total_desired += live['DesiredCapacity']
        total_instances += len(live.get('Instances', []))

    # ── Path detection ─────────────────────────
    conf_file = None
    if total_desired == 0 and total_instances == 0:
        conf_file = find_conf_file(args.state_dir)
        upgrade_path = 'C' if conf_file else 'A'
    else:
        upgrade_path = 'B'

    # ── Upgrade path check for a config restore ──
    # Path C always restores a backup; Path B only with --restore-config. Restoring a
    # backup from another minor or major version is a version conversion in one step,
    # so it is refused until the upgrade path has been confirmed.
    restore_file = conf_file if upgrade_path == 'C' else getattr(args, 'restore_config', None)
    if restore_file:
        errors = restore_upgrade_path_errors(inventory, restore_file,
                                             getattr(args, 'upgrade_path_verified', False))
        if errors:
            print()
            print('\n'.join(errors))
            print()
            print("  Nothing was changed.")
            sys.exit(2)

    # ── Pre-flight summary ─────────────────────
    banner("In-Place FortiOS Upgrade — Pre-flight Summary")
    print(f"  Region:          {region}")
    print(f"  Architecture:    {arch.get('arch')}")
    print(f"  Current FortiOS: {arch.get('current_fortios_version')}  ({arch.get('current_ami_id')})")
    print(f"  Target FortiOS:  {target.get('fortios_version')}  ({target.get('byol_ami_id')})")
    print()
    print("  Live ASG state:")
    for t in asg_targets:
        a = inventory['autoscale_groups'][t['license_type']]
        print(f"    {t['asg_name']}: desired={a['desired']}, min={a['min']}, max={a['max']}")
    print()

    primary, secondaries = None, []

    if upgrade_path == 'C':
        print(f"  Path: C — desired=0, config restore from {os.path.basename(conf_file)}")
        print()
        print("  Procedure:")
        print("    1. Update launch templates with target AMI")
        print("    2. Launch single primary instance (min=1, desired=1)")
        print("    3. Wait for instance running + tagged Primary")
        print(f"    4. Restore config from {os.path.basename(conf_file)} "
              f"({'REST API' if args.fgt_api_key else 'FortiGate GUI'})")
        print("    5. Wait for reboot")
        print("    6. Scale out")
    elif upgrade_path == 'A':
        print("  Path: A — desired=0 on all ASGs, no conf file in the state directory.")
        print("  Launch template update only — new instances will launch with new FortiOS.")
    else:
        primary, secondaries, on_target, problems = preflight_rolling(
            autoscaling, ec2, elbv2, asg_targets, tg_arn,
            allow_single=args.allow_single_instance, flex=flex)

        print(f"  Path: B — {total_instances} instance(s) running, rolling replacement")
        print()
        print(f"  Primary:               {primary['instance_id'] if primary else 'NOT IDENTIFIED'}")
        print(f"  Secondaries to replace: {[m['instance_id'] for m in secondaries] or 'none'}")
        if on_target:
            print(f"  Already on target AMI:  {[m['instance_id'] for m in on_target]}")
        if flex and flex.skipped:
            print(f"  FortiFlex serial check skipped: {flex.skipped}")

        # Processes this script suspends that are still suspended: an earlier run
        # was interrupted before it could resume them.
        left_suspended = {t['asg_name']: upgrade_suspended_processes(autoscaling, t['asg_name'])
                          for t in asg_targets}
        left_suspended = {name: procs for name, procs in left_suspended.items() if procs}

        if problems:
            print()
            print("  The group is not ready for a rolling replacement:")
            for prob in problems:
                print(f"    ✗ {prob}")
            if any('FortiFlex' in prob for prob in problems):
                print()
                for line in FLEX_FIX_HINT:
                    print(f"  {line}")
            print()
            print("  Nothing was changed.")
            if left_suspended:
                print()
                print("  An earlier run was interrupted and left ASG processes suspended. If a")
                print("  replacement is still starting, wait until it is healthy and run this again.")
                print("  To resume the processes now:")
                for name in left_suspended:
                    print(f"    {resume_command(name)}")
            sys.exit(1)

        to_replace = len(secondaries) + (1 if primary['ami'] != primary['target_ami_id'] else 0)

        if to_replace == 0:
            # Nothing left to replace: a rerun after an interrupted or finished run.
            print()
            print("  Every instance is already on its target AMI. Nothing to replace.")
            if left_suspended:
                print()
                print("  An earlier run was interrupted and left ASG processes suspended.")
                for name in left_suspended:
                    resume_asg_processes(autoscaling, name)
            passed = verify(autoscaling, ec2, elbv2, asg_targets, tg_arn, title="Final Status",
                            flex=flex)
            print()
            if not passed:
                print("  WARNING: Some checks failed. Review above.")
                sys.exit(1)
            print("  All checks passed. The group is on the target FortiOS version.")
            return

        if left_suspended:
            print()
            print("  Note: an earlier run was interrupted and left ASG processes suspended on "
                  f"{', '.join(left_suspended)}.")
            print("  This run resumes them when it finishes.")

        warning = credentials_warning(to_replace)
        if warning:
            print()
            for line in warning:
                print(f"  {line}")

        stray = find_conf_file(args.state_dir)
        if stray and not args.restore_config:
            print()
            print(f"  Note: {stray} is ignored. A config restore after a rolling")
            print("  replacement only happens with --restore-config FILE.")

        print()
        print("  Procedure: replace secondaries one at a time, each from the new launch template;")
        print("             replace the primary last, after you confirm; the Lambda promotes a secondary.")
        print("             Capacity is one instance short during each replacement, and connections")
        print("             through the instance being replaced are dropped.")
        if args.restore_config:
            print(f"             Then restore {args.restore_config} to the new primary (reboots it).")

    confirm("Proceed?")

    # ── Run path ──────────────────────────────
    if upgrade_path == 'C':
        run_path_c(ec2, autoscaling, elbv2, inventory, conf_file, args.state_dir,
                   api_key=args.fgt_api_key, mgmt_port=args.fgt_mgmt_port)
    elif upgrade_path == 'A':
        run_path_a(ec2, autoscaling, inventory, args.state_dir)
    else:
        run_path_b(ec2, autoscaling, elbv2, inventory, asg_targets, primary, secondaries,
                   args.state_dir,
                   restore_conf=args.restore_config,
                   api_key=args.fgt_api_key,
                   mgmt_port=args.fgt_mgmt_port,
                   flex=flex)


if __name__ == '__main__':
    main()
