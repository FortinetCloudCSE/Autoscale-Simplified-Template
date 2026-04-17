#!/usr/bin/env python3
"""
rollback.py — Revert Blue-to-Green cutover

Reads blue_inventory.json and state/cutover_progress.json to determine what
the cutover script completed and performs the inverse operations.

  Phase 1 rollback — TGW Route Flip  (always; < 30 seconds)
    Replaces spoke-VPC TGW default routes from Green attachment → Blue attachment.
    Production traffic returns to Blue FortiGates immediately.

  Phase 2 rollback — NAT Gateway EIP Recreation  (only if EIP migration ran)
    Re-associates the original Blue EIPs with new Blue NAT Gateways.
    Requires ~2–3 minutes (NAT GW creation takes time).

    Step 2a  Delete Green NAT GWs holding Blue EIPs
    Step 2b  Wait for Green NAT GW deletion (~60 s)
    Step 2c  Recreate Blue NAT GWs in original Blue subnets with Blue EIP alloc IDs
    Step 2d  Wait for new Blue NAT GWs to become Available (~60 s)
    Step 2e  Update Blue VPC route tables: old Blue natgw IDs → new natgw IDs

Usage:
  python3 scripts/rollback.py \\
    --inventory  state/blue_inventory.json \\
    --progress   state/cutover_progress.json \\
    [--dry-run] [--yes]

Options:
  --dry-run    Preview all changes without executing any AWS API calls.
  --yes        Skip the interactive confirmation prompt.

NOTE: If cutover.py was interrupted mid-run, check cutover_progress.json to
understand the partial state before running rollback.
"""

import argparse
import boto3
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ─────────────────────────────────────────────────────────────────────────────
# Load helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_json(path):
    with open(path) as f:
        return json.load(f)


# ─────────────────────────────────────────────────────────────────────────────
# Wait helpers (same as cutover.py)
# ─────────────────────────────────────────────────────────────────────────────

def wait_nat_gw_deleted(ec2, natgw_ids, timeout=180, poll=10):
    ids = list(natgw_ids)
    deadline = time.time() + timeout
    while True:
        resp = ec2.describe_nat_gateways(NatGatewayIds=ids)
        states = {n['NatGatewayId']: n['State'] for n in resp['NatGateways']}
        pending = [nid for nid in ids if states.get(nid) not in ('deleted', 'deleting')]
        deleting = [nid for nid in ids if states.get(nid) == 'deleting']
        if not pending and not deleting:
            print(f"  All NAT Gateways deleted: {ids}")
            return
        summary = ', '.join(f"{nid}={states.get(nid,'?')}" for nid in ids)
        print(f"  Waiting for deletion: {summary}")
        if time.time() > deadline:
            raise TimeoutError(f"NAT GW deletion timed out after {timeout}s")
        time.sleep(poll)


def wait_nat_gw_available(ec2, natgw_ids, timeout=180, poll=10):
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
        print(f"  Waiting for availability: {summary}")
        if time.time() > deadline:
            raise TimeoutError(f"NAT GW availability timed out after {timeout}s")
        time.sleep(poll)


# ─────────────────────────────────────────────────────────────────────────────
# Route table update
# ─────────────────────────────────────────────────────────────────────────────

