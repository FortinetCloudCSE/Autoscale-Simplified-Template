#!/usr/bin/env python3
"""
blue_green.py — Run a blue-green FortiOS upgrade up to, but never including, the cutover.

Starts from a deployed Blue (terraform/autoscale_template and terraform/existing_vpc_resources
with their terraform.tfstate) and ends with a Green stack on the target FortiOS version that
runs Blue's configuration, is healthy behind its own GWLB, and carries no traffic yet. It then
prints the cutover commands. Moving traffic is always left to the operator.

Steps (each can be the starting point with --start-at):

  preflight  Tools, files and the Transit Gateway routes Blue is serving
  discover   state/refresh.sh, then discover.py → state/blue_inventory.json
  backup     Back up Blue's primary over the FortiGate REST API → state/blue_primary_config.conf
  tfvars     Generate terraform/green_inspection_stack/terraform.tfvars from Blue's
  deploy     terraform init / plan / apply in green_inspection_stack, copy the state
  wait       Wait for Green's primary: InService, GWLB-healthy, REST login works
  prepare    prepare_green_config.py → state/green_primary_config.conf (Green's GWLB addresses)
  restore    Restore that file on Green's primary over the REST API
  verify     Wait for the reboot, check the GENEVE peers and GWLB health

The FortiGate REST API is used with the admin password from Blue's terraform.tfvars
(fortigate_asg_password), or FGT_PASSWORD from the environment when set. A new Green
FortiGate has no API key, so a session login is the only way in without the GUI.

Usage:
  python3 scripts/blue_green.py --fortios-version 8.0.2 [--upgrade-path-verified]
      [--start-at STEP] [--yes] [--use-private-ip] [--fgt-mgmt-port 443]

Progress is recorded in state/bluegreen_progress.json.
"""

import argparse
import difflib
import http.cookiejar
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import boto3

import discover
import prepare_green_config

SCRIPT_DIR = Path(__file__).resolve().parent
UPGRADE_DIR = SCRIPT_DIR.parent
REPO_ROOT = UPGRADE_DIR.parent
STATE_DIR = UPGRADE_DIR / 'state'
BLUE_TF_DIR = REPO_ROOT / 'terraform' / 'autoscale_template'
VPC_TF_DIR = REPO_ROOT / 'terraform' / 'existing_vpc_resources'
GREEN_TF_DIR = REPO_ROOT / 'terraform' / 'green_inspection_stack'

INVENTORY = STATE_DIR / 'blue_inventory.json'
BLUE_BACKUP = STATE_DIR / 'blue_primary_config.conf'
GREEN_CONFIG = STATE_DIR / 'green_primary_config.conf'
GREEN_STATE = STATE_DIR / 'green.tfstate'
PROGRESS = STATE_DIR / 'bluegreen_progress.json'

STEPS = ['preflight', 'discover', 'backup', 'tfvars', 'deploy', 'wait', 'prepare', 'restore', 'verify']

POLL = 20
WAIT_GREEN_MINS = 30
WAIT_REBOOT_MINS = 20


class StepError(Exception):
    """A step cannot continue. The message says why and what to do."""


# ─────────────────────────────────────────────────────────────────────────────
# Small helpers
# ─────────────────────────────────────────────────────────────────────────────

def ts():
    return datetime.now(timezone.utc).strftime('%H:%M:%S')


def banner(msg):
    print()
    print('─' * 64)
    print(f'  {msg}')
    print('─' * 64)


def confirm(prompt, assume_yes):
    if assume_yes:
        print(f'{prompt} [y/N]: y  (--yes)')
        return
    if input(f'\n{prompt} [y/N]: ').strip().lower() not in ('y', 'yes'):
        raise StepError('stopped at your answer; nothing further was changed')


def load_json(path):
    with open(path) as f:
        return json.load(f)


def write_progress(done, extra=None):
    data = {'completed': done, 'updated_at': datetime.now(timezone.utc).isoformat()}
    if extra:
        data.update(extra)
    with open(PROGRESS, 'w') as f:
        json.dump(data, f, indent=2)


