#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for the ops reporting script."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ops_report = load_module("ops_report", REPO_ROOT / "scripts" / "ops-report.py")


class OpsReportTests(unittest.TestCase):
    def test_select_approval_timestamp_uses_owner_keyword(self) -> None:
        comments = [
            {
                "body": "looks interesting",
                "createdAt": "2026-03-01T12:00:00Z",
                "author": {"login": "fairchild"},
            },
            {
                "body": "plan it",
                "createdAt": "2026-03-02T12:00:00Z",
                "author": {"login": "fairchild"},
            },
            {
                "body": "approved",
                "createdAt": "2026-03-03T12:00:00Z",
                "author": {"login": "someone-else"},
            },
        ]
        self.assertEqual(
            ops_report.select_approval_timestamp(comments, "fairchild"),
            "2026-03-02T12:00:00Z",
        )

    def test_extract_summary_issue_numbers_requires_planned_marker(self) -> None:
        body = "\n".join(
            [
                "<!-- peter-planner:discussion=43;status=planned -->",
                "",
                "- #61 — First",
                "- #62 — Second",
            ]
        )
        self.assertEqual(ops_report.extract_summary_issue_numbers(body, 43), [61, 62])
        self.assertEqual(ops_report.extract_summary_issue_numbers(body, 99), [])

    def test_build_timeline_rows_links_issues_and_prs(self) -> None:
        discussions = [
            {
                "number": 43,
                "title": "[idea][endorsed] Example",
                "url": "https://example.test/discussions/43",
                "createdAt": "2026-03-01T10:00:00Z",
                "updatedAt": "2026-03-10T10:00:00Z",
                "comments": {
                    "nodes": [
                        {
                            "body": "plan it",
                            "createdAt": "2026-03-02T10:00:00Z",
                            "author": {"login": "fairchild"},
                        },
                        {
                            "body": "\n".join(
                                [
                                    "<!-- peter-planner:discussion=43;status=planned -->",
                                    "",
                                    "- #61 — First issue",
                                    "- #62 — Second issue",
                                ]
                            ),
                            "createdAt": "2026-03-03T10:00:00Z",
                            "author": {"login": "github-actions"},
                        },
                    ]
                },
            }
        ]
        issues = [
            {
                "number": 61,
                "body": "<!-- peter-planner:discussion=43;issue=first-issue -->",
                "state": "OPEN",
                "updatedAt": "2026-03-05T10:00:00Z",
                "milestone": {"number": 4, "title": "Milestone"},
            },
            {
                "number": 62,
                "body": "<!-- peter-planner:discussion=43;issue=second-issue -->",
                "state": "CLOSED",
                "updatedAt": "2026-03-08T10:00:00Z",
                "milestone": {"number": 4, "title": "Milestone"},
            },
        ]
        prs = [
            {
                "number": 71,
                "state": "OPEN",
                "createdAt": "2026-03-06T10:00:00Z",
                "updatedAt": "2026-03-09T10:00:00Z",
                "mergedAt": None,
                "closingIssuesReferences": [{"number": 61}],
            },
            {
                "number": 72,
                "state": "MERGED",
                "createdAt": "2026-03-04T10:00:00Z",
                "updatedAt": "2026-03-07T10:00:00Z",
                "mergedAt": "2026-03-07T12:00:00Z",
                "closingIssuesReferences": [{"number": 62}],
            },
        ]

        rows = ops_report.build_timeline_rows(
            discussions,
            issues,
            prs,
            "fairchild",
            datetime(2026, 3, 12, tzinfo=UTC),
        )

        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["approved_at"], "2026-03-02T10:00:00Z")
        self.assertEqual(row["planned_at"], "2026-03-03T10:00:00Z")
        self.assertEqual(row["issue_numbers"], "61,62")
        self.assertEqual(row["pr_numbers"], "71,72")
        self.assertEqual(row["milestone_number"], "4")
        self.assertEqual(row["status"], "merged")

    def test_derive_status_marks_stalled_after_fourteen_days(self) -> None:
        status = ops_report.derive_status(
            approved_at="2026-03-01T00:00:00Z",
            planned_at="2026-03-01T00:00:00Z",
            open_pr_count=0,
            merged_pr_count=0,
            latest_activity_at="2026-03-01T00:00:00Z",
            current_time=datetime(2026, 3, 20, tzinfo=UTC),
        )
        self.assertEqual(status, "stalled")

    def test_summarize_ci_computes_failure_and_rerun_rates(self) -> None:
        runs = [
            {
                "status": "completed",
                "conclusion": "success",
                "createdAt": "2026-03-11T10:00:00Z",
                "attempt": 1,
                "workflowName": "Tests",
            },
            {
                "status": "completed",
                "conclusion": "failure",
                "createdAt": "2026-03-11T11:00:00Z",
                "attempt": 2,
                "workflowName": "Tests",
            },
            {
                "status": "completed",
                "conclusion": "failure",
                "createdAt": "2026-03-11T12:00:00Z",
                "attempt": 1,
                "workflowName": "Build",
            },
        ]

        ci = ops_report.summarize_ci(runs, 30, datetime(2026, 3, 12, tzinfo=UTC))
        self.assertEqual(ci["completed_runs"], 3)
        self.assertAlmostEqual(ci["failure_rate"], 66.6666666, places=3)
        self.assertAlmostEqual(ci["rerun_rate"], 33.3333333, places=3)
        self.assertEqual(ci["top_failing_workflows"][0]["workflow_name"], "Tests")

    def test_detect_breaches_orders_by_severity(self) -> None:
        perf = {
            "available": True,
            "metrics": {
                "launch_to_first_prompt": {
                    "status": "fail",
                    "latest_median_ms": 300.0,
                    "target_ms": 250.0,
                    "delta_percent": 20.0,
                }
            },
        }
        ci = {
            "completed_runs": 20,
            "failure_rate": 30.0,
            "rerun_rate": 20.0,
            "top_failing_workflows": [{"workflow_name": "Tests", "failures": 4}],
        }
        stale = [
            {"discussion_number": 43, "discussion_title": "One"},
            {"discussion_number": 44, "discussion_title": "Two"},
        ]

        breaches = ops_report.detect_breaches(perf, ci, stale)
        self.assertEqual([breach["category"] for breach in breaches], ["perf", "ci", "throughput"])

    def test_load_perf_summary_reads_delta_and_freshness(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            latest_path = root / "latest-summary.json"
            history_path = root / "metrics-history.csv"
            latest_path.write_text(
                """{
  "launch_to_first_prompt": {"median": 180.0},
  "repo_hydration": {"median": 2.0},
  "repo_click_to_focus": {"median": 150.0},
  "metadata": {"timestamp": "2026-03-10T10:00:00Z"}
}
""",
                encoding="utf-8",
            )
            history_path.write_text(
                "\n".join(
                    [
                        "timestamp,launch_to_first_prompt_median_ms,repo_hydration_median_ms,repo_click_to_focus_median_ms",
                        "2026-03-01T10:00:00Z,150.0,1.0,140.0",
                        "2026-03-10T10:00:00Z,180.0,2.0,150.0",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            original_latest = ops_report.PERF_LATEST_PATH
            original_history = ops_report.PERF_HISTORY_PATH
            ops_report.PERF_LATEST_PATH = latest_path
            ops_report.PERF_HISTORY_PATH = history_path
            try:
                perf = ops_report.load_perf_summary(datetime(2026, 3, 12, tzinfo=UTC))
            finally:
                ops_report.PERF_LATEST_PATH = original_latest
                ops_report.PERF_HISTORY_PATH = original_history

        self.assertTrue(perf["available"])
        self.assertAlmostEqual(perf["freshness_days"], 1.5833333, places=3)
        self.assertAlmostEqual(
            perf["metrics"]["launch_to_first_prompt"]["delta_percent"],
            20.0,
            places=3,
        )

    def test_should_skip_idea_dedupes_open_discussions_and_cooldown(self) -> None:
        idea = {
            "category": "ci",
            "title": "[idea] [ops] Stabilize GitHub Actions reliability",
            "body": "Body",
        }
        open_discussions = [
            {
                "title": "[idea] [ops] Stabilize GitHub Actions reliability",
                "closed": False,
                "closedAt": None,
                "updatedAt": "2026-03-10T00:00:00Z",
            }
        ]
        self.assertEqual(
            ops_report.should_skip_idea(idea, open_discussions, datetime(2026, 3, 12, tzinfo=UTC)),
            "matching open ops discussion already exists",
        )

        closed_discussions = [
            {
                "title": "[idea] [ops] Stabilize GitHub Actions reliability",
                "closed": True,
                "closedAt": "2026-03-01T00:00:00Z",
                "updatedAt": "2026-03-01T00:00:00Z",
            }
        ]
        self.assertEqual(
            ops_report.should_skip_idea(idea, closed_discussions, datetime(2026, 3, 12, tzinfo=UTC)),
            "matching ops discussion closed within the 30-day cooldown",
        )

    def test_candidate_idea_from_breaches_returns_first_breach(self) -> None:
        summary = {
            "breaches": [
                {
                    "category": "perf",
                    "title": "[idea] [ops] Investigate performance regression",
                    "summary": "Performance targets regressed",
                    "details": [{"metric": "launch_to_first_prompt"}],
                    "suggested_direction": "Investigate.",
                }
            ]
        }
        idea = ops_report.candidate_idea_from_breaches(summary)
        self.assertIsNotNone(idea)
        self.assertEqual(idea["title"], "[idea] [ops] Investigate performance regression")


if __name__ == "__main__":
    unittest.main()
