#!/usr/bin/env python3
"""
discover.py — Extract Blue environment inventory from terraform.tfstate

Reads the autoscale_template terraform.tfstate and queries live AWS state
to produce blue_inventory.json used by all subsequent upgrade phases.
"""

import argparse
import boto3
import json
import sys
from datetime import datetime, timezone


# ─────────────────────────────────────────────
# State file parsing
# ─────────────────────────────────────────────

def load_state(state_file):
    with open(state_file) as f:
        return json.load(f)


def get_resources(state, resource_type, name=None):
    """Return all instances of a resource type, optionally filtered by name."""
    results = []
    for r in state['resources']:
        if r['type'] != resource_type:
            continue
        if name and r.get('name') != name:
            continue
        for inst in r.get('instances', []):
            results.append(inst['attributes'])
    return results


def get_resource(state, resource_type, name=None):
    """Return first matching resource instance attributes."""
    results = get_resources(state, resource_type, name)
    return results[0] if results else None


def nat_gateways_in_state(state, vpc_id=None):
    """
    NAT gateways recorded in a Terraform state, optionally only those in vpc_id.

    The VPC is taken from the NAT gateway itself where the provider records it,
    otherwise from the gateway's subnet. A gateway whose VPC cannot be determined
    is left out when vpc_id is given.
    """
    subnet_vpc = {a.get('id'): a.get('vpc_id') for a in get_resources(state, 'aws_subnet')}
    found, seen = [], set()
    for attr in get_resources(state, 'aws_nat_gateway'):
        if attr['id'] in seen:
            continue
        if vpc_id and (attr.get('vpc_id') or subnet_vpc.get(attr.get('subnet_id'))) != vpc_id:
            continue
        seen.add(attr['id'])
        found.append({
            'id': attr['id'],
            'subnet_id': attr.get('subnet_id'),
            'eip_allocation_id': attr.get('allocation_id'),
            'public_ip': attr.get('public_ip'),
        })
    return found


# ─────────────────────────────────────────────
# Architecture detection
# ─────────────────────────────────────────────

# AWS Marketplace product codes for the FortiGate-VM listings, keyed by
# (architecture, license type). Used only when the product code cannot be read
# from the AMI the launch template uses today. Same values as the Fortinet
# terraform module (modules/fortigate/fgt_asg/main.tf).
FALLBACK_PRODUCT_CODES = {
    ('arm64', 'byol'):      '33ndn84xbrajb9vmu5lxnfpjq',
    ('x86_64', 'byol'):     'dlaioq277sglm5mw1y1dmeuqa',
    ('arm64', 'ondemand'):  '8gc40z1w65qjt61p9ps88057n',
    ('x86_64', 'ondemand'): '2wqkpek696qhdeo7lbbjncqli',
}


def describe_ami(ec2, ami_id):
    """
    Return (architecture, name, product_code) of an AMI.
    Looking an AMI up by ID also returns deprecated AMIs, which is what the
    launch template of an older FortiOS version usually points at.
    """
    try:
        resp = ec2.describe_images(ImageIds=[ami_id])
        if not resp['Images']:
            return 'unknown', 'unknown', None
        img = resp['Images'][0]
        codes = [c.get('ProductCodeId') for c in img.get('ProductCodes', []) if c.get('ProductCodeId')]
        return img.get('Architecture', 'unknown'), img.get('Name', ''), (codes[0] if codes else None)
    except Exception as e:
        print(f"  Warning: could not describe AMI {ami_id}: {e}")
        return 'unknown', 'unknown', None


def detect_architecture(ec2, ami_id):
    """Detect x86 or arm64 from the current launch template AMI."""
    arch, name, _ = describe_ami(ec2, ami_id)
    return arch, name


def ami_name_filter(arch, license_type):
    """Return boto3 name filter for target AMI lookup."""
    if arch == 'arm64':
        if license_type == 'ondemand':
            return 'FortiGate-VMARM64-AWSONDEMAND*'
        else:
            # BYOL: name contains VMARM64-AWS but NOT AWSONDEMAND
            return 'FortiGate-VMARM64-AWS *'
    else:
        if license_type == 'ondemand':
            return 'FortiGate-VM64-AWSONDEMAND*'
        else:
            return 'FortiGate-VM64-AWS *'


