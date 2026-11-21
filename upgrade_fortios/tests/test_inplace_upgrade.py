#!/usr/bin/env python3
"""
Tests for scripts/inplace_upgrade.py and scripts/discover.py.

No AWS calls are made. FakeAWS below stands in for the autoscaling, ec2 and elbv2
clients and simulates what the ASG and the autoscale Lambda do over time:
a terminated instance is replaced from the ASG's launch template version, the
replacement goes Pending → InService → licensed and tagged, and when the primary
is terminated a surviving instance is promoted.

Run:  python3 upgrade_fortios/tests/test_inplace_upgrade.py
"""

import builtins
import contextlib
import io
import os
import sys
import tempfile
import types
import unittest
from unittest import mock

try:
    import boto3  # noqa: F401
except ImportError:                      # the scripts import boto3 at module load
    sys.modules['boto3'] = types.ModuleType('boto3')

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts'))
import discover            # noqa: E402
import inplace_upgrade as up   # noqa: E402

OLD_BYOL, NEW_BYOL = 'ami-old-byol', 'ami-new-byol'
OLD_OD, NEW_OD = 'ami-old-od', 'ami-new-od'
TG = 'arn:aws:elasticloadbalancing:eu-central-1:111111111111:targetgroup/tg/abc'


class FakeAWS:
    """One object that answers as the autoscaling, ec2 and elbv2 clients."""

    BOOT_TICKS = 2      # Pending → InService
    CONFIG_TICKS = 2    # InService → licensed, tagged, GWLB healthy
    DRAIN_TICKS = 2     # Terminating → gone

    def __init__(self):
        self.asgs = {}          # name → {desired, min, max, lt_id, version, suspended}
        self.lts = {}           # lt_id → [{'VersionNumber', 'ImageId'}]
        self.instances = {}     # id → dict
        self.seq = 0
        self.events = []        # ('terminate', id, [other instance snapshots])
        self.elect_on_terminate = True
        self.force_unhealthy = set()
        # FortiFlex bookkeeping, as the Lambda keeps it. None = FortiFlex not in use.
        self.flex_used = None           # instance id → serial
        self.flex_available = set()
        self.flex_force = None          # serial the Lambda hands out next, whatever is free
        self.flex_unreadable = False
        self.projections = []

    # ── setup helpers ──────────────────────────
    def add_asg(self, name, lt_id, ami, desired, min_size=0, max_size=4):
        self.lts[lt_id] = [{'VersionNumber': 1, 'ImageId': ami}]
        self.asgs[name] = {'desired': desired, 'min': min_size, 'max': max_size,
                           'lt_id': lt_id, 'version': '1', 'suspended': set()}

    def add_instance(self, asg, ami, role='Secondary', protected=False):
        self.seq += 1
        iid = f'i-{self.seq:04d}'
        self.instances[iid] = {'asg': asg, 'ami': ami, 'lifecycle': 'InService',
                               'health': 'Healthy', 'state': 'running', 'role': role,
                               'protected': protected, 'age': 99, 'configured': True}
        return iid

    def _lt_ami(self, asg_name):
        asg = self.asgs[asg_name]
        ver = int(asg['version'])
        return next(v['ImageId'] for v in self.lts[asg['lt_id']] if v['VersionNumber'] == ver)

    def _live(self, asg_name):
        return [(i, d) for i, d in self.instances.items()
                if d['asg'] == asg_name and d['lifecycle'] != 'Terminating']

    def healthy(self, iid):
        d = self.instances[iid]
        return (d['lifecycle'] == 'InService' and d['configured']
                and iid not in self.force_unhealthy)

    # ── time ───────────────────────────────────
    def tick(self, *_):
        """Advance the simulation one poll interval. Patched in for time.sleep."""
        for iid in list(self.instances):
            d = self.instances[iid]
            d['age'] += 1
            if d['lifecycle'] == 'Terminating':
                if d['age'] >= self.DRAIN_TICKS:
                    del self.instances[iid]
            elif d['lifecycle'] == 'Pending' and d['age'] >= self.BOOT_TICKS:
                d['lifecycle'] = 'InService'
            elif (d['lifecycle'] == 'InService' and not d['configured']
                  and d['age'] >= self.BOOT_TICKS + self.CONFIG_TICKS):
                d['configured'] = True
                if self.flex_used is not None:      # the Lambda issues the first free serial
                    sn = self.flex_force or sorted(self.flex_available)[0]
                    self.flex_available.discard(sn)
                    self.flex_used[iid] = sn
                has_primary = any(x['role'] == 'Primary' for x in self.instances.values())
                d['role'] = 'Secondary' if has_primary else 'Primary'
                d['protected'] = d['role'] == 'Primary'
        for name, asg in self.asgs.items():
            while len(self._live(name)) < asg['desired']:
                self.seq += 1
                self.instances[f'i-{self.seq:04d}'] = {
                    'asg': name, 'ami': self._lt_ami(name), 'lifecycle': 'Pending',
                    'health': 'Healthy', 'state': 'pending', 'role': '',
                    'protected': False, 'age': 0, 'configured': False}
        for d in self.instances.values():
            if d['lifecycle'] == 'InService':
                d['state'] = 'running'

    # ── autoscaling ────────────────────────────
    def describe_auto_scaling_groups(self, AutoScalingGroupNames):
        out = []
        for name in AutoScalingGroupNames:
            asg = self.asgs.get(name)
            if not asg:
                continue
            out.append({
                'AutoScalingGroupName': name,
                'DesiredCapacity': asg['desired'], 'MinSize': asg['min'], 'MaxSize': asg['max'],
                'LaunchTemplate': {'LaunchTemplateId': asg['lt_id'], 'Version': asg['version']},
                'SuspendedProcesses': [{'ProcessName': p} for p in sorted(asg['suspended'])],
                'Instances': [{'InstanceId': i, 'LifecycleState': d['lifecycle'],
                               'HealthStatus': d['health'],
                               'ProtectedFromScaleIn': d['protected']}
                              for i, d in self.instances.items() if d['asg'] == name],
            })
        return {'AutoScalingGroups': out}

    def update_auto_scaling_group(self, AutoScalingGroupName, **kw):
        asg = self.asgs[AutoScalingGroupName]
        if 'LaunchTemplate' in kw:
            asg['version'] = str(kw['LaunchTemplate']['Version'])
        for key, field in (('MinSize', 'min'), ('MaxSize', 'max'), ('DesiredCapacity', 'desired')):
            if key in kw:
                asg[field] = kw[key]

    def suspend_processes(self, AutoScalingGroupName, ScalingProcesses):
        self.asgs[AutoScalingGroupName]['suspended'] |= set(ScalingProcesses)

    def resume_processes(self, AutoScalingGroupName, ScalingProcesses):
        self.asgs[AutoScalingGroupName]['suspended'] -= set(ScalingProcesses)

    def terminate_instance_in_auto_scaling_group(self, InstanceId, ShouldDecrementDesiredCapacity):
        d = self.instances[InstanceId]
        others = [{'id': i, 'healthy': self.healthy(i), 'lifecycle': x['lifecycle'],
                   'role': x['role'], 'ami': x['ami']}
                  for i, x in self.instances.items() if i != InstanceId]
        self.events.append(('terminate', InstanceId, others))
        was_primary = d['role'] == 'Primary'
        d.update(lifecycle='Terminating', role='', protected=False, age=0)
        if self.flex_used is not None and InstanceId in self.flex_used:
            self.flex_available.add(self.flex_used.pop(InstanceId))   # back in the pool
        if was_primary and self.elect_on_terminate:
            for x in self.instances.values():
                if x['lifecycle'] == 'InService' and x['configured']:
                    x['role'], x['protected'] = 'Primary', True
                    break

    # ── ec2 ────────────────────────────────────
    def describe_instances(self, InstanceIds):
        return {'Reservations': [{'Instances': [
            {'InstanceId': i, 'ImageId': self.instances[i]['ami'],
             'State': {'Name': self.instances[i]['state']},
             'Tags': [{'Key': 'Autoscale Role', 'Value': self.instances[i]['role']}]}
            for i in InstanceIds if i in self.instances]}]}

    def describe_launch_template_versions(self, LaunchTemplateId, Versions):
        versions = self.lts[LaunchTemplateId]
        want = Versions[0]
        found = [versions[-1]] if want == '$Latest' else [
            v for v in versions if str(v['VersionNumber']) == str(want)]
        return {'LaunchTemplateVersions': [{'VersionNumber': v['VersionNumber'],
                                            'LaunchTemplateData': {'ImageId': v['ImageId']}}
                                           for v in found]}

    def create_launch_template_version(self, LaunchTemplateId, SourceVersion,
                                       LaunchTemplateData, VersionDescription):
        num = self.lts[LaunchTemplateId][-1]['VersionNumber'] + 1
        self.lts[LaunchTemplateId].append({'VersionNumber': num,
                                           'ImageId': LaunchTemplateData['ImageId']})
        return {'LaunchTemplateVersion': {'VersionNumber': num}}

    # ── dynamodb ───────────────────────────────
    def get_item(self, TableName, Key, ProjectionExpression):
        self.projections.append(ProjectionExpression)
        if self.flex_unreadable:
            raise PermissionError('AccessDeniedException')
        if Key != {'Category': {'S': 'fortiflex'}} or self.flex_used is None:
            return {}
        item = {'used_sn_map': {'M': {i: {'S': sn} for i, sn in self.flex_used.items()}}}
        if self.flex_available:                      # DynamoDB cannot store an empty set
            item['available_sn_list'] = {'SS': sorted(self.flex_available)}
        return {'Item': item}

    # ── elbv2 ──────────────────────────────────
    def describe_target_health(self, TargetGroupArn, Targets=None):
        ids = [t['Id'] for t in Targets] if Targets else [
            i for i, d in self.instances.items() if d['lifecycle'] == 'InService']
        return {'TargetHealthDescriptions': [
            {'Target': {'Id': i},
             'TargetHealth': {'State': 'healthy' if i in self.instances and self.healthy(i)
                              else 'unhealthy'}} for i in ids]}


