#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for the local Factory dashboard.

Loads scripts/factory-dashboard.py via importlib and exercises it against an
injectable fake `gh` fetcher (no network): cost aggregation math, stage-latency
computation, idempotent re-sync, cursor advancement, and the graceful
no-cost-rows render.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "factory-dashboard.py"


def load_module():
    spec = importlib.util.spec_from_file_location("factory_dashboard", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["factory_dashboard"] = module
    spec.loader.exec_module(module)
    return module


dashboard = load_module()

NOW = datetime(2026, 7, 18, 12, 0, 0, tzinfo=UTC)


def iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


class FakeFetcher:
    """Fixed-response gh boundary; records call counts for no-op assertions."""

    def __init__(self) -> None:
        t0 = NOW - timedelta(days=2)
        # Runs grouped by workflow id, without workflow_name — sync stamps the
        # true name from the id→name mapping (mirrors the real fetcher, whose
        # run `.name` is a customized title, not the workflow name).
        self.workflows = {"Factory Implement": 100, "Factory Review Executor": 101}
        self.runs_by_workflow = {
            100: [
                {
                    "run_id": 1, "event": "issues", "head_branch": "main",
                    "status": "completed", "conclusion": "success", "run_attempt": 1,
                    "display_title": "Factory Implement claimed #100", "url": "u1",
                    "created_at": iso(t0), "updated_at": iso(t0),
                },
                {
                    "run_id": 2, "event": "issues", "head_branch": "main",
                    "status": "completed", "conclusion": "failure", "run_attempt": 1,
                    "display_title": "Factory Implement claimed #101", "url": "u2",
                    "created_at": iso(t0 + timedelta(hours=1)),
                    "updated_at": iso(t0 + timedelta(hours=1)),
                },
            ],
            101: [
                {
                    "run_id": 3, "event": "pull_request", "head_branch": "pr",
                    "status": "completed", "conclusion": "success", "run_attempt": 1,
                    "display_title": "Factory Review Executor #200", "url": "u3",
                    "created_at": iso(NOW - timedelta(days=1)),
                    "updated_at": iso(NOW - timedelta(days=1)),
                },
            ],
        }
        self.jobs = {
            1: [{"job_id": 11, "run_id": 1, "name": "implement", "conclusion": "success",
                 "status": "completed", "started_at": iso(t0), "completed_at": iso(t0)}],
            2: [{"job_id": 21, "run_id": 2, "name": "implement", "conclusion": "failure",
                 "status": "completed", "started_at": iso(t0), "completed_at": iso(t0)}],
            3: [{"job_id": 31, "run_id": 3, "name": "review", "conclusion": "success",
                 "status": "completed", "started_at": iso(t0), "completed_at": iso(t0)}],
        }
        self.issues = [
            {
                "number": 100, "title": "Do a thing", "state": "CLOSED",
                "labels": ["idea", "review"], "created_at": iso(t0 - timedelta(days=1)),
                "closed_at": iso(NOW - timedelta(days=1)), "updated_at": iso(NOW - timedelta(days=1)),
            }
        ]
        self.events = {
            100: [
                {"id": 1, "event": "labeled", "label": "ready", "actor": "owner",
                 "created_at": iso(t0)},
                {"id": 2, "event": "labeled", "label": "claimed", "actor": "owner",
                 "created_at": iso(t0 + timedelta(hours=1))},
                {"id": 3, "event": "labeled", "label": "review", "actor": "bot",
                 "created_at": iso(t0 + timedelta(hours=3))},
                {"id": 4, "event": "labeled", "label": "mergeable", "actor": "bot",
                 "created_at": iso(t0 + timedelta(hours=4))},
            ]
        }
        self.prs = [
            {
                "number": 200, "title": "Implement thing", "state": "MERGED",
                "labels": ["author:april"], "closing_issues": [100],
                "created_at": iso(t0), "merged_at": iso(NOW - timedelta(days=1)),
                "updated_at": iso(NOW - timedelta(days=1)),
            }
        ]
        self.reviews = {
            200: [{"id": 501, "state": "APPROVED", "author": "plat", "submitted_at": iso(t0)}]
        }
        self.cost_text = "\n".join(
            [
                '{"id":"1-0-implement","ts":"%s","phase":"implement","issue":100,"pr":200,'
                '"cost_usd":0.5,"input_tokens":1000,"output_tokens":500}' % iso(NOW - timedelta(days=2)),
                '{"id":"2-0-review","ts":"%s","phase":"review","issue":100,"pr":200,'
                '"cost_usd":1.5,"input_tokens":2000,"output_tokens":800}' % iso(NOW - timedelta(days=1)),
            ]
        )
        self.calls: dict[str, int] = {}

        self.ops_head = "head-sha-1"

    def _tick(self, name: str) -> None:
        self.calls[name] = self.calls.get(name, 0) + 1

    @staticmethod
    def _after(items, field, since_date):
        # Mirror the API `created=>=`/`updated:>=` date-granular inclusive filter
        # so cursor/backfill tests exercise real narrowing.
        return [x for x in items if (x.get(field) or "")[:10] >= since_date]

    def workflow_ids(self):
        self._tick("workflow_ids")
        return dict(self.workflows)

    def runs_for_workflow(self, workflow_id, since_date):
        self._tick("runs_for_workflow")
        runs = [dict(run) for run in self.runs_by_workflow.get(workflow_id, [])]
        return self._after(runs, "created_at", since_date)

    def jobs_for_run(self, run_id):
        self._tick("jobs_for_run")
        return list(self.jobs.get(run_id, []))

    def issues_since(self, since_date):
        self._tick("issues_since")
        return self._after([dict(i) for i in self.issues], "updated_at", since_date)

    def label_events(self, issue_number):
        self._tick("label_events")
        return list(self.events.get(issue_number, []))

    def prs_since(self, since_date):
        self._tick("prs_since")
        return self._after([dict(p) for p in self.prs], "updated_at", since_date)

    def pr_reviews(self, pr_number):
        self._tick("pr_reviews")
        return list(self.reviews.get(pr_number, []))

    def ops_branch_head(self):
        self._tick("ops_branch_head")
        return self.ops_head

    def ops_file(self, path):
        self._tick("ops_file")
        return self.cost_text

    def repo_variables(self):
        self._tick("repo_variables")
        return {"FACTORY_IMPLEMENT_DAILY_CAP": "6", "FACTORY_REVIEW_DAILY_CAP": "12"}


def table_counts(conn) -> dict[str, int]:
    tables = ["workflow_runs", "jobs", "issues", "label_events", "prs", "reviews", "cost_rows"]
    return {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in tables}


class CostMathTests(unittest.TestCase):
    def test_cost_per_merged_pr_and_efficiency(self) -> None:
        rows = [{"cost_usd": 0.5, "input_tokens": 1000, "output_tokens": 500},
                {"cost_usd": 1.5, "input_tokens": 2000, "output_tokens": 800}]
        agg = dashboard.aggregate_cost(rows, merged_pr_count=2)
        self.assertAlmostEqual(agg["total_cost_usd"], 2.0)
        self.assertAlmostEqual(agg["cost_per_merged_pr"], 1.0)
        self.assertAlmostEqual(agg["prs_per_dollar"], 1.0)
        self.assertEqual(agg["total_input_tokens"], 3000)

    def test_cost_per_merged_pr_none_without_ships(self) -> None:
        agg = dashboard.aggregate_cost([{"cost_usd": 1.0}], merged_pr_count=0)
        self.assertIsNone(agg["cost_per_merged_pr"])

    def test_rolling_efficiency_cumulative(self) -> None:
        rows = [
            {"cost_usd": 0.5, "ts": iso(NOW - timedelta(days=2))},
            {"cost_usd": 1.5, "ts": iso(NOW - timedelta(days=1))},
        ]
        merged = [
            {"merged_at": iso(NOW - timedelta(days=2))},
            {"merged_at": iso(NOW - timedelta(days=1))},
        ]
        series = dashboard.rolling_efficiency(rows, merged, days=30, now=NOW)
        self.assertEqual(len(series), 2)
        self.assertAlmostEqual(series[0]["prs_per_dollar"], 2.0)   # 1 ship / $0.5
        self.assertAlmostEqual(series[-1]["prs_per_dollar"], 1.0)  # 2 ships / $2.0


class StageLatencyTests(unittest.TestCase):
    def test_medians_between_label_transitions(self) -> None:
        events = [{**e, "issue_number": 100} for e in FakeFetcher().events[100]]
        result = dashboard.stage_latencies(events)
        stages = {s["name"]: s for s in result["stages"]}
        self.assertAlmostEqual(stages["ready → claimed"]["median_hours"], 1.0)
        self.assertAlmostEqual(stages["claimed → review"]["median_hours"], 2.0)
        self.assertAlmostEqual(stages["review → mergeable"]["median_hours"], 1.0)
        self.assertEqual(stages["ready → claimed"]["count"], 1)

    def test_redispatch_uses_the_second_full_lifecycle(self) -> None:
        # A complete first cycle (1h/2h/1h), then a re-dispatch and a full second
        # cycle (1h/3h/2h). Latencies must come from the second cycle alone, not a
        # mix of the abandoned first attempt and its retry.
        base = NOW - timedelta(hours=40)

        def ev(seq, label, hours):
            return {"issue_number": 7, "id": seq, "event": "labeled", "label": label,
                    "actor": "o", "created_at": iso(base + timedelta(hours=hours))}

        events = [
            ev(1, "ready", 0), ev(2, "claimed", 1), ev(3, "review", 3), ev(4, "mergeable", 4),
            ev(5, "ready", 10), ev(6, "claimed", 11), ev(7, "review", 14), ev(8, "mergeable", 16),
        ]
        stages = {s["name"]: s for s in dashboard.stage_latencies(events)["stages"]}
        self.assertAlmostEqual(stages["ready → claimed"]["median_hours"], 1.0)
        self.assertAlmostEqual(stages["claimed → review"]["median_hours"], 3.0)
        self.assertAlmostEqual(stages["review → mergeable"]["median_hours"], 2.0)


class SyncTests(unittest.TestCase):
    def test_sync_is_idempotent_and_advances_cursors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "cache.sqlite3"
            conn = dashboard.connect(db)
            fake = FakeFetcher()

            dashboard.sync_all(conn, fake, days=30)
            first = table_counts(conn)
            self.assertEqual(first["workflow_runs"], 3)
            self.assertEqual(first["jobs"], 3)
            self.assertEqual(first["label_events"], 4)
            self.assertEqual(first["prs"], 1)
            self.assertEqual(first["reviews"], 1)
            self.assertEqual(first["cost_rows"], 2)

            all_runs = [r for runs in fake.runs_by_workflow.values() for r in runs]
            runs_cursor = dashboard.get_cursor(conn, "workflow_runs")
            self.assertEqual(runs_cursor, max(r["created_at"] for r in all_runs))
            self.assertEqual(dashboard.get_cursor(conn, "prs"), fake.prs[0]["updated_at"])

            dashboard.sync_all(conn, fake, days=30)
            self.assertEqual(table_counts(conn), first, "re-sync must not duplicate rows")
            conn.close()

    def test_metrics_reflect_synced_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")
            dashboard.sync_all(conn, FakeFetcher(), days=30)
            metrics = dashboard.build_metrics(conn, days=30, now=NOW)
            self.assertEqual(metrics["throughput"]["agent_prs_merged"], 1)
            self.assertEqual(metrics["cost"]["row_count"], 2)
            self.assertAlmostEqual(metrics["cost"]["total_cost_usd"], 2.0)
            self.assertEqual(metrics["review_verdicts"]["approved"], 1)
            self.assertEqual(metrics["failures"]["rollback_count"], 1)
            html = dashboard.render_html(metrics)
            self.assertIn("Factory Operations", html)
            self.assertNotIn(dashboard.COST_PLACEHOLDER, html)
            conn.close()


class RenderTests(unittest.TestCase):
    def test_no_cost_rows_renders_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")
            metrics = dashboard.build_metrics(conn, days=30, now=NOW)
            html = dashboard.render_html(metrics)
            self.assertIn(dashboard.COST_PLACEHOLDER, html)
            conn.close()

    def test_render_only_exits_zero_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "cache.sqlite3"
            out = Path(tmp) / "index.html"
            code = dashboard.main(["--render", "--db", str(db), "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertTrue(out.is_file())
            self.assertIn(dashboard.COST_PLACEHOLDER, out.read_text(encoding="utf-8"))

    def test_stale_banner_when_last_sync_failed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")
            dashboard.meta_set(conn, "last_sync_ok", "0")
            dashboard.meta_set(conn, "last_sync_error", "runs: offline")
            metrics = dashboard.build_metrics(conn, days=30, now=NOW)
            html = dashboard.render_html(metrics)
            self.assertIn("Rendered from cache", html)
            conn.close()


class CursorTests(unittest.TestCase):
    def test_widening_days_backfills_via_min_cursor_floor(self) -> None:
        # A narrow first window fetches only the most recent rows; widening the
        # window must backfill older rows the cursor sits ahead of.
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")
            fake = FakeFetcher()

            dashboard.sync_all(conn, fake, days=1)
            narrow = conn.execute("SELECT COUNT(*) FROM workflow_runs").fetchone()[0]
            self.assertEqual(narrow, 1, "days=1 excludes the two runs from 2 days ago")

            dashboard.sync_all(conn, fake, days=30)
            wide = conn.execute("SELECT COUNT(*) FROM workflow_runs").fetchone()[0]
            self.assertEqual(wide, 3, "widening --days backfills the older runs")
            conn.close()

    def test_partial_failure_isolates_and_leaves_cursor_unmoved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")

            class Boom(FakeFetcher):
                def prs_since(self, since_date):
                    raise ValueError("rate limited")  # non-FetchError

            stats = dashboard.sync_all(conn, Boom(), days=30)
            self.assertTrue(any("prs" in e for e in stats["errors"]))
            # Other sources still synced despite the PR-source failure.
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM workflow_runs").fetchone()[0], 3)
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM prs").fetchone()[0], 0)
            self.assertIsNone(dashboard.get_cursor(conn, "prs"))

            metrics = dashboard.build_metrics(conn, days=30, now=NOW)
            self.assertFalse(metrics["last_sync_ok"])
            self.assertIn("Rendered from cache", dashboard.render_html(metrics))
            conn.close()

    def test_settings_failure_degrades_like_a_source(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conn = dashboard.connect(Path(tmp) / "cache.sqlite3")

            class NoVars(FakeFetcher):
                def repo_variables(self):
                    raise dashboard.FetchError("variables unreadable")

            stats = dashboard.sync_all(conn, NoVars(), days=30)
            self.assertTrue(any("settings" in e for e in stats["errors"]))
            self.assertEqual(dashboard.meta_get(conn, "last_sync_ok"), "0")
            conn.close()


class CapUtilizationTests(unittest.TestCase):
    def test_window_beyond_14_days_is_not_truncated(self) -> None:
        runs = [
            {"run_id": 1, "run_attempt": 1, "workflow_name": "Factory Implement",
             "status": "completed", "conclusion": "success",
             "created_at": iso(NOW - timedelta(days=20))},
        ]
        caps = dashboard.cap_utilization(
            runs, cap_implement=6, cap_review=12, days=30, now=NOW
        )
        series = caps["implement"]["series"]
        self.assertEqual(len(series), 31)  # floor..today inclusive over 30 days
        day20 = (NOW - timedelta(days=20)).date().isoformat()
        self.assertEqual(next(p["count"] for p in series if p["date"] == day20), 1)


class BoundaryEfficiencyTests(unittest.TestCase):
    def test_first_partial_day_is_kept(self) -> None:
        # A ship+spend earlier in the day than the exact floor time must still
        # land in the series (date-to-date comparison, not exact-time).
        floor_day = (NOW - timedelta(days=2))
        early = floor_day.replace(hour=6, minute=0)
        series = dashboard.rolling_efficiency(
            [{"cost_usd": 1.0, "ts": iso(early)}],
            [{"merged_at": iso(early)}],
            days=2,
            now=NOW,
        )
        self.assertEqual([p["date"] for p in series], [floor_day.date().isoformat()])


if __name__ == "__main__":
    unittest.main()