def find_target_ami(ec2, arch, license_type, target_version, product_code=None):
    """
    Find the AMI ID for the target FortiOS version and architecture.

    The search is limited to images owned by AWS Marketplace and to the
    Marketplace product the deployment already uses. An image name alone is not
    enough: anyone can publish a public AMI with a FortiGate-looking name.
    """
    name_filter = ami_name_filter(arch, license_type)
    version_str = f'({target_version})'
    product_code = product_code or FALLBACK_PRODUCT_CODES.get((arch, license_type))

    filters = [{'Name': 'name', 'Values': [name_filter]}]
    if product_code:
        filters.append({'Name': 'product-code', 'Values': [product_code]})

    paginator = ec2.get_paginator('describe_images')
    pages = paginator.paginate(Owners=['aws-marketplace'], Filters=filters)
    images = []
    for page in pages:
        for img in page['Images']:
            if version_str in img.get('Name', ''):
                # Exclude Federal AMIs
                if 'Federal' not in img.get('Name', '') and 'prod-' not in img.get('Name', ''):
                    images.append(img)

    if not images:
        return None, None

    images.sort(key=lambda x: x['CreationDate'], reverse=True)
    img = images[0]
    return img['ImageId'], img['Name']


# ─────────────────────────────────────────────
# Live ASG state
# ─────────────────────────────────────────────

def get_live_asg(autoscaling, asg_name):
    """Get live ASG state including running instances."""
    try:
        resp = autoscaling.describe_auto_scaling_groups(
            AutoScalingGroupNames=[asg_name]
        )
        if not resp['AutoScalingGroups']:
            return None
        return resp['AutoScalingGroups'][0]
    except Exception as e:
        print(f"  Warning: could not describe ASG {asg_name}: {e}")
        return None


def get_autoscale_roles(ec2, instance_ids):
    """Return {instance_id: value of the 'Autoscale Role' tag} for the given instances."""
    roles = {}
    if not instance_ids:
        return roles
    try:
        resp = ec2.describe_instances(InstanceIds=list(instance_ids))
        for res in resp['Reservations']:
            for inst in res['Instances']:
                tags = {t['Key']: t['Value'] for t in inst.get('Tags', [])}
                roles[inst['InstanceId']] = tags.get('Autoscale Role', '')
    except Exception as e:
        print(f"  Warning: could not read Autoscale Role tags: {e}")
    return roles


# ─────────────────────────────────────────────
# Version change and upgrade path
# ─────────────────────────────────────────────

UPGRADE_PATH_TOOL_URL = 'https://docs.fortinet.com/upgrade-tool/fortigate'

# Version changes a blue-green upgrade refuses until the operator has confirmed the
# upgrade path, and the one it always refuses.
NEEDS_UPGRADE_PATH_CHECK = ('minor', 'major', 'unknown')


def parse_version(text):
    """'7.6.8' -> (7, 6, 8). None when text is not three dot-separated numbers."""
    parts = str(text or '').strip().split('.')
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)


def classify_version_change(current, target):
    """
    How far apart two FortiOS versions are: 'same', 'patch' (7.6.7 -> 7.6.8),
    'minor' (7.4.x -> 7.6.x), 'major' (7.x -> 8.x), 'downgrade', or 'unknown'
    when either version cannot be read.
    """
    cur, tgt = parse_version(current), parse_version(target)
    if not cur or not tgt:
        return 'unknown'
    if tgt == cur:
        return 'same'
    if tgt < cur:
        return 'downgrade'
    if tgt[0] != cur[0]:
        return 'major'
    if tgt[1] != cur[1]:
        return 'minor'
    return 'patch'


def fortios_version_from_ami_name(name):
    """'FortiGate-VMARM64-AWS build3744 (7.6.8) GA-...' -> '7.6.8'; 'unknown' if absent."""
    name = name or ''
    if '(' in name and ')' in name:
        return name.split('(')[1].split(')')[0]
    return 'unknown'


