#!/usr/bin/env python3
"""
prepare_green_config.py — Make Blue's configuration backup fit Green before it is restored.

Each FortiGate reaches the Gateway Load Balancer through one GENEVE tunnel per
availability zone. The tunnel peer is the GWLB's network interface address in that
zone, and a host route sends the tunnel traffic out port1 to it:

    config system geneve
        edit "geneve-az1"
            set remote-ip 10.0.2.138        <- Blue's GWLB, us-east-1a
    ...
    config router static
        edit 1
            set dst 10.0.2.138 255.255.255.255

Green has its own GWLB with different addresses. A backup of Blue restored as it is
points Green's tunnels at Blue's GWLB: the GWLB health check still passes, because it
only probes a port, but no traffic gets through. FortiOS will not change a tunnel peer
while routes, policy routes or a zone use the tunnel, so fixing it on the FortiGate
afterwards means taking those apart and putting them back.

This script writes a copy of the backup with Blue's GWLB addresses replaced by Green's,
zone by zone, in the GENEVE peers and in the /32 static routes to them. Restore that
copy to Green's primary. The original backup is not changed; cutover.py still checks it.

Usage:
  python3 scripts/prepare_green_config.py \\
    --inventory    state/blue_inventory.json \\
    --green-state  state/green.tfstate \\
    [--config-backup state/blue_primary_config.conf] \\
    [--output        state/green_primary_config.conf]

Exit status: 0 written, 2 the backup does not look as expected (nothing written).
"""

import argparse
import json
import re
import sys

import boto3

DEFAULT_CONFIG_BACKUP = 'state/blue_primary_config.conf'
DEFAULT_OUTPUT = 'state/green_primary_config.conf'


class PrepareError(Exception):
    pass


# ─────────────────────────────────────────────────────────────────────────────
# GWLB addresses
# ─────────────────────────────────────────────────────────────────────────────

def green_gwlb_arn(green_state):
    """ARN of the aws_lb in the Green Terraform state."""
    arns = [inst['attributes']['arn']
            for r in green_state.get('resources', [])
            if r.get('type') == 'aws_lb' and r.get('mode', 'managed') == 'managed'
            for inst in r.get('instances', [])]
    if len(arns) != 1:
        raise PrepareError(f"expected one aws_lb in the Green state, found {len(arns)}")
    return arns[0]


def gwlb_ips_by_az(ec2, lb_arn):
    """{availability zone: private IP} of a Gateway Load Balancer's network interfaces."""
    # The GWLB's interfaces are described as "ELB gwy/<name>/<id>".
    description = 'ELB ' + lb_arn.split(':loadbalancer/', 1)[1]
    resp = ec2.describe_network_interfaces(Filters=[
        {'Name': 'description', 'Values': [description]},
    ])
    ips = {}
    for eni in resp.get('NetworkInterfaces', []):
        az = eni['AvailabilityZone']
        if az in ips:
            raise PrepareError(f"{lb_arn} has more than one interface in {az}")
        ips[az] = eni['PrivateIpAddress']
    if not ips:
        raise PrepareError(f"no network interfaces found for {lb_arn}")
    return ips


def pair_by_az(blue_ips, green_ips):
    """{Blue IP: Green IP}, matched by availability zone."""
    if set(blue_ips) != set(green_ips):
        raise PrepareError(
            f"Blue's GWLB is in {sorted(blue_ips)} but Green's is in {sorted(green_ips)}; "
            "the tunnels cannot be matched zone by zone")
    return {blue_ips[az]: green_ips[az] for az in sorted(blue_ips)}


# ─────────────────────────────────────────────────────────────────────────────
# Config rewrite
# ─────────────────────────────────────────────────────────────────────────────

_REMOTE_IP = re.compile(r'^(\s*set remote-ip )(\S+)(\s*)$')
_HOST_ROUTE = re.compile(r'^(\s*set dst )(\S+)( 255\.255\.255\.255\s*)$')


