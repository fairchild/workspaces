#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for perf history recording and channel scenario plumbing.

Pins the #1238 completeness guarantees: canonical summaries append to the
history CSV and dashboard, every contract scenario is dispatchable through
perf-runner.sh, and channel metrics gate honestly (absolute caps, missing
metrics fail).
"""

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import perf_channel_baseline
from perf_history import (
    HISTORY_FIELDNAMES,
    append_history_row,
    history_row_from_summary,
    record_summary,
    render_dashboard,
)
from perf_schema import load_contract


def debug_summary() -> dict:
    return {
        "scenario": "debug_no_activate",
        "metrics": {
            "launch_to_first_prompt": {"count": 3, "median": 600.0, "mean": 610.0, "unit": "ms"},
            "repo_hydration": {"count": 3, "median": 2.5, "mean": 2.6, "unit": "ms"},
        },
        "budget_results": {
            "launch_to_first_prompt": {"gate_budget_ms": 740, "status": "pass"},
            "repo_hydration": {"gate_budget_ms": 25, "status": "pass"},
        },
        "environment": {
            "build_kind": "debug",
            "os_version": "26.4",
            "os_build": "25E123",
            "arch": "arm64",
            "machine_model": "Mac16,13",
        },
        "metadata": {
            "build_kind": "debug",
            "runs_requested": 3,
            "sleep_seconds": 6,
            "os_version": "26.4",
            "os_build": "25E123",
            "arch": "arm64",
            "model": "Mac16,13",
            "discovered_repos_median": 26,
            "imported_repos_median": 0,
            "activation_to_first_prompt_median_ms": None,
        },
    }


def installed_summary() -> dict:
    return {
        "scenario": "installed_clean_shell",
        "metrics": {
            "launch_to_first_prompt": {"count": 1, "median": 288.2, "mean": 288.2, "unit": "ms"},
        },
        "budget_results": {
            "launch_to_first_prompt": {"gate_budget_ms": 800, "status": "pass"},
        },
        "environment": {
            "build_kind": "installed",
            "os_version": "26.4",
            "os_build": "25E123",
            "arch": "arm64",
            "machine_model": "Mac16,13",
        },
        "metadata": {"build_kind": "installed", "scenario": "installed_clean_shell"},
    }


class PerfHistoryTests(unittest.TestCase):
    def test_debug_summary_row_carries_all_columns(self) -> None:
        row = history_row_from_summary(debug_summary(), "2026-08-07T10:00:00-0700")
        self.assertEqual(row["scenario"], "debug_no_activate")
        self.assertEqual(row["build_kind"], "debug")
        self.assertEqual(row["launch_to_first_prompt_median_ms"], 600.0)
        self.assertEqual(row["repo_hydration_mean_ms"], 2.6)
        self.assertEqual(row["discovered_repos_median"], 26)
        self.assertEqual(row["workspace_click_to_focus_median_ms"], "")
        self.assertEqual(row["activation_to_first_prompt_median_ms"], "")

    def test_installed_summary_row_leaves_debug_only_columns_blank(self) -> None:
        row = history_row_from_summary(installed_summary(), "2026-08-07T10:00:00-0700")
        self.assertEqual(row["scenario"], "installed_clean_shell")
        self.assertEqual(row["build_kind"], "installed")
        self.assertEqual(row["launch_to_first_prompt_median_ms"], 288.2)
        self.assertEqual(row["runs_requested"], "")
        self.assertEqual(row["repo_hydration_median_ms"], "")

    def test_append_preserves_legacy_rows_without_scenario_column(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            csv_path = Path(tmpdir) / "metrics-history.csv"
            csv_path.write_text(
                "timestamp,launch_to_first_prompt_median_ms\n"
                "2026-03-22T10:29:08-0700,1468.205\n"
            )
            row = history_row_from_summary(debug_summary(), "2026-08-07T10:00:00-0700")
            rows = append_history_row(csv_path, row)

            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["timestamp"], "2026-03-22T10:29:08-0700")
            self.assertEqual(rows[0]["launch_to_first_prompt_median_ms"], "1468.205")
            self.assertEqual(rows[0]["scenario"], "")
            self.assertEqual(rows[1]["scenario"], "debug_no_activate")

            with csv_path.open(newline="") as f:
                header = next(csv.reader(f))
            self.assertIn("scenario", header)
            self.assertIn("workspace_click_to_focus_median_ms", header)

    def test_append_rewrites_existing_rows_byte_for_byte(self) -> None:
        """One new row must arrive as one added line.

        The whole file is rewritten on every append, so a line terminator that differs
        from the one already on disk turns a one-row append into a diff touching every
        row that came before it.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            csv_path = Path(tmpdir) / "metrics-history.csv"
            row = history_row_from_summary(debug_summary(), "2026-08-07T10:00:00-0700")
            append_history_row(csv_path, row)
            before = csv_path.read_bytes()

            append_history_row(
                csv_path,
                history_row_from_summary(debug_summary(), "2026-08-08T10:00:00-0700"),
            )
            after = csv_path.read_bytes()

            self.assertNotIn(b"\r", after)
            self.assertTrue(
                after.startswith(before),
                "appending a row rewrote the lines that preceded it",
            )

    def test_record_summary_writes_history_dashboard_and_latest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            paths = record_summary(summary=debug_summary(), root_dir=root, timestamp="2026-08-07T10:00:00-0700")
            self.assertTrue(paths["history_csv"].is_file())
            self.assertTrue(paths["latest_json"].is_file())
            dashboard = paths["dashboard_md"].read_text()
            self.assertIn("# Performance Dashboard", dashboard)
            self.assertIn("| Timestamp | Scenario |", dashboard)
            self.assertIn("## Recording Cadence", dashboard)

    def test_dashboard_renders_without_history(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            text = render_dashboard([], installed_summary(), "2026-08-07T10:00:00-0700", Path(tmpdir))
            self.assertIn("Not enough recorded history", text)

    def test_dashboard_latest_is_chronological_not_ingestion_order(self) -> None:
        newer = debug_summary()
        older = debug_summary()
        older["metrics"]["launch_to_first_prompt"]["median"] = 500.0
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            record_summary(summary=newer, root_dir=root, timestamp="2026-08-07T10:00:00-0700")
            paths = record_summary(summary=older, root_dir=root, timestamp="2026-08-01T10:00:00-0700")
            dashboard = paths["dashboard_md"].read_text()

            latest_snapshot = dashboard.split("## Investigated Delta")[0]
            self.assertIn("600.00", latest_snapshot)
            self.assertNotIn("500.00", latest_snapshot)

            trend = dashboard.split("## Trend")[1]
            self.assertLess(trend.index("2026-08-01"), trend.index("2026-08-07"))


class CommittedEvidenceSchemaTests(unittest.TestCase):
    """The checked-in evidence has to parse as the current writer would write it.

    Evidence and schema drifted apart once already: #1495 added `launch_trigger` to
    `HISTORY_FIELDNAMES`, and the committed history kept a header one column narrower,
    so the next append would silently rewrite the schema and every row recorded in
    between carried an unknown readiness signal. Nothing failed, because the release
    gate reads only `release_tag` — a row can be short, or shifted a field, and still
    pass. These are the two properties a reader relies on and no other check asserts.
    """

    def test_the_committed_history_header_is_the_writer_s_schema(self) -> None:
        history = REPO_ROOT / "docs" / "performance" / "metrics-history.csv"
        with history.open(newline="") as f:
            header = next(csv.reader(f))

        self.assertEqual(header, HISTORY_FIELDNAMES)

    def test_every_tracked_csv_row_parses_at_its_header_s_width(self) -> None:
        """A short row does not raise; it reads back with every later field shifted.

        `csv.DictReader` pairs by position, so a 14-field row under a 15-column header
        answers `os_version` with an arch and `notes` with None. Counting fields is the
        only thing that sees it.
        """
        tracked = subprocess.run(
            ["git", "ls-files", "*.csv"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
        self.assertTrue(tracked, "no tracked CSVs found — the sweep would pass vacuously")

        mismatches = []
        for relative in tracked:
            with (REPO_ROOT / relative).open(newline="") as f:
                reader = csv.reader(f)
                header = next(reader, None)
                if header is None:
                    continue
                for number, row in enumerate(reader, start=1):
                    if len(row) != len(header):
                        mismatches.append(f"{relative}:{number} has {len(row)}, header has {len(header)}")

        self.assertEqual(mismatches, [])


class PerfChannelBaselineTests(unittest.TestCase):
    def test_contract_has_no_unrunnable_scenarios(self) -> None:
        contract = load_contract()
        runner_text = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text()
        for scenario in contract["scenarios"]:
            self.assertIn(
                scenario["id"],
                runner_text,
                f"contract scenario {scenario['id']} is not dispatchable via perf-runner.sh",
            )

    def test_channel4_removed_from_contract(self) -> None:
        contract = load_contract()
        scenario_ids = {scenario["id"] for scenario in contract["scenarios"]}
        metric_names = {metric["name"] for metric in contract["metrics"]}
        self.assertNotIn("channel4_replay_10k_records", scenario_ids)
        self.assertFalse({name for name in metric_names if name.startswith("channel4_")})

    def test_normalize_metrics_maps_burst_rollup_stats(self) -> None:
        payload = {
            "runs": 5,
            "metrics": {
                "channel1_ingest_http_200_latency_ms": {
                    "median_ms": 1.65,
                    "mean_ms": 1.76,
                    "p95_ms": 2.46,
                    "p99_ms": 3.57,
                    "max_ms": 3.73,
                }
            },
        }
        metrics = perf_channel_baseline.normalize_metrics(
            "channel1_hook_ingest_burst", payload, {"channel1_ingest_http_200_latency_ms": "ms"}
        )
        stats = metrics["channel1_ingest_http_200_latency_ms"]
        self.assertEqual(stats["median"], 1.65)
        self.assertEqual(stats["p95"], 2.46)
        self.assertEqual(stats["count"], 5)
        self.assertEqual(stats["unit"], "ms")

    def test_normalize_metrics_expands_value_observations(self) -> None:
        payload = {"metrics": {"channel1_long_session_rss_delta_mb": {"value": 20.39}}}
        metrics = perf_channel_baseline.normalize_metrics(
            "channel1_long_session_memory", payload, {"channel1_long_session_rss_delta_mb": "MB"}
        )
        stats = metrics["channel1_long_session_rss_delta_mb"]
        self.assertEqual(stats["median"], 20.39)
        self.assertEqual(stats["count"], 1)
        self.assertEqual(stats["unit"], "MB")

    def test_absolute_caps_gate_ungated_cap_references(self) -> None:
        summary = {
            "metrics": {
                "channel1_long_session_rss_delta_mb": {"value": 20.39, "median": 20.39, "unit": "MB"},
                "channel1_registry_size_after_close": {"value": 0.0, "median": 0.0, "unit": "entries"},
            },
            "budget_results": {
                "channel1_long_session_rss_delta_mb": {
                    "status": "ungated",
                    "reason": "reference_baseline_missing_required_stat",
                    "reference_baseline": {"ten_minute_max_mb": 1, "sixty_minute_max_mb": 5},
                },
                "channel1_registry_size_after_close": {
                    "status": "ungated",
                    "reason": "reference_baseline_missing_required_stat",
                    "reference_baseline": {"max_entries": 0},
                },
            },
        }
        perf_channel_baseline.apply_absolute_caps(summary, duration_seconds=600)

        rss_budget = summary["budget_results"]["channel1_long_session_rss_delta_mb"]
        self.assertEqual(rss_budget["status"], "fail")
        self.assertEqual(rss_budget["cap_key"], "ten_minute_max_mb")
        self.assertEqual(rss_budget["gate_budget"], 1.0)

        registry_budget = summary["budget_results"]["channel1_registry_size_after_close"]
        self.assertEqual(registry_budget["status"], "pass")
        self.assertEqual(registry_budget["gate_kind"], "absolute_cap")

    def test_long_run_uses_sixty_minute_cap(self) -> None:
        cap = perf_channel_baseline.pick_absolute_cap(
            {"ten_minute_max_mb": 1, "sixty_minute_max_mb": 5}, duration_seconds=3600
        )
        self.assertEqual(cap, ("sixty_minute_max_mb", 5.0))

    def test_missing_expected_metric_fails_assertion(self) -> None:
        summary = {"scenario": "channel1_hook_ingest_burst", "metrics": {}, "budget_results": {}}
        perf_channel_baseline.mark_missing_expected_metrics(
            summary, load_contract(), "channel1_hook_ingest_burst"
        )
        statuses = {name: budget["status"] for name, budget in summary["budget_results"].items()}
        self.assertEqual(
            statuses,
            {
                "channel1_ingest_http_200_latency_ms": "missing",
                "channel1_ingest_flush_lag_ms": "missing",
                "channel1_ingest_registry_publishes": "missing",
            },
        )
        with self.assertRaises(SystemExit):
            perf_channel_baseline.assert_budget(summary)


if __name__ == "__main__":
    unittest.main()