def running_fortios_versions(ec2, instance_ids):
    """Return {instance_id: FortiOS version of the AMI the instance was launched from}."""
    versions = {}
    if not instance_ids:
        return versions
    try:
        images = {}
        for res in ec2.describe_instances(InstanceIds=list(instance_ids))['Reservations']:
            for inst in res['Instances']:
                images[inst['InstanceId']] = inst.get('ImageId')
        names = {}
        for ami_id in {a for a in images.values() if a}:
            names[ami_id] = describe_ami(ec2, ami_id)[1]
        for instance_id, ami_id in images.items():
            versions[instance_id] = fortios_version_from_ami_name(names.get(ami_id))
    except Exception as e:
        print(f"  Warning: could not read the running FortiOS version: {e}")
    return versions


def backup_fortios_version(path):
    """
    FortiOS version a configuration backup was taken on, from its first line
    ('#config-version=FGAAWS-7.6.8-FW-build3744-...'). 'unknown' when the file cannot
    be read or has no such line, as with an encrypted backup.
    """
    try:
        with open(path, 'rb') as f:
            head = f.read(512).decode('utf-8', errors='replace')
    except OSError:
        return 'unknown'
    for line in head.splitlines():
        if line.startswith('#config-version='):
            for field in line.split(':')[0].split('-'):
                if parse_version(field):
                    return field
    return 'unknown'


def restore_path_errors(cur, tgt, verified, upgrade, restores, confirm):
    """
    Why a configuration backup taken on FortiOS `cur` must not be restored on `tgt`,
    as lines of text. Empty when it may.

      upgrade   what is being attempted, e.g. 'blue-green upgrade'
      restores  sentence saying what gets restored where
      confirm   how the operator confirms the upgrade path and tries again

    FortiOS converts an older backup when it is restored, in one step. That is only a
    supported path when Fortinet's upgrade path between the two versions is itself a
    single step.
    """
    kind = classify_version_change(cur, tgt)

    if kind == 'downgrade':
        return [
            f"ERROR: {upgrade} from FortiOS {cur} to {tgt} is a downgrade.",
            "",
            "  Fortinet supports no downgrade paths, and a configuration backup taken on a newer",
            "  FortiOS version cannot be restored on an older one.",
        ]

    if kind in NEEDS_UPGRADE_PATH_CHECK and not verified:
        what = {'major': 'crosses a major version',
                'minor': 'crosses a minor version',
                'unknown': 'starts from a version that could not be determined'}[kind]
        return [
            f"ERROR: {upgrade} from FortiOS {cur} to {tgt} {what},",
            "       and the upgrade path has not been confirmed.",
            "",
            f"  {restores}",
            "  FortiOS converts the backup when it is restored, in one step. Fortinet tests",
            "  upgrades step by step along the supported upgrade path; if that path has",
            "  intermediate versions between these two, the restore skips them and can lose or",
            "  corrupt configuration.",
            "",
            "  Before continuing:",
            f"    1. Open the Upgrade Path Tool: {UPGRADE_PATH_TOOL_URL}",
            f"       Select the FortiGate-VM AWS model, current version {cur}, target version {tgt}.",
            f"    2. Continue only if the recommended path is a single step, {cur} -> {tgt}.",
            "       If it lists intermediate versions, upgrade to the last intermediate version",
            "       first and start again from there.",
            f"    3. Read \"Upgrade information\" and the special notices in the {tgt} release notes.",
            "",
            f"  {confirm}",
        ]
    return []


def upgrade_path_errors(version_change, blue_green):
    """
    Why a blue-green upgrade must not go ahead with this version change, as lines
    of text. Empty when it may, and always empty for an in-place discovery: an
    in-place upgrade is checked by inplace_upgrade.py, and only when it restores a
    configuration backup.

    Blue-green carries the configuration across as a backup taken on the current
    version and restored on FortiGates already running the target version.
    """
    if not blue_green or not version_change:
        return []
    cur, tgt = version_change.get('from'), version_change.get('to')
    return restore_path_errors(
        cur, tgt, version_change.get('upgrade_path_verified'),
        upgrade='blue-green upgrade',
        restores=(f"A blue-green upgrade restores a configuration backup taken on {cur} onto "
                  f"FortiGates\n  that are already running {tgt}."),
        confirm='Then run discovery again with --upgrade-path-verified.')


