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


# ─────────────────────────────────────────────
# Architecture detection
# ─────────────────────────────────────────────

def detect_architecture(ec2, ami_id):
    """Detect x86 or arm64 from the current launch template AMI."""
    try:
        resp = ec2.describe_images(ImageIds=[ami_id])
        if not resp['Images']:
            return 'unknown', 'unknown'
        img = resp['Images'][0]
        arch = img.get('Architecture', 'unknown')
        name = img.get('Name', '')
        return arch, name
    except Exception as e:
        print(f"  Warning: could not describe AMI {ami_id}: {e}")
        return 'unknown', 'unknown'


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


def find_target_ami(ec2, arch, license_type, target_version):
    """Find the AMI ID for the target FortiOS version and architecture."""
    name_filter = ami_name_filter(arch, license_type)
    version_str = f'({target_version})'

    paginator = ec2.get_paginator('describe_images')
    pages = paginator.paginate(Filters=[
        {'Name': 'name', 'Values': [name_filter]}
    ])
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


def find_primary_instance(autoscaling, asg_name):
    """Find the primary instance — the one with scale-in protection."""
    try:
        resp = autoscaling.describe_auto_scaling_instances()
        for inst in resp['AutoScalingInstances']:
            if (inst['AutoScalingGroupName'] == asg_name and
                    inst.get('ProtectedFromScaleIn')):
                return inst['InstanceId']
    except Exception as e:
        print(f"  Warning: could not find primary instance: {e}")
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


def discover(state_file, target_version=None, vpc_state_file=None):
    print(f"\nLoading state from {state_file}...")
    state = load_state(state_file)

    region = boto3.session.Session().region_name or 'us-west-2'
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
    print("Discovering NAT gateways...")
    nat_gws = []
    for attr in get_resources(state, 'aws_nat_gateway'):
        nat_gws.append({
            'id': attr['id'],
            'subnet_id': attr.get('subnet_id'),
            'eip_allocation_id': attr.get('allocation_id'),
            'public_ip': attr.get('public_ip'),
        })
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
        print(f"Looking up target AMI for FortiOS {target_version} ({arch})...")
        byol_ami_id, byol_ami_name = find_target_ami(ec2, arch, 'byol', target_version)
        od_ami_id, od_ami_name = find_target_ami(ec2, arch, 'ondemand', target_version)

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
            primary = find_primary_instance(autoscaling, asg_name)
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

    if target:
        print(f"  Target AMI:   {target.get('byol_ami_id')}  (FortiOS {target.get('fortios_version')})")

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
                        help='Target FortiOS version (e.g. 7.6.6) — triggers AMI lookup')
    args = parser.parse_args()

    try:
        inventory = discover(args.state, args.target_version, args.vpc_state)
    except FileNotFoundError as e:
        print(f"Error: state file not found: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error during discovery: {e}")
        raise

    with open(args.output, 'w') as f:
        json.dump(inventory, f, indent=2, default=str)

    print_summary(inventory)
    print(f"\nInventory written to {args.output}")


if __name__ == '__main__':
    main()
