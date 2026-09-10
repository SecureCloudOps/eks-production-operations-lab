"""Exercise the actual shell gate with a fake AWS executable; no cloud access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_AWS = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
op = args[1]
case = os.environ['GATE_CASE']
with open(os.environ['AWS_CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\n')
if case == 'api-error' and op == 'describe-target-groups':
    sys.exit(254)
if case == 'invalid-json' and op == 'describe-network-interfaces':
    print('{'); sys.exit(0)
keys = {'describe-vpcs':'Vpcs', 'describe-load-balancers':'LoadBalancers',
        'describe-target-groups':'TargetGroups', 'describe-security-groups':'SecurityGroups',
        'describe-network-interfaces':'NetworkInterfaces'}
if op not in keys:
    sys.exit(99)
key = keys[op]
if case == 'missing-' + key:
    print('{}'); sys.exit(0)
if case == 'null-' + key:
    print(json.dumps({key:None})); sys.exit(0)
vpc = os.environ['VPC_ID']
items = []
if op == 'describe-vpcs':
    items = [] if case == 'missing-vpc' else [{'VpcId': 'vpc-11111111111111111' if case == 'wrong-vpc' else vpc}]
elif case == key:
    items = [{'VpcId':vpc}]
elif case == 'other-vpc' and key in ['LoadBalancers','TargetGroups']:
    items = [{'VpcId':'vpc-11111111111111111'}]
print(json.dumps({key:items}))
'''


class CleanupGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        aws = self.directory / 'aws'
        aws.write_text(FAKE_AWS)
        aws.chmod(0o700)
        self.calls = self.directory / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.directory)+os.pathsep+os.environ['PATH'],
                        VPC_ID='vpc-0123456789abcdef0', AWS_REGION='us-east-1',
                        CLUSTER_NAME='test-lab', AWS_CALLS=str(self.calls))

    def run_gate(self, case):
        return subprocess.run(['bash', str(ROOT/'scripts/check-load-balancer-cleanup.sh')],
                              env=dict(self.env, GATE_CASE=case), cwd=ROOT,
                              capture_output=True, text=True, timeout=15)

    def test_only_empty_lab_inventory_passes(self):
        for case in ['empty', 'other-vpc']:
            with self.subTest(case=case):
                result = self.run_gate(case)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('gate passed', result.stdout)

    def test_remaining_resources_block(self):
        for case in ['LoadBalancers', 'TargetGroups', 'SecurityGroups', 'NetworkInterfaces']:
            with self.subTest(case=case):
                result = self.run_gate(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('STOP:', result.stderr)
                self.assertNotIn('gate passed', result.stdout)

    def test_failed_or_incomplete_responses_block(self):
        cases = ['api-error', 'invalid-json', 'missing-vpc', 'wrong-vpc']
        for key in ['LoadBalancers', 'TargetGroups', 'SecurityGroups', 'NetworkInterfaces']:
            cases += ['missing-'+key, 'null-'+key]
        for case in cases:
            with self.subTest(case=case):
                result = self.run_gate(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('gate passed', result.stdout)

    def test_invalid_vpc_stops_before_aws(self):
        self.env['VPC_ID'] = 'invalid'
        self.assertNotEqual(self.run_gate('empty').returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_requests_are_scoped_and_read_only(self):
        self.assertEqual(self.run_gate('empty').returncode, 0)
        calls = [json.loads(x) for x in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 5)
        for args in calls:
            self.assertTrue(args[1].startswith('describe-'))
            self.assertEqual(args[args.index('--region')+1], 'us-east-1')
        sg = next(x for x in calls if x[1] == 'describe-security-groups')
        self.assertIn('Name=vpc-id,Values='+self.env['VPC_ID'], sg)
        self.assertIn('Name=tag:elbv2.k8s.aws/cluster,Values=test-lab', sg)

    def test_make_down_never_destroys_after_failed_gate(self):
        fake = self.directory/'terraform'
        marker = self.directory/'terraform-called'
        fake.write_text('#!/bin/sh\nprintf invoked > "$TF_MARKER"\n')
        fake.chmod(0o700)
        result = subprocess.run(['make', 'down', 'TERRAFORM='+str(fake)], cwd=ROOT,
                                env=dict(self.env, GATE_CASE='LoadBalancers', TF_MARKER=str(marker)),
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