def find_primary_instance(instances, roles):
    """
    Find the primary among one ASG's instances.

    The Lambda tags the elected primary 'Autoscale Role: Primary'. That tag is
    always written. Scale-in protection is only set when the deployment has
    primary_scalein_protection = true, so it is the fallback, and only when
    exactly one instance carries it.
    """
    tagged = [i['instance_id'] for i in instances if roles.get(i['instance_id']) == 'Primary']
    if len(tagged) == 1:
        return tagged[0]
    if len(tagged) > 1:
        print(f"  Warning: more than one instance is tagged Primary: {tagged}")
        return None
    protected = [i['instance_id'] for i in instances if i.get('protected')]
    if len(protected) == 1:
        return protected[0]
    return None


def get_gwlb_target_health(elbv2, target_group_arn):
    """Get health of all targets in the GWLB target group."""
    try:
        resp = elbv2.describe_target_health(TargetGroupArn=target_group_arn)
        return resp['TargetHealthDescriptions']
    except Exception as e:
        print(f"  Warning: could not get target health: {e}")
        return []


# ─────────────────────────────────────────────
# Main discovery
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# VPC resources discovery (existing_vpc_resources state)
# ─────────────────────────────────────────────

def discover_vpc_resources(vpc_state_file):
    """
    Extract VPC topology from existing_vpc_resources terraform state.
    Used by blue-green upgrade to understand the full TGW topology and
    generate green.tfvars with correct CIDRs and attachment IDs.
    """
    print(f"Loading vpc state from {vpc_state_file}...")
    state = load_state(vpc_state_file)

    # ── VPCs ──────────────────────────────────
    vpcs = []
    seen = set()
    for attr in get_resources(state, 'aws_vpc'):
        if attr['id'] in seen:
            continue
        seen.add(attr['id'])
        tags = attr.get('tags', {}) or {}
        vpcs.append({
            'id': attr['id'],
            'cidr': attr['cidr_block'],
            'name': tags.get('Name', attr['id']),
        })

    # ── TGW route tables ──────────────────────
    route_tables = {}
    for r in state['resources']:
        if r['type'] != 'aws_ec2_transit_gateway_route_table':
            continue
        for inst in r.get('instances', []):
            rtb_id = inst['attributes']['id']
            route_tables[r['name']] = rtb_id

    # ── TGW VPC attachments ───────────────────
    attachments = {}
    seen_attach = set()
    for r in state['resources']:
        if r['type'] != 'aws_ec2_transit_gateway_vpc_attachment':
            continue
        for inst in r.get('instances', []):
            a = inst['attributes']
            attach_id = a['id']
            if attach_id in seen_attach:
                continue
            seen_attach.add(attach_id)
            # Derive role from the VPC it attaches to
            tags = a.get('tags', {}) or {}
            vpc_name = tags.get('Name', attach_id)
            attachments[attach_id] = {
                'id': attach_id,
                'vpc_id': a.get('vpc_id'),
                'name': vpc_name,
            }

    # ── TGW routes (0.0.0.0/0 default routes to switch at cutover) ──
    cutover_routes = []
    for attr in get_resources(state, 'aws_ec2_transit_gateway_route'):
        if attr.get('destination_cidr_block') == '0.0.0.0/0':
            cutover_routes.append({
                'destination_cidr_block': attr['destination_cidr_block'],
                'route_table_id': attr['transit_gateway_route_table_id'],
                'current_attachment_id': attr['transit_gateway_attachment_id'],
            })

    return {
        'vpcs': vpcs,
        'tgw_route_tables': route_tables,
        'tgw_attachments': list(attachments.values()),
        'cutover_routes': cutover_routes,
    }


def region_from_state(state):
    """Read the deployment's region from an ARN in the terraform state."""
    for rtype in ('aws_lb', 'aws_lb_target_group', 'aws_autoscaling_group', 'aws_launch_template'):
        for attr in get_resources(state, rtype):
            arn = attr.get('arn') or ''
            parts = arn.split(':')
            if len(parts) > 3 and parts[3]:
                return parts[3]
    return None


def resolve_region(state, region_arg=None):
    """--region wins, then the region recorded in the state file, then the AWS CLI profile."""
    state_region = region_from_state(state)
    session_region = boto3.session.Session().region_name
    if region_arg:
        if state_region and state_region != region_arg:
            print(f"  Warning: --region {region_arg} differs from the state file's region {state_region}")
        return region_arg
    if state_region:
        if session_region and session_region != state_region:
            print(f"  Note: using region {state_region} from the state file "
                  f"(the AWS CLI profile is set to {session_region})")
        return state_region
    if session_region:
        return session_region
    print("Error: could not determine the AWS region from the state file or the AWS CLI profile.")
    print("       Pass it explicitly with --region.")
    sys.exit(1)


