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
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from perf_schema import evaluate_budgets, load_contract

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
        self.assertEqual(result["launch_to_first_prompt"]["gate_budget_ms"], 740)
        self.assertEqual(result["launch_to_first_prompt"]["diagnostic_threshold_ms"], 947)
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

    def test_main_window_hotspot_scenarios_are_registered(self) -> None:
        contract = load_contract()
        scenario_ids = {scenario["id"] for scenario in contract["scenarios"]}
        for scenario_id in {
            "main_window_agent_activity_burst",
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
            self.assertEqual(payload["budget_results"]["launch_to_first_prompt"]["gate_budget_ms"], 740)

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


if __name__ == "__main__":
    unittest.main()
