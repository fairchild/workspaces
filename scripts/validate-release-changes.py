#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run focused syntax checks for release-sensitive PR changes."""

from __future__ import annotations

import argparse
import json
import plistlib
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
INFO_PLIST_PATH = "Sources/WorkspaceManager/Resources/Info.plist"


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


def validate_perf_gate() -> int:
    """A version bump is a release being prepared, so the benchmark-freshness
    gate runs here — a stale docs/performance_benchmarks.csv fails the PR
    check instead of the signed release run (which is where v0.25.0 burned a
    tag on it). Needs tags in the checkout; the gate fails closed without them.
    """
    plist_path = REPO_ROOT / INFO_PLIST_PATH
    try:
        with plist_path.open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        print(f"error: could not read {INFO_PLIST_PATH}: {error}", file=sys.stderr)
        return 1
    version = data.get("CFBundleShortVersionString") if isinstance(data, dict) else None
    if not isinstance(version, str) or not version:
        print(f"error: no CFBundleShortVersionString in {INFO_PLIST_PATH}", file=sys.stderr)
        return 1
    # sys.executable rather than uv: the gate script's PEP 723 block declares no
    # dependencies, and this interpreter already satisfies its python floor.
    return run(
        [
            sys.executable, "scripts/check-perf-benchmarks.py",
            "--tag", f"v{version}", "--format", "github",
        ]
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", required=True, help="JSON file containing changed file paths.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    all_files = load_files(args.changed_files)
    files = release_files(all_files)
    version_bumped = INFO_PLIST_PATH in all_files
    if not files and not version_bumped:
        print("No release-sensitive files changed.")
        return 0

    if version_bumped:
        print("App version metadata changed: running the release perf-benchmark gate.", flush=True)

    if files:
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

    if version_bumped:
        status |= validate_perf_gate()

    if status == 0:
        print("Release change validation passed.")
    else:
        print("Release change validation failed.", file=sys.stderr)
    return 1 if status else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
