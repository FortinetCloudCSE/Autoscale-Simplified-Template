#!/usr/bin/env python3
"""
Tests for scripts/blue_green.py. No AWS, FortiGate or terraform calls are made.

Run:  python3 upgrade_fortios/tests/test_blue_green.py
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import types
import unittest
import urllib.error
from http.cookiejar import Cookie
from pathlib import Path
from unittest import mock

try:
    import boto3  # noqa: F401
except ImportError:
    sys.modules['boto3'] = types.ModuleType('boto3')

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts'))
import blue_green as bg   # noqa: E402

BLUE_TFVARS = '''\
# Blue
aws_region          = "us-east-1"
cp                  = "acme"   # customer prefix
asg_module_prefix   = "asg"
fortios_version     = "7.6.8"
access_internet_mode = "nat_gw"
firewall_policy_mode = "2-arm"
enable_dedicated_management_vpc = true
fortigate_asg_password = "s3cret#notacomment"
asg_byol_asg_min_size     = 2
asg_byol_asg_max_size     = 4
asg_byol_asg_desired_size = 2
fortiflex_sn_list = [
  "FGVM0001",   # first
  "FGVM0002",
]
additional_tags = {
  owner = "lab"
}
# fortimanager_ip = "10.3.0.14"
endpoint_name_az1 = "asg-gwlbe_az1"
only_in_blue = 1
'''

GREEN_VARIABLES = ''.join(f'variable "{n}" {{}}\n' for n in [
    'aws_region', 'cp', 'asg_module_prefix', 'stack_label', 'fortios_version',
    'access_internet_mode', 'fortigate_asg_password', 'asg_byol_asg_min_size',
    'asg_byol_asg_max_size', 'asg_byol_asg_desired_size', 'fortiflex_sn_list',
    'endpoint_name_az1', 'endpoint_name_az2', 'base_config_file', 'tgw_return_routes',
    'additional_tags'])


class TfvarsTests(unittest.TestCase):
    def test_parse_keeps_multiline_values_and_drops_comments(self):
        v = bg.parse_tfvars(BLUE_TFVARS)
        self.assertEqual(v['cp'], '"acme"')
        self.assertEqual(v['fortigate_asg_password'], '"s3cret#notacomment"')
        self.assertEqual(bg.hcl_value(v['fortiflex_sn_list']), ['FGVM0001', 'FGVM0002'])
        self.assertEqual(bg.hcl_value(v['additional_tags']), {'owner': 'lab'})
        self.assertNotIn('fortimanager_ip', v)          # commented out
        self.assertEqual(bg.hcl_value(v['enable_dedicated_management_vpc']), True)
        self.assertEqual(bg.hcl_value(v['asg_byol_asg_min_size']), 2)

    def test_green_gets_its_own_names_version_mode_and_one_flex_instance(self):
        blue = bg.parse_tfvars(BLUE_TFVARS)
        over = bg.green_overrides(blue, {'egress_mode': 'eip'}, '8.0.2', 'green')
        text, src = bg.build_green_tfvars(bg.variable_names(GREEN_VARIABLES), blue, {}, over)
        g = {k: bg.hcl_value(v) for k, v in bg.parse_tfvars(text).items()}
        self.assertEqual(g['asg_module_prefix'], 'green')
        self.assertEqual(g['stack_label'], 'green')
        self.assertEqual(g['endpoint_name_az1'], 'green-gwlbe_az1')
        self.assertEqual(g['endpoint_name_az2'], 'green-gwlbe_az2')
        self.assertEqual(g['fortios_version'], '8.0.2')
        self.assertEqual(g['access_internet_mode'], 'eip')         # from the inventory, not Blue's tfvars
        self.assertEqual((g['asg_byol_asg_min_size'], g['asg_byol_asg_desired_size'],
                          g['asg_byol_asg_max_size']), (1, 1, 4))
        self.assertEqual(g['cp'], 'acme')
        self.assertEqual(g['fortiflex_sn_list'], ['FGVM0001', 'FGVM0002'])
        self.assertEqual(g['base_config_file'], 'fgt-conf.cfg')
        self.assertNotIn('tgw_return_routes', g)                     # variables.tf default
        self.assertNotIn('only_in_blue', g)
        self.assertEqual(src['cp'], 'blue')

    def test_without_fortiflex_sizes_are_copied(self):
        blue = bg.parse_tfvars(BLUE_TFVARS.replace('"FGVM0001",   # first\n  "FGVM0002",', ''))
        over = bg.green_overrides(blue, {}, '8.0.2', 'green')
        self.assertNotIn('asg_byol_asg_min_size', over)

    def test_values_only_in_the_current_green_file_are_kept(self):
        blue = bg.parse_tfvars(BLUE_TFVARS)
        existing = {'tgw_return_routes': '{\n  "192.168.9.0/24" = "tgw-attach-1"\n}'}
        text, src = bg.build_green_tfvars(bg.variable_names(GREEN_VARIABLES), blue, existing, {})
        self.assertEqual(src['tgw_return_routes'], 'kept')
        self.assertIn('"192.168.9.0/24" = "tgw-attach-1"', text)

    def test_redact_hides_secrets(self):
        out = bg.redact('fortigate_asg_password = "x"\nfortiflex_password="y"\ncp = "acme"')
        self.assertNotIn('"x"', out)
        self.assertNotIn('"y"', out)
        self.assertIn('cp = "acme"', out)


# ─────────────────────────────────────────────────────────────────────────────
# FortiGate REST client
# ─────────────────────────────────────────────────────────────────────────────

class Resp(io.BytesIO):
    def __init__(self, status, body):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeOpener:
    """Answers like a FortiGate. Records requests."""

    def __init__(self, fgt, login_ok=True, backup_get_status=200,
                 config=b'#config-version=FGAAWS-7.6.8-FW-build1:x\n', gzip_bodies=False):
        self.fgt = fgt
        self.gzip_bodies = gzip_bodies
        self.login_ok = login_ok
        self.backup_get_status = backup_get_status
        self.config = config
        self.requests = []

    def _cookie(self, name, value):
        return Cookie(0, name, value, None, False, 'h', False, False, '/', True,
                      False, None, False, None, None, {})

    def open(self, req, timeout=None):
        resp = self._open(req)
        if self.gzip_bodies:
            import gzip
            resp = Resp(resp.status, gzip.compress(resp.getvalue()))
        return resp

    def _open(self, req):
        path = req.full_url.split(':443', 1)[1]
        self.requests.append((req.get_method(), path, dict(req.header_items())))
        if path == '/logincheck':
            if self.login_ok:
                self.fgt.jar.set_cookie(self._cookie('ccsrftoken', '"TOKEN"'))
                return Resp(200, b'1document.location="/ng/";')
            return Resp(200, b'0')
        if path.startswith('/api/v2/monitor/system/config/backup'):
            if req.get_method() == 'GET' and self.backup_get_status != 200:
                raise urllib.error.HTTPError(req.full_url, self.backup_get_status, 'x', {}, io.BytesIO(b''))
            return Resp(200, self.config)
        if path == '/api/v2/monitor/system/config/restore':
            return Resp(200, json.dumps({'status': 'success'}).encode())
        if path == '/api/v2/cmdb/system/geneve':
            return Resp(200, json.dumps({'results': [
                {'name': 'geneve-az1', 'remote-ip': '10.0.2.171'},
                {'name': 'geneve-az2', 'remote-ip': '10.0.6.88'}]}).encode())
        if path == '/logout':
            return Resp(200, b'')
        raise AssertionError(path)


def fgt_with(**kw):
    fgt = bg.FortiGate('10.9.9.9', 'pw', opener=object())
    fgt.opener = FakeOpener(fgt, **kw)
    return fgt


class FortiGateTests(unittest.TestCase):
    def test_login_then_post_carries_the_csrf_token(self):
        fgt = fgt_with()
        fgt.login()
        fgt.restore(b'#config-version=x\n')
        method, path, headers = fgt.opener.requests[-1]
        self.assertEqual((method, path), ('POST', '/api/v2/monitor/system/config/restore'))
        self.assertEqual(headers.get('X-csrftoken'), 'TOKEN')
        self.assertIn('multipart/form-data', headers.get('Content-type'))

    def test_bad_password_is_an_error(self):
        fgt = fgt_with(login_ok=False)
        with self.assertRaisesRegex(bg.FortiGateError, 'login .* failed'):
            fgt.login()

    def test_backup_falls_back_to_post(self):
        fgt = fgt_with(backup_get_status=405)
        fgt.login()
        self.assertTrue(fgt.backup().startswith(b'#config-version='))
        self.assertEqual([m for m, p, _ in fgt.opener.requests if 'backup' in p], ['GET', 'POST'])

    def test_backup_that_is_not_a_config_is_refused(self):
        fgt = fgt_with(config=b'<html>login</html>')
        fgt.login()
        with self.assertRaisesRegex(bg.FortiGateError, 'backup .* failed'):
            fgt.backup()

    def test_ca_file_turns_on_certificate_and_hostname_checks(self):
        import ssl
        real = ssl.create_default_context
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return real()                 # default context: CERT_REQUIRED + check_hostname
        with mock.patch.object(bg.ssl, 'create_default_context', fake):
            ctx = bg.tls_context('/path/ca.pem')
        self.assertEqual(seen, {'cafile': '/path/ca.pem'})
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)

    def test_without_ca_file_certificates_are_not_checked(self):
        import ssl
        ctx = bg.tls_context(None)
        self.assertEqual(ctx.verify_mode, ssl.CERT_NONE)
        self.assertFalse(ctx.check_hostname)

    def test_certificate_failure_stops_instead_of_retrying(self):
        import ssl
        err = urllib.error.URLError(ssl.SSLCertVerificationError(1, 'self-signed'))
        fgt = fgt_with()
        fgt.login = mock.Mock(side_effect=err)
        with self.assertRaisesRegex(bg.StepError, 'certificate check failed'):
            bg.try_login(lambda: fgt)

    def test_a_fortigate_that_is_still_booting_is_retried(self):
        fgt = fgt_with()
        fgt.login = mock.Mock(side_effect=urllib.error.URLError(ConnectionRefusedError()))
        self.assertIsNone(bg.try_login(lambda: fgt))

    def test_gzipped_responses_are_read(self):
        fgt = fgt_with(gzip_bodies=True)
        fgt.login()
        self.assertTrue(fgt.backup().startswith(b'#config-version='))
        fgt.restore(b'#config-version=x\n')
        self.assertEqual(fgt.geneve_peers()['geneve-az1'], '10.0.2.171')

    def test_failed_login_shows_the_decoded_response(self):
        fgt = fgt_with(login_ok=False, gzip_bodies=True)
        with self.assertRaisesRegex(bg.FortiGateError, "response: '0'"):
            fgt.login()

    def test_geneve_peers(self):
        fgt = fgt_with()
        fgt.login()
        self.assertEqual(fgt.geneve_peers(), {'geneve-az1': '10.0.2.171', 'geneve-az2': '10.0.6.88'})


# ─────────────────────────────────────────────────────────────────────────────
# AWS helpers
# ─────────────────────────────────────────────────────────────────────────────

class AwsHelperTests(unittest.TestCase):
    def test_management_device_index(self):
        f = bg.management_device_index
        self.assertEqual(f({'enable_dedicated_management_vpc': 'true'}), 2)
        self.assertEqual(f({'enable_dedicated_management_eni': 'true', 'firewall_policy_mode': '"1-arm"'}), 1)
        self.assertEqual(f({}), 1)
        self.assertEqual(f({'firewall_policy_mode': '"1-arm"'}), 0)

    def test_management_address_prefers_public_unless_told(self):
        ec2 = mock.Mock()
        ec2.describe_network_interfaces.return_value = {'NetworkInterfaces': [
            {'Attachment': {'DeviceIndex': 1}, 'PrivateIpAddress': '10.0.0.5',
             'Association': {'PublicIp': '3.3.3.3'}},
            {'Attachment': {'DeviceIndex': 2}, 'PrivateIpAddress': '10.3.0.9',
             'Association': {'PublicIp': '4.4.4.4'}}]}
        self.assertEqual(bg.management_address(ec2, 'i-1', 2), '4.4.4.4')
        self.assertEqual(bg.management_address(ec2, 'i-1', 2, use_private=True), '10.3.0.9')
        with self.assertRaises(bg.StepError):
            bg.management_address(ec2, 'i-1', 0)


# ─────────────────────────────────────────────────────────────────────────────
# Whole run against fakes
# ─────────────────────────────────────────────────────────────────────────────

GREEN_LB = 'arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/gwy/green-gwlb-fgt/bbb'
BLUE_LB = 'arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/gwy/asg-gwlb-fgt/aaa'
BACKUP = '''#config-version=FGAAWS-7.6.8-FW-build3744-x:opmode=0
config system geneve
    edit "geneve-az1"
        set remote-ip 10.0.2.138
    next
    edit "geneve-az2"
        set remote-ip 10.0.7.133
    next
end
config router static
    edit 1
        set dst 10.0.2.138 255.255.255.255
    next
    edit 2
        set dst 10.0.7.133 255.255.255.255
    next
end
'''


class FakeAWS:
    def __init__(self, default_route='tgw-attach-blue'):
        self.default_route = default_route

    def describe_network_interfaces(self, Filters):
        f = Filters[0]
        if f['Name'] == 'description':
            ips = {'ELB gwy/asg-gwlb-fgt/aaa': [('us-east-1a', '10.0.2.138'), ('us-east-1b', '10.0.7.133')],
                   'ELB gwy/green-gwlb-fgt/bbb': [('us-east-1a', '10.0.2.171'), ('us-east-1b', '10.0.6.88')]}
            return {'NetworkInterfaces': [{'AvailabilityZone': a, 'PrivateIpAddress': i}
                                          for a, i in ips[f['Values'][0]]]}
        return {'NetworkInterfaces': [{'Attachment': {'DeviceIndex': 2}, 'PrivateIpAddress': '10.3.0.9',
                                       'Association': {'PublicIp': '4.4.4.4'}}]}

    def search_transit_gateway_routes(self, **kw):
        return {'Routes': [{'TransitGatewayAttachments': [{'TransitGatewayAttachmentId': self.default_route}]}]}

    def describe_instances(self, InstanceIds):
        return {'Reservations': [{'Instances': [
            {'InstanceId': i, 'Tags': [{'Key': 'Autoscale Role', 'Value': 'Primary'}]} for i in InstanceIds]}]}

    def describe_auto_scaling_groups(self, AutoScalingGroupNames):
        return {'AutoScalingGroups': [{'Instances': [
            {'InstanceId': 'i-green', 'LifecycleState': 'InService', 'ProtectedFromScaleIn': False}]}]}

    def describe_target_health(self, TargetGroupArn):
        return {'TargetHealthDescriptions': [{'Target': {'Id': 'i-green'}, 'TargetHealth': {'State': 'healthy'}}]}


class WholeRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.root = root
        paths = {
            'UPGRADE_DIR': root / 'upgrade_fortios', 'REPO_ROOT': root,
            'STATE_DIR': root / 'upgrade_fortios' / 'state',
            'BLUE_TF_DIR': root / 'terraform' / 'autoscale_template',
            'VPC_TF_DIR': root / 'terraform' / 'existing_vpc_resources',
            'GREEN_TF_DIR': root / 'terraform' / 'green_inspection_stack',
        }
        for p in paths.values():
            p.mkdir(parents=True, exist_ok=True)
        st = paths['STATE_DIR']
        paths.update({'INVENTORY': st / 'blue_inventory.json', 'BLUE_BACKUP': st / 'blue_primary_config.conf',
                      'GREEN_CONFIG': st / 'green_primary_config.conf', 'GREEN_STATE': st / 'green.tfstate',
                      'PROGRESS': st / 'bluegreen_progress.json'})
        for k, v in paths.items():
            p = mock.patch.object(bg, k, v)
            p.start()
            self.addCleanup(p.stop)
        self.paths = paths
        (paths['BLUE_TF_DIR'] / 'terraform.tfvars').write_text(BLUE_TFVARS)
        (paths['BLUE_TF_DIR'] / 'terraform.tfstate').write_text(json.dumps({'resources': [
            {'type': 'aws_autoscaling_group', 'instances': [{'attributes': {}}]}]}))
        (paths['VPC_TF_DIR'] / 'terraform.tfstate').write_text('{}')
        (paths['GREEN_TF_DIR'] / 'variables.tf').write_text(GREEN_VARIABLES)
        self.inventory = {
            'discovery_metadata': {'region': 'us-east-1'}, 'egress_mode': 'eip',
            'gwlb': {'lb_arn': BLUE_LB},
            'transit_gateway': {'inspection_attachment_id': 'tgw-attach-blue',
                                'routes_to_update': [{'route_table_id': 'tgw-rtb-east'}]},
            'autoscale_groups': {'byol': {'primary_instance': 'i-blue'}},
            'version_change': {'from': '7.6.8', 'to': '8.0.2'},
        }
        self.green_state = {'resources': [
            {'mode': 'managed', 'type': 'aws_lb', 'instances': [{'attributes': {'arn': GREEN_LB}}]},
            {'mode': 'managed', 'type': 'aws_lb_target_group', 'instances': [{'attributes': {'arn': 'tg'}}]}]}
        self.commands = []
        self.fgts = []
        mock.patch.object(bg.time, 'sleep', lambda s: None).start()
        mock.patch.object(bg.shutil, 'which', lambda t: '/usr/bin/' + t).start()
        self.addCleanup(mock.patch.stopall)

    def runner(self, cmd, cwd=None):
        self.commands.append(cmd)
        if cmd[0] == 'bash':
            pass
        elif 'discover.py' in cmd[1] if len(cmd) > 1 else False:
            self.paths['INVENTORY'].write_text(json.dumps(self.inventory))
        elif cmd[:2] == ['terraform', 'apply']:
            (self.paths['GREEN_TF_DIR'] / 'terraform.tfstate').write_text(json.dumps(self.green_state))
        return 0

    def fgt_factory(self, host):
        fgt = bg.FortiGate(host, 'pw', opener=object())
        fgt.opener = FakeOpener(fgt, config=BACKUP.encode())
        self.fgts.append(fgt)
        return fgt

    def run_all(self, aws=None, **argkw):
        args = bg.parse_args(['--fortios-version', '8.0.2', '--yes'] +
                             [x for k, v in argkw.items() for x in (f'--{k.replace("_", "-")}', v)])
        aws = aws or FakeAWS()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bg.Run(args, clients={'ec2': aws, 'autoscaling': aws, 'elbv2': aws},
                   fgt_factory=self.fgt_factory, runner=self.runner).run()
        return out.getvalue()

    def test_full_run_builds_green_restores_the_prepared_backup_and_never_cuts_over(self):
        out = self.run_all()
        flat = [' '.join(c) for c in self.commands]
        self.assertFalse(any('cutover.py' in c or 'rollback.py' in c for c in flat), flat)
        self.assertTrue(any(c.startswith('terraform apply') for c in flat))
        # Green's tfvars written from Blue's
        g = bg.parse_tfvars((self.paths['GREEN_TF_DIR'] / 'terraform.tfvars').read_text())
        self.assertEqual(bg.hcl_value(g['fortios_version']), '8.0.2')
        # The restored file carries Green's GWLB addresses
        restored = self.paths['GREEN_CONFIG'].read_text()
        self.assertIn('set remote-ip 10.0.2.171', restored)
        self.assertNotIn('10.0.2.138', restored)
        restores = [r for f in self.fgts for r in f.opener.requests if r[1].endswith('/config/restore')]
        self.assertEqual(len(restores), 1)
        # Blue's backup kept as taken
        self.assertIn('10.0.2.138', self.paths['BLUE_BACKUP'].read_text())
        self.assertIn('The cutover is yours to run', out)
        self.assertIn('scripts/cutover.py', out)
        self.assertEqual(json.loads(self.paths['PROGRESS'].read_text())['completed'], bg.STEPS)
        self.assertNotIn('s3cret', out)

    def test_destroyed_blue_is_refused(self):
        (self.paths['BLUE_TF_DIR'] / 'terraform.tfstate').write_text('{"resources": []}')
        with self.assertRaisesRegex(bg.StepError, 'Blue is not deployed'):
            self.run_all()
        self.assertEqual(self.commands, [])

    def test_run_warns_when_certificates_are_not_checked(self):
        out = self.run_all()
        self.assertIn('WARNING: FortiGate TLS certificates are not checked', out)

    def test_missing_ca_file_stops_before_anything_runs(self):
        with self.assertRaisesRegex(bg.StepError, 'is not a file'):
            self.run_all(fgt_ca_file=str(self.root / 'nope.pem'))
        self.assertEqual(self.commands, [])

    def test_backup_on_another_version_stops_before_green_is_built(self):
        self.inventory['version_change']['from'] = '7.6.7'
        with self.assertRaisesRegex(bg.StepError, 'backup says FortiOS 7.6.8 but Blue runs 7.6.7'):
            self.run_all()
        self.assertFalse(any(c[:2] == ['terraform', 'apply'] for c in self.commands))

    def test_routes_not_on_blue_need_a_yes(self):
        args = bg.parse_args(['--fortios-version', '8.0.2'])
        aws = FakeAWS(default_route='tgw-attach-green')
        r = bg.Run(args, clients={'ec2': aws}, fgt_factory=self.fgt_factory, runner=self.runner)
        with contextlib.redirect_stdout(io.StringIO()), mock.patch('builtins.input', return_value='n'):
            with self.assertRaisesRegex(bg.StepError, 'stopped at your answer'):
                r.check_routes(self.inventory)

    def test_wrong_geneve_peers_fail_verify(self):
        self.run_all()
        self.green_state['resources'][0]['instances'][0]['attributes']['arn'] = BLUE_LB
        self.paths['GREEN_STATE'].write_text(json.dumps(self.green_state))
        args = bg.parse_args(['--fortios-version', '8.0.2', '--start-at', 'verify', '--yes'])
        aws = FakeAWS()
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(bg.StepError, 'GENEVE peers are not'):
                bg.Run(args, clients={'ec2': aws, 'autoscaling': aws, 'elbv2': aws},
                       fgt_factory=self.fgt_factory, runner=self.runner).run()


if __name__ == '__main__':
    unittest.main(verbosity=2)