def build(byol=2, ondemand=0, flex=False):
    """
    A group with `byol` BYOL instances (first is the primary) and `ondemand` on-demand ones.
    With flex=True each BYOL instance holds its own FortiFlex serial and two more are free.
    """
    aws = FakeAWS()
    aws.add_asg('fgt_byol_asg', 'lt-byol', OLD_BYOL, desired=byol, min_size=1)
    aws.add_asg('fgt_on_demand_asg', 'lt-od', OLD_OD, desired=ondemand)
    ids = [aws.add_instance('fgt_byol_asg', OLD_BYOL,
                            role='Primary' if n == 0 else 'Secondary', protected=(n == 0))
           for n in range(byol)]
    if flex:
        aws.flex_used = {iid: f'FGVMFLEX{n + 1}' for n, iid in enumerate(ids)}
        aws.flex_available = {'FGVMFLEX8', 'FGVMFLEX9'}
    ids += [aws.add_instance('fgt_on_demand_asg', OLD_OD) for _ in range(ondemand)]
    inventory = {
        'dynamodb': {'table_name': 'asg_track_table'},
        'discovery_metadata': {'region': 'eu-central-1'},
        'gwlb': {'target_group_arn': TG},
        'architecture': {'arch': 'arm64', 'current_fortios_version': '7.6.7',
                         'current_ami_id': OLD_BYOL},
        'target': {'fortios_version': '7.6.8', 'byol_ami_id': NEW_BYOL, 'ondemand_ami_id': NEW_OD},
        'launch_templates': {
            'byol': {'id': 'lt-byol', 'name': 'fgt_asg_template', 'license_type': 'byol',
                     'target_ami_id': NEW_BYOL},
            'ondemand': {'id': 'lt-od', 'name': 'fgt_asg_template_on_demand',
                         'license_type': 'ondemand', 'target_ami_id': NEW_OD},
        },
        'autoscale_groups': {
            'byol': {'asg_name': 'fgt_byol_asg', 'max': 4},
            'ondemand': {'asg_name': 'fgt_on_demand_asg', 'max': 4},
        },
    }
    return aws, inventory, ids


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        up.RenewingClient.generation = 0
        up.RenewingClient.gave_up = False

    def run_b(self, aws, inventory, answers=None, allow_single=False, flex=None):
        """Run pre-flight and Path B against the fake. Returns (output, exit code or None)."""
        answers = iter(answers) if answers is not None else None
        targets = up.asg_targets_from_inventory(inventory)
        out = io.StringIO()
        code = None
        with mock.patch.object(up.time, 'sleep', aws.tick), \
                mock.patch.object(builtins, 'input',
                                  lambda *_: next(answers) if answers else 'y'), \
                contextlib.redirect_stdout(out):
            primary, secondaries, _, problems = up.preflight_rolling(
                aws, aws, aws, targets, TG, allow_single=allow_single, flex=flex)
            self.assertEqual(problems, [], out.getvalue())
            try:
                up.run_path_b(aws, aws, aws, inventory, targets, primary, secondaries,
                              self.tmp.name, flex=flex)
            except SystemExit as e:
                code = e.code
        return out.getvalue(), code

    def assert_upgraded(self, aws):
        for iid, d in aws.instances.items():
            want = NEW_OD if d['asg'] == 'fgt_on_demand_asg' else NEW_BYOL
            self.assertEqual(d['ami'], want, iid)
            self.assertEqual(d['lifecycle'], 'InService', iid)
        self.assertEqual(sum(d['role'] == 'Primary' for d in aws.instances.values()), 1)
        for asg in aws.asgs.values():
            self.assertEqual(asg['suspended'], set())

    def assert_one_at_a_time(self, aws):
        """At every terminate call, every other instance was InService and GWLB healthy."""
        for _, iid, others in aws.events:
            for o in others:
                self.assertTrue(o['healthy'],
                                f"{iid} was terminated while {o['id']} was {o['lifecycle']}")