def discover(state_file, target_version=None, vpc_state_file=None, region_arg=None,
             upgrade_path_verified=False):
    print(f"\nLoading state from {state_file}...")
    state = load_state(state_file)

    region = resolve_region(state, region_arg)
    ec2 = boto3.client('ec2', region_name=region)
    autoscaling = boto3.client('autoscaling', region_name=region)
    elbv2 = boto3.client('elbv2', region_name=region)

    inventory = {
        'discovery_metadata': {
            'state_file': state_file,
            'vpc_state_file': vpc_state_file,
            'discovered_at': datetime.now(timezone.utc).isoformat(),
            'region': region,
        }
    }

    # ── VPC ──────────────────────────────────
    print("Discovering VPC...")
    vpc = get_resource(state, 'aws_vpc', 'inspection')
    if not vpc:
        # fallback: any vpc resource
        vpc = get_resource(state, 'aws_vpc')
    inventory['inspection_vpc'] = {
        'vpc_id': vpc['id'],
        'cidr_block': vpc['cidr_block'],
    }

    # ── Subnets ───────────────────────────────
    print("Discovering subnets...")
    subnets = {}
    for attr in get_resources(state, 'aws_subnet'):
        sid = attr['id']
        cidr = attr['cidr_block']
        az = attr['availability_zone']
        tags = {t['key']: t['value'] for t in attr.get('tags', []) or []} if isinstance(attr.get('tags'), list) else attr.get('tags', {}) or {}
        role = tags.get('Fortinet-Role', '')
        name = tags.get('Name', attr.get('id', ''))
        subnets[sid] = {'id': sid, 'cidr': cidr, 'az': az, 'role': role, 'name': name}
    inventory['subnets'] = list(subnets.values())

    # ── NAT Gateways ─────────────────────────
    # The inspection VPC is normally built by existing_vpc_resources, so its NAT
    # gateways are in that state and are added below when --vpc-state is given.
    print("Discovering NAT gateways...")
    nat_gws = nat_gateways_in_state(state)
    inventory['nat_gateways'] = nat_gws
    inventory['egress_mode'] = 'nat_gw' if nat_gws else 'eip'

    # ── GWLB ─────────────────────────────────
    print("Discovering GWLB...")
    gwlb = get_resource(state, 'aws_lb', 'gwlb')
    tg = get_resource(state, 'aws_lb_target_group')
    endpoints = get_resources(state, 'aws_vpc_endpoint')

    inventory['gwlb'] = {
        'lb_arn': gwlb['arn'] if gwlb else None,
        'lb_name': gwlb['name'] if gwlb else None,
        'target_group_arn': tg['arn'] if tg else None,
        'endpoint_ids': list({e['id'] for e in endpoints}),
    }

    # ── TGW ──────────────────────────────────
    print("Discovering Transit Gateway...")
    tgw_attachment = get_resource(state, 'aws_ec2_transit_gateway_vpc_attachment', 'inspection')
    tgw_routes = get_resources(state, 'aws_ec2_transit_gateway_route')

    routes_to_update = []
    for r in tgw_routes:
        routes_to_update.append({
            'destination_cidr_block': r.get('destination_cidr_block'),
            'route_table_id': r.get('transit_gateway_route_table_id'),
            'current_attachment_id': r.get('transit_gateway_attachment_id'),
        })

    inventory['transit_gateway'] = {
        'tgw_id': tgw_attachment['transit_gateway_id'] if tgw_attachment else None,
        'inspection_attachment_id': tgw_attachment['id'] if tgw_attachment else None,
        'routes_to_update': routes_to_update,
    }

    # ── Launch Templates ──────────────────────
    print("Discovering launch templates...")
    launch_templates = {}
    for attr in get_resources(state, 'aws_launch_template'):
        lt_name = attr['name']
        ami_id = attr.get('image_id') or attr.get('image_id')

        # detect from userdata if image_id not directly on template
        if not ami_id:
            ami_id = 'unknown'

        license_type = 'ondemand' if 'on_demand' in lt_name.lower() or 'ondemand' in lt_name.lower() else 'byol'
        launch_templates[license_type] = {
            'id': attr['id'],
            'name': lt_name,
            'current_version': attr.get('latest_version', 1),
            'current_ami_id': ami_id,
            'license_type': license_type,
        }

    # ── Architecture detection ────────────────
    print("Detecting instance architecture...")
    byol_lt = launch_templates.get('byol', {})
    current_ami_id = byol_lt.get('current_ami_id', 'unknown')
    arch, current_ami_name = detect_architecture(ec2, current_ami_id)

    # derive fortios version from AMI name e.g. "build1762 (7.2.13)"
    current_version = 'unknown'
    if '(' in current_ami_name and ')' in current_ami_name:
        current_version = current_ami_name.split('(')[1].split(')')[0]

    inventory['architecture'] = {
        'arch': arch,
        'current_ami_id': current_ami_id,
        'current_ami_name': current_ami_name,
        'current_fortios_version': current_version,
    }

    # ── Target AMI lookup ─────────────────────
    if target_version:
        if arch not in ('x86_64', 'arm64'):
            print(f"Error: could not detect the architecture of the current AMI ({current_ami_id}).")
            print("       Without it the target AMI cannot be chosen safely. Check that the state file")
            print("       is current and that the AWS credentials can describe that AMI.")
            sys.exit(1)

        print(f"Looking up target AMI for FortiOS {target_version} ({arch})...")
        product_codes = {}
        for lic, lt in launch_templates.items():
            _, _, product_codes[lic] = describe_ami(ec2, lt['current_ami_id'])
            lt['product_code'] = product_codes[lic] or FALLBACK_PRODUCT_CODES.get((arch, lic))

        byol_ami_id, byol_ami_name = find_target_ami(
            ec2, arch, 'byol', target_version, product_codes.get('byol'))
        od_ami_id, od_ami_name = find_target_ami(
            ec2, arch, 'ondemand', target_version, product_codes.get('ondemand'))

        missing = [lic for lic in launch_templates
                   if not (byol_ami_id if lic == 'byol' else od_ami_id)]
        if missing:
            print(f"Error: no AWS Marketplace AMI found for FortiOS {target_version} ({arch}) "
                  f"for: {', '.join(missing)}.")
            print(f"       Check the version number and that it is published in {region}.")
            sys.exit(1)

        inventory['target'] = {
            'fortios_version': target_version,
            'byol_ami_id': byol_ami_id,
            'byol_ami_name': byol_ami_name,
            'ondemand_ami_id': od_ami_id,
            'ondemand_ami_name': od_ami_name,
        }

        for lt in launch_templates.values():
            lt['target_ami_id'] = byol_ami_id if lt['license_type'] == 'byol' else od_ami_id

    inventory['launch_templates'] = launch_templates

    # ── ASGs (live state from AWS) ────────────
    print("Reading live ASG state from AWS...")
    asgs = {}
    for attr in get_resources(state, 'aws_autoscaling_group'):
        asg_name = attr['name']
        license_type = 'ondemand' if 'on_demand' in asg_name.lower() or 'ondemand' in asg_name.lower() else 'byol'

        live = get_live_asg(autoscaling, asg_name)
        if live:
            instances = [
                {
                    'instance_id': i['InstanceId'],
                    'health': i['HealthStatus'],
                    'lifecycle': i['LifecycleState'],
                    'protected': i.get('ProtectedFromScaleIn', False),
                }
                for i in live.get('Instances', [])
            ]
            roles = get_autoscale_roles(ec2, [i['instance_id'] for i in instances])
            for i in instances:
                i['role'] = roles.get(i['instance_id'], '')
            primary = find_primary_instance(instances, roles)
            asgs[license_type] = {
                'asg_name': asg_name,
                'license_type': license_type,
                'desired': live['DesiredCapacity'],
                'min': live['MinSize'],
                'max': live['MaxSize'],
                'instances': instances,
                'primary_instance': primary,
                'launch_template_id': attr.get('launch_template', [{}])[0].get('id') if attr.get('launch_template') else None,
            }
        else:
            print(f"  Warning: ASG {asg_name} is in the state file but was not found in {region}. "
                  f"The state file may be out of date, or the credentials may be for another account.")
            asgs[license_type] = {
                'asg_name': asg_name,
                'license_type': license_type,
                'desired': attr.get('desired_capacity', 0),
                'min': attr.get('min_size', 0),
                'max': attr.get('max_size', 0),
                'instances': [],
                'primary_instance': None,
            }

    inventory['autoscale_groups'] = asgs

    # ── Running version and version change ────
    # The launch template in the state file is what Terraform last applied. After an
    # in-place upgrade that has not been reconciled it still names the old version, so
    # the version that matters is the one the primary is running: that is where the
    # configuration backup comes from.
    in_service = [i for asg in asgs.values() for i in asg.get('instances', [])
                  if i['lifecycle'] == 'InService']
    running = running_fortios_versions(ec2, [i['instance_id'] for i in in_service])
    for i in in_service:
        i['fortios_version'] = running.get(i['instance_id'], 'unknown')
    primaries = [asg['primary_instance'] for asg in asgs.values() if asg.get('primary_instance')]
    primary_version = running.get(primaries[0]) if len(primaries) == 1 else None
    known = sorted({v for v in running.values() if v != 'unknown'})
    if primary_version and primary_version != 'unknown':
        running_version, version_source = primary_version, 'primary instance'
    elif len(known) == 1:
        running_version, version_source = known[0], 'running instances'
    else:
        running_version, version_source = current_version, 'launch template in the state file'
    inventory['architecture']['running_fortios_version'] = running_version
    inventory['architecture']['running_fortios_version_source'] = version_source

    if target_version:
        inventory['version_change'] = {
            'from': running_version,
            'to': target_version,
            'kind': classify_version_change(running_version, target_version),
            'upgrade_path_verified': bool(upgrade_path_verified),
        }

    # ── Lambda + DynamoDB ─────────────────────
    print("Discovering Lambda and DynamoDB...")
    lambdas = [attr.get('function_name') for attr in get_resources(state, 'aws_lambda_function')]
    dynamo = get_resource(state, 'aws_dynamodb_table')
    inventory['lambda'] = {'function_names': lambdas}
    inventory['dynamodb'] = {'table_name': dynamo['name'] if dynamo else None}

    # ── CloudWatch Alarms ─────────────────────
    print("Discovering CloudWatch alarms...")
    alarms = []
    for attr in get_resources(state, 'aws_cloudwatch_metric_alarm'):
        alarms.append({
            'alarm_name': attr.get('alarm_name'),
            'metric': attr.get('metric_name'),
            'threshold': attr.get('threshold'),
            'comparison': attr.get('comparison_operator'),
            'evaluation_periods': attr.get('evaluation_periods'),
            'period': attr.get('period'),
        })
    inventory['cloudwatch_alarms'] = alarms

    # ── Path detection ────────────────────────
    byol_desired = asgs.get('byol', {}).get('desired', 0)
    od_desired = asgs.get('ondemand', {}).get('desired', 0)
    total_running = sum(
        1 for asg in asgs.values()
        for inst in asg.get('instances', [])
        if inst['lifecycle'] == 'InService'
    )

    if byol_desired == 0 and od_desired == 0:
        upgrade_path = 'A'
        path_reason = 'desired=0 on all ASGs — launch template update only'
    else:
        upgrade_path = 'B'
        path_reason = f'{total_running} running instance(s) — rolling replacement'

    inventory['upgrade_path'] = upgrade_path
    inventory['upgrade_path_reason'] = path_reason

    # ── VPC resources (blue-green only) ──────
    if vpc_state_file:
        print("Discovering VPC resources (existing_vpc_resources)...")
        inventory['vpc_resources'] = discover_vpc_resources(vpc_state_file)

        # NAT gateways of the inspection VPC that existing_vpc_resources created.
        # Only that VPC's: the same state can hold a management VPC NAT gateway.
        known = {n['id'] for n in inventory['nat_gateways']}
        from_vpc_state = [
            n for n in nat_gateways_in_state(load_state(vpc_state_file),
                                             inventory['inspection_vpc']['vpc_id'])
            if n['id'] not in known
        ]
        if from_vpc_state:
            inventory['nat_gateways'].extend(from_vpc_state)
            inventory['egress_mode'] = 'nat_gw'

    return inventory