def update_vpc_routes_for_new_natgw(ec2, vpc_id, old_natgw_id, new_natgw_id, dry_run=False):
    """
    Find routes in vpc_id that reference old_natgw_id (may be blackhole if
    the old NAT GW was deleted) and replace them with new_natgw_id.
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
                    try:
                        ec2.replace_route(
                            RouteTableId=rt_id,
                            DestinationCidrBlock=cidr,
                            NatGatewayId=new_natgw_id,
                        )
                    except Exception as e:
                        print(f"    WARNING: replace_route failed: {e}")
                updated.append({'route_table_id': rt_id, 'cidr': cidr})
    return updated


# ─────────────────────────────────────────────────────────────────────────────
# Preview
# ─────────────────────────────────────────────────────────────────────────────

def print_preview(progress, inventory):
    blue_attach = progress.get('blue_tgw_attachment_id')
    routes      = progress.get('routes_flipped', [])
    eip_done    = progress.get('eip_migration_completed', False)
    new_green   = progress.get('new_green_natgw_ids', [])   # NAT GWs holding Blue EIPs
    blue_natgws = progress.get('blue_natgw_info', [])
    blue_vpc    = progress.get('blue_vpc_id')

    print()
    print("=" * 70)
    print("  ROLLBACK PREVIEW  (--dry-run)")
    print("=" * 70)
    print()
    print(f"  Blue TGW attachment: {blue_attach}")
    print()
    print("  PHASE 1 — TGW Route Flip (back to Blue)")
    print(f"  {len(routes)} route(s) will be restored:")
    for r in routes:
        print(f"    {r['route_table_id']}  {r['cidr']}  →  {blue_attach}")
    print()
    if eip_done and new_green:
        print("  PHASE 2 — NAT Gateway EIP Rollback")
        print("  (EIP migration was completed — NAT GW recreation required)")
        for ng in new_green:
            print(f"    AZ {ng['az']}: Delete Green NAT GW {ng['id']} (EIP {ng['eip']})")
        print()
        print(f"  Then recreate Blue NAT GWs in Blue VPC ({blue_vpc}):")
        for b in blue_natgws:
            print(f"    Subnet {b['subnet_id']} with EIP alloc {b['eip_allocation_id']} ({b['public_ip']})")
    else:
        print("  PHASE 2 — Not required (EIP migration did not complete)")
    print()
    print("=" * 70)


# ─────────────────────────────────────────────────────────────────────────────
# Main rollback logic
# ─────────────────────────────────────────────────────────────────────────────

def run_rollback(inventory, progress, dry_run, yes):
    region = progress.get('region') or inventory.get('discovery_metadata', {}).get('region', 'us-west-2')
    ec2 = boto3.client('ec2', region_name=region)

    blue_attach = progress.get('blue_tgw_attachment_id')
    if not blue_attach:
        print("ERROR: blue_tgw_attachment_id not found in progress file.")
        print("       Cannot determine Blue attachment ID for TGW rollback.")
        sys.exit(1)

    routes_flipped  = progress.get('routes_flipped', [])
    eip_done        = progress.get('eip_migration_completed', False)
    new_green_natgws = progress.get('new_green_natgw_ids', [])   # hold Blue EIPs
    blue_natgw_info  = progress.get('blue_natgw_info', [])
    blue_vpc         = progress.get('blue_vpc_id') or inventory.get('inspection_vpc', {}).get('vpc_id')

    print_preview(progress, inventory)

    if dry_run:
        print("Dry-run complete. No changes made.")
        return

    if not yes:
        try:
            answer = input("Proceed with rollback? This will interrupt active sessions. [yes/N] ").strip()
        except KeyboardInterrupt:
            print("\nAborted.")
            sys.exit(1)
        if answer.lower() != 'yes':
            print("Aborted.")
            sys.exit(1)

    # ── Phase 1: TGW Route Flip back to Blue ───────────────────────────────
    print()
    print("━" * 70)
    print("  PHASE 1 — TGW Route Flip (Blue restoration)")
    print("━" * 70)
    t0 = time.time()
    for r in routes_flipped:
        rtb  = r['route_table_id']
        cidr = r['cidr']
        print(f"  Restoring {rtb}  {cidr}  →  {blue_attach} ...", end=' ', flush=True)
        if not dry_run:
            ec2.replace_transit_gateway_route(
                DestinationCidrBlock=cidr,
                TransitGatewayRouteTableId=rtb,
                TransitGatewayAttachmentId=blue_attach,
            )
        print("OK")

    print(f"  Phase 1 complete in {round(time.time()-t0, 1)}s.")
    print(f"  Traffic is now routing through Blue.")

    # ── Phase 2: NAT GW EIP Re-creation (if EIP migration ran) ────────────
    if not eip_done or not new_green_natgws:
        print()
        print("  Phase 2 skipped — EIP migration was not completed.")
        print()
        print("━" * 70)
        print("  ROLLBACK COMPLETE")
        print("━" * 70)
        return

    if not blue_natgw_info:
        print()
        print("  WARNING: EIP migration ran but blue_natgw_info missing from progress file.")
        print("           Cannot recreate Blue NAT Gateways automatically.")
        print("           Manually recreate Blue NAT GWs with EIP allocation IDs from inventory.")
        sys.exit(1)

    print()
    print("━" * 70)
    print("  PHASE 2 — NAT Gateway EIP Rollback")
    print("━" * 70)
    t0 = time.time()

    # Step 2a: Delete Green NAT GWs holding Blue EIPs
    print()
    print("  Step 2a: Deleting Green NAT Gateways (holding Blue EIPs)...")
    for ng in new_green_natgws:
        print(f"    Deleting {ng['id']} (EIP {ng.get('eip', '?')}) ...", end=' ', flush=True)
        try:
            ec2.delete_nat_gateway(NatGatewayId=ng['id'])
            print("OK")
        except Exception as e:
            print(f"WARNING: {e}")

    # Step 2b: Wait for deletion
    print()
    print("  Step 2b: Waiting for Green NAT GW deletion (~60 s)...")
    try:
        wait_nat_gw_deleted(ec2, [ng['id'] for ng in new_green_natgws])
    except TimeoutError as e:
        print(f"  WARNING: {e} — continuing anyway")

    # Step 2c: Recreate Blue NAT GWs with original EIP allocation IDs
    print()
    print("  Step 2c: Recreating Blue NAT Gateways with original EIPs...")
    recreated = []
    for b in blue_natgw_info:
        subnet_id = b.get('subnet_id')
        alloc_id  = b.get('eip_allocation_id')
        eip       = b.get('public_ip', '?')
        if not subnet_id or not alloc_id:
            print(f"  WARNING: Incomplete NAT GW info {b} — skipping")
            continue
        print(f"    Subnet {subnet_id} + EIP {eip} ({alloc_id}) ...", end=' ', flush=True)
        resp = ec2.create_nat_gateway(
            AllocationId=alloc_id,
            SubnetId=subnet_id,
            TagSpecifications=[{
                'ResourceType': 'natgateway',
                'Tags': [{'Key': 'Name', 'Value': f"blue-inspection-natgw-rollback"}]
            }]
        )
        new_id = resp['NatGateway']['NatGatewayId']
        recreated.append({
            'new_id':          new_id,
            'old_id':          b['id'],
            'eip':             eip,
            'subnet_id':       subnet_id,
        })
        print(f"OK ({new_id})")

    # Step 2d: Wait for new Blue NAT GWs
    print()
    print("  Step 2d: Waiting for recreated Blue NAT Gateways to become available...")
    wait_nat_gw_available(ec2, [r['new_id'] for r in recreated])

    # Step 2e: Update Blue VPC route tables
    print()
    print(f"  Step 2e: Updating Blue VPC ({blue_vpc}) route tables...")
    for r in recreated:
        print(f"    Replacing routes from {r['old_id']} → {r['new_id']}")
        update_vpc_routes_for_new_natgw(ec2, blue_vpc, r['old_id'], r['new_id'])

    print(f"\n  Phase 2 complete in {round(time.time()-t0, 1)}s.")
    print()
    print("━" * 70)
    print("  ROLLBACK COMPLETE")
    print("━" * 70)
    print()
    print("  Traffic is flowing through Blue.")
    print("  Investigate Green before attempting another cutover.")
    print()


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Revert Blue-to-Green cutover'
    )
    parser.add_argument(
        '--inventory', default='state/blue_inventory.json',
        help='Path to blue_inventory.json (default: state/blue_inventory.json)'
    )
    parser.add_argument(
        '--progress', default='state/cutover_progress.json',
        help='Path to cutover_progress.json written by cutover.py (default: state/cutover_progress.json)'
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
        inventory = load_json(args.inventory)
    except FileNotFoundError:
        print(f"ERROR: inventory not found: {args.inventory}")
        sys.exit(1)

    try:
        progress = load_json(args.progress)
    except FileNotFoundError:
        print(f"ERROR: cutover progress not found: {args.progress}")
        print("       cutover.py must have started before rollback.py can run.")
        sys.exit(1)

    try:
        run_rollback(inventory, progress, args.dry_run, args.yes)
    except KeyboardInterrupt:
        print("\nInterrupted.")
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: {e}")
        raise


if __name__ == '__main__':
    main()