class RollingTests(Base):
    def test_two_instances(self):
        aws, inv, ids = build(byol=2)
        out, code = self.run_b(aws, inv)
        self.assertIsNone(code, out)
        self.assert_upgraded(aws)
        self.assert_one_at_a_time(aws)
        self.assertEqual([e[1] for e in aws.events], [ids[1], ids[0]])   # secondary, then primary
        self.assertIn('All checks passed', out)

    def test_three_instances_never_two_down(self):
        aws, inv, ids = build(byol=3)
        out, code = self.run_b(aws, inv)
        self.assertIsNone(code, out)
        self.assert_upgraded(aws)
        self.assert_one_at_a_time(aws)
        self.assertEqual(aws.events[-1][1], ids[0])                      # primary last
        self.assertEqual(len(aws.events), 3)

    def test_primary_terminated_only_when_a_secondary_is_upgraded(self):
        aws, inv, ids = build(byol=2)
        self.run_b(aws, inv)
        _, _, others = aws.events[-1]
        self.assertTrue(all(o['ami'] == NEW_BYOL and o['role'] == 'Secondary' for o in others))

    def test_on_demand_instances_are_replaced_too(self):
        aws, inv, ids = build(byol=2, ondemand=1)
        out, code = self.run_b(aws, inv)
        self.assertIsNone(code, out)
        self.assert_upgraded(aws)
        self.assert_one_at_a_time(aws)
        self.assertEqual(len(aws.events), 3)

    def test_abort_at_primary_prompt_resumes_processes(self):
        aws, inv, ids = build(byol=2)
        # backup: y, launch templates: y, terminate primary: n
        out, code = self.run_b(aws, inv, answers=['y', 'y', 'n'])
        self.assertEqual(code, 0)
        self.assertIn(ids[0], aws.instances)                             # primary untouched
        self.assertEqual(aws.instances[ids[0]]['ami'], OLD_BYOL)
        for asg in aws.asgs.values():
            self.assertEqual(asg['suspended'], set(), 'processes left suspended after abort')

    def test_error_during_roll_resumes_processes(self):
        aws, inv, ids = build(byol=2)
        aws.elect_on_terminate = False          # the Lambda never promotes anyone
        aws.CONFIG_TICKS = 10 ** 6              # and replacements never get configured
        with mock.patch.object(up, 'MAX_WAIT_MINS', 0.0001), self.assertRaises(TimeoutError):
            self.run_b(aws, inv)
        for asg in aws.asgs.values():
            self.assertEqual(asg['suspended'], set())

    def test_rerun_after_abort_skips_upgraded_instances(self):
        aws, inv, ids = build(byol=3)
        self.run_b(aws, inv, answers=['y', 'y', 'n'])
        first_run = len(aws.events)
        self.assertEqual(first_run, 2)                                   # both secondaries
        out, code = self.run_b(aws, inv)
        self.assertIsNone(code, out)
        self.assertEqual(len(aws.events) - first_run, 1)                 # only the primary
        self.assert_upgraded(aws)

    def test_single_instance_allowed_explicitly(self):
        aws, inv, ids = build(byol=1)
        out, code = self.run_b(aws, inv, allow_single=True)
        self.assertIsNone(code, out)
        self.assertIn('there is no other instance', out)
        self.assert_upgraded(aws)


