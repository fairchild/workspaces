#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the weekly engineering summary generator."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "weekly-engineering-summary.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


weekly_summary = load_module("weekly_engineering_summary", SCRIPT_PATH)


class WeeklyEngineeringSummaryTests(unittest.TestCase):
    def test_parse_last_window_end_prefers_reviewed_window_over_later_run_notes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            memory_path = Path(directory) / "memory.md"
            memory_path.write_text(
                "\n".join(
                    [
                        "## Previous run",
                        "- Run time (UTC): 2026-05-29T23:02:03Z",
                        "- Window reviewed: 2026-05-22T23:00:50Z to 2026-05-29T23:02:03Z",
                        "## Automation hardening",
                        "- Run time (UTC): 2026-05-30T21:45:42Z",
                    ]
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                weekly_summary.parse_last_window_end(memory_path),
                datetime(2026, 5, 29, 23, 2, 3, tzinfo=UTC),
            )

    def test_parse_release_rows_filters_releases_to_window(self) -> None:
        releases = weekly_summary.parse_release_rows(
            [
                "WorkSpaces v0.16.0\tLatest\tv0.16.0\t2026-05-26T14:55:05Z",
                "WorkSpaces v0.15.1\t\tv0.15.1\t2026-05-19T15:14:36Z",
            ]
        )
        since = datetime(2026, 5, 22, tzinfo=UTC)
        now = datetime(2026, 5, 30, tzinfo=UTC)

        in_window = [
            release["tag"]
            for release in releases
            if weekly_summary.release_in_window(release, since, now)
        ]

        self.assertEqual(in_window, ["v0.16.0"])

    def test_confirmed_incident_requires_prod_regression_or_operational_label(self) -> None:
        self.assertTrue(
            weekly_summary.is_confirmed_incident(
                {
                    "title": "Prod regression on abc123",
                    "labels": [{"name": "auto-opened"}],
                }
            )
        )
        self.assertTrue(
            weekly_summary.is_confirmed_incident(
                {
                    "title": "Release workflow failed",
                    "labels": [{"name": "cd-failure:prod"}],
                }
            )
        )
        self.assertFalse(
            weekly_summary.is_confirmed_incident(
                {
                    "title": "Web dashboard regression test harness",
                    "labels": [{"name": "quality"}],
                }
            )
        )

    def test_emit_markdown_reports_in_window_release_and_broad_query_match_separately(self) -> None:
        since = datetime(2026, 5, 22, tzinfo=UTC)
        now = datetime(2026, 5, 30, tzinfo=UTC)
        summary = weekly_summary.RepoSummary(
            repo="fairchild/workspaces",
            prs=[
                {
                    "number": 577,
                    "title": "release: v0.16.0",
                    "mergedAt": "2026-05-26T14:44:29Z",
                    "url": "https://github.com/fairchild/workspaces/pull/577",
                }
            ],
            releases=[
                {
                    "title": "WorkSpaces v0.16.0",
                    "tag": "v0.16.0",
                    "createdAt": "2026-05-26T14:55:05Z",
                    "raw": "",
                }
            ],
            releases_in_window=[
                {
                    "title": "WorkSpaces v0.16.0",
                    "tag": "v0.16.0",
                    "createdAt": "2026-05-26T14:55:05Z",
                    "raw": "",
                }
            ],
            confirmed_incidents=[],
            incident_query_matches=[
                {
                    "number": 536,
                    "title": "Web dashboard regression test harness",
                    "url": "https://github.com/fairchild/workspaces/issues/536",
                    "state": "OPEN",
                    "createdAt": "2026-05-25T22:01:10Z",
                    "closedAt": None,
                    "labels": [{"name": "quality"}],
                }
            ],
            review_counts={"APPROVED": 2},
            prs_with_reviews=1,
            previous_pr_count=0,
        )

        markdown = weekly_summary.emit_markdown(since, now, [summary])

        self.assertIn("`WorkSpaces v0.16.0` (`v0.16.0`, 2026-05-26T14:55:05Z)", markdown)
        self.assertIn("No confirmed incident matches", markdown)
        self.assertIn("broad incident-query matches not classified", markdown)
        self.assertIn("APPROVED=2", markdown)


if __name__ == "__main__":
    unittest.main()
