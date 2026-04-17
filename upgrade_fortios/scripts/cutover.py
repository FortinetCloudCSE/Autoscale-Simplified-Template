#!/usr/bin/env python3
"""
cutover.py — Blue-to-Green cutover: TGW route flip + NAT Gateway EIP migration

Two-phase execution:

  Phase 1 — TGW Route Flip  (< 30 seconds)
    Replaces spoke-VPC TGW default routes from Blue attachment → Green attachment.
    Production traffic immediately routes to Green FortiGates.

  Phase 2 — NAT Gateway EIP Migration  (nat_gw mode only, ~2–3 minutes)
    Migrates Blue public EIPs to Green NAT Gateways so outbound source IPs are
    preserved. External firewall rules and IP allowlists are unaffected.

    Step 2a  Delete Blue NAT Gateways → Blue EIPs released
    Step 2b  Wait for Blue NAT GW deletion to complete (~60 s)
    Step 2c  Create new Green NAT GWs in Green natgw subnets with Blue EIP alloc IDs
    Step 2d  Wait for new NAT GWs to become Available (~60 s)
    Step 2e  Update Green VPC route tables: old Green natgw IDs → new natgw IDs
    Step 2f  Delete original Green NAT GWs (temp EIPs)
    Step 2g  Release Green temp EIP allocations

Progress is written to state/cutover_progress.json after each phase so that
rollback.py can determine what has been done and what needs to be undone.

Usage:
  python3 scripts/cutover.py \\
    --inventory  state/blue_inventory.json \\
    --green-state state/green.tfstate \\
    [--dry-run] [--yes]

Options:
  --dry-run    Preview all changes without executing any AWS API calls.
  --yes        Skip the interactive confirmation prompt.
"""

import argparse
import boto3
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ─────────────────────────────────────────────────────────────────────────────
# State file helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_inventory(path):
    with open(path) as f:
        return json.load(f)


def load_green_state(path):
    with open(path) as f:
        return json.load(f)


def get_green_output(state, name):
    """Extract a Terraform output value from parsed green tfstate."""
    return state.get('outputs', {}).get(name, {}).get('value')


def get_green_resources(state, resource_type, name=None):
    """Return attribute dicts for matching resources in green tfstate."""
    results = []
    for r in state.get('resources', []):
        if r['type'] != resource_type:
            continue
        if name and r.get('name') != name:
            continue
        for inst in r.get('instances', []):
            results.append(inst['attributes'])
    return results


def get_green_resource(state, resource_type, name=None):
    results = get_green_resources(state, resource_type, name)
    return results[0] if results else None


# ─────────────────────────────────────────────────────────────────────────────
# Route collection
# ─────────────────────────────────────────────────────────────────────────────

def collect_routes_to_flip(inventory):
    """
    Merge TGW routes from all inventory sources.
    Returns a de-duplicated list of routes to flip, keyed by (rtb_id, cidr).
    """
    seen = {}

    # Primary source: autoscale_template state (routes_to_update)
    for r in inventory.get('transit_gateway', {}).get('routes_to_update', []):
        key = (r['route_table_id'], r['destination_cidr_block'])
        seen[key] = r

    # Secondary source: existing_vpc_resources state (cutover_routes)
    for r in inventory.get('vpc_resources', {}).get('cutover_routes', []):
        key = (r['route_table_id'], r['destination_cidr_block'])
        if key not in seen:
            seen[key] = r

    return list(seen.values())


# ─────────────────────────────────────────────────────────────────────────────
# Green state extraction
# ─────────────────────────────────────────────────────────────────────────────

