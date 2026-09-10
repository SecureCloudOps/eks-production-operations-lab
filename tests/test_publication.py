"""Keep the privacy guard strict on captures without rejecting documentation."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1]/'scripts/check-publication.py'
spec = importlib.util.spec_from_file_location('publication', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicationTests(unittest.TestCase):
    def test_captured_hostname_is_rejected(self):
        # Construct the fixture so the repository scan does not flag the test itself.
        host = 'ip-' + '-'.join(['10', '20', '30', '40']) + '.ec2.internal'
        self.assertIn('captured EC2 hostname', module.issues('evidence/events.txt', host.encode()))

    def test_private_artifacts_are_rejected(self):
        for name in ['terraform/terraform.tfstate', 'terraform/terraform.tfstate.backup',
                     'terraform/terraform.tfvars', 'terraform/secret.tfplan', '.local/capture.json']:
            with self.subTest(name=name):
                self.assertTrue(module.issues(name, b'{}'))

    def test_examples_and_provenance_are_allowed(self):
        for name, content in [('terraform/terraform.tfvars.sample', b'operator_cidr="192.0.2.1/32"'),
                              ('evidence/provenance.json', b'{"sha256":"' + b'a'*64 + b'"}'),
                              ('evidence/events.txt', b'node/<NODE-01>')]:
            with self.subTest(name=name):
                self.assertEqual(module.issues(name, content), [])
