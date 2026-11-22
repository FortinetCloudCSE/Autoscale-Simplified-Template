#!/usr/bin/env python3
"""
Tests for scripts/prepare_green_config.py. No AWS calls are made.

Run:  python3 upgrade_fortios/tests/test_prepare_green_config.py
"""

import os
import sys
import types
import unittest

try:
    import boto3  # noqa: F401
except ImportError:                      # the script imports boto3 at module load
    sys.modules['boto3'] = types.ModuleType('boto3')

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts'))
import prepare_green_config as pg   # noqa: E402

BLUE_ARN = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/gwy/asg-gwlb-fgt/aaa'
GREEN_ARN = 'arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/gwy/green-gwlb-fgt/bbb'

BACKUP = """\
#config-version=FGAAWS-7.6.8-FW-build3744-260929:opmode=0:vdom=0
config system interface
    edit "geneve-az1"
        set type geneve
    next
end
config system geneve
    edit "geneve-az1"
        set interface "port1"
        set type ppp
        set remote-ip 10.0.2.138
    next
    edit "geneve-az2"
        set interface "port1"
        set type ppp
        set remote-ip 10.0.7.133
    next
end
config router static
    edit 1
        set dst 10.0.2.138 255.255.255.255
        set device "port1"
        set dynamic-gateway enable
    next
    edit 2
        set dst 10.0.7.133 255.255.255.255
        set device "port1"
        set dynamic-gateway enable
    next
    edit 3
        set dst 192.168.0.0 255.255.255.0
        set device "geneve-az1"
    next
end
"""


class FakeEC2:
    def __init__(self, enis):
        self.enis = enis      # {description: [(az, ip), ...]}

    def describe_network_interfaces(self, Filters):
        desc = Filters[0]['Values'][0]
        return {'NetworkInterfaces': [
            {'AvailabilityZone': az, 'PrivateIpAddress': ip}
            for az, ip in self.enis.get(desc, [])]}


def fake_ec2(blue=(('us-east-1a', '10.0.2.138'), ('us-east-1b', '10.0.7.133')),
             green=(('us-east-1a', '10.0.2.171'), ('us-east-1b', '10.0.6.88'))):
    return FakeEC2({'ELB gwy/asg-gwlb-fgt/aaa': list(blue),
                    'ELB gwy/green-gwlb-fgt/bbb': list(green)})


INVENTORY = {'gwlb': {'lb_arn': BLUE_ARN}}
GREEN_STATE = {'resources': [
    {'mode': 'managed', 'type': 'aws_lb', 'name': 'gwlb',
     'instances': [{'attributes': {'arn': GREEN_ARN}}]},
]}


class PrepareTests(unittest.TestCase):
    def test_peers_and_host_routes_are_rewritten_zone_by_zone(self):
        text, changes, ip_map = pg.prepare(INVENTORY, GREEN_STATE, BACKUP, fake_ec2())
        self.assertEqual(ip_map, {'10.0.2.138': '10.0.2.171', '10.0.7.133': '10.0.6.88'})
        self.assertEqual(len(changes), 4)
        self.assertIn('set remote-ip 10.0.2.171\n', text)
        self.assertIn('set remote-ip 10.0.6.88\n', text)
        self.assertIn('set dst 10.0.2.171 255.255.255.255\n', text)
        self.assertIn('set dst 10.0.6.88 255.255.255.255\n', text)
        self.assertEqual(pg.leftover_mentions(text, ip_map), [])

    def test_everything_else_is_left_alone(self):
        text, _, _ = pg.prepare(INVENTORY, GREEN_STATE, BACKUP, fake_ec2())
        old, new = BACKUP.splitlines(), text.splitlines()
        self.assertEqual(len(old), len(new))
        self.assertEqual(old[0], new[0])                 # version line kept for cutover's check
        self.assertEqual(sum(a != b for a, b in zip(old, new)), 4)
        self.assertIn('set dst 192.168.0.0 255.255.255.0', text)

    def test_a_rewritten_backup_is_refused(self):
        text, _, _ = pg.prepare(INVENTORY, GREEN_STATE, BACKUP, fake_ec2())
        with self.assertRaisesRegex(pg.PrepareError, 'is not an address of Blue'):
            pg.prepare(INVENTORY, GREEN_STATE, text, fake_ec2())

    def test_a_backup_without_a_peer_for_every_zone_is_refused(self):
        one_zone = BACKUP.replace('set remote-ip 10.0.7.133', 'set remote-ip 10.0.2.138')
        with self.assertRaisesRegex(pg.PrepareError, 'no GENEVE peer found for .*10.0.7.133'):
            pg.prepare(INVENTORY, GREEN_STATE, one_zone, fake_ec2())

    def test_zones_that_do_not_match_are_refused(self):
        ec2 = fake_ec2(green=(('us-east-1a', '10.0.2.171'), ('us-east-1c', '10.0.6.88')))
        with self.assertRaisesRegex(pg.PrepareError, 'cannot be matched zone by zone'):
            pg.prepare(INVENTORY, GREEN_STATE, BACKUP, ec2)

    def test_missing_gwlb_interfaces_are_refused(self):
        with self.assertRaisesRegex(pg.PrepareError, 'no network interfaces'):
            pg.prepare(INVENTORY, GREEN_STATE, BACKUP, fake_ec2(green=()))

    def test_inventory_without_a_gwlb_is_refused(self):
        with self.assertRaisesRegex(pg.PrepareError, 'gwlb.lb_arn'):
            pg.prepare({}, GREEN_STATE, BACKUP, fake_ec2())

    def test_other_mentions_are_reported(self):
        extra = BACKUP + 'config firewall address\n    edit "x"\n        set subnet 10.0.2.138 255.255.255.255\n    next\nend\n'
        text, _, ip_map = pg.prepare(INVENTORY, GREEN_STATE, extra, fake_ec2())
        self.assertEqual(len(pg.leftover_mentions(text, ip_map)), 1)

    def test_crlf_line_endings_are_kept(self):
        crlf = BACKUP.replace('\n', '\r\n')
        text, changes, _ = pg.prepare(INVENTORY, GREEN_STATE, crlf, fake_ec2())
        self.assertEqual(len(changes), 4)
        self.assertIn('set remote-ip 10.0.2.171\r\n', text)
        self.assertNotIn('\n', text.replace('\r\n', ''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