# ─────────────────────────────────────────────
# Output + summary
# ─────────────────────────────────────────────

def print_summary(inventory):
    arch = inventory.get('architecture', {})
    asgs = inventory.get('autoscale_groups', {})
    target = inventory.get('target', {})
    nats = inventory.get('nat_gateways', [])

    print()
    print("=" * 60)
    print("  DISCOVERY SUMMARY")
    print("=" * 60)
    print(f"  VPC:          {inventory['inspection_vpc']['vpc_id']}  ({inventory['inspection_vpc']['cidr_block']})")
    print(f"  Architecture: {arch.get('arch', 'unknown')}")
    print(f"  Current AMI:  {arch.get('current_ami_id')}  (FortiOS {arch.get('current_fortios_version')})")

    if arch.get('running_fortios_version'):
        print(f"  Running:      FortiOS {arch['running_fortios_version']}  "
              f"(from the {arch.get('running_fortios_version_source')})")

    if target:
        print(f"  Target AMI:   {target.get('byol_ami_id')}  (FortiOS {target.get('fortios_version')})")

    change = inventory.get('version_change')
    if change:
        verified = '  — upgrade path confirmed by the operator' if change.get('upgrade_path_verified') else ''
        print(f"  Version change: {change['from']} -> {change['to']}  ({change['kind']}){verified}")
        if change['kind'] != 'same' and not change.get('upgrade_path_verified'):
            print(f"    Check the supported upgrade path before upgrading: {UPGRADE_PATH_TOOL_URL}")

    print()
    print("  ASGs:")
    for lt, asg in asgs.items():
        print(f"    {asg['asg_name']}")
        print(f"      desired={asg['desired']}, min={asg['min']}, max={asg['max']}")
        print(f"      instances: {len(asg.get('instances', []))}  primary: {asg.get('primary_instance') or 'none'}")

    if nats:
        print()
        print("  NAT Gateways (EIPs to preserve):")
        for n in nats:
            print(f"    {n['id']}  {n['public_ip']}  ({n['eip_allocation_id']})")

    print()
    print(f"  Upgrade Path: {inventory['upgrade_path']} — {inventory['upgrade_path_reason']}")
    print("=" * 60)


