#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the ops reporting script.

Intent: protect the live-ops report generator using checked-in fixtures so
cooldown, breach selection, and report rendering behavior can be validated
without writing real ops snapshots or mutating GitHub state.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES_DIR = REPO_ROOT / "fixtures" / "ops-report"
SCRIPT_PATH = REPO_ROOT / "scripts" / "ops-report.py"
sys.path.insert(0, str(REPO_ROOT / "scripts"))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ops_report = load_module("ops_report", SCRIPT_PATH)


class OpsReportTests(unittest.TestCase):
    maxDiff = None

    def fixture_path(self, name: str) -> Path:
        return FIXTURES_DIR / name

    def load_fixture_report(
        self,
        name: str,
        *,
        current_time: datetime | None = None,
    ) -> tuple[ops_report.ReportInputs, list[dict[str, str]], dict[str, object]]:
        current_time = current_time or datetime(2026, 3, 12, tzinfo=UTC)
        inputs = ops_report.load_fixture_inputs(self.fixture_path(name))
        rows, summary = ops_report.build_report(inputs, current_time=current_time, days=30)
        return inputs, rows, summary

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
            perf = ops_report.load_perf_summary(
                datetime(2026, 3, 12, tzinfo=UTC),
                latest_path=latest_path,
                history_path=history_path,
            )

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

    def test_validate_args_rejects_invalid_fixture_combinations(self) -> None:
        args = argparse.Namespace(
            record=True,
            days=30,
            output_dir=None,
            open_idea_on_breach=False,
            dry_run=False,
            fixtures_dir=Path("fixtures/ops-report/clean"),
        )
        with self.assertRaisesRegex(ops_report.OpsReportError, "cannot be combined with --record"):
            ops_report.validate_args(args)

        args = argparse.Namespace(
            record=False,
            days=30,
            output_dir=None,
            open_idea_on_breach=True,
            dry_run=False,
            fixtures_dir=Path("fixtures/ops-report/clean"),
        )
        with self.assertRaisesRegex(ops_report.OpsReportError, "requires --dry-run"):
            ops_report.validate_args(args)

    def test_load_fixture_inputs_missing_file_raises(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "repo.json").write_text('{"owner":"fairchild","name":"workspaces"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ops_report.OpsReportError, "missing required files"):
                ops_report.load_fixture_inputs(root)

    def test_load_inputs_uses_fixture_without_gh_calls(self) -> None:
        args = argparse.Namespace(
            record=False,
            days=30,
            output_dir=None,
            open_idea_on_breach=False,
            dry_run=False,
            fixtures_dir=self.fixture_path("clean"),
        )
        with mock.patch.object(ops_report, "run_checked", side_effect=AssertionError("run_checked called")):
            with mock.patch.object(ops_report, "graphql", side_effect=AssertionError("graphql called")):
                inputs = ops_report.load_inputs(args, {})

        self.assertEqual(inputs.source_mode, "fixture")
        self.assertEqual(inputs.fixture_name, "clean")

    def test_fixture_report_includes_source_metadata_and_dashboard_label(self) -> None:
        _, rows, summary = self.load_fixture_report("clean")
        dashboard = ops_report.render_dashboard(rows, summary)
        self.assertEqual(summary["source_mode"], "fixture")
        self.assertEqual(summary["fixture_name"], "clean")
        self.assertIn("Source: `fixture:clean`", dashboard)

    def test_fixture_scenarios_produce_expected_preview_states(self) -> None:
        expected = {
            "clean": (None, "no breach candidate"),
            "perf-breach": ("[idea] [ops] Investigate performance regression", None),
            "ci-breach": ("[idea] [ops] Stabilize GitHub Actions reliability", None),
            "throughput-breach": ("[idea] [ops] Unblock planned work from execution", None),
            "deduped": (
                "[idea] [ops] Stabilize GitHub Actions reliability",
                "matching open ops discussion already exists",
            ),
            "cooldown": (
                "[idea] [ops] Stabilize GitHub Actions reliability",
                "matching ops discussion closed within the 30-day cooldown",
            ),
        }
        current_time = datetime(2026, 3, 12, tzinfo=UTC)
        for fixture_name, (expected_title, expected_reason) in expected.items():
            with self.subTest(fixture=fixture_name):
                inputs, _, summary = self.load_fixture_report(fixture_name, current_time=current_time)
                idea = ops_report.candidate_idea_from_breaches(summary)
                skip_reason = ops_report.should_skip_idea(idea, inputs.discussions, current_time)
                actual_title = idea["title"] if idea is not None else None
                self.assertEqual(actual_title, expected_title)
                self.assertEqual(skip_reason, expected_reason)

    def test_cli_smoke_fixture_preview_writes_artifacts_without_system_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "out"
            env = os.environ.copy()
            env["PATH"] = ""
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--fixtures-dir",
                    str(self.fixture_path("clean")),
                    "--output-dir",
                    str(output_dir),
                    "--dry-run",
                    "--open-idea-on-breach",
                ],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("output_dir=", result.stdout)
            self.assertIn('"would_open_discussion": null', result.stdout)
            self.assertTrue((output_dir / "timeline.csv").is_file())
            self.assertTrue((output_dir / "latest-summary.json").is_file())
            self.assertTrue((output_dir / "dashboard.md").is_file())


