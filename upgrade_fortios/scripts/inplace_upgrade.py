#!/usr/bin/env python3
"""
inplace_upgrade.py — In-place FortiOS upgrade via rolling instance replacement

Reads blue_inventory.json produced by discover.py and performs:
  Path A (desired=0, no conf file): Update launch templates with target AMI. Done.
  Path C (desired=0, conf file present): Update launch templates, launch single
                      primary instance, wait for healthy, prompt operator to restore
                      config, wait for reboot, then scale out to full capacity.
  Path B (desired>0): Update launch templates, then rolling replacement:
                      terminate secondaries first, primary last.
                      Secondaries cover traffic when primary is terminated — no gap.
                      After all instances are on the new AMI, restores the primary
                      config backup via FortiGate API (cross-version config sync does
                      not work — e.g. 7.4.x primary cannot sync to 7.6.x secondary).
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


POLL_INTERVAL = 15   # seconds between status polls
MAX_WAIT_MINS = 10   # minutes to wait for replacement to become InService
SYNC_PAUSE   = 60    # seconds to wait after replacement for config sync


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
# Launch template update
# ─────────────────────────────────────────────

def update_launch_template(ec2, lt_id, lt_name, target_ami_id, license_type):
    """Create a new launch template version with the target AMI. Return new version number."""
    print(f"  Creating new version of {lt_name} ({license_type}) with AMI {target_ami_id}...")
    try:
        resp = ec2.create_launch_template_version(
            LaunchTemplateId=lt_id,
            SourceVersion='$Latest',
            LaunchTemplateData={'ImageId': target_ami_id},
            VersionDescription=f'FortiOS upgrade to {target_ami_id}',
        )
        new_version = resp['LaunchTemplateVersion']['VersionNumber']
        print(f"    Created version {new_version}")
        return new_version
    except Exception as e:
        print(f"  ERROR updating launch template {lt_name}: {e}")
        raise


def update_asg_launch_template(autoscaling, asg_name, lt_id, new_version):
    """Update ASG to use the new launch template version."""
    print(f"  Updating {asg_name} to launch template version {new_version}...")
    try:
        autoscaling.update_auto_scaling_group(
            AutoScalingGroupName=asg_name,
            LaunchTemplate={
                'LaunchTemplateId': lt_id,
                'Version': str(new_version),
            }
        )
        print(f"    Done.")
    except Exception as e:
        print(f"  ERROR updating ASG {asg_name}: {e}")
        raise


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


def resume_asg_processes(autoscaling, asg_name):
    print(f"  Resuming ASG processes on {asg_name}: {', '.join(SUSPEND_PROCESSES)}")
    try:
        autoscaling.resume_processes(
            AutoScalingGroupName=asg_name,
            ScalingProcesses=SUSPEND_PROCESSES,
        )
    except Exception as e:
        print(f"  Warning: could not resume processes on {asg_name}: {e}")


# ─────────────────────────────────────────────
# Instance replacement polling
# ─────────────────────────────────────────────

def get_asg_instances(autoscaling, asg_name):
    """Return list of instance dicts currently in the ASG."""
    resp = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    if not resp['AutoScalingGroups']:
        return []
    return resp['AutoScalingGroups'][0].get('Instances', [])


def get_instance_ami(ec2, instance_id):
    """Return the AMI ID of a running EC2 instance."""
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        return resp['Reservations'][0]['Instances'][0]['ImageId']
    except Exception:
        return None


def wait_for_replacement(autoscaling, ec2, asg_name, terminated_id, target_ami_id):
    """
    Poll the ASG until a new instance (not terminated_id) is InService.
    Returns the new instance ID.
    """
    print(f"    [{ts()}] Waiting for replacement of {terminated_id}...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS:
        instances = get_asg_instances(autoscaling, asg_name)
        for inst in instances:
            if (inst['InstanceId'] != terminated_id and
                    inst['LifecycleState'] == 'InService' and
                    inst['HealthStatus'] == 'Healthy'):
                # Check it is on the target AMI
                ami = get_instance_ami(ec2, inst['InstanceId'])
                if ami == target_ami_id:
                    print(f"    [{ts()}] Replacement {inst['InstanceId']} is InService on target AMI.")
                    return inst['InstanceId']
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"Replacement for {terminated_id} did not become healthy within {MAX_WAIT_MINS} minutes")


def wait_for_gwlb_healthy(elbv2, tg_arn, instance_id):
    """Poll GWLB target group until instance_id reports healthy."""
    print(f"    [{ts()}] Waiting for {instance_id} to be healthy in GWLB target group...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS:
        try:
            resp = elbv2.describe_target_health(
                TargetGroupArn=tg_arn,
                Targets=[{'Id': instance_id}]
            )
            for t in resp['TargetHealthDescriptions']:
                state = t['TargetHealth']['State']
                if state == 'healthy':
                    print(f"    [{ts()}] {instance_id} is healthy in GWLB.")
                    return
                print(f"    [{ts()}] GWLB health: {state} — waiting...")
        except Exception as e:
            print(f"    [{ts()}] Warning: GWLB health check error: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"{instance_id} did not become healthy in GWLB within {MAX_WAIT_MINS} minutes")


def wait_for_secondary_ready(autoscaling, ec2, elbv2, asg_name, tg_arn, instance_id):
    """
    Poll until secondary instance is fully initialized and config sync'd:
      - EC2 state: running
      - ASG lifecycle: InService
      - GWLB: healthy
      - EC2 tag 'Autoscale Role': Secondary
    """
    print(f"    [{ts()}] Waiting for {instance_id} to be running, GWLB healthy, and config sync'd (Autoscale Role: Secondary)...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS * 3:
        try:
            resp = ec2.describe_instances(InstanceIds=[instance_id])
            inst = resp['Reservations'][0]['Instances'][0]
            state = inst['State']['Name']
            tags = {t['Key']: t['Value'] for t in inst.get('Tags', [])}
            role = tags.get('Autoscale Role', '')
            gwlb_ok = is_gwlb_healthy(elbv2, tg_arn, instance_id)
            status = f"ec2={state}, gwlb={'healthy' if gwlb_ok else 'unhealthy'}, role={role or 'unset'}"
            if state == 'running' and gwlb_ok and role == 'Secondary':
                print(f"    [{ts()}] {instance_id}: {status} — ready.")
                return
            print(f"    [{ts()}] {instance_id}: {status} — waiting...")
        except Exception as e:
            print(f"    [{ts()}] Warning: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"{instance_id} did not become a healthy secondary within 30 minutes")


def wait_for_new_primary(autoscaling, asg_name, old_primary_id):
    """Poll until a new instance (not old_primary_id) has ProtectedFromScaleIn=True."""
    print(f"    [{ts()}] Waiting for Lambda to elect new primary...")
    start = time.time()
    while elapsed_mins(start) < MAX_WAIT_MINS:
        resp = autoscaling.describe_auto_scaling_instances()
        for inst in resp['AutoScalingInstances']:
            if (inst['AutoScalingGroupName'] == asg_name and
                    inst['InstanceId'] != old_primary_id and
                    inst.get('ProtectedFromScaleIn') and
                    inst['LifecycleState'] == 'InService'):
                print(f"    [{ts()}] New primary elected: {inst['InstanceId']}")
                return inst['InstanceId']
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"New primary not elected within {MAX_WAIT_MINS} minutes")


# ─────────────────────────────────────────────
# Rolling replacement (Path B)
# ─────────────────────────────────────────────

def terminate_instance(autoscaling, instance_id):
    """Terminate instance via ASG — keeps desired capacity, ASG launches replacement."""
    print(f"    [{ts()}] Terminating {instance_id} (ASG will launch replacement)...")
    autoscaling.terminate_instance_in_auto_scaling_group(
        InstanceId=instance_id,
        ShouldDecrementDesiredCapacity=False,
    )


def rolling_replacement(autoscaling, ec2, elbv2, inventory):
    """Replace all instances: secondaries first, primary last."""
    byol_asg = inventory['autoscale_groups']['byol']
    asg_name = byol_asg['asg_name']
    primary_id = byol_asg['primary_instance']
    tg_arn = inventory['gwlb']['target_group_arn']
    target_ami_id = inventory['target']['byol_ami_id']

    instances = byol_asg['instances']
    secondaries = [i['instance_id'] for i in instances if i['instance_id'] != primary_id]

    print(f"  Primary:    {primary_id}")
    print(f"  Secondaries: {secondaries}")
    print(f"  Target AMI: {target_ami_id}")

    # ── Replace secondaries ───────────────────
    for i, sec_id in enumerate(secondaries, 1):
        banner(f"Phase 3.{i}: Replacing secondary {sec_id} ({i}/{len(secondaries)})")
        terminate_instance(autoscaling, sec_id)

        # Wait for a new InService instance on the target AMI
        new_id = wait_for_replacement(autoscaling, ec2, asg_name, sec_id, target_ami_id)

        # Wait for secondary fully ready: running + GWLB healthy + config sync'd
        wait_for_secondary_ready(autoscaling, ec2, elbv2, asg_name, tg_arn, new_id)
        print(f"    [{ts()}] Secondary replacement complete: {new_id}")

    # ── Replace primary (last) ────────────────
    banner(f"Phase 3.{len(secondaries)+1}: Replacing primary {primary_id}")
    print(f"  Secondaries now running on target AMI — traffic continues through them.")

    confirm(f"Terminate primary {primary_id}? All secondaries are healthy on target AMI.")

    terminate_instance(autoscaling, primary_id)

    # Lambda elects new primary from existing secondaries (does not launch new instance)
    # Just need to wait for the election (ProtectedFromScaleIn flag)
    new_primary_id = wait_for_new_primary(autoscaling, asg_name, primary_id)

    # Also wait for the replacement instance ASG launched for the old primary slot
    new_instance_id = wait_for_replacement(autoscaling, ec2, asg_name, primary_id, target_ami_id)
    wait_for_gwlb_healthy(elbv2, tg_arn, new_instance_id)

    print(f"    [{ts()}] Primary replacement complete.")
    print(f"    New primary (by Lambda election): {new_primary_id}")

    return new_primary_id


# ─────────────────────────────────────────────
# Verification (Phase 4)
# ─────────────────────────────────────────────

def verify(autoscaling, ec2, elbv2, inventory):
    """Verify all instances are on target AMI, GWLB healthy, primary elected."""
    banner("Phase 4: Verification")

    byol_asg = inventory['autoscale_groups']['byol']
    asg_name = byol_asg['asg_name']
    tg_arn = inventory['gwlb']['target_group_arn']
    target_ami_id = inventory['target']['byol_ami_id']

    passed = True

    # ── ASG instances ──────────────────────────
    instances = get_asg_instances(autoscaling, asg_name)
    all_inservice = all(i['LifecycleState'] == 'InService' for i in instances)
    print(f"  [{'✓' if all_inservice else '✗'}] All ASG instances InService  ({len(instances)} total)")
    if not all_inservice:
        passed = False
        for i in instances:
            if i['LifecycleState'] != 'InService':
                print(f"      {i['InstanceId']}: {i['LifecycleState']}")

    # ── AMI check ─────────────────────────────
    ami_ok = True
    for inst in instances:
        ami = get_instance_ami(ec2, inst['InstanceId'])
        if ami != target_ami_id:
            ami_ok = False
            print(f"      {inst['InstanceId']}: AMI {ami} (expected {target_ami_id})")
    print(f"  [{'✓' if ami_ok else '✗'}] All instances running target AMI ({target_ami_id})")
    if not ami_ok:
        passed = False

    # ── GWLB health ────────────────────────────
    try:
        tg_health = elbv2.describe_target_health(TargetGroupArn=tg_arn)
        targets = tg_health['TargetHealthDescriptions']
        all_healthy = all(t['TargetHealth']['State'] == 'healthy' for t in targets)
        print(f"  [{'✓' if all_healthy else '✗'}] GWLB target group: {len(targets)} targets, all healthy={all_healthy}")
        if not all_healthy:
            passed = False
            for t in targets:
                state = t['TargetHealth']['State']
                if state != 'healthy':
                    print(f"      {t['Target']['Id']}: {state}")
    except Exception as e:
        print(f"  [✗] GWLB health check failed: {e}")
        passed = False

    # ── Primary election ───────────────────────
    try:
        resp = autoscaling.describe_auto_scaling_instances()
        primary = None
        for inst in resp['AutoScalingInstances']:
            if inst['AutoScalingGroupName'] == asg_name and inst.get('ProtectedFromScaleIn'):
                primary = inst['InstanceId']
                break
        print(f"  [{'✓' if primary else '✗'}] Primary elected: {primary or 'NONE'}")
        if not primary:
            passed = False
    except Exception as e:
        print(f"  [✗] Primary check failed: {e}")
        passed = False

    return passed


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
# Path A: No running instances
# ─────────────────────────────────────────────

def run_path_a(ec2, autoscaling, inventory):
    banner("Phase 1: Update Launch Templates (Path A — desired=0)")

    lts = inventory['launch_templates']
    target = inventory['target']
    asgs = inventory['autoscale_groups']

    for lt_key, lt in lts.items():
        if not lt.get('target_ami_id'):
            print(f"  Skipping {lt['name']} — no target AMI")
            continue

        new_ver = update_launch_template(
            ec2, lt['id'], lt['name'], lt['target_ami_id'], lt['license_type']
        )

        # Find ASG for this license type
        asg = asgs.get(lt['license_type'])
        if asg:
            update_asg_launch_template(autoscaling, asg['asg_name'], lt['id'], new_ver)

    print()
    print("  Launch templates updated. All future instances will launch with the new FortiOS.")
    print("  Path A complete.")


# ─────────────────────────────────────────────
# Path C: Config restore (desired=0 + conf file)
# ─────────────────────────────────────────────

def run_path_c(ec2, autoscaling, elbv2, inventory, conf_file):
    byol_asg = inventory['autoscale_groups']['byol']
    asg_name = byol_asg['asg_name']
    original_max = byol_asg['max']
    target_ami_id = inventory['target']['byol_ami_id']
    tg_arn = inventory['gwlb']['target_group_arn']

    # ── Phase 1: Update launch templates ──────
    banner("Phase 1: Update Launch Templates")

    lts = inventory['launch_templates']
    asgs = inventory['autoscale_groups']

    for lt_key, lt in lts.items():
        if not lt.get('target_ami_id'):
            print(f"  Skipping {lt['name']} — no target AMI")
            continue
        new_ver = update_launch_template(
            ec2, lt['id'], lt['name'], lt['target_ami_id'], lt['license_type']
        )
        asg = asgs.get(lt['license_type'])
        if asg:
            update_asg_launch_template(autoscaling, asg['asg_name'], lt['id'], new_ver)

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
    print("  Restore the FortiGate configuration:")
    print(f"    1. Log in to FortiGate GUI at https://{mgmt_ip}")
    print(f"    2. System → Settings → Restore → Upload → select {os.path.basename(conf_file)}")
    print("    3. Confirm restore — the FortiGate will reboot")
    print()
    confirm("Config restore initiated and FortiGate is rebooting?")

    # ── Phase 4: Wait for reboot ───────────────
    banner("Phase 4: Waiting for Reboot")
    # Brief pause to allow the instance to go down before we start polling
    print(f"  [{ts()}] Pausing 60s for reboot to initiate...")
    time.sleep(60)

    wait_for_primary_after_reboot(autoscaling, ec2, elbv2, asg_name, tg_arn, primary_id)

    # ── Phase 5: Scale out ─────────────────────
    banner("Phase 5: Scale Out")
    confirm(f"Primary is up and healthy. Scale out to min=2, desired=2, max={original_max}?")

    scale_asg(autoscaling, asg_name, min_size=2, desired=2, max_size=original_max)

    print()
    print(f"  [{ts()}] ASG scaling out. Secondary instance will launch and sync from primary.")
    print(f"  Monitor CloudWatch logs: watch_lambda")
    print()
    print("  Path C complete.")


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
    raise TimeoutError(f"{instance_id} did not recover within 20 minutes")


def config_restore_phase(ec2, elbv2, tg_arn, new_primary_id, conf_file, api_key=None, mgmt_port=443):
    """Phase 5: Restore primary config backup to the new primary instance."""
    banner("Phase 5: Config Restore")

    mgmt_ip = get_instance_management_ip(ec2, new_primary_id)
    print(f"  New primary: {new_primary_id}")
    print(f"  Management IP: {mgmt_ip}")
    print(f"  Config file: {conf_file}")
    print()

    restored_via_api = False

    if api_key and mgmt_ip:
        print(f"  Attempting API restore to https://{mgmt_ip}:{mgmt_port}...")
        restored_via_api = restore_config_via_api(mgmt_ip, api_key, conf_file, port=mgmt_port)
        if restored_via_api:
            print(f"  [{ts()}] Config restore accepted — FortiGate will reboot now.")
        else:
            print(f"  API restore failed — falling back to manual restore.")

    if not restored_via_api:
        print("  Restore the FortiGate configuration manually:")
        print(f"    1. Log in to FortiGate GUI at https://{mgmt_ip}:{mgmt_port}")
        print(f"    2. System → Settings → Restore → Upload")
        print(f"    3. Select {conf_file}")
        print("    4. Confirm restore — the FortiGate will reboot")
        print()
        confirm("Config restore initiated and FortiGate is rebooting?")

    banner("Phase 5.1: Waiting for Primary Recovery")
    print(f"  [{ts()}] Pausing 60s for reboot to begin...")
    time.sleep(60)

    wait_for_instance_recovery(ec2, elbv2, tg_arn, new_primary_id)
    print(f"  [{ts()}] Primary recovered. Config restore complete.")


# ─────────────────────────────────────────────
# Path B: Rolling replacement
# ─────────────────────────────────────────────

def run_path_b(ec2, autoscaling, elbv2, inventory, conf_file=None, api_key=None, mgmt_port=443):
    byol_asg = inventory['autoscale_groups']['byol']
    asg_name = byol_asg['asg_name']

    # ── Phase 1: Backup prompt ─────────────────
    banner("Phase 1: Backup")
    primary_id = byol_asg.get('primary_instance')
    print(f"  Primary instance: {primary_id}")
    print()
    print("  Before proceeding, export the primary FortiGate configuration:")
    print("    1. Log in to primary FortiGate GUI")
    print("    2. System → Settings → Backup → Full Configuration")
    print(f"    3. Save as: state/blue_primary_config.conf")
    print()
    print("  NOTE: Cross-version upgrades (e.g. 7.4 → 7.6) cannot config-sync between")
    print("  FortiOS versions. This backup will be restored to the new primary via API")
    print("  after all instances are upgraded (Phase 5).")
    confirm("Backup complete and saved to state/blue_primary_config.conf?")

    # ── Phase 2: Update launch templates ──────
    banner("Phase 2: Update Launch Templates")

    lts = inventory['launch_templates']
    asgs = inventory['autoscale_groups']

    updated_lts = {}
    for lt_key, lt in lts.items():
        if not lt.get('target_ami_id'):
            print(f"  Skipping {lt['name']} — no target AMI")
            continue

        new_ver = update_launch_template(
            ec2, lt['id'], lt['name'], lt['target_ami_id'], lt['license_type']
        )
        updated_lts[lt['license_type']] = {'id': lt['id'], 'version': new_ver}

        asg = asgs.get(lt['license_type'])
        if asg:
            update_asg_launch_template(autoscaling, asg['asg_name'], lt['id'], new_ver)

    confirm("Launch templates updated. Proceed with rolling replacement?")

    # ── Phase 3: Suspend processes ────────────
    banner("Phase 3: Rolling Replacement")
    suspend_asg_processes(autoscaling, asg_name)

    try:
        new_primary = rolling_replacement(autoscaling, ec2, elbv2, inventory)
    except Exception as e:
        print(f"\n  ERROR during rolling replacement: {e}")
        print("  Resuming ASG processes before exit...")
        resume_asg_processes(autoscaling, asg_name)
        raise

    # ── Resume processes ──────────────────────
    resume_asg_processes(autoscaling, asg_name)

    # ── Phase 4: Verify ────────────────────────
    passed = verify(autoscaling, ec2, elbv2, inventory)

    if not passed:
        print()
        print("  WARNING: Some checks failed. Review above before proceeding.")
        sys.exit(1)

    # ── Phase 5: Config restore ────────────────
    tg_arn = inventory['gwlb']['target_group_arn']
    if conf_file:
        config_restore_phase(ec2, elbv2, tg_arn, new_primary, conf_file,
                             api_key=api_key, mgmt_port=mgmt_port)
    else:
        print()
        print("  No config backup found — skipping Phase 5 config restore.")
        print("  If runtime config changes were made on the old primary, restore manually.")

    print()
    print("  All checks passed. In-place upgrade complete.")


# ─────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='In-place FortiOS upgrade via rolling instance replacement')
    parser.add_argument('--inventory', default='state/blue_inventory.json',
                        help='Path to blue_inventory.json (default: state/blue_inventory.json)')
    parser.add_argument('--state-dir', default='state',
                        help='Directory containing state files and conf backup (default: state)')
    parser.add_argument('--fgt-api-key',
                        help='FortiGate REST API key for automated config restore (Phase 5). '
                             'Generate via: System → Administrators → REST API Admin. '
                             'If omitted, Phase 5 falls back to a manual restore prompt.')
    parser.add_argument('--fgt-mgmt-port', type=int, default=443,
                        help='FortiGate management HTTPS port (default: 443)')
    args = parser.parse_args()

    inventory = load_inventory(args.inventory)

    region = inventory['discovery_metadata']['region']
    ec2 = boto3.client('ec2', region_name=region)
    autoscaling = boto3.client('autoscaling', region_name=region)
    elbv2 = boto3.client('elbv2', region_name=region)

    arch = inventory.get('architecture', {})
    target = inventory.get('target', {})
    byol_asg = inventory.get('autoscale_groups', {}).get('byol', {})
    od_asg = inventory.get('autoscale_groups', {}).get('ondemand', {})

    # ── Path detection ─────────────────────────
    upgrade_path = inventory.get('upgrade_path', 'B')
    conf_file = None

    if upgrade_path == 'A':
        conf_file = find_conf_file(args.state_dir)
        if conf_file:
            upgrade_path = 'C'

    # ── Pre-flight summary ─────────────────────
    banner("In-Place FortiOS Upgrade — Pre-flight Summary")
    print(f"  Deployment:      {byol_asg.get('asg_name')}")
    print(f"  Architecture:    {arch.get('arch')}")
    print(f"  Current FortiOS: {arch.get('current_fortios_version')}  ({arch.get('current_ami_id')})")
    print(f"  Target FortiOS:  {target.get('fortios_version')}  ({target.get('byol_ami_id')})")
    print()
    print(f"  Live ASG state:")
    print(f"    BYOL:      desired={byol_asg.get('desired')}, min={byol_asg.get('min')}, max={byol_asg.get('max')}")
    print(f"    On-Demand: desired={od_asg.get('desired')}, min={od_asg.get('min')}, max={od_asg.get('max')}")
    print()

    path_reason = inventory.get('upgrade_path_reason', '')

    if upgrade_path == 'C':
        print(f"  Path: C — desired=0, config restore from {os.path.basename(conf_file)}")
        print()
        print(f"  Procedure:")
        print(f"    1. Update launch templates with target AMI")
        print(f"    2. Launch single primary instance (min=1, desired=1)")
        print(f"    3. Wait for instance running + tagged Primary")
        print(f"    4. Restore config from {os.path.basename(conf_file)} via FortiGate GUI")
        print(f"    5. Wait for reboot")
        print(f"    6. Scale out to min=2, desired=2")
    elif upgrade_path == 'A':
        print(f"  Path: A — {path_reason}")
        print()
        print("  No running instances, no conf file found.")
        print("  Launch template update only — new instances will launch with new FortiOS.")
    else:
        instances = byol_asg.get('instances', [])
        primary = byol_asg.get('primary_instance')
        secondaries = [i['instance_id'] for i in instances if i['instance_id'] != primary]
        print(f"  Path: B — {path_reason}")
        print()
        print(f"  Primary:     {primary}")
        print(f"  Secondaries: {secondaries}")
        print()
        print("  Procedure: terminate secondaries one-at-a-time → ASG replaces with new AMI")
        print("             terminate primary last — secondaries cover traffic, no gap")
        print("             restore primary config backup after all instances upgraded (Phase 5)")

    confirm("Proceed?")

    # ── Run path ──────────────────────────────
    if upgrade_path == 'C':
        run_path_c(ec2, autoscaling, elbv2, inventory, conf_file)
    elif upgrade_path == 'A':
        run_path_a(ec2, autoscaling, inventory)
    else:
        conf_file = find_conf_file(args.state_dir)
        run_path_b(ec2, autoscaling, elbv2, inventory,
                   conf_file=conf_file,
                   api_key=args.fgt_api_key,
                   mgmt_port=args.fgt_mgmt_port)


if __name__ == '__main__':
    main()