def extract_green_info(green_state):
    """
    Pull everything cutover needs from the Green Terraform state.

    Returns a dict with:
      tgw_attachment_id
      natgw_az1 / natgw_az2  (id, subnet_id, temp_eip_allocation_id, temp_eip)
      vpc_id
    """
    info = {
        'tgw_attachment_id': get_green_output(green_state, 'green_tgw_attachment_id'),
        'vpc_id': get_green_output(green_state, 'green_vpc_id'),
    }

    # NAT Gateway info from outputs
    natgw_az1_id = get_green_output(green_state, 'green_natgw_az1_id')
    natgw_az2_id = get_green_output(green_state, 'green_natgw_az2_id')
    natgw_az1_temp_alloc = get_green_output(green_state, 'green_natgw_az1_eip_allocation_id')
    natgw_az2_temp_alloc = get_green_output(green_state, 'green_natgw_az2_eip_allocation_id')
    natgw_az1_temp_eip   = get_green_output(green_state, 'green_natgw_az1_temp_eip')
    natgw_az2_temp_eip   = get_green_output(green_state, 'green_natgw_az2_temp_eip')

    # Natgw subnet IDs from resources (not in outputs)
    natgw_az1_res = get_green_resource(green_state, 'aws_nat_gateway', 'green_az1')
    natgw_az2_res = get_green_resource(green_state, 'aws_nat_gateway', 'green_az2')

    natgw_az1_subnet = natgw_az1_res['subnet_id'] if natgw_az1_res else None
    natgw_az2_subnet = natgw_az2_res['subnet_id'] if natgw_az2_res else None

    # Natgw subnet AZ from resources
    subnet_az1_res = get_green_resource(green_state, 'aws_subnet', 'green_natgw_az1')
    subnet_az2_res = get_green_resource(green_state, 'aws_subnet', 'green_natgw_az2')

    natgw_az1_az = subnet_az1_res['availability_zone'] if subnet_az1_res else None
    natgw_az2_az = subnet_az2_res['availability_zone'] if subnet_az2_res else None
    natgw_az1_cidr = subnet_az1_res['cidr_block'] if subnet_az1_res else None
    natgw_az2_cidr = subnet_az2_res['cidr_block'] if subnet_az2_res else None

    if natgw_az1_id:
        info['natgw_az1'] = {
            'id':                  natgw_az1_id,
            'subnet_id':           natgw_az1_subnet,
            'subnet_az':           natgw_az1_az,
            'subnet_cidr':         natgw_az1_cidr,
            'temp_eip_allocation': natgw_az1_temp_alloc,
            'temp_eip':            natgw_az1_temp_eip,
        }
    if natgw_az2_id:
        info['natgw_az2'] = {
            'id':                  natgw_az2_id,
            'subnet_id':           natgw_az2_subnet,
            'subnet_az':           natgw_az2_az,
            'subnet_cidr':         natgw_az2_cidr,
            'temp_eip_allocation': natgw_az2_temp_alloc,
            'temp_eip':            natgw_az2_temp_eip,
        }

    return info


# ─────────────────────────────────────────────────────────────────────────────
# AZ-based NAT GW pairing
# ─────────────────────────────────────────────────────────────────────────────

def pair_natgws_by_az(ec2, blue_natgws, green_info):
    """
    Match each Blue NAT Gateway to the Green NAT GW subnet in the same AZ.

    Returns a list of dicts:
      {
        'blue_natgw_id':       str,
        'blue_eip_alloc':      str,
        'blue_eip':            str,
        'blue_subnet_id':      str,
        'az':                  str,
        'green_natgw_id':      str,    # original Green NAT GW (to delete)
        'green_subnet_id':     str,    # Green natgw subnet to create new NAT GW in
        'green_temp_alloc':    str,
      }
    """
    # Resolve Blue NAT GW subnet AZs from AWS
    blue_subnet_ids = [n['subnet_id'] for n in blue_natgws if n.get('subnet_id')]
    if not blue_subnet_ids:
        raise RuntimeError("Blue NAT gateway subnet IDs not found in inventory")

    resp = ec2.describe_subnets(SubnetIds=blue_subnet_ids)
    blue_subnet_az = {s['SubnetId']: s['AvailabilityZone'] for s in resp['Subnets']}

    # Build Green natgw info indexed by AZ
    green_by_az = {}
    for key in ('natgw_az1', 'natgw_az2'):
        gn = green_info.get(key)
        if gn and gn.get('subnet_az'):
            green_by_az[gn['subnet_az']] = gn

    pairs = []
    for blue in blue_natgws:
        az = blue_subnet_az.get(blue['subnet_id'])
        if not az:
            raise RuntimeError(f"Cannot determine AZ for Blue NAT GW {blue['id']} subnet {blue['subnet_id']}")
        green = green_by_az.get(az)
        if not green:
            raise RuntimeError(
                f"No Green NAT GW subnet found for AZ {az}. "
                f"Available Green AZs: {list(green_by_az.keys())}"
            )
        pairs.append({
            'blue_natgw_id':    blue['id'],
            'blue_eip_alloc':   blue['eip_allocation_id'],
            'blue_eip':         blue['public_ip'],
            'blue_subnet_id':   blue['subnet_id'],
            'az':               az,
            'green_natgw_id':   green['id'],
            'green_subnet_id':  green['subnet_id'],
            'green_temp_alloc': green['temp_eip_allocation'],
            'green_temp_eip':   green.get('temp_eip'),
        })

    return pairs