# ─────────────────────────────────────────────────────────────────────────────
# terraform.tfvars: read assignments, write Green's
# ─────────────────────────────────────────────────────────────────────────────

_ASSIGN = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.*)$')


def _scan(text, depth):
    """Track bracket depth across text, ignoring strings and comments.
    Returns (new depth, index where a trailing comment starts or None)."""
    in_str = False
    i = 0
    while i < len(text):
        c = text[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '#' or text.startswith('//', i):
            return depth, i
        elif c in '[{(':
            depth += 1
        elif c in ']})':
            depth -= 1
        i += 1
    return depth, None


def parse_tfvars(text):
    """
    {name: raw value text} for the top-level assignments in a terraform.tfvars, in file
    order. Multi-line lists and maps are kept whole; trailing comments are dropped.
    Commented-out assignments are ignored.
    """
    out = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = _ASSIGN.match(lines[i])
        if not m:
            i += 1
            continue
        name, rest = m.group(1), m.group(2)
        depth, cut = _scan(rest, 0)
        parts = [rest[:cut] if cut is not None else rest]
        while depth > 0 and i + 1 < len(lines):
            i += 1
            depth, cut = _scan(lines[i], depth)
            parts.append(lines[i][:cut] if cut is not None else lines[i])
        out[name] = '\n'.join(p.rstrip() for p in parts).strip()
        i += 1
    return out


def hcl_value(raw):
    """Python value of a simple HCL literal: string, number, bool, or list/map of those."""
    if raw in ('true', 'false'):
        return raw == 'true'
    text = re.sub(r',(\s*[\]}])', r'\1', raw)                   # trailing commas
    text = re.sub(r'(^|[{,\s])([A-Za-z_][A-Za-z0-9_-]*)\s*=', r'\1"\2":', text)  # map keys
    try:
        return json.loads(text)
    except ValueError:
        return raw


def hcl_string(value):
    return json.dumps(value)


def variable_names(variables_tf_text):
    return re.findall(r'^variable\s+"([^"]+)"', variables_tf_text, re.M)


def green_overrides(blue, inventory, target_version, prefix):
    """Values Green must not copy from Blue. {name: raw HCL}"""
    over = {
        'asg_module_prefix': hcl_string(prefix),
        'stack_label': hcl_string(prefix),
        'endpoint_name_az1': hcl_string(f'{prefix}-gwlbe_az1'),
        'endpoint_name_az2': hcl_string(f'{prefix}-gwlbe_az2'),
        'fortios_version': hcl_string(target_version),
    }
    egress = inventory.get('egress_mode')
    if egress:
        # The mode Blue's inspection VPC actually uses, which decides Green's subnet layout.
        over['access_internet_mode'] = hcl_string(egress)
    # FortiFlex: two instances launching together can be issued the same serial,
    # so Green starts with one and is raised to Blue's size by hand once licensed.
    flex = hcl_value(blue.get('fortiflex_sn_list', '[]'))
    if isinstance(flex, list) and flex:
        for name in ('asg_byol_asg_min_size', 'asg_byol_asg_desired_size'):
            val = hcl_value(blue.get(name, '1'))
            if isinstance(val, int) and val > 1:
                over[name] = '1'
    return over


GREEN_DEFAULTS = {
    # No default in variables.tf that works; the example ships this value.
    'base_config_file': hcl_string('fgt-conf.cfg'),
}


def build_green_tfvars(green_vars, blue, existing_green, overrides):
    """
    Text of Green's terraform.tfvars. For each variable Green declares: the override,
    else Blue's value, else the current Green value, else a known default, else left out
    (variables.tf default). Returns (text, {name: source}).
    """
    lines = [
        '# Generated by upgrade_fortios/scripts/blue_green.py from',
        '# terraform/autoscale_template/terraform.tfvars. Values marked "# green" differ',
        '# from Blue on purpose. Re-running the script regenerates this file.',
        '',
    ]
    sources = {}
    for name in green_vars:
        if name in overrides:
            raw, src = overrides[name], 'green'
        elif name in blue:
            raw, src = blue[name], 'blue'
        elif name in existing_green:
            raw, src = existing_green[name], 'kept'
        elif name in GREEN_DEFAULTS:
            raw, src = GREEN_DEFAULTS[name], 'default'
        else:
            continue
        sources[name] = src
        suffix = '  # green' if src == 'green' else ''
        first, *more = raw.split('\n')
        lines.append(f'{name} = {first}{suffix if not more else ""}')
        lines.extend(more)
    return '\n'.join(lines) + '\n', sources


_SECRET = re.compile(r'^(\s*\S*(password|secret|token|api_key)\S*\s*=\s*).*$', re.I)


def redact(text):
    return '\n'.join(_SECRET.sub(r'\1<redacted>', line) for line in text.splitlines())


# ─────────────────────────────────────────────────────────────────────────────
# FortiGate REST API with an admin session
# ─────────────────────────────────────────────────────────────────────────────

class FortiGateError(Exception):
    pass


class FortiGate:
    """Session-cookie client for the FortiOS REST API (login with the admin password)."""

    def __init__(self, host, password, port=443, username='admin', opener=None, timeout=30):
        self.base = f'https://{host}:{port}'
        self.host = host
        self.username = username
        self.password = password
        self.timeout = timeout
        self.jar = http.cookiejar.CookieJar()
        if opener is None:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE           # FortiGates ship a self-signed cert
            opener = urllib.request.build_opener(
                urllib.request.HTTPSHandler(context=ctx),
                urllib.request.HTTPCookieProcessor(self.jar))
        self.opener = opener

    def _csrf(self):
        for c in self.jar:
            if c.name.startswith('ccsrftoken'):
                return c.value.strip('"')
        return None

    def _send(self, method, path, data=None, headers=None):
        headers = dict(headers or {})
        token = self._csrf()
        if token and method != 'GET':
            headers['X-CSRFTOKEN'] = token
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.read()

    def login(self):
        body = urllib.parse.urlencode({'username': self.username, 'secretkey': self.password,
                                       'ajax': '1'}).encode()
        status, data = self._send('POST', '/logincheck', body,
                                  {'Content-Type': 'application/x-www-form-urlencoded'})
        # With ajax=1 FortiOS answers "1" on success; 0 bad credentials, 2 locked out.
        if status != 200 or not data.strip().startswith(b'1') or not self._csrf():
            raise FortiGateError(f'login to {self.host} as {self.username} failed '
                                 f'(HTTP {status}, response {data[:40]!r})')

    def logout(self):
        try:
            self._send('POST', '/logout')
        except Exception:
            pass

    def backup(self):
        """Full configuration, as the GUI's Backup gives it (unencrypted)."""
        status, data = self._send('GET', '/api/v2/monitor/system/config/backup?scope=global')
        if status in (404, 405):
            # Later FortiOS versions take the backup as a POST.
            status, data = self._send(
                'POST', '/api/v2/monitor/system/config/backup',
                json.dumps({'destination': 'file', 'scope': 'global'}).encode(),
                {'Content-Type': 'application/json'})
        if status != 200 or not data.startswith(b'#config-version='):
            raise FortiGateError(f'backup from {self.host} failed (HTTP {status}, '
                                 f'starts {data[:60]!r})')
        return data

    def restore(self, config_bytes, filename='config.conf'):
        """Upload a full configuration. The FortiGate reboots when it is accepted."""
        boundary = 'BlueGreenRestoreBoundary'
        body = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="source"\r\n\r\nupload\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="scope"\r\n\r\nglobal\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f'Content-Type: application/octet-stream\r\n\r\n'
        ).encode() + config_bytes + f'\r\n--{boundary}--\r\n'.encode()
        status, data = self._send('POST', '/api/v2/monitor/system/config/restore', body,
                                  {'Content-Type': f'multipart/form-data; boundary={boundary}'})
        try:
            ok = json.loads(data).get('status') == 'success'
        except ValueError:
            ok = False
        if status != 200 or not ok:
            raise FortiGateError(f'restore on {self.host} was not accepted (HTTP {status}, '
                                 f'{data[:200]!r})')

    def geneve_peers(self):
        """{tunnel name: remote-ip}"""
        status, data = self._send('GET', '/api/v2/cmdb/system/geneve')
        if status != 200:
            raise FortiGateError(f'reading system geneve on {self.host} failed (HTTP {status})')
        return {t['name']: t.get('remote-ip') for t in json.loads(data).get('results', [])}