class AgentHealthTests(unittest.TestCase):
    maxDiff = None

    def fixture_path(self, name: str) -> Path:
        return FIXTURES_DIR / name

    def load_fixture_report(
        self,
        name: str,
        *,
        current_time: datetime | None = None,
    ) -> tuple[ops_report.ReportInputs, list[dict[str, str]], dict[str, object]]:
        current_time = current_time or datetime(2026, 3, 12, tzinfo=UTC)
        inputs = ops_report.load_fixture_inputs(self.fixture_path(name))
        rows, summary = ops_report.build_report(inputs, current_time=current_time, days=30)
        return inputs, rows, summary

    def test_summarize_ci_per_agent_breakdown(self) -> None:
        runs = [
            {"status": "completed", "conclusion": "failure", "createdAt": "2026-03-11T10:00:00Z", "attempt": 1, "workflowName": "Agent: April Clearwater"},
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T11:00:00Z", "attempt": 1, "workflowName": "Agent: April Clearwater"},
            {"status": "completed", "conclusion": "failure", "createdAt": "2026-03-11T12:00:00Z", "attempt": 2, "workflowName": "Agent: April Clearwater"},
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T13:00:00Z", "attempt": 1, "workflowName": "Agent: Peter Planner"},
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T14:00:00Z", "attempt": 1, "workflowName": "CI"},
        ]
        ci = ops_report.summarize_ci(runs, 30, datetime(2026, 3, 12, tzinfo=UTC))
        self.assertIn("agents", ci)
        agents = ci["agents"]
        self.assertIn("April Clearwater", agents)
        self.assertIn("Peter Planner", agents)
        april = agents["April Clearwater"]
        self.assertEqual(april["completed_runs"], 3)
        self.assertEqual(april["failure_runs"], 2)
        self.assertAlmostEqual(april["failure_rate"], 66.666, places=2)
        self.assertEqual(april["rerun_runs"], 1)
        self.assertAlmostEqual(april["rerun_rate"], 33.333, places=2)
        peter = agents["Peter Planner"]
        self.assertEqual(peter["completed_runs"], 1)
        self.assertEqual(peter["failure_runs"], 0)
        self.assertAlmostEqual(peter["failure_rate"], 0.0)

    def test_excludes_non_agent_workflows(self) -> None:
        runs = [
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T10:00:00Z", "attempt": 1, "workflowName": "CI"},
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T11:00:00Z", "attempt": 1, "workflowName": "Release"},
            {"status": "completed", "conclusion": "success", "createdAt": "2026-03-11T12:00:00Z", "attempt": 1, "workflowName": "Agent: Observer"},
        ]
        ci = ops_report.summarize_ci(runs, 30, datetime(2026, 3, 12, tzinfo=UTC))
        agents = ci["agents"]
        self.assertNotIn("CI", agents)
        self.assertNotIn("Release", agents)
        self.assertIn("Observer", agents)

    def test_detect_breaches_agent_breach(self) -> None:
        ci = {
            "completed_runs": 20,
            "failure_rate": 15.0,
            "rerun_rate": 5.0,
            "top_failing_workflows": [],
            "agents": {
                "April Clearwater": {
                    "completed_runs": 10,
                    "failure_runs": 4,
                    "failure_rate": 40.0,
                    "rerun_runs": 0,
                    "rerun_rate": 0.0,
                },
            },
        }
        perf = {"available": False, "metrics": {}}
        breaches = ops_report.detect_breaches(perf, ci, [])
        categories = [b["category"] for b in breaches]
        self.assertIn("agent", categories)
        agent_breach = next(b for b in breaches if b["category"] == "agent")
        self.assertEqual(agent_breach["title"], "[idea] [ops] Stabilize individual agent reliability")
        self.assertEqual(agent_breach["details"][0]["agent"], "April Clearwater")

    def test_no_agent_breach_below_threshold(self) -> None:
        ci_low_runs = {
            "completed_runs": 10,
            "failure_rate": 10.0,
            "rerun_rate": 5.0,
            "top_failing_workflows": [],
            "agents": {
                "April Clearwater": {
                    "completed_runs": 4,
                    "failure_runs": 3,
                    "failure_rate": 75.0,
                    "rerun_runs": 0,
                    "rerun_rate": 0.0,
                },
            },
        }
        perf = {"available": False, "metrics": {}}
        breaches = ops_report.detect_breaches(perf, ci_low_runs, [])
        self.assertNotIn("agent", [b["category"] for b in breaches])

        ci_low_rate = {
            "completed_runs": 10,
            "failure_rate": 10.0,
            "rerun_rate": 5.0,
            "top_failing_workflows": [],
            "agents": {
                "April Clearwater": {
                    "completed_runs": 10,
                    "failure_runs": 1,
                    "failure_rate": 10.0,
                    "rerun_runs": 0,
                    "rerun_rate": 0.0,
                },
            },
        }
        breaches = ops_report.detect_breaches(perf, ci_low_rate, [])
        self.assertNotIn("agent", [b["category"] for b in breaches])

    def test_breach_ordering(self) -> None:
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
            "top_failing_workflows": [{"workflow_name": "CI", "failures": 6}],
            "agents": {
                "April Clearwater": {
                    "completed_runs": 5,
                    "failure_runs": 3,
                    "failure_rate": 60.0,
                    "rerun_runs": 0,
                    "rerun_rate": 0.0,
                },
            },
        }
        stale = [
            {"discussion_number": 43, "discussion_title": "One"},
            {"discussion_number": 44, "discussion_title": "Two"},
        ]
        breaches = ops_report.detect_breaches(perf, ci, stale)
        categories = [b["category"] for b in breaches]
        self.assertEqual(categories, ["perf", "ci", "agent", "throughput"])

    def test_dashboard_agent_health_table(self) -> None:
        _, _, summary = self.load_fixture_report("agent-breach")
        dashboard = ops_report.render_dashboard([], summary)
        self.assertIn("## Agent Health", dashboard)
        self.assertIn("| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |", dashboard)
        self.assertIn("April Clearwater", dashboard)
        self.assertIn("Peter Planner", dashboard)

    def test_fixture_agent_breach_scenario(self) -> None:
        current_time = datetime(2026, 3, 12, tzinfo=UTC)
        inputs, _, summary = self.load_fixture_report("agent-breach", current_time=current_time)
        breaches = summary["breaches"]
        categories = [b["category"] for b in breaches]
        self.assertIn("agent", categories)
        self.assertNotIn("ci", categories)
        idea = ops_report.candidate_idea_from_breaches(summary)
        self.assertIsNotNone(idea)
        self.assertEqual(idea["title"], "[idea] [ops] Stabilize individual agent reliability")
        skip_reason = ops_report.should_skip_idea(idea, inputs.discussions, current_time)
        self.assertIsNone(skip_reason)


if __name__ == "__main__":
    unittest.main()