# ─────────────────────────────────────────────────────────────────────────────
# Wait helpers
# ─────────────────────────────────────────────────────────────────────────────

def wait_nat_gw_deleted(ec2, natgw_ids, timeout=180, poll=10):
    """Poll until all NAT GWs reach 'deleted' state."""
    ids = list(natgw_ids)
    deadline = time.time() + timeout
    while True:
        resp = ec2.describe_nat_gateways(NatGatewayIds=ids)
        states = {n['NatGatewayId']: n['State'] for n in resp['NatGateways']}
        not_done = [nid for nid in ids if states.get(nid) not in ('deleted', 'deleting')]
        pending  = [nid for nid in ids if states.get(nid) == 'deleting']
        if not pending and not not_done:
            print(f"  All NAT Gateways deleted: {ids}")
            return
        summary = ', '.join(f"{nid}={states.get(nid,'?')}" for nid in ids)
        print(f"  Waiting for NAT GW deletion: {summary}")
        if time.time() > deadline:
            raise TimeoutError(f"NAT GW deletion timed out after {timeout}s: {summary}")
        time.sleep(poll)


def wait_nat_gw_available(ec2, natgw_ids, timeout=180, poll=10):
    """Poll until all NAT GWs reach 'available' state."""
    ids = list(natgw_ids)
    deadline = time.time() + timeout
    while True:
        resp = ec2.describe_nat_gateways(NatGatewayIds=ids)
        states = {n['NatGatewayId']: n['State'] for n in resp['NatGateways']}
        pending = [nid for nid in ids if states.get(nid) != 'available']
        if not pending:
            print(f"  All NAT Gateways available: {ids}")
            return
        summary = ', '.join(f"{nid}={states.get(nid,'?')}" for nid in ids)
        print(f"  Waiting for NAT GW availability: {summary}")
        if time.time() > deadline:
            raise TimeoutError(f"NAT GW availability timed out after {timeout}s: {summary}")
        time.sleep(poll)


# ─────────────────────────────────────────────────────────────────────────────
# Green VPC route table update
# ─────────────────────────────────────────────────────────────────────────────

def update_vpc_routes_for_new_natgw(ec2, vpc_id, old_natgw_id, new_natgw_id, dry_run=False):
    """
    Find all route tables in vpc_id that route via old_natgw_id and
    replace those routes with new_natgw_id.
    """
    resp = ec2.describe_route_tables(
        Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}]
    )
    updated = []
    for rt in resp['RouteTables']:
        rt_id = rt['RouteTableId']
        for route in rt.get('Routes', []):
            if route.get('NatGatewayId') == old_natgw_id:
                cidr = route['DestinationCidrBlock']
                print(f"  Route table {rt_id}: {cidr} → {old_natgw_id}  →  {new_natgw_id}")
                if not dry_run:
                    ec2.replace_route(
                        RouteTableId=rt_id,
                        DestinationCidrBlock=cidr,
                        NatGatewayId=new_natgw_id,
                    )
                updated.append({'route_table_id': rt_id, 'cidr': cidr})
    return updated