class PreflightTests(Base):
    def problems(self, aws, inv, **kw):
        targets = up.asg_targets_from_inventory(inv)
        return up.preflight_rolling(aws, aws, aws, targets, TG, **kw)

    def test_single_instance_refused(self):
        aws, inv, _ = build(byol=1)
        *_, problems = self.problems(aws, inv)
        self.assertTrue(any('Only 1 instance' in p for p in problems), problems)
        *_, problems = self.problems(aws, inv, allow_single=True)
        self.assertEqual(problems, [])

    def test_unhealthy_target_refused(self):
        aws, inv, ids = build(byol=2)
        aws.force_unhealthy.add(ids[1])
        *_, problems = self.problems(aws, inv)
        self.assertTrue(any('GWLB targets not healthy' in p for p in problems), problems)

    def test_pending_instance_refused(self):
        aws, inv, ids = build(byol=2)
        aws.instances[ids[1]]['lifecycle'] = 'Pending'
        *_, problems = self.problems(aws, inv)
        self.assertTrue(any('not InService' in p for p in problems), problems)

    def test_primary_by_tag_without_scalein_protection(self):
        aws, inv, ids = build(byol=2)
        aws.instances[ids[0]]['protected'] = False       # primary_scalein_protection = false
        primary, secondaries, _, problems = self.problems(aws, inv)
        self.assertEqual(problems, [])
        self.assertEqual(primary['instance_id'], ids[0])
        self.assertEqual([m['instance_id'] for m in secondaries], [ids[1]])

    def test_primary_falls_back_to_scalein_protection(self):
        aws, inv, ids = build(byol=2)
        aws.instances[ids[0]]['role'] = ''
        primary, *_ = self.problems(aws, inv)
        self.assertEqual(primary['instance_id'], ids[0])

    def test_no_primary_refused(self):
        aws, inv, ids = build(byol=2)
        aws.instances[ids[0]].update(role='', protected=False)
        primary, _, _, problems = self.problems(aws, inv)
        self.assertIsNone(primary)
        self.assertTrue(any('Cannot identify the primary' in p for p in problems), problems)

    def test_two_primaries_refused(self):
        aws, inv, ids = build(byol=2)
        aws.instances[ids[1]]['role'] = 'Primary'
        primary, _, _, problems = self.problems(aws, inv)
        self.assertIsNone(primary)
        self.assertTrue(problems)