# ─────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Discover Blue environment from terraform state')
    parser.add_argument('--state', default='state/autoscale_template.tfstate',
                        help='Path to autoscale_template state (default: state/autoscale_template.tfstate)')
    parser.add_argument('--vpc-state', default=None,
                        help='Path to existing_vpc_resources state (required for blue-green)')
    parser.add_argument('--output', default='blue_inventory.json',
                        help='Output inventory file (default: blue_inventory.json)')
    parser.add_argument('--target-version',
                        help='Target FortiOS version (e.g. 7.6.8) — triggers AMI lookup')
    parser.add_argument('--region', default=None,
                        help='AWS region of the deployment (default: read from the state file, '
                             'then from the AWS CLI profile)')
    parser.add_argument('--upgrade-path-verified', action='store_true',
                        help='Confirm that Fortinet\'s Upgrade Path Tool gives a single-step path '
                             'from the running version to --target-version. Required for a '
                             'blue-green discovery (--vpc-state) that crosses a minor or major '
                             'version: without it discovery stops and writes no inventory. Recorded '
                             'in the inventory, where inplace_upgrade.py and cutover.py read it.')
    args = parser.parse_args()

    try:
        inventory = discover(args.state, args.target_version, args.vpc_state, args.region,
                             upgrade_path_verified=args.upgrade_path_verified)
    except FileNotFoundError as e:
        print(f"Error: state file not found: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error during discovery: {e}")
        raise

    # A blue-green upgrade (--vpc-state) across a minor or major version stops here
    # until the upgrade path has been confirmed. No inventory is written, so nothing
    # downstream can run on it.
    errors = upgrade_path_errors(inventory.get('version_change'), blue_green=bool(args.vpc_state))
    if errors:
        print()
        print('\n'.join(errors))
        sys.exit(2)

    with open(args.output, 'w') as f:
        json.dump(inventory, f, indent=2, default=str)

    print_summary(inventory)
    print(f"\nInventory written to {args.output}")


if __name__ == '__main__':
    main()