def try_login(make_fgt):
    fgt = make_fgt()
    try:
        fgt.login()
        return fgt
    except (FortiGateError, OSError):
        return None


# ─────────────────────────────────────────────────────────────────────────────
# AWS lookups
# ─────────────────────────────────────────────────────────────────────────────

def management_device_index(tfvars):
    two_arm = hcl_value(tfvars.get('firewall_policy_mode', '"2-arm"')) == '2-arm'
    dedicated = (hcl_value(tfvars.get('enable_dedicated_management_vpc', 'false')) is True or
                 hcl_value(tfvars.get('enable_dedicated_management_eni', 'false')) is True)
    if dedicated:
        return 2 if two_arm else 1
    return 1 if two_arm else 0


def management_address(ec2, instance_id, device_index, use_private=False):
    resp = ec2.describe_network_interfaces(
        Filters=[{'Name': 'attachment.instance-id', 'Values': [instance_id]}])
    for eni in resp.get('NetworkInterfaces', []):
        if eni.get('Attachment', {}).get('DeviceIndex') == device_index:
            public = eni.get('Association', {}).get('PublicIp')
            if public and not use_private:
                return public
            return eni['PrivateIpAddress']
    raise StepError(f'{instance_id} has no interface at device index {device_index} '
                    '(the management interface)')


