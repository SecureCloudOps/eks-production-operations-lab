#!/usr/bin/env python3
"""Reject raw capture hostnames and private artifact paths without printing values.

This narrow repository-specific guard complements Gitleaks; it is not a complete
PII/secret detector. Documentation CIDRs and public AWS image registries are valid.
"""
import argparse
from pathlib import Path
import re
import subprocess

PATTERNS = {
    'captured EC2 hostname': re.compile(r'\bip-(?:\d{1,3}-){3}\d{1,3}(?:\.ec2\.internal)?\b'),
    'captured ALB/NLB hostname': re.compile(r'\b[a-zA-Z0-9.-]+\.elb\.amazonaws\.com\b'),
    'captured EKS endpoint': re.compile(r'\b[A-Za-z0-9]{20,}\.[A-Za-z0-9.-]*eks\.amazonaws\.com\b'),
    'local home path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
}
PRIVATE_PATH = re.compile(
    r'(^|/)(?:\.local|\.terraform|\.aws|\.kube)/|'
    r'\.tfstate(?:\.|$)|\.tfplan(?:\.|$)|'
    r'(^|/)(?:credentials|kubeconfig|\.env)(?:\.|$)'
)


def issues(name, data):
    result = []
    if PRIVATE_PATH.search(name):
        result.append('private artifact path')
    if re.search(r'\.tfvars(?:\.json)?$', name):
        result.append('private Terraform inputs')
    text = data.decode('utf-8', errors='replace')
    for description, pattern in PATTERNS.items():
        if pattern.search(text):
            result.append(description)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', metavar='REF', help='Scan every reachable blob at this Git ref')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    failures = []
    checked = 0
    if args.history:
        commit = subprocess.check_output(['git', 'rev-parse', '--verify', args.history+'^{commit}'], cwd=root, text=True).strip()
        rows = subprocess.check_output(['git', 'rev-list', '--objects', commit], cwd=root, text=True).splitlines()
        for row in rows:
            oid, _, name = row.partition(' ')
            if not name or subprocess.check_output(['git', 'cat-file', '-t', oid], cwd=root, text=True).strip() != 'blob':
                continue
            data = subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=root)
            checked += 1
            failures += [f'{name} (blob {oid[:12]}): {problem}' for problem in issues(name, data)]
    else:
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
        for name in sorted(set(filter(None, names))):
            path = root/name
            if path.is_file():
                checked += 1
                failures += [f'{name}: {problem}' for problem in issues(name, path.read_bytes())]
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'Publication pattern checks passed: {checked} files/blobs; run Gitleaks separately.')


if __name__ == '__main__':
    main()