# ─────────────────────────────────────────────────────────────────────────────
# Progress file
# ─────────────────────────────────────────────────────────────────────────────

def write_progress(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, default=str)


# ─────────────────────────────────────────────────────────────────────────────
# Dry-run preview
# ─────────────────────────────────────────────────────────────────────────────

def print_preview(routes_to_flip, green_attach_id, blue_natgws, green_info, egress_mode, pairs=None):
    print()
    print("=" * 70)
    print("  CUTOVER PREVIEW  (--dry-run)")
    print("=" * 70)
    print()
    print(f"  Green TGW attachment: {green_attach_id}")
    print()
    print("  PHASE 1 — TGW Route Flip")
    print(f"  {len(routes_to_flip)} route(s) will be updated:")
    for r in routes_to_flip:
        print(f"    {r['route_table_id']}  {r['destination_cidr_block']}")
        print(f"      {r['current_attachment_id']}  →  {green_attach_id}")
    print()
    if egress_mode == 'nat_gw' and pairs:
        print("  PHASE 2 — NAT Gateway EIP Migration")
        print(f"  {len(pairs)} AZ(s) to migrate:")
        for p in pairs:
            print(f"    AZ {p['az']}:")
            print(f"      Blue NAT GW {p['blue_natgw_id']} (EIP {p['blue_eip']}) — DELETE")
            print(f"      Green NAT GW {p['green_natgw_id']} (temp EIP {p['green_temp_eip']}) — REPLACE")
            print(f"      New Green NAT GW will be created in subnet {p['green_subnet_id']}")
            print(f"        using Blue EIP allocation {p['blue_eip_alloc']} ({p['blue_eip']})")
    elif egress_mode == 'eip':
        print("  PHASE 2 — Skipped (egress mode is 'eip', no NAT Gateways)")
    print()
    print("=" * 70)


# ─────────────────────────────────────────────────────────────────────────────
# Main cutover logic
# ─────────────────────────────────────────────────────────────────────────────

