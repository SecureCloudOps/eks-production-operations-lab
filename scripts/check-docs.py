#!/usr/bin/env python3
"""Check local documentation links, evidence JSON and script syntax without AWS."""

import ast
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit


def main():
    root = Path(__file__).resolve().parents[1]
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    ).decode().split("\0")
    paths = sorted({root / name for name in names if name})
    failures = []
    counts = {"markdown": 0, "structured_evidence": 0, "python": 0, "shell": 0}
    for path in paths:
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if path.suffix == ".md":
            counts["markdown"] += 1
            content = path.read_text()
            # Match inline Markdown links; remote URLs/fragment-only links are skipped.
            for match in re.finditer(r"\[[^\]\n]*\]\(([^\s)]+)\)", content):
                target = urlsplit(match.group(1).strip("<>"))
                if target.scheme or target.netloc or not target.path:
                    continue
                destination = (path.parent / unquote(target.path)).resolve()
                if not destination.is_relative_to(root) or not destination.exists():
                    failures.append(f"{relative}: missing local link: {target.path}")
        if relative.parts[0] == "evidence" and path.suffix in {".json", ".jsonl"}:
            counts["structured_evidence"] += 1
            try:
                if path.suffix == ".jsonl":
                    for number, line in enumerate(path.read_text().splitlines(), 1):
                        if line.strip():
                            try:
                                json.loads(line)
                            except ValueError as error:
                                raise ValueError(f"line {number}: {error}") from error
                else:
                    json.loads(path.read_text())
            except ValueError as error:
                failures.append(f"{relative}: invalid JSON: {error}")
        if relative.parts[0] == "scripts" and path.suffix == ".py":
            counts["python"] += 1
            try:
                ast.parse(path.read_text(), filename=str(relative))
            except SyntaxError as error:
                failures.append(f"{relative}: {error}")
        if relative.parts[0] == "scripts" and path.suffix == ".sh":
            counts["shell"] += 1
            result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
            if result.returncode:
                failures.append(f"{relative}: {result.stderr.strip()}")
    if failures:
        raise SystemExit("\n".join(failures))
    print("Repository checks passed: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    print("Local link destinations checked; remote URLs and heading fragments were not validated.")


if __name__ == "__main__":
    main()