class ReplacementWaitTests(Base):
    def test_ignores_instances_that_were_already_there(self):
        """The old bug: an already-upgraded instance was returned as 'the replacement'."""
        aws, inv, ids = build(byol=3)
        aws.asgs['fgt_byol_asg']['version'] = '1'
        aws.lts['lt-byol'][0]['ImageId'] = NEW_BYOL
        aws.instances[ids[1]]['ami'] = NEW_BYOL          # upgraded earlier
        before = set(aws.instances)
        with mock.patch.object(up.time, 'sleep', aws.tick), contextlib.redirect_stdout(io.StringIO()):
            aws.terminate_instance_in_auto_scaling_group(ids[2], False)
            new_id = up.wait_for_replacement(aws, aws, 'fgt_byol_asg', before, NEW_BYOL)
        self.assertNotIn(new_id, before)

    def test_replacement_on_wrong_ami_is_an_error(self):
        aws, inv, ids = build(byol=2)                    # launch template still on the old AMI
        before = set(aws.instances)
        with mock.patch.object(up.time, 'sleep', aws.tick), contextlib.redirect_stdout(io.StringIO()):
            aws.terminate_instance_in_auto_scaling_group(ids[1], False)
            with self.assertRaises(RuntimeError):
                up.wait_for_replacement(aws, aws, 'fgt_byol_asg', before, NEW_BYOL)


class LaunchTemplateTests(Base):
    def test_creates_version_and_records_previous(self):
        aws, inv, _ = build(byol=2)
        with contextlib.redirect_stdout(io.StringIO()):
            changes = up.update_all_launch_templates(aws, aws, inv, self.tmp.name)
        byol = next(c for c in changes if c['asg_name'] == 'fgt_byol_asg')
        self.assertEqual((byol['previous_version'], byol['new_version']), ('1', '2'))
        self.assertEqual(aws.asgs['fgt_byol_asg']['version'], '2')
        self.assertTrue(os.path.isfile(os.path.join(self.tmp.name, 'inplace_rollback.json')))

    def test_reuses_version_terraform_already_created(self):
        aws, inv, _ = build(byol=2)
        aws.lts['lt-byol'].append({'VersionNumber': 2, 'ImageId': NEW_BYOL})
        aws.asgs['fgt_byol_asg']['version'] = '2'
        with contextlib.redirect_stdout(io.StringIO()):
            changes = up.update_all_launch_templates(aws, aws, inv, self.tmp.name)
        byol = next(c for c in changes if c['asg_name'] == 'fgt_byol_asg')
        self.assertEqual(byol['new_version'], '2')
        self.assertEqual(len(aws.lts['lt-byol']), 2)     # no extra version created

    def test_second_run_does_not_overwrite_rollback_record(self):
        aws, inv, _ = build(byol=2)
        path = os.path.join(self.tmp.name, 'inplace_rollback.json')
        with contextlib.redirect_stdout(io.StringIO()):
            up.update_all_launch_templates(aws, aws, inv, self.tmp.name)
            with open(path) as f:
                first = f.read()
            up.update_all_launch_templates(aws, aws, inv, self.tmp.name)
        with open(path) as f:
            self.assertEqual(f.read(), first)


STILL_EXPIRED = 'Credentials were refreshed, but the refreshed credentials are still expired.'


class ExpiringAWS:
    """
    Hands out clients backed by a FakeAWS whose credentials expire after
    `good_calls` API calls. Clients built before renew() keep failing, as real
    clients do; only a client built afterwards works again.
    """

    def __init__(self, aws, good_calls):
        self.aws, self.calls_left, self.epoch, self.built = aws, good_calls, 0, 0

    def renew(self):
        self.epoch += 1
        self.calls_left = 10 ** 9

    def factory(self, service, region):
        outer, epoch = self, self.epoch
        self.built += 1

        class Client:
            def __getattr__(self, name):
                real = getattr(outer.aws, name)

                def call(*args, **kwargs):
                    if epoch != outer.epoch:
                        raise RuntimeError(STILL_EXPIRED)
                    if outer.calls_left <= 0:
                        raise RuntimeError(STILL_EXPIRED)
                    outer.calls_left -= 1
                    return real(*args, **kwargs)
                return call
        return Client()