def run_cutover(inventory, green_state, dry_run, yes, progress_path):
    region = inventory.get('discovery_metadata', {}).get('region', 'us-west-2')
    ec2 = boto3.client('ec2', region_name=region)

    green_info   = extract_green_info(green_state)
    green_attach = green_info.get('tgw_attachment_id')
    if not green_attach:
        print("ERROR: green_tgw_attachment_id not found in green state outputs.")
        print("       Has 'terraform apply' completed for the green_inspection_stack?")
        sys.exit(1)

    egress_mode  = inventory.get('egress_mode', 'eip')
    blue_natgws  = inventory.get('nat_gateways', [])
    routes       = collect_routes_to_flip(inventory)

    if not routes:
        print("WARNING: No TGW routes found to flip. Check that discovery was run with")
        print("         --vpc-state pointing to existing_vpc_resources.tfstate.")

    # Pair NAT GWs before preview (need AZ info from AWS even for dry-run)
    pairs = []
    if egress_mode == 'nat_gw' and blue_natgws:
        print("Resolving NAT Gateway AZ assignments...")
        pairs = pair_natgws_by_az(ec2, blue_natgws, green_info)

    print_preview(routes, green_attach, blue_natgws, green_info, egress_mode, pairs)

    if dry_run:
        print("Dry-run complete. No changes made.")
        return

    if not yes:
        try:
            answer = input("Proceed with cutover? This will interrupt active sessions. [yes/N] ").strip()
        except KeyboardInterrupt:
            print("\nAborted.")
            sys.exit(1)
        if answer.lower() != 'yes':
            print("Aborted.")
            sys.exit(1)

    progress = {
        'started_at': datetime.now(timezone.utc).isoformat(),
        'region': region,
        'green_tgw_attachment_id': green_attach,
        'blue_tgw_attachment_id': inventory['transit_gateway']['inspection_attachment_id'],
        'routes_flipped': [],
        'tgw_flip_completed': False,
        'eip_migration_completed': False,
        'new_green_natgw_ids': [],
        'old_green_natgw_ids': [],
        'blue_natgw_info': blue_natgws,
        'blue_vpc_id': inventory['inspection_vpc']['vpc_id'],
    }

    # ── Phase 1: TGW Route Flip ─────────────────────────────────────────────
    print()
    print("━" * 70)
    print("  PHASE 1 — TGW Route Flip")
    print("━" * 70)
    t0 = time.time()
    for r in routes:
        rtb  = r['route_table_id']
        cidr = r['destination_cidr_block']
        print(f"  Flipping {rtb}  {cidr}  →  {green_attach} ...", end=' ', flush=True)
        ec2.replace_transit_gateway_route(
            DestinationCidrBlock=cidr,
            TransitGatewayRouteTableId=rtb,
            TransitGatewayAttachmentId=green_attach,
        )
        progress['routes_flipped'].append({'route_table_id': rtb, 'cidr': cidr})
        print("OK")

    progress['tgw_flip_completed'] = True
    progress['tgw_flip_duration_s'] = round(time.time() - t0, 1)
    write_progress(progress_path, progress)
    print(f"  Phase 1 complete in {progress['tgw_flip_duration_s']}s.")
    print(f"  Traffic is now routing through Green.")

    # ── Phase 2: NAT GW EIP Migration ───────────────────────────────────────
    if egress_mode != 'nat_gw' or not pairs:
        if egress_mode != 'nat_gw':
            print()
            print("  Phase 2 skipped — egress mode is 'eip'.")
        progress['eip_migration_completed'] = True
        write_progress(progress_path, progress)
        _print_done(progress)
        return

    print()
    print("━" * 70)
    print("  PHASE 2 — NAT Gateway EIP Migration")
    print("━" * 70)
    t0 = time.time()

    # Step 2a: Delete Blue NAT Gateways
    print()
    print("  Step 2a: Deleting Blue NAT Gateways...")
    for p in pairs:
        print(f"    Deleting {p['blue_natgw_id']} (EIP {p['blue_eip']}) ...", end=' ', flush=True)
        ec2.delete_nat_gateway(NatGatewayId=p['blue_natgw_id'])
        print("OK")

    # Step 2b: Wait for deletion
    print()
    print("  Step 2b: Waiting for Blue NAT GW deletion (~60 s)...")
    wait_nat_gw_deleted(ec2, [p['blue_natgw_id'] for p in pairs])

    # Step 2c: Create new Green NAT Gateways with Blue EIP allocation IDs
    print()
    print("  Step 2c: Creating new Green NAT Gateways with Blue EIPs...")
    new_natgw_ids = []
    for p in pairs:
        print(f"    Creating NAT GW in subnet {p['green_subnet_id']} (AZ {p['az']}) "
              f"with EIP {p['blue_eip']} ...", end=' ', flush=True)
        resp = ec2.create_nat_gateway(
            AllocationId=p['blue_eip_alloc'],
            SubnetId=p['green_subnet_id'],
            TagSpecifications=[{
                'ResourceType': 'natgateway',
                'Tags': [{'Key': 'Name', 'Value': f"green-inspection-natgw-{p['az']}-blueip"}]
            }]
        )
        new_id = resp['NatGateway']['NatGatewayId']
        new_natgw_ids.append({
            'id':              new_id,
            'az':              p['az'],
            'eip_alloc':       p['blue_eip_alloc'],
            'eip':             p['blue_eip'],
            'old_green_natgw': p['green_natgw_id'],
        })
        p['new_natgw_id'] = new_id
        print(f"OK ({new_id})")

    progress['new_green_natgw_ids'] = new_natgw_ids
    progress['old_green_natgw_ids'] = [p['green_natgw_id'] for p in pairs]
    write_progress(progress_path, progress)

    # Step 2d: Wait for new NAT GWs to become available
    print()
    print("  Step 2d: Waiting for new NAT Gateways to become available...")
    wait_nat_gw_available(ec2, [p['new_natgw_id'] for p in pairs])

    # Step 2e: Update Green VPC route tables
    print()
    print(f"  Step 2e: Updating Green VPC ({green_info['vpc_id']}) route tables...")
    for p in pairs:
        print(f"    AZ {p['az']}: replacing routes from {p['green_natgw_id']} → {p['new_natgw_id']}")
        update_vpc_routes_for_new_natgw(
            ec2, green_info['vpc_id'], p['green_natgw_id'], p['new_natgw_id']
        )

    # Step 2f: Delete original Green NAT GWs (with temp EIPs)
    print()
    print("  Step 2f: Deleting original Green NAT Gateways (temp EIPs)...")
    for p in pairs:
        print(f"    Deleting {p['green_natgw_id']} (temp EIP {p.get('green_temp_eip', '?')}) ...",
              end=' ', flush=True)
        ec2.delete_nat_gateway(NatGatewayId=p['green_natgw_id'])
        print("OK")
    wait_nat_gw_deleted(ec2, [p['green_natgw_id'] for p in pairs])

    # Step 2g: Release Green temp EIP allocations
    print()
    print("  Step 2g: Releasing Green temporary EIP allocations...")
    for p in pairs:
        alloc = p.get('green_temp_alloc')
        if alloc:
            print(f"    Releasing {alloc} (EIP {p.get('green_temp_eip', '?')}) ...",
                  end=' ', flush=True)
            try:
                ec2.release_address(AllocationId=alloc)
                print("OK")
            except Exception as e:
                print(f"WARNING: {e}")

    progress['eip_migration_completed'] = True
    progress['eip_migration_duration_s'] = round(time.time() - t0, 1)
    write_progress(progress_path, progress)
    print(f"\n  Phase 2 complete in {progress['eip_migration_duration_s']}s.")
    _print_done(progress)