def rewrite_config(text, ip_map):
    """
    Replace Blue's GWLB addresses in the GENEVE peers and their /32 static routes.

    Returns (new_text, changes) where changes is a list of (line number, section, old, new).
    Raises PrepareError when a GENEVE peer is not one of Blue's GWLB addresses: the
    backup is then not of this Blue, or has been rewritten already.
    """
    lines = text.splitlines(keepends=True)
    section = None
    changes = []
    peers_seen = set()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line.startswith('config '):
            section = stripped
            continue
        if line.startswith('end'):
            section = None
            continue
        if section == 'config system geneve':
            m = _REMOTE_IP.match(line)
            if m:
                old = m.group(2)
                if old not in ip_map:
                    raise PrepareError(
                        f"line {i + 1}: GENEVE peer {old} is not an address of Blue's GWLB "
                        f"({', '.join(sorted(ip_map))})")
                peers_seen.add(old)
                lines[i] = m.group(1) + ip_map[old] + m.group(3)
                changes.append((i + 1, section, old, ip_map[old]))
        elif section == 'config router static':
            m = _HOST_ROUTE.match(line)
            if m and m.group(2) in ip_map:
                old = m.group(2)
                lines[i] = m.group(1) + ip_map[old] + m.group(3)
                changes.append((i + 1, section, old, ip_map[old]))
    missing = set(ip_map) - peers_seen
    if missing:
        raise PrepareError(
            f"no GENEVE peer found for Blue's GWLB address(es) {', '.join(sorted(missing))}")
    return ''.join(lines), changes


def leftover_mentions(text, ip_map):
    """Line numbers where a Blue GWLB address still appears after the rewrite."""
    found = []
    for n, line in enumerate(text.splitlines(), 1):
        for ip in ip_map:
            if re.search(r'(?<![\d.])' + re.escape(ip) + r'(?![\d.])', line):
                found.append((n, line.strip()))
    return found


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def prepare(inventory, green_state, backup_text, ec2):
    blue_arn = inventory.get('gwlb', {}).get('lb_arn')
    if not blue_arn:
        raise PrepareError("the inventory has no gwlb.lb_arn; run discover.py again")
    ip_map = pair_by_az(gwlb_ips_by_az(ec2, blue_arn),
                        gwlb_ips_by_az(ec2, green_gwlb_arn(green_state)))
    new_text, changes = rewrite_config(backup_text, ip_map)
    return new_text, changes, ip_map


def main():
    parser = argparse.ArgumentParser(
        description="Rewrite Blue's GWLB addresses in a configuration backup for Green")
    parser.add_argument('--inventory', default='state/blue_inventory.json')
    parser.add_argument('--green-state', default='state/green.tfstate')
    parser.add_argument('--config-backup', default=DEFAULT_CONFIG_BACKUP,
                        help=f"Backup of Blue's primary (default: {DEFAULT_CONFIG_BACKUP})")
    parser.add_argument('--output', default=DEFAULT_OUTPUT,
                        help=f"Copy to restore on Green's primary (default: {DEFAULT_OUTPUT})")
    args = parser.parse_args()

    if args.output == args.config_backup:
        print("ERROR: --output must differ from --config-backup; the original is kept as it is.")
        sys.exit(2)

    with open(args.inventory) as f:
        inventory = json.load(f)
    with open(args.green_state) as f:
        green_state = json.load(f)
    with open(args.config_backup, newline='') as f:
        backup_text = f.read()

    region = inventory.get('discovery_metadata', {}).get('region')
    ec2 = boto3.client('ec2', region_name=region)

    try:
        new_text, changes, ip_map = prepare(inventory, green_state, backup_text, ec2)
    except PrepareError as e:
        print(f"ERROR: {e}")
        print("       Nothing was written.")
        sys.exit(2)

    print("GWLB addresses, Blue → Green:")
    for blue, green in ip_map.items():
        print(f"  {blue:<15} → {green}")
    print()
    for line_no, section, old, new in changes:
        print(f"  line {line_no:>6}  {section:<22}  {old} → {new}")

    leftovers = leftover_mentions(new_text, ip_map)
    if leftovers:
        print()
        print("WARNING: Blue's GWLB addresses still appear elsewhere. Check these by hand:")
        for n, line in leftovers:
            print(f"  line {n:>6}  {line}")

    with open(args.output, 'w', newline='') as f:
        f.write(new_text)
    print()
    print(f"Wrote {args.output}. Restore this file, not {args.config_backup}, to Green's primary.")


if __name__ == '__main__':
    main()
