#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the Workspaces performance contract.

Intent: keep perf summary parsing, budget evaluation, and diagnostic report
helpers aligned with `config/performance/contract.json` using small local
fixtures instead of launching the app or requiring a performance runner.
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import importlib.util as _importlib_util

from perf_history import LEGACY_PROTOCOL_EPOCH, history_row_from_summary, render_dashboard
from perf_schema import evaluate_budgets, load_contract, measured_duration_samples


def _load_hyphenated_module(name: str, path: Path):
    """`perf-compare.py` is not importable by name; load it by path."""
    spec = _importlib_util.spec_from_file_location(name, path)
    module = _importlib_util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


perf_compare = _load_hyphenated_module("perf_compare", REPO_ROOT / "scripts" / "perf-compare.py")


def expected_budgets(scenario: str, metric: str = "launch_to_first_prompt") -> tuple[int, int]:
    """The budgets the contract implies for `scenario`, computed independently.

    References are refreshed whenever a capture protocol changes (#1251), so pinning
    the numbers here would make every legitimate refresh look like a tool regression.
    The formula is what these tests are for, so it is spelled out literally rather
    than imported from the code under test.
    """
    contract = load_contract()
    entry = next(item for item in contract["metrics"] if item["name"] == metric)
    reference = entry["reference_baselines"][scenario]
    gate = contract["budget_formula"]["gate"]
    diagnostic = contract["budget_formula"]["diagnostic"]
    return (
        math.ceil(reference["median_ms"] * gate["multiplier"]),
        math.ceil(reference["p95_ms"] * diagnostic["multiplier"]),
    )


SUMMARIZE_PERF_LOG = (
    REPO_ROOT
    / ".agents"
    / "skills"
    / "workspaces-optimization"
    / "scripts"
    / "summarize_perf_log.py"
)
SUMMARIZE_DIAGNOSTIC_REPORT = (
    REPO_ROOT
    / ".agents"
    / "skills"
    / "workspaces-optimization"
    / "scripts"
    / "summarize_diagnostic_report.py"
)


class PerfContractTests(unittest.TestCase):
    def test_budget_evaluator_uses_contract_formula(self) -> None:
        contract = load_contract()
        result = evaluate_budgets(
            contract,
            "debug_no_activate",
            {
                "launch_to_first_prompt": {
                    "count": 10,
                    "min": 180.0,
                    "median": 210.0,
                    "mean": 205.0,
                    "max": 230.0,
                    "p95": 225.0,
                    "unit": "ms",
                }
            },
        )
        gate_budget, diagnostic_threshold = expected_budgets("debug_no_activate")
        self.assertEqual(result["launch_to_first_prompt"]["gate_budget_ms"], gate_budget)
        self.assertEqual(result["launch_to_first_prompt"]["diagnostic_threshold_ms"], diagnostic_threshold)
        self.assertEqual(result["launch_to_first_prompt"]["status"], "pass")

    def test_release_policy_uses_installed_signoff(self) -> None:
        contract = load_contract()
        release_policy = contract["gate_policy"]["release"]
        self.assertTrue(release_policy["installed_build_verification_required"])
        self.assertEqual(release_policy["release_signoff_scenario"], "installed_clean_shell")
        self.assertFalse(release_policy["debug_scenarios_block_release"])

    def test_budget_evaluator_supports_non_ms_units(self) -> None:
        contract = load_contract()
        result = evaluate_budgets(
            contract,
            "channel1_sidebar_churn",
            {
                "channel1_steady_state_cpu_percent": {
                    "count": 3,
                    "min": 3.0,
                    "median": 4.0,
                    "mean": 4.33,
                    "max": 6.0,
                    "p95": 6.0,
                    "unit": "percent",
                }
            },
        )

        budget = result["channel1_steady_state_cpu_percent"]
        self.assertEqual(budget["status"], "pass")
        self.assertEqual(budget["gate_budget"], 7)
        self.assertEqual(budget["diagnostic_threshold"], 18)
        self.assertNotIn("gate_budget_ms", budget)

    def test_measured_duration_samples_reject_abandoned_click_intervals(self) -> None:
        text = "\n".join(
            [
                "2026-08-06 10:00:00.000 [Perf] metric=launch_to_first_prompt duration_ms=240.00 trigger=terminal_focus",
                "2026-08-06 10:00:00.100 [Perf] metric=workspace_click_to_focus duration_ms=271.27 session=a outcome=prompt_ready",
                "2026-08-06 10:00:00.200 [Perf] metric=repo_click_to_focus duration_ms=463.59 session=b outcome=focused",
                "2026-08-06 10:00:15.300 [Perf] metric=workspace_click_to_focus duration_ms=15006.41 session=c outcome=web_source_selected",
                "2026-08-06 10:00:15.400 [Perf] metric=repo_click_to_focus duration_ms=9001.00 session=d outcome=superseded",
                "2026-08-06 10:00:15.500 [Perf] metric=workspace_click_to_focus duration_ms=8000.00 session=e",
                "2026-08-06 10:00:15.600 [Perf] metric=workspace_click_to_focus status=abandoned elapsed_ms=36566.90 session=f outcome=repo_overview_selected",
            ]
        )

        samples = measured_duration_samples(text)

        self.assertEqual(
            samples,
            [
                ("launch_to_first_prompt", 240.0),
                ("workspace_click_to_focus", 271.27),
                ("repo_click_to_focus", 463.59),
            ],
        )

    def test_main_window_hotspot_scenarios_are_registered(self) -> None:
        contract = load_contract()
        scenario_ids = {scenario["id"] for scenario in contract["scenarios"]}
        for scenario_id in {
            "main_window_agent_activity_burst",
            "main_window_session_switcher_snapshot",
            "main_window_workspace_create_ui_stall",
            "main_window_idle_cpu_diagnostics_closed",
            "main_window_resident_memory_20_workspaces",
        }:
            self.assertIn(scenario_id, scenario_ids)