def asg_primary(autoscaling, ec2, asg_name):
    """(primary instance id or None, ASG instance list)"""
    resp = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    groups = resp.get('AutoScalingGroups', [])
    if not groups:
        return None, []
    instances = [{'instance_id': i['InstanceId'], 'lifecycle': i['LifecycleState'],
                  'protected': i.get('ProtectedFromScaleIn', False)}
                 for i in groups[0].get('Instances', [])]
    in_service = [i for i in instances if i['lifecycle'] == 'InService']
    roles = discover.get_autoscale_roles(ec2, [i['instance_id'] for i in in_service])
    return discover.find_primary_instance(in_service, roles), instances


def gwlb_healthy(elbv2, tg_arn, instance_id):
    for t in discover.get_gwlb_target_health(elbv2, tg_arn):
        if t['Target']['Id'] == instance_id:
            return t['TargetHealth']['State'] == 'healthy'
    return False


def green_resource_attr(green_state, rtype, attr):
    vals = [inst['attributes'].get(attr)
            for r in green_state.get('resources', [])
            if r.get('type') == rtype and r.get('mode', 'managed') == 'managed'
            for inst in r.get('instances', [])]
    if len(vals) != 1:
        raise StepError(f'expected one {rtype} in the Green state, found {len(vals)}')
    return vals[0]


def default_route_targets(ec2, route_table_ids):
    """{route table: attachment id of its 0.0.0.0/0 route, or None}"""
    out = {}
    for rt in route_table_ids:
        resp = ec2.search_transit_gateway_routes(
            TransitGatewayRouteTableId=rt,
            Filters=[{'Name': 'route-search.exact-match', 'Values': ['0.0.0.0/0']}])
        routes = resp.get('Routes', [])
        att = routes[0].get('TransitGatewayAttachments', [{}])[0].get('TransitGatewayAttachmentId') \
            if routes else None
        out[rt] = att
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Steps
# ─────────────────────────────────────────────────────────────────────────────