def _print_done(progress):
    print()
    print("━" * 70)
    print("  CUTOVER COMPLETE")
    print("━" * 70)
    print(f"  Started:  {progress['started_at']}")
    print(f"  TGW flip: {'complete' if progress['tgw_flip_completed'] else 'NOT DONE'}")
    print(f"  EIP mig:  {'complete' if progress['eip_migration_completed'] else 'NOT DONE / skipped'}")
    print()
    print("  Next steps:")
    print("    1. Verify spoke VPC connectivity through Green")
    print("    2. Monitor Green ASG health and CloudWatch alarms")
    print("    3. If issues found: python3 scripts/rollback.py --inventory <inv>")
    print("    4. After 24–48 h stable: python3 scripts/destroy.py --blue --inventory <inv>")
    print()


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Blue-to-Green cutover: TGW route flip + NAT GW EIP migration'
    )
    parser.add_argument(
        '--inventory', default='state/blue_inventory.json',
        help='Path to blue_inventory.json (default: state/blue_inventory.json)'
    )
    parser.add_argument(
        '--green-state', default='state/green.tfstate',
        help='Path to Green Terraform state (default: state/green.tfstate)'
    )
    parser.add_argument(
        '--progress', default='state/cutover_progress.json',
        help='Path to write cutover progress (default: state/cutover_progress.json)'
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Preview changes without executing any AWS API calls'
    )
    parser.add_argument(
        '--yes', action='store_true',
        help='Skip interactive confirmation prompt'
    )
    args = parser.parse_args()

    try:
        inventory = load_inventory(args.inventory)
    except FileNotFoundError:
        print(f"ERROR: inventory not found: {args.inventory}")
        print("       Run discover.py first to generate the inventory.")
        sys.exit(1)

    try:
        green_state = load_green_state(args.green_state)
    except FileNotFoundError:
        print(f"ERROR: green state not found: {args.green_state}")
        print("       Run 'terraform apply' in terraform/green_inspection_stack/ first.")
        sys.exit(1)

    try:
        run_cutover(inventory, green_state, args.dry_run, args.yes, args.progress)
    except KeyboardInterrupt:
        print("\nInterrupted. Check state/cutover_progress.json to determine what ran.")
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: {e}")
        print("Check state/cutover_progress.json to determine what ran before the failure.")
        raise


if __name__ == '__main__':
    main()