class CredentialTests(Base):
    def clients(self, aws, good_calls):
        exp = ExpiringAWS(aws, good_calls)
        return exp, [up.RenewingClient(s, 'eu-central-1', factory=exp.factory)
                     for s in ('ec2', 'autoscaling', 'elbv2')]

    def roll(self, aws, inv, clients, on_retry_prompt):
        """Run Path B through RenewingClients. Returns (output, prompts seen, exception)."""
        ec2, autoscaling, elbv2 = clients
        targets = up.asg_targets_from_inventory(inv)
        prompts, out, raised = [], io.StringIO(), None

        def answer(prompt=''):
            prompts.append(prompt)
            return on_retry_prompt() if 'retry' in prompt else 'y'

        with mock.patch.object(up.time, 'sleep', aws.tick), \
                mock.patch.object(builtins, 'input', answer), \
                contextlib.redirect_stdout(out):
            primary, secondaries, _, problems = up.preflight_rolling(
                aws, aws, aws, targets, TG)
            self.assertEqual(problems, [])
            try:
                up.run_path_b(ec2, autoscaling, elbv2, inv, targets, primary, secondaries,
                              self.tmp.name)
            except up.CredentialsExpired as e:
                raised = e
        return out.getvalue(), prompts, raised

    def test_renewed_credentials_let_the_roll_finish(self):
        aws, inv, _ = build(byol=2)
        exp, clients = self.clients(aws, good_calls=12)     # expires mid-roll

        def renew():
            exp.renew()
            return ''
        out, prompts, raised = self.roll(aws, inv, clients, renew)
        self.assertIsNone(raised, out)
        self.assertEqual(sum('retry' in p for p in prompts), 1, 'asked once, not once per client')
        self.assertIn('AWS credentials have expired', out)
        self.assertIn('All checks passed', out)
        self.assert_upgraded(aws)
        self.assert_one_at_a_time(aws)

    def test_declining_stops_once_and_prints_the_resume_command(self):
        aws, inv, _ = build(byol=2)
        exp, clients = self.clients(aws, good_calls=12)
        with mock.patch.object(up, 'CLI_REGION', ' --region eu-central-1'):
            out, prompts, raised = self.roll(aws, inv, clients, lambda: 'q')
        self.assertIsInstance(raised, up.CredentialsExpired)
        self.assertEqual(sum('retry' in p for p in prompts), 1, 'asked again after the operator said stop')
        self.assertIn('aws autoscaling resume-processes --auto-scaling-group-name fgt_byol_asg', out)
        self.assertIn('--region eu-central-1', out)
        self.assertTrue(aws.asgs['fgt_byol_asg']['suspended'])      # the resume could not run

    def test_pressing_enter_without_renewing_asks_again(self):
        aws, inv, _ = build(byol=2)
        exp, clients = self.clients(aws, good_calls=12)
        tries = []

        def second_time():
            tries.append(1)
            if len(tries) == 2:
                exp.renew()
            return ''
        out, prompts, raised = self.roll(aws, inv, clients, second_time)
        self.assertIsNone(raised, out)
        self.assertEqual(len(tries), 2)
        self.assert_upgraded(aws)

    def test_recognises_expired_credential_errors(self):
        class ClientError(Exception):
            def __init__(self, code):
                self.response = {'Error': {'Code': code}}

        class UnauthorizedSSOTokenError(Exception):
            pass
        self.assertTrue(up.is_expired_credentials_error(RuntimeError(STILL_EXPIRED)))
        self.assertTrue(up.is_expired_credentials_error(ClientError('ExpiredToken')))
        self.assertTrue(up.is_expired_credentials_error(ClientError('RequestExpired')))
        self.assertTrue(up.is_expired_credentials_error(UnauthorizedSSOTokenError()))
        self.assertFalse(up.is_expired_credentials_error(ClientError('Throttling')))
        self.assertFalse(up.is_expired_credentials_error(RuntimeError('something else')))

    def test_other_errors_are_not_treated_as_expired_credentials(self):
        class Broken:
            def describe_instances(self, **_):
                raise ValueError('boom')
        client = up.RenewingClient('ec2', 'eu-central-1', factory=lambda *_: Broken())
        with mock.patch.object(builtins, 'input', side_effect=AssertionError('prompted')), \
                self.assertRaises(ValueError):
            client.describe_instances(InstanceIds=['i-1'])

    def test_warns_when_credentials_expire_before_the_roll_can_finish(self):
        from datetime import datetime, timedelta, timezone
        now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
        soon = up.credentials_warning(2, now=now, expiry=now + timedelta(minutes=14))
        self.assertIn('in 14 min', soon[0])
        self.assertIn('12:14 UTC', soon[0])
        self.assertEqual(up.credentials_warning(2, now=now, expiry=now + timedelta(hours=2)), [])
        self.assertEqual(up.credentials_warning(0, now=now, expiry=now + timedelta(minutes=1)), [])
        with mock.patch.object(up, 'credentials_expiry', lambda: None):
            self.assertEqual(up.credentials_warning(2, now=now), [])      # static credentials


