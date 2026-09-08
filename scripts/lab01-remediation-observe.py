#!/usr/bin/env python3
"""Read-only pod/PDB/ALB sampling; write JSONL until REMEDIATION_DIR/stop exists."""

import datetime
import json
import os
from pathlib import Path
import subprocess
import time


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


def main():
    directory = Path(os.environ['REMEDIATION_DIR'])
    target_group = os.environ['REMEDIATION_TARGET_GROUP_ARN']
    commands = [
        ('pods', ['kubectl', '-n', 'default', 'get', 'pods', '-l', 'app=http-demo', '-o', 'json']),
        ('pdb', ['kubectl', '-n', 'default', 'get', 'pdb', 'http-demo', '-o', 'json']),
        ('targets', ['aws', 'elbv2', 'describe-target-health', '--target-group-arn', target_group, '--output', 'json']),
    ]
    print(json.dumps({'kind': 'collector-start', 'utc': utc(), 'intervalAfterCycleSeconds': 5}), flush=True)
    while not (directory / 'stop').exists():
        for kind, command in commands:
            if (directory / 'stop').exists():
                break
            record = {'kind': kind, 'startedUTC': utc(), 'phase': (directory / 'phase').read_text().strip()}
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
                record['exitCode'] = result.returncode
                if result.returncode:
                    record.update(gap=True, error=result.stderr.strip())
                else:
                    record['response'] = json.loads(result.stdout)
                    if result.stderr.strip():
                        record['warning'] = result.stderr.strip()
            except (subprocess.TimeoutExpired, OSError, ValueError) as error:
                record.update(gap=True, error=str(error))
            record['finishedUTC'] = utc()
            print(json.dumps(record, separators=(',', ':')), flush=True)
        for _ in range(5):
            if (directory / 'stop').exists():
                break
            time.sleep(1)
    print(json.dumps({'kind': 'collector-stop', 'utc': utc()}), flush=True)


if __name__ == '__main__':
    main()
