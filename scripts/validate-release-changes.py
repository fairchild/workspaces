#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run focused syntax checks for release-sensitive PR changes."""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from release_policy import RELEASE_PATHS


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_files(path: str | None) -> list[str]:
    if not path:
        return []
    with Path(path).open(encoding="utf-8") as file:
        data = json.load(file)
    return [str(item) for item in data]


def run(command: list[str]) -> int:
    print("$", shlex.join(command), flush=True)
    result = subprocess.run(command, cwd=REPO_ROOT, text=True, check=False)
    return result.returncode


def validate_shell(path: str) -> int:
    return run(["bash", "-n", path])


def validate_workflow_yaml(path: str) -> int:
    if not shutil.which("ruby"):
        print("notice: ruby unavailable; skipping YAML parser check")
        return 0
    script = "require 'yaml'; YAML.load_file(ARGV.fetch(0)); puts 'YAML parse OK'"
    return run(["ruby", "-e", script, path])


def validate_swift_parse(path: str) -> int:
    if not shutil.which("swift"):
        print("notice: swift unavailable; skipping Swift parser check")
        return 0
    return run(["swift", "-frontend", "-parse", path])


def release_files(files: list[str]) -> list[str]:
    return [path for path in files if path in RELEASE_PATHS]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", required=True, help="JSON file containing changed file paths.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    files = release_files(load_files(args.changed_files))
    if not files:
        print("No release-sensitive files changed.")
        return 0

    print("Release-sensitive files changed:", flush=True)
    for path in files:
        print(f"- {path}")

    status = 0
    for path in files:
        if path.endswith(".sh") and (REPO_ROOT / path).exists():
            status |= validate_shell(path)
        if path.endswith(".swift") and (REPO_ROOT / path).exists():
            status |= validate_swift_parse(path)

    if ".github/workflows/release.yml" in files:
        status |= validate_workflow_yaml(".github/workflows/release.yml")

    if status == 0:
        print("Release change validation passed.")
    else:
        print("Release change validation failed.", file=sys.stderr)
    return 1 if status else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
