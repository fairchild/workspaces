#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Release gate: has anyone measured performance recently?

The release job cannot measure perf itself — it runs on a hosted image with no
display, and launching the app there produces no launch telemetry (that is what
blocked v0.24.0). Perf measurement lives on the laptop, opt-in, per
docs/decisions/perf-measurement-laptop-optin.md.

So this gate reads committed evidence instead: docs/performance_benchmarks.csv,
one row per release. It grades the gap between the newest benchmarked release and
the release being cut — pass at 0, warn at 1, fail at 2 or more. Absent or empty
evidence fails, because #1238's rule is that a skipped measurement must never be
indistinguishable from a passing one.

Usage: check-perf-benchmarks.py --tag v0.25.0 [--format github]
Exit 0 when evidence is current or one release stale, 1 when it is older or missing.
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV = REPO_ROOT / "docs" / "performance_benchmarks.csv"
BLOCK_AFTER = 2
RELEASE_TAG_GLOB = "v*"


def release_tags(repo_root: Path) -> list[str]:
    """Every v* tag, oldest first, ordered by when the tag was created.

    creatordate rather than version sort: a tag cut out of order still lands
    where it actually happened, and that is what "releases since" means.
    """
    result = subprocess.run(
        ["git", "tag", "--list", RELEASE_TAG_GLOB, "--sort=creatordate"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def benchmarked_tags(csv_path: Path) -> list[str]:
    if not csv_path.is_file():
        return []
    with csv_path.open(newline="") as handle:
        return [
            row["release_tag"].strip()
            for row in csv.DictReader(handle)
            if (row.get("release_tag") or "").strip()
        ]


def releases_since(tags: list[str], benchmarked: set[str], current: str) -> int:
    """How many releases have happened since the newest benchmarked one.

    Counts the release being cut, so a tag with its own row scores 0 and a tag
    whose predecessor was the last measured one scores 1.
    """
    ordered = [tag for tag in tags if tag != current] + [current]
    for distance, tag in enumerate(reversed(ordered)):
        if tag in benchmarked:
            return distance
    # No benchmarked tag appears in release history — the row references a tag
    # that does not exist, or tags are unavailable. Freshness cannot be shown,
    # so it is not assumed: floor the answer at the blocking distance rather
    # than let a short history read as nearly current.
    return max(len(ordered), BLOCK_AFTER)


def emit(level: str, message: str, style: str) -> None:
    if style == "github" and level in ("warning", "error"):
        print(f"::{level}::{message}")
    else:
        print(f"{level}: {message}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--tag", required=True, help="release tag being cut, e.g. v0.25.0")
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--format", choices=("plain", "github"), default="plain")
    args = parser.parse_args()

    benchmarked = benchmarked_tags(args.csv)
    if not benchmarked:
        emit(
            "error",
            f"No performance benchmarks found in {args.csv.relative_to(REPO_ROOT) if args.csv.is_relative_to(REPO_ROOT) else args.csv}. "
            "Release blocked: absent evidence is not a passing measurement. "
            "See docs/performance_benchmarks.md to generate a row.",
            args.format,
        )
        return 1

    gap = releases_since(release_tags(args.repo_root), set(benchmarked), args.tag)
    newest = benchmarked[-1]

    if gap == 0:
        print(f"ok: {args.tag} has committed performance benchmarks")
        return 0

    if gap < BLOCK_AFTER:
        emit(
            "warning",
            f"No performance benchmarks for {args.tag}; newest is {newest} "
            f"({gap} release behind). Release proceeds, but the next one is blocked "
            "unless benchmarks are updated. See docs/performance_benchmarks.md.",
            args.format,
        )
        return 0

    emit(
        "error",
        f"Performance benchmarks are {gap} releases stale (newest: {newest}, releasing: {args.tag}). "
        f"Release blocked at {BLOCK_AFTER}. Run ./scripts/perf-runner.sh on a laptop and add a row "
        "to docs/performance_benchmarks.csv — see docs/performance_benchmarks.md.",
        args.format,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