class Run:
    def __init__(self, args, clients=None, fgt_factory=None, runner=None):
        self.args = args
        self.clients = clients
        self.fgt_factory = fgt_factory or (lambda host: FortiGate(
            host, self.password(), port=args.fgt_mgmt_port))
        self.runner = runner or self._run_cmd
        self._blue_tfvars = None

    # lazily created so --help and tests need no AWS
    def aws(self, name):
        if self.clients is None:
            region = (load_json(INVENTORY).get('discovery_metadata', {}).get('region')
                      if INVENTORY.exists() else None)
            self.clients = {n: boto3.client(n, region_name=region)
                            for n in ('ec2', 'autoscaling', 'elbv2')}
        return self.clients[name]

    def blue_tfvars(self):
        if self._blue_tfvars is None:
            self._blue_tfvars = parse_tfvars((BLUE_TF_DIR / 'terraform.tfvars').read_text())
        return self._blue_tfvars

    def password(self):
        pw = os.environ.get('FGT_PASSWORD') or hcl_value(
            self.blue_tfvars().get('fortigate_asg_password', '""'))
        if not pw:
            raise StepError('no FortiGate password: set fortigate_asg_password in '
                            "Blue's terraform.tfvars or FGT_PASSWORD in the environment")
        return pw

    @staticmethod
    def _run_cmd(cmd, cwd=None):
        print(f'  $ {" ".join(cmd)}')
        result = subprocess.run(cmd, cwd=cwd)
        return result.returncode

    def run_or_fail(self, cmd, cwd=None, what=None):
        code = self.runner(cmd, cwd=cwd)
        if code != 0:
            raise StepError(f'{what or cmd[0]} exited with status {code}')

    # ── preflight ────────────────────────────────────────────────────────────
    def preflight(self):
        missing = [t for t in ('terraform',) if not shutil.which(t)]
        if missing:
            raise StepError(f'not on PATH: {", ".join(missing)}')
        for p in (BLUE_TF_DIR / 'terraform.tfstate', BLUE_TF_DIR / 'terraform.tfvars',
                  VPC_TF_DIR / 'terraform.tfstate'):
            if not p.exists():
                raise StepError(f'{p} not found — Blue must be deployed from this checkout')
        blue_state = load_json(BLUE_TF_DIR / 'terraform.tfstate')
        if not any(r.get('type') == 'aws_autoscaling_group'
                   for r in blue_state.get('resources', []) for _ in r.get('instances', [])):
            raise StepError(f'{BLUE_TF_DIR.relative_to(REPO_ROOT)}/terraform.tfstate has no '
                            'autoscaling group — Blue is not deployed (or was destroyed)')
        print(f'  Blue state and tfvars found in {BLUE_TF_DIR.relative_to(REPO_ROOT)}')
        self.password()
        print('  FortiGate admin password available (not shown)')
        if GREEN_STATE.exists() or (GREEN_TF_DIR / 'terraform.tfstate').exists():
            state = GREEN_TF_DIR / 'terraform.tfstate'
            if state.exists() and load_json(state).get('resources'):
                print('  Note: green_inspection_stack already has resources in its state; '
                      '"deploy" will update that stack, not create a second one.')
        stale = [p for p in (STATE_DIR / 'cutover_progress.json',) if p.exists()]
        if stale:
            print(f'  Note: {stale[0].name} from an earlier cutover exists; '
                  'cutover.py and rollback.py will read it. Move it aside before cutover.')

    # ── discover ─────────────────────────────────────────────────────────────
    def discover(self):
        self.run_or_fail(['bash', str(STATE_DIR / 'refresh.sh')], what='refresh.sh')
        cmd = [sys.executable, str(SCRIPT_DIR / 'discover.py'),
               '--state', 'state/autoscale_template.tfstate',
               '--vpc-state', 'state/existing_vpc_resources.tfstate',
               '--target-version', self.args.fortios_version,
               '--output', 'state/blue_inventory.json']
        if self.args.upgrade_path_verified:
            cmd.append('--upgrade-path-verified')
        self.run_or_fail(cmd, cwd=str(UPGRADE_DIR), what='discover.py')
        inv = load_json(INVENTORY)
        self.check_routes(inv)

    def check_routes(self, inv):
        tgw = inv.get('transit_gateway', {})
        blue_att = tgw.get('inspection_attachment_id')
        rts = [r['route_table_id'] for r in tgw.get('routes_to_update', [])]
        if not rts:
            raise StepError('the inventory lists no spoke route tables to flip; '
                            'cutover would have nothing to do')
        targets = default_route_targets(self.aws('ec2'), rts)
        off = {rt: att for rt, att in targets.items() if att != blue_att}
        for rt, att in targets.items():
            mark = 'Blue' if att == blue_att else 'NOT Blue'
            print(f'  {rt}  0.0.0.0/0 → {att}  ({mark})')
        if off:
            print()
            print(f"  WARNING: {len(off)} spoke route table(s) do not send their default route to "
                  f"Blue's inspection attachment {blue_att}. Blue is not carrying that traffic, "
                  'or a previous cutover already moved it.')
            confirm('Continue anyway?', self.args.yes)

    # ── backup ───────────────────────────────────────────────────────────────
    def backup(self):
        inv = load_json(INVENTORY)
        primary = inv['autoscale_groups']['byol'].get('primary_instance')
        if not primary:
            raise StepError("discovery found no primary in Blue's BYOL ASG")
        host = self.args.blue_mgmt_ip or management_address(
            self.aws('ec2'), primary, management_device_index(self.blue_tfvars()),
            self.args.use_private_ip)
        print(f"  Blue primary {primary} at {host}")
        fgt = self.fgt_factory(host)
        fgt.login()
        try:
            data = fgt.backup()
        finally:
            fgt.logout()
        if BLUE_BACKUP.exists():
            BLUE_BACKUP.replace(BLUE_BACKUP.with_suffix('.conf.prev'))
        BLUE_BACKUP.write_bytes(data)
        os.chmod(BLUE_BACKUP, 0o600)
        version = discover.backup_fortios_version(str(BLUE_BACKUP))
        running = inv.get('version_change', {}).get('from')
        print(f'  Saved {BLUE_BACKUP.relative_to(UPGRADE_DIR)} ({len(data):,} bytes), '
              f'taken on FortiOS {version}')
        if running and version != running:
            raise StepError(f'the backup says FortiOS {version} but Blue runs {running}')

    # ── tfvars ───────────────────────────────────────────────────────────────
    def tfvars(self):
        inv = load_json(INVENTORY)
        blue = self.blue_tfvars()
        target = GREEN_TF_DIR / 'terraform.tfvars'
        existing_text = target.read_text() if target.exists() else ''
        green_vars = variable_names((GREEN_TF_DIR / 'variables.tf').read_text())
        overrides = green_overrides(blue, inv, self.args.fortios_version, self.args.green_prefix)
        text, sources = build_green_tfvars(green_vars, blue, parse_tfvars(existing_text), overrides)

        new_values = parse_tfvars(text)
        print(f'  {sum(s == "blue" for s in sources.values())} values copied from Blue; the rest:')
        for name, src in sources.items():
            if src != 'blue':
                print('  ' + redact(f'{name:<32} = {new_values[name]}   ({src})'))
        lic = hcl_value(blue.get('asg_license_directory', '"asg_license"'))
        if isinstance(lic, str) and lic and not (GREEN_TF_DIR / lic).is_dir():
            (GREEN_TF_DIR / lic).mkdir(parents=True)
            print(f'  Created empty {GREEN_TF_DIR.relative_to(REPO_ROOT)}/{lic}/')

        if text == existing_text:
            print('  terraform.tfvars is already up to date')
            return
        diff = difflib.unified_diff(redact(existing_text).splitlines(), redact(text).splitlines(),
                                    'terraform.tfvars (current)', 'terraform.tfvars (new)', lineterm='')
        print()
        print('\n'.join(diff))
        confirm(f'Write {target.relative_to(REPO_ROOT)}?', self.args.yes)
        if target.exists():
            shutil.copy2(target, target.with_name(
                f'terraform.tfvars.bak-{datetime.now().strftime("%Y%m%d-%H%M%S")}'))
        target.write_text(text)
        os.chmod(target, 0o600)

    # ── deploy ───────────────────────────────────────────────────────────────
    def deploy(self):
        d = str(GREEN_TF_DIR)
        self.run_or_fail(['terraform', 'init', '-input=false'], cwd=d, what='terraform init')
        plan = 'bluegreen.tfplan'
        self.run_or_fail(['terraform', 'plan', '-input=false', f'-out={plan}'], cwd=d,
                         what='terraform plan')
        confirm('Apply this plan to build Green? (Blue and the spoke routes are not touched)',
                self.args.yes)
        try:
            self.run_or_fail(['terraform', 'apply', '-input=false', plan], cwd=d,
                             what='terraform apply')
        finally:
            (GREEN_TF_DIR / plan).unlink(missing_ok=True)
        shutil.copy2(GREEN_TF_DIR / 'terraform.tfstate', GREEN_STATE)
        print(f'  Copied the Green state to {GREEN_STATE.relative_to(UPGRADE_DIR)}')

    # ── wait ─────────────────────────────────────────────────────────────────
    def green_context(self):
        gs = load_json(GREEN_STATE)
        tg = green_resource_attr(gs, 'aws_lb_target_group', 'arn')
        asg = f'{self.args.green_prefix}-fgt_byol_asg'
        return gs, tg, asg

    def find_green_primary(self, deadline_mins, need_login=True):
        _, tg, asg = self.green_context()
        ec2, autoscaling, elbv2 = self.aws('ec2'), self.aws('autoscaling'), self.aws('elbv2')
        start = time.time()
        while (time.time() - start) / 60 < deadline_mins:
            primary, instances = asg_primary(autoscaling, ec2, asg)
            status = ', '.join(f"{i['instance_id']}={i['lifecycle']}" for i in instances) or 'none'
            if primary and gwlb_healthy(elbv2, tg, primary):
                host = self.args.green_mgmt_ip or management_address(
                    ec2, primary, management_device_index(self.blue_tfvars()),
                    self.args.use_private_ip)
                if not need_login:
                    return primary, host
                fgt = try_login(lambda: self.fgt_factory(host))
                if fgt:
                    fgt.logout()
                    return primary, host
                status += f'; GWLB healthy, REST login to {host} not answering yet'
            elif primary:
                status += f'; primary {primary} not GWLB-healthy yet'
            print(f'  [{ts()}] {asg}: {status}')
            time.sleep(POLL)
        raise StepError(f'Green primary not ready after {deadline_mins} minutes')

    def wait(self):
        primary, host = self.find_green_primary(WAIT_GREEN_MINS)
        print(f'  Green primary {primary} at {host}: InService, GWLB-healthy, login works')
        write_progress(self.done, {'green_primary': primary, 'green_host': host})

    # ── prepare ──────────────────────────────────────────────────────────────
    def prepare(self):
        text, changes, ip_map = prepare_green_config.prepare(
            load_json(INVENTORY), load_json(GREEN_STATE),
            BLUE_BACKUP.read_text(newline=''), self.aws('ec2'))
        for blue_ip, green_ip in ip_map.items():
            print(f'  GWLB {blue_ip:<15} → {green_ip}')
        for line_no, section, old, new in changes:
            print(f'  line {line_no:>6}  {section:<22}  {old} → {new}')
        for n, line in prepare_green_config.leftover_mentions(text, ip_map):
            print(f'  WARNING: Blue GWLB address still at line {n}: {line}')
        with open(GREEN_CONFIG, 'w', newline='') as f:
            f.write(text)
        os.chmod(GREEN_CONFIG, 0o600)
        print(f'  Wrote {GREEN_CONFIG.relative_to(UPGRADE_DIR)}')

    # ── restore ──────────────────────────────────────────────────────────────
    def restore(self):
        primary, host = self.find_green_primary(5)
        confirm(f"Restore {GREEN_CONFIG.name} on Green's primary {primary} ({host})? "
                'It reboots', self.args.yes)
        fgt = self.fgt_factory(host)
        fgt.login()
        fgt.restore(GREEN_CONFIG.read_bytes(), GREEN_CONFIG.name)
        print(f'  [{ts()}] Restore accepted; {primary} is rebooting')
        write_progress(self.done, {'green_primary': primary, 'green_host': host,
                                   'restored_at': datetime.now(timezone.utc).isoformat()})

    # ── verify ───────────────────────────────────────────────────────────────
    def verify(self):
        expected = set(prepare_green_config.gwlb_ips_by_az(
            self.aws('ec2'), green_resource_attr(load_json(GREEN_STATE), 'aws_lb', 'arn')).values())
        time.sleep(POLL)                       # let the reboot start before polling
        primary, host = self.find_green_primary(WAIT_REBOOT_MINS)
        fgt = self.fgt_factory(host)
        fgt.login()
        try:
            peers = fgt.geneve_peers()
        finally:
            fgt.logout()
        for name, ip in sorted(peers.items()):
            print(f'  {name}: remote-ip {ip}  ({"Green GWLB" if ip in expected else "NOT Green"})')
        wrong = {n: ip for n, ip in peers.items() if ip not in expected}
        if not peers or wrong:
            raise StepError("Green's GENEVE peers are not Green's GWLB addresses "
                            f'({", ".join(sorted(expected))}); traffic will not pass after cutover')
        print(f'  Green primary {primary} is healthy behind its GWLB with the right GENEVE peers')

    # ── driver ───────────────────────────────────────────────────────────────
    def run(self):
        self.done = []
        if PROGRESS.exists() and self.args.start_at != 'preflight':
            self.done = load_json(PROGRESS).get('completed', [])
        start = STEPS.index(self.args.start_at)
        for step in STEPS[start:]:
            banner(f'{STEPS.index(step) + 1}/{len(STEPS)}  {step}')
            getattr(self, step)()
            self.done = [s for s in self.done if s != step] + [step]
            write_progress(self.done)
        handoff()