class RerunTests(Base):
    """Running the same command again after a run that was interrupted."""

    ARGS = types.SimpleNamespace(restore_config=None, allow_single_instance=False,
                                 fgt_api_key=None, fgt_mgmt_port=443)

    def rerun(self, aws, inv, answer='y', dynamodb=None):
        args = types.SimpleNamespace(**vars(self.ARGS), state_dir=self.tmp.name)
        prompts, out, code = [], io.StringIO(), None

        def respond(prompt=''):
            prompts.append(prompt)
            return answer
        with mock.patch.object(up.time, 'sleep', aws.tick), \
                mock.patch.object(builtins, 'input', respond), \
                mock.patch.object(up, 'credentials_expiry', lambda: None), \
                contextlib.redirect_stdout(out):
            try:
                up.run(args, inv, 'eu-central-1', aws, aws, aws, dynamodb)
            except SystemExit as e:
                code = e.code
        return out.getvalue(), prompts, code

    def upgraded_but_left_suspended(self):
        aws, inv, _ = build(byol=2)
        self.run_b(aws, inv)
        aws.asgs['fgt_byol_asg']['suspended'] = set(up.SUSPEND_PROCESSES)
        return aws, inv

    def test_finished_group_gets_processes_resumed_and_a_final_status(self):
        aws, inv = self.upgraded_but_left_suspended()
        out, prompts, code = self.rerun(aws, inv)
        self.assertIsNone(code, out)
        self.assertEqual(prompts, [], 'nothing to replace, so nothing to confirm')
        self.assertEqual(aws.asgs['fgt_byol_asg']['suspended'], set())
        self.assertIn('Nothing to replace', out)
        self.assertIn('Final Status', out)
        self.assertIn('All checks passed', out)
        self.assertEqual(len(aws.events), 2)                              # no further terminations

    def test_replacement_still_starting_is_reported_with_the_resume_command(self):
        aws, inv = self.upgraded_but_left_suspended()
        aws.force_unhealthy.add(next(iter(aws.instances)))
        out, prompts, code = self.rerun(aws, inv)
        self.assertEqual(code, 1)
        self.assertIn('Nothing was changed', out)
        self.assertIn('aws autoscaling resume-processes', out)
        self.assertTrue(aws.asgs['fgt_byol_asg']['suspended'])

    def test_interrupted_before_the_primary_finishes_the_roll(self):
        aws, inv, ids = build(byol=2)
        self.run_b(aws, inv, answers=['y', 'y', 'n'])                     # stop at the primary
        aws.asgs['fgt_byol_asg']['suspended'] = set(up.SUSPEND_PROCESSES)  # as after a crash
        out, prompts, code = self.rerun(aws, inv)
        self.assertIsNone(code, out)
        self.assertIn('left ASG processes suspended', out)
        self.assert_upgraded(aws)

    def test_final_status_fails_if_the_asg_still_launches_the_old_ami(self):
        aws, inv = self.upgraded_but_left_suspended()
        aws.asgs['fgt_byol_asg']['version'] = '1'
        out, prompts, code = self.rerun(aws, inv)
        self.assertEqual(code, 1)
        self.assertIn('its launch template version uses ami-old-byol', out)


class FortiFlexTests(RerunTests):
    """Every FortiGate must hold its own FortiFlex serial."""

    def flex(self, aws):
        return up.FlexSerials(aws, 'asg_track_table')

    def test_clean_group_rolls_and_every_instance_keeps_its_own_serial(self):
        aws, inv, _ = build(byol=3, flex=True)
        out, code = self.run_b(aws, inv, flex=self.flex(aws))
        self.assertIsNone(code, out)
        self.assert_upgraded(aws)
        self.assertEqual(len(set(aws.flex_used.values())), 3, aws.flex_used)
        self.assertEqual(set(aws.flex_used), set(aws.instances))
        self.assertIn('(not shared)', out)
        self.assertIn('[✓] Each instance has its own FortiFlex serial', out)
        self.assertIn('serial=FGVMFLEX', out)

    def test_refuses_to_start_when_two_instances_share_a_serial(self):
        aws, inv, ids = build(byol=2, flex=True)
        aws.flex_used = {ids[0]: 'FGVMFLEX1', ids[1]: 'FGVMFLEX1'}
        out, prompts, code = self.rerun(aws, inv, dynamodb=aws)
        self.assertEqual(code, 1)
        self.assertEqual(prompts, [], 'refused before asking anything')
        self.assertIn('FortiFlex serial FGVMFLEX1 is issued to 2 instances', out)
        self.assertIn('execute vm-license', out)
        self.assertIn('Nothing was changed', out)
        self.assertEqual(aws.events, [])
        self.assertEqual(aws.asgs['fgt_byol_asg']['version'], '1')         # launch template untouched

    def test_refuses_to_start_when_a_serial_in_use_is_also_in_the_pool(self):
        aws, inv, ids = build(byol=2, flex=True)
        aws.flex_available.add('FGVMFLEX1')
        out, prompts, code = self.rerun(aws, inv, dynamodb=aws)
        self.assertEqual(code, 1)
        self.assertIn('also', out)
        self.assertIn('lists it as available', out)
        self.assertEqual(aws.events, [])

    def test_duplicate_issued_mid_roll_stops_before_the_primary(self):
        aws, inv, ids = build(byol=3, flex=True)
        aws.flex_force = 'FGVMFLEX1'                 # the Lambda hands out the primary's serial
        with self.assertRaises(RuntimeError) as ctx:
            self.run_b(aws, inv, flex=self.flex(aws))
        self.assertIn('FGVMFLEX1 is issued to 2 instances', str(ctx.exception))
        self.assertEqual(len(aws.events), 1)                              # one secondary only
        self.assertIn(ids[0], aws.instances)                              # primary untouched
        self.assertEqual(aws.instances[ids[0]]['ami'], OLD_BYOL)
        self.assertEqual(aws.asgs['fgt_byol_asg']['suspended'], set())

    def test_finished_group_with_shared_serial_fails_the_final_status(self):
        aws, inv = self.upgraded_but_left_suspended()
        aws.flex_used = {iid: 'FGVMFLEX1' for iid in aws.instances}
        aws.flex_available = {'FGVMFLEX2', 'FGVMFLEX3'}
        out, prompts, code = self.rerun(aws, inv, dynamodb=aws)
        self.assertEqual(code, 1)
        self.assertIn('Final Status', out)
        self.assertIn('[✗] Each instance has its own FortiFlex serial', out)
        self.assertEqual(aws.asgs['fgt_byol_asg']['suspended'], set(), 'processes are still resumed')
        self.assertEqual(len(aws.events), 2)                              # nothing replaced again

    def test_unreadable_table_is_reported_and_does_not_block(self):
        aws, inv, _ = build(byol=2, flex=True)
        aws.flex_unreadable = True
        out, code = self.run_b(aws, inv, flex=self.flex(aws))
        self.assertIsNone(code, out)
        self.assertIn('FortiFlex serial check skipped', out)
        self.assert_upgraded(aws)

    def test_license_file_group_is_not_checked(self):
        aws, inv, _ = build(byol=2)                  # no FortiFlex record in the table
        out, code = self.run_b(aws, inv, flex=self.flex(aws))
        self.assertIsNone(code, out)
        self.assertNotIn('FortiFlex', out)
        self.assertIn('All checks passed', out)

    def test_only_the_serial_attributes_are_read(self):
        aws, inv, _ = build(byol=2, flex=True)
        self.run_b(aws, inv, flex=self.flex(aws))
        self.assertEqual(set(aws.projections), {'available_sn_list, used_sn_map'})


