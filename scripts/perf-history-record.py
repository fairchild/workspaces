#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Append canonical perf summary.json files to the launch-lane history.

Gives ad-hoc canonical summaries (re-baseline output dirs, installed-lane runs)
the same metrics-history.csv + dashboard.md recording path that
perf-baseline.sh --record uses, so trend history survives between cron
recordings (#1238).
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from perf_history import history_row_from_summary, record_summary  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--summary",
        action="append",
        required=True,
        type=Path,
        help="Canonical summary.json path. Repeat to append several rows; the last one drives the dashboard.",
    )
    parser.add_argument(
        "--timestamp",
        default=None,
        help="Row timestamp (%%Y-%%m-%%dT%%H:%%M:%%S%%z). Defaults to each summary file's mtime.",
    )
    parser.add_argument(
        "--root-dir",
        type=Path,
        default=REPO_ROOT,
        help="Repo root whose docs/performance history is updated.",
    )
    return parser.parse_args()


def summary_timestamp(summary_path: Path, override: str | None) -> str:
    if override:
        return override
    mtime = datetime.fromtimestamp(summary_path.stat().st_mtime).astimezone()
    return mtime.strftime("%Y-%m-%dT%H:%M:%S%z")


def main() -> int:
    args = parse_args()
    for summary_path in args.summary:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        timestamp = summary_timestamp(summary_path, args.timestamp)
        row = history_row_from_summary(summary, timestamp)
        paths = record_summary(summary=summary, root_dir=args.root_dir, timestamp=timestamp)
        print(
            f"recorded scenario={row['scenario']} timestamp={timestamp} "
            f"launch_median_ms={row['launch_to_first_prompt_median_ms'] or 'n/a'}"
        )
    print(f"history_csv={paths['history_csv']}")
    print(f"dashboard_md={paths['dashboard_md']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