class PerfRunnerScriptTests(unittest.TestCase):
    def test_installed_scenario_normalizes_app_bundle_path(self) -> None:
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        self.assertIn("normalize_installed_app_path", script)
        self.assertIn("Contents/MacOS/WorkspaceManager", script)
        self.assertIn('--app "$resolved_app_path"', script)

    def test_main_window_hotspot_scenarios_delegate_to_helper(self) -> None:
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        self.assertIn("main-window-hotspots-baseline.py", script)
        self.assertIn("main_window_agent_activity_burst", script)
        self.assertIn("main_window_session_switcher_snapshot", script)
        self.assertIn("main_window_resident_memory_20_workspaces", script)


class PerfSummarizerTests(unittest.TestCase):
    def run_json(self, command: list[str]) -> dict:
        if command and Path(command[0]).suffix == ".py":
            command = [sys.executable, *command]
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.fail(f"command failed: {' '.join(command)}\n{result.stderr}\n{result.stdout}")
        return json.loads(result.stdout)

    def test_debug_perf_log_summary_is_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "debug.log"
            log_path.write_text(
                "\n".join(
                    [
                        "2026-04-11 10:00:00.000 [Perf] metric=launch_to_first_prompt duration_ms=240.00 trigger=terminal_focus",
                        "2026-04-11 10:00:00.100 [Perf] metric=repo_hydration duration_ms=12.00 discovered=18 imported=0",
                        "2026-04-11 10:00:00.200 [Perf] metric=repo_click_to_focus duration_ms=180.00 session=abc outcome=focused",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            payload = self.run_json(
                [
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    "--scenario",
                    "debug_no_activate",
                    "--build-kind",
                    "debug",
                    str(log_path),
                ]
            )
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["scenario"], "debug_no_activate")
            self.assertEqual(payload["environment"]["build_kind"], "debug")
            self.assertIn("launch_to_first_prompt", payload["metrics"])
            self.assertEqual(
                payload["budget_results"]["launch_to_first_prompt"]["gate_budget_ms"],
                expected_budgets("debug_no_activate")[0],
            )

    def test_installed_clean_log_summary_is_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "installed-clean.log"
            log_path.write_text(
                "\n".join(
                    [
                        "2026-04-11 10:00:00.000 [Perf] metric=terminal_investigation phase=surface_create_succeeded duration_ms=120.00 shell_profile_mode=clean",
                        "2026-04-11 10:00:00.100 [Perf] metric=terminal_first_output duration_ms=500.00 signal=pwd shell_profile_mode=clean",
                        "2026-04-11 10:00:00.200 [Perf] metric=first_prompt_ready duration_ms=520.00 signal=pwd shell_profile_mode=clean",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            payload = self.run_json(
                [
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    str(log_path),
                ]
            )
            self.assertEqual(payload["scenario"], "installed_clean_shell")
            self.assertEqual(payload["environment"]["build_kind"], "installed")
            self.assertIn("terminal_first_output", payload["metrics"])
            self.assertIn("first_prompt_ready", payload["metrics"])

    def test_installed_login_log_summary_is_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "installed-login.log"
            log_path.write_text(
                "\n".join(
                    [
                        "2026-04-11 10:00:00.000 [Perf] metric=terminal_investigation phase=surface_create_succeeded duration_ms=180.00 shell_profile_mode=login",
                        "2026-04-11 10:00:00.100 [Perf] metric=terminal_first_output duration_ms=700.00 signal=set_title shell_profile_mode=login",
                        "2026-04-11 10:00:00.200 [Perf] metric=first_prompt_ready duration_ms=730.00 signal=set_title shell_profile_mode=login",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            payload = self.run_json(
                [
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    str(log_path),
                ]
            )
            self.assertEqual(payload["scenario"], "installed_login_shell")
            self.assertEqual(payload["environment"]["build_kind"], "installed")
            self.assertIn("terminal_first_output", payload["metrics"])

    def test_installed_input_log_summary_is_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "installed-input.log"
            log_path.write_text(
                "\n".join(
                    [
                        "2026-04-11 10:00:00.000 [Perf] metric=input_investigation phase=key_down_handled event_age_ms=14.00 handler_duration_ms=0.80 window_key=true surface_missing=false",
                        "2026-04-11 10:00:00.100 [Perf] metric=input_investigation phase=key_down_handled event_age_ms=11.00 handler_duration_ms=0.60 window_key=true surface_missing=false",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            payload = self.run_json(
                [
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    str(log_path),
                ]
            )
            self.assertEqual(payload["scenario"], "installed_input_short_capture")
            self.assertEqual(payload["environment"]["build_kind"], "installed")
            self.assertIn("input_event_age_ms_median", payload["metrics"])
            self.assertIn("input_handler_duration_ms_median", payload["metrics"])

    def test_diagnostic_report_summary_is_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = Path(tmpdir) / "workspaces-report.zip"
            report = {
                "generatedAt": "2026-04-11T10:00:00Z",
                "system": {
                    "hardwareModel": "Mac16,13",
                    "architecture": "arm64",
                    "physicalMemoryGB": 32,
                    "processorCount": 10,
                    "osVersion": "26.3.1",
                    "osBuild": "25D2128",
                },
                "startupDiagnostics": {
                    "appVersion": "0.10.0",
                    "buildNumber": "11",
                    "events": [
                        {
                            "metric": "launch_to_first_prompt",
                            "durationMs": 780.0,
                            "timestamp": "2026-04-11T10:00:01Z",
                            "labels": {"trigger": "terminal_focus"},
                        },
                        {
                            "metric": "terminal_first_output",
                            "durationMs": 600.0,
                            "timestamp": "2026-04-11T10:00:01Z",
                            "labels": {"signal": "pwd"},
                        },
                        {
                            "metric": "first_prompt_ready",
                            "durationMs": 620.0,
                            "timestamp": "2026-04-11T10:00:01Z",
                            "labels": {"signal": "pwd"},
                        },
                    ],
                },
            }
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("report.json", json.dumps(report))
                archive.writestr("system-profile.txt", "Path: /Applications/WorkSpaces.app\n")
                archive.writestr("recent-logs.txt", "Timestamp Message\n")

            payload = self.run_json(
                [
                    str(SUMMARIZE_DIAGNOSTIC_REPORT),
                    "--json",
                    str(zip_path),
                ]
            )
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["scenario"], "installed_login_shell")
            self.assertIn("launch_to_first_prompt", payload["metrics"])
            self.assertIn("terminal_first_output", payload["metrics"])


class PerfHistoryEpochTests(unittest.TestCase):
    """Rows are only comparable within one measurement protocol (#1251)."""

    @staticmethod
    def summary(median_ms: float, epoch: str | None) -> dict:
        metadata = {"build_kind": "debug", "runs_requested": 10, "sleep_seconds": 8}
        if epoch is not None:
            metadata["protocol_epoch"] = epoch
        return {
            "scenario": "debug_no_activate",
            "metrics": {"launch_to_first_prompt": {"median": median_ms, "mean": median_ms}},
            "metadata": metadata,
        }

    def test_summary_without_an_epoch_records_as_legacy(self) -> None:
        row = history_row_from_summary(self.summary(592.0, None), "2026-06-08T00:00:00-0700")

        self.assertEqual(row["protocol_epoch"], LEGACY_PROTOCOL_EPOCH)

    def test_declared_epoch_is_carried_onto_the_row(self) -> None:
        row = history_row_from_summary(
            self.summary(830.0, "isolated-preferences-v1"), "2026-08-08T22:00:00-0700"
        )

        self.assertEqual(row["protocol_epoch"], "isolated-preferences-v1")

    def render(self, rows: list[dict]) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            return render_dashboard(
                rows, rows_summary(rows[-1]), "2026-08-08T22:00:00-0700", Path(tmp)
            )

    def test_first_row_of_a_new_epoch_has_no_delta(self) -> None:
        """The only same-scenario predecessor is legacy, so there is nothing to compare to.

        Reporting +238 ms here would attribute the protocol switch to the app.
        """
        dashboard = self.render(
            [
                history_row_from_summary(self.summary(592.0, None), "2026-06-08T00:00:00-0700"),
                history_row_from_summary(
                    self.summary(830.0, "isolated-preferences-v1"), "2026-08-08T22:00:00-0700"
                ),
            ]
        )

        self.assertNotIn("+238.00 ms", dashboard)
        self.assertIn("n/a", dashboard)

    def test_delta_skips_a_legacy_row_to_reach_the_same_epoch(self) -> None:
        """An out-of-order legacy append must not become the baseline for an isolated row."""
        dashboard = self.render(
            [
                history_row_from_summary(
                    self.summary(700.0, "isolated-preferences-v1"), "2026-08-08T20:00:00-0700"
                ),
                history_row_from_summary(self.summary(592.0, None), "2026-08-08T21:00:00-0700"),
                history_row_from_summary(
                    self.summary(830.0, "isolated-preferences-v1"), "2026-08-08T22:00:00-0700"
                ),
            ]
        )

        self.assertIn("+130.00 ms", dashboard)
        self.assertNotIn("+238.00 ms", dashboard)


def rows_summary(row: dict) -> dict:
    """The summary shape `render_dashboard` reads alongside the rows."""
    return {
        "scenario": row["scenario"],
        "metrics": {"launch_to_first_prompt": {"median": float(row["launch_to_first_prompt_median_ms"])}},
        "metadata": {"protocol_epoch": row["protocol_epoch"]},
        "budget_results": {},
    }


class LaunchTriggerLabelTests(unittest.TestCase):
    """`launch_to_first_prompt` means different things per trigger (#1399)."""

    def summarize(self, trigger_lines: list[str]) -> dict:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "launch.log"
            log_path.write_text("\n".join(trigger_lines) + "\n", encoding="utf-8")
            command = [
                sys.executable,
                str(SUMMARIZE_PERF_LOG),
                "--json",
                "--scenario",
                "installed_clean_shell",
                "--build-kind",
                "installed",
                str(log_path),
            ]
            result = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, check=True)
            return json.loads(result.stdout)

    @staticmethod
    def line(ms: float, trigger: str) -> str:
        return (
            f"2026-08-30 10:00:00.000 [Perf] metric=launch_to_first_prompt "
            f"duration_ms={ms:.2f} trigger={trigger}"
        )

    def findings_text(self, payload: dict) -> str:
        return " ".join(payload.get("findings", []))

    def test_trigger_breakdown_is_reported(self) -> None:
        payload = self.summarize([self.line(600.0, "terminal_set_title")])

        self.assertIn("closed by triggers", self.findings_text(payload))
        self.assertIn("terminal_set_title", self.findings_text(payload))

    def test_focus_closed_samples_are_called_out_as_time_to_foreground(self) -> None:
        """A 61s backgrounded launch must not read as a slow launch."""
        payload = self.summarize(
            [self.line(61_000.0, "terminal_focus"), self.line(640.0, "terminal_set_title")]
        )
        text = self.findings_text(payload)

        self.assertIn("time-to-foreground", text)
        self.assertIn("1 launch_to_first_prompt sample(s) closed on terminal_focus", text)

    def test_readiness_only_capture_raises_no_attention_warning(self) -> None:
        payload = self.summarize(
            [self.line(600.0, "terminal_set_title"), self.line(620.0, "terminal_set_title")]
        )

        self.assertNotIn("time-to-foreground", self.findings_text(payload))


class MissingLaunchMetricTests(unittest.TestCase):
    """A capture that never reached a prompt must not summarize clean (#1238/#1399)."""

    def findings_for(self, lines: list[str], scenario: str = "installed_clean_shell") -> list[str]:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "capture.log"
            log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    "--scenario",
                    scenario,
                    "--build-kind",
                    "installed",
                    str(log_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            return json.loads(result.stdout)["findings"]

    def test_absent_launch_metric_is_called_a_failed_measurement(self) -> None:
        """Observed live: a reattached tmux session emits no readiness signal at all."""
        findings = self.findings_for(
            [
                "2026-08-30 10:00:00.000 [Perf] metric=terminal_investigation "
                "phase=surface_create_succeeded duration_ms=25.17 shell_profile_mode=clean",
            ]
        )

        self.assertTrue(any("MISSING: launch_to_first_prompt" in f for f in findings))
        self.assertTrue(any("do not record a benchmark row" in f for f in findings))

    def test_present_launch_metric_is_not_flagged(self) -> None:
        findings = self.findings_for(
            [
                "2026-08-30 10:00:00.000 [Perf] metric=launch_to_first_prompt "
                "duration_ms=640.00 trigger=terminal_set_title",
            ]
        )

        self.assertFalse(any("MISSING" in f for f in findings))


class InstalledEpochStampTests(unittest.TestCase):
    """Installed rows must claim the protocol they ran under, not a default (#1251/#1399)."""

    def summarize(self, extra_args: list[str]) -> dict:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "installed.log"
            log_path.write_text(
                "2026-08-30 10:00:00.000 [Perf] metric=launch_to_first_prompt "
                "duration_ms=640.00 trigger=terminal_set_title\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZE_PERF_LOG),
                    "--json",
                    "--scenario",
                    "installed_clean_shell",
                    "--build-kind",
                    "installed",
                    *extra_args,
                    str(log_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            return json.loads(result.stdout)

    def test_live_capture_records_the_epoch_it_ran_under(self) -> None:
        summary = self.summarize(["--protocol-epoch", "deterministic-delivery-v1"])
        row = history_row_from_summary(summary, "2026-08-30T00:00:00-0700")

        self.assertEqual(row["protocol_epoch"], "deterministic-delivery-v1")

    def test_resummarized_archive_is_not_relabelled_as_current(self) -> None:
        """An old log re-run through the summarizer describes its own era, not today's."""
        summary = self.summarize([])
        row = history_row_from_summary(summary, "2026-08-30T00:00:00-0700")

        self.assertEqual(row["protocol_epoch"], LEGACY_PROTOCOL_EPOCH)


class PerfCompareGuardTests(unittest.TestCase):
    """A delta only means an app change within one scenario and one protocol (#1251)."""

    @staticmethod
    def summary(scenario: str, epoch: str | None, median_ms: float = 800.0) -> dict:
        metadata: dict = {"build_kind": "debug"}
        if epoch is not None:
            metadata["protocol_epoch"] = epoch
        return {
            "scenario": scenario,
            "metrics": {"launch_to_first_prompt": {"median": median_ms}},
            "metadata": metadata,
        }

    def test_matching_scenario_and_epoch_compare_cleanly(self) -> None:
        payload = perf_compare.compare(
            self.summary("debug_no_activate", "deterministic-delivery-v1", 892.0),
            self.summary("debug_no_activate", "deterministic-delivery-v1", 850.0),
        )

        self.assertEqual(payload["incomparable"], [])

    def test_crossing_the_artifact_fix_boundary_is_flagged(self) -> None:
        """v1 rows mix the inline-tick artifact with honest samples; v2 rows do not."""
        payload = perf_compare.compare(
            self.summary("debug_no_activate", "isolated-preferences-v1", 830.0),
            self.summary("debug_no_activate", "deterministic-delivery-v1", 892.0),
        )

        self.assertEqual(len(payload["incomparable"]), 1)
        self.assertIn("protocol epoch differs", payload["incomparable"][0])

    def test_a_summary_without_an_epoch_is_legacy_not_a_silent_match(self) -> None:
        payload = perf_compare.compare(
            self.summary("debug_no_activate", None),
            self.summary("debug_no_activate", "deterministic-delivery-v1"),
        )

        self.assertEqual(payload["protocol_epoch_before"], LEGACY_PROTOCOL_EPOCH)
        self.assertTrue(payload["incomparable"])

    def test_different_scenarios_are_flagged(self) -> None:
        payload = perf_compare.compare(
            self.summary("debug_no_activate", "deterministic-delivery-v1"),
            self.summary("debug_activate", "deterministic-delivery-v1"),
        )

        self.assertEqual(len(payload["incomparable"]), 1)
        self.assertIn("scenario differs", payload["incomparable"][0])


if __name__ == "__main__":
    unittest.main()