def handoff():
    banner('Green is ready. The cutover is yours to run.')
    print("""
  Nothing has moved traffic. Blue still serves the spokes.

  Before cutting over, check Green's primary yourself: policies, license status,
  and a test session from a spoke once you have cut over.

  Preview, then run, from upgrade_fortios/:

    python3 scripts/cutover.py --inventory state/blue_inventory.json \\
      --green-state state/green.tfstate --dry-run

    python3 scripts/cutover.py --inventory state/blue_inventory.json \\
      --green-state state/green.tfstate

  Roll back with scripts/rollback.py; see the blue-green guide, Phases 4 and 5.
""")


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description='Blue-green FortiOS upgrade up to the cutover (which is never run here)')
    p.add_argument('--fortios-version', required=True, help='Target FortiOS version, e.g. 8.0.2')
    p.add_argument('--upgrade-path-verified', action='store_true',
                   help="Passed to discover.py: Fortinet's Upgrade Path Tool shows a single step")
    p.add_argument('--start-at', choices=STEPS, default='preflight',
                   help='Resume from this step (default: preflight)')
    p.add_argument('--yes', action='store_true',
                   help='Answer yes to the tfvars, apply and restore prompts. Cutover is never run.')
    p.add_argument('--green-prefix', default='green',
                   help='asg_module_prefix and stack_label for Green (default: green)')
    p.add_argument('--use-private-ip', action='store_true',
                   help="Reach the FortiGates' management interfaces on their private addresses "
                        '(VPN, Direct Connect or a jump host)')
    p.add_argument('--blue-mgmt-ip', help="Address of Blue's primary to use instead of looking it up")
    p.add_argument('--green-mgmt-ip', help="Address of Green's primary to use instead of looking it up")
    p.add_argument('--fgt-mgmt-port', type=int, default=443,
                   help='FortiGate admin HTTPS port (default: 443)')
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        Run(args).run()
    except (StepError, FortiGateError, prepare_green_config.PrepareError) as e:
        print(f'\nSTOPPED: {e}')
        if PROGRESS.exists():
            done = load_json(PROGRESS).get('completed', [])
            nxt = next((s for s in STEPS if s not in done), None)
            if nxt:
                print(f'Completed so far: {", ".join(done) or "nothing"}. '
                      f'Resume with --start-at {nxt} once fixed.')
        sys.exit(2)
    except KeyboardInterrupt:
        print('\nInterrupted. Resume with --start-at <step>; progress is in '
              f'{PROGRESS.relative_to(UPGRADE_DIR)}.')
        sys.exit(1)


if __name__ == '__main__':
    main()