class DiscoverTests(unittest.TestCase):
    def test_target_ami_lookup_is_limited_to_marketplace_and_product(self):
        calls = []

        class Paginator:
            def paginate(self, **kw):
                calls.append(kw)
                return [{'Images': [
                    {'ImageId': 'ami-good', 'CreationDate': '2026-10-20',
                     'Name': 'FortiGate-VMARM64-AWS build3744 (7.6.8) GA-x'},
                    {'ImageId': 'ami-other-version', 'CreationDate': '2026-11-01',
                     'Name': 'FortiGate-VMARM64-AWS build3704 (7.6.7) GA-x'}]}]

        ec2 = types.SimpleNamespace(get_paginator=lambda name: Paginator())
        ami, name = discover.find_target_ami(ec2, 'arm64', 'byol', '7.6.8', 'prodcode123')
        self.assertEqual(ami, 'ami-good')
        self.assertEqual(calls[0]['Owners'], ['aws-marketplace'])
        self.assertIn({'Name': 'product-code', 'Values': ['prodcode123']}, calls[0]['Filters'])

    def test_product_code_falls_back_to_known_listing(self):
        calls = []
        ec2 = types.SimpleNamespace(get_paginator=lambda name: types.SimpleNamespace(
            paginate=lambda **kw: calls.append(kw) or []))
        self.assertEqual(discover.find_target_ami(ec2, 'x86_64', 'ondemand', '7.6.8'), (None, None))
        self.assertIn({'Name': 'product-code',
                       'Values': [discover.FALLBACK_PRODUCT_CODES[('x86_64', 'ondemand')]]},
                      calls[0]['Filters'])

    def test_primary_by_tag_then_protection(self):
        insts = [{'instance_id': 'i-a', 'protected': False}, {'instance_id': 'i-b', 'protected': True}]
        self.assertEqual(discover.find_primary_instance(insts, {'i-a': 'Primary'}), 'i-a')
        self.assertEqual(discover.find_primary_instance(insts, {}), 'i-b')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(discover.find_primary_instance(
                insts, {'i-a': 'Primary', 'i-b': 'Primary'}))

    def test_region_comes_from_state_file(self):
        state = {'resources': [{'type': 'aws_lb', 'name': 'gwlb', 'instances': [
            {'attributes': {'arn': 'arn:aws:elasticloadbalancing:eu-central-1:1:loadbalancer/gwy/x/y'}}]}]}
        self.assertEqual(discover.region_from_state(state), 'eu-central-1')
        fake_boto3 = types.SimpleNamespace(session=types.SimpleNamespace(
            Session=lambda: types.SimpleNamespace(region_name='us-west-2')))
        with mock.patch.object(discover, 'boto3', fake_boto3), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(discover.resolve_region(state), 'eu-central-1')
            self.assertEqual(discover.resolve_region(state, 'ap-south-1'), 'ap-south-1')
            self.assertEqual(discover.resolve_region({'resources': []}), 'us-west-2')

    def test_no_region_is_an_error_not_a_default(self):
        fake_boto3 = types.SimpleNamespace(session=types.SimpleNamespace(
            Session=lambda: types.SimpleNamespace(region_name=None)))
        with mock.patch.object(discover, 'boto3', fake_boto3), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            discover.resolve_region({'resources': []})


if __name__ == '__main__':
    unittest.main(verbosity=2)
