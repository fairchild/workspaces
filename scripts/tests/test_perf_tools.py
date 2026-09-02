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
import os
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import importlib.util as _importlib_util

from perf_history import (
    HISTORY_FIELDNAMES,
    LEGACY_PROTOCOL_EPOCH,
    history_row_from_summary,
    render_dashboard,
)
from perf_schema import (
    evaluate_budgets,
    launch_trigger_label,
    load_contract,
    measured_duration_samples,
)


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

    def test_installed_lanes_isolate_the_preferences_domain(self) -> None:
        """Every installed launch names a scratch suite rather than the shipped domain.

        Un-isolated, the lane reads whatever `com.cloudcompute.workspaces` happens to
        hold — the non-determinism `deterministic-delivery-v1` claims to have removed —
        and writes its own selection state back into the domain the installed app uses.
        """
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        launches = re.findall(
            r"(?s)WORKSPACES_DATA_DIR=.*?launch-installed-diagnostics\.sh", script
        )
        self.assertTrue(launches, "no installed launch found in perf-runner.sh")
        for launch in launches:
            self.assertIn("WORKSPACES_PREFERENCES_SUITE=", launch)
        self.assertIn("cleanup_preferences_suite", script)

    def test_every_installed_launch_reads_its_isolation_back(self) -> None:
        """Exporting the suite is an intent; each lane must verify what the app resolved."""
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        launches = re.findall(
            r"(?s)WORKSPACES_DATA_DIR=.*?summarize_installed_log", script
        )
        self.assertTrue(launches, "no installed launch found in perf-runner.sh")
        for launch in launches:
            self.assertIn("assert_preferences_isolated", launch)

    def test_main_window_hotspot_scenarios_delegate_to_helper(self) -> None:
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        self.assertIn("main-window-hotspots-baseline.py", script)
        self.assertIn("main_window_agent_activity_burst", script)
        self.assertIn("main_window_session_switcher_snapshot", script)
        self.assertIn("main_window_resident_memory_20_workspaces", script)


class PreferencesIsolationReadBackTests(unittest.TestCase):
    """The installed lane's isolation check, run against real log shapes.

    `domain=scratch` is not proof of isolation — the refusal path logs that domain too —
    so each of the three ways the export is silently defeated has to fail closed here.
    """

    SUITE = "com.cloudcompute.workspaces.perf.mine"
    PREFIX = "2026-08-31 07:58:19.633 I WorkspaceManager[1:2] [LaunchPreferences] "

    def run_check(self, log_body: str) -> subprocess.CompletedProcess:
        script = (REPO_ROOT / "scripts" / "perf-runner.sh").read_text(encoding="utf-8")
        match = re.search(
            r"(?ms)^assert_preferences_isolated\(\) \{.*?^\}", script
        )
        self.assertIsNotNone(match, "assert_preferences_isolated not found in perf-runner.sh")
        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp) / "capture.log"
            log_path.write_text(log_body, encoding="utf-8")
            return subprocess.run(
                [
                    "bash",
                    "-c",
                    f"set -euo pipefail\nPREFERENCES_SUITE={self.SUITE}\n"
                    f"{match.group(0)}\nassert_preferences_isolated \"$1\"",
                    "_",
                    str(log_path),
                ],
                capture_output=True,
                text=True,
            )

    def assert_refused(self, log_body: str, because: str) -> None:
        """Fails closed *and* says why.

        The exit code alone is not enough: `set -e` plus `pipefail` will abort this
        function at its own no-match grep, which refuses the capture without printing
        anything — a silent abort in the branch whose whole job is to be loud.
        """
        result = self.run_check(log_body)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[preferences]", result.stderr)
        self.assertIn(because, result.stderr)

    def test_an_isolated_launch_on_the_expected_suite_passes(self) -> None:
        line = f"{self.PREFIX}domain=scratch suite={self.SUITE} reset=false isolated=true"
        self.assertEqual(self.run_check(line + "\n").returncode, 0)

    def test_a_log_without_the_line_is_refused_out_loud(self) -> None:
        """An app older than WORKSPACES_PREFERENCES_SUITE reports no domain at all."""
        self.assert_refused("some capture output\n", "no [LaunchPreferences] line")

    def test_the_persistent_domain_is_refused_out_loud(self) -> None:
        """A reserved suite name is logged and ignored, resolving to domain=standard."""
        self.assert_refused(f"{self.PREFIX}domain=standard\n", "resolved domain=standard")

    def test_a_refused_suite_is_refused_out_loud(self) -> None:
        """The defaults system refusing the suite still logs domain=scratch."""
        line = f"{self.PREFIX}domain=scratch suite={self.SUITE} reset=false isolated=false"
        self.assert_refused(line + "\n", "isolated=false")

    def test_a_missing_suite_field_is_refused_out_loud(self) -> None:
        """A line that never names a suite proves nothing about which store backed it.

        This is the shape a truncated final log entry takes, and the shape any tooling
        older than the `suite=` field emits. `domain=scratch` and `isolated=true` say a
        scratch store was opened; only `suite=` says it was *this lane's*. Treating the
        field as optional lets an isolated-looking capture through against a suite the
        runner does not own and will not clean up — the failure class the readback
        exists to close, wearing a passing label.
        """
        line = f"{self.PREFIX}domain=scratch reset=false isolated=true"
        self.assert_refused(line + "\n", "reported no suite=")

    def test_a_foreign_suite_is_refused_out_loud(self) -> None:
        line = f"{self.PREFIX}domain=scratch suite=com.cloudcompute.workspaces.perf.other reset=false isolated=true"
        self.assert_refused(line + "\n", "expected")

    def test_a_truncated_final_entry_does_not_fall_back_to_an_earlier_one(self) -> None:
        """A cut final entry is an unjudged resolution, not an absent one.

        Anchoring the search on `domain=` made a final entry that never reached its
        first field invisible, so the reader silently fell back to the previous
        resolution and judged a launch by a line that did not describe it.
        """
        body = (
            f"{self.PREFIX}domain=scratch suite={self.SUITE} reset=false isolated=true\n"
            f"{self.PREFIX}\n"
        )
        self.assert_refused(body, "no readable domain=")

    def test_the_marker_must_be_a_field_of_its_own(self) -> None:
        """A path that happens to contain the marker is not a resolution.

        The installed capture carries every message the process and its subsystem
        emit, so a logged path or identifier can hold the literal text. Matched as a
        substring, such a message becomes the newest entry and replaces the genuine
        resolution before it — the one shape where more log output makes the check
        weaker. A real entry stands as its own whitespace-delimited field.
        """
        genuine_failure = f"{self.PREFIX}domain=standard"
        impostors = [
            f"2026-08-31 07:58:20.000 I WorkspaceManager[1:2] [Perf] root=/tmp/[LaunchPreferences] "
            f"domain=scratch suite={self.SUITE} isolated=true",
            f"2026-08-31 07:58:20.000 I WorkspaceManager[1:2] "
            f"[LaunchPreferences]domain=scratch suite={self.SUITE} isolated=true",
            # The category is the first bracketed field, and a repository path is logged
            # verbatim after it — so a path with spaces in it can carry the marker as a
            # field of its own without ever being one.
            f"2026-08-31 07:58:20.000 I WorkspaceManager[1:2] [HostSession] path=/tmp/x "
            f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true",
        ]
        for impostor in impostors:
            with self.subTest(impostor=impostor):
                self.assert_refused(f"{genuine_failure}\n{impostor}\n", "resolved domain=standard")

    def test_a_carriage_return_does_not_survive_into_the_last_field(self) -> None:
        """A CRLF log must read the same as an LF one, or the lanes disagree."""
        line = f"{self.PREFIX}domain=scratch suite={self.SUITE} reset=false isolated=true"
        self.assertEqual(self.run_check(line + "\r\n").returncode, 0)

    def test_a_field_repeated_on_one_line_has_no_answer(self) -> None:
        """Two values for one key is unreadable, including when the second is empty.

        A reader that keeps the last non-empty value silently prefers whichever token
        it happened to see, which is a choice no log entry authorised. The empty case
        is the one that hides: the shell drops a trailing empty line from a command
        substitution, so a duplicate that reports nothing looks like no duplicate.
        """
        for repeated in (
            f"domain=scratch suite={self.SUITE} isolated=true domain=",
            f"domain=scratch suite={self.SUITE} isolated=true suite=",
            f"domain=scratch suite={self.SUITE} isolated=true isolated=",
            f"domain=scratch suite={self.SUITE} isolated=true domain=standard",
            f"domain=scratch suite={self.SUITE} isolated=true suite=perf.other",
        ):
            with self.subTest(line=repeated):
                self.assert_refused(f"{self.PREFIX}{repeated}\n", "[preferences]")

    def test_the_last_resolution_in_the_log_is_the_one_judged(self) -> None:
        """A relaunch that fell back must not be masked by an earlier isolated line."""
        body = (
            f"{self.PREFIX}domain=scratch suite={self.SUITE} reset=false isolated=true\n"
            f"{self.PREFIX}domain=standard\n"
        )
        self.assert_refused(body, "resolved domain=standard")


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

    def test_summary_carries_the_trigger_where_a_recorded_row_reads_it(self) -> None:
        """Findings are prose for a reader; a row is cut from `metadata` (#1399)."""
        payload = self.summarize([self.line(600.0, "terminal_set_title")])

        self.assertEqual(payload["metadata"]["launch_trigger"], "terminal_set_title")

    def test_a_focus_closed_capture_reaches_the_row_labelled(self) -> None:
        """The 61s sample: recorded, it must not present as a launch measurement."""
        payload = self.summarize([self.line(61_000.0, "terminal_focus")])
        row = history_row_from_summary(payload, "2026-08-30T10:00:00-0700")

        self.assertEqual(row["launch_trigger"], "terminal_focus")

    def test_a_mixed_capture_names_both_triggers_on_the_row(self) -> None:
        """A median over a mix is the row that most needs to say so."""
        payload = self.summarize(
            [self.line(61_000.0, "terminal_focus"), self.line(640.0, "terminal_set_title")]
        )
        row = history_row_from_summary(payload, "2026-08-30T10:00:00-0700")

        self.assertEqual(row["launch_trigger"], "terminal_focus+terminal_set_title")


class LaunchTriggerRowTests(unittest.TestCase):
    """The recorded row carries what the samples measured, not just the number (#1399)."""

    def test_the_history_csv_has_a_column_for_it(self) -> None:
        self.assertIn("launch_trigger", HISTORY_FIELDNAMES)

    def test_a_summary_predating_the_column_records_blank_not_a_guess(self) -> None:
        """Blank means unreported. Only a producer that saw a trigger can name one."""
        row = history_row_from_summary(
            {
                "scenario": "debug_no_activate",
                "metrics": {"launch_to_first_prompt": {"median": 592.0, "mean": 592.0}},
                "metadata": {"build_kind": "debug"},
            },
            "2026-06-08T00:00:00-0700",
        )

        self.assertEqual(row["launch_trigger"], "")

    def test_both_lanes_render_the_label_the_same_way(self) -> None:
        """One home for the format, so a cell means the same thing whichever lane wrote it.

        The debug lane hands per-sample strings, the installed summarizer hands a
        trigger→count mapping; the cell must not depend on which shape arrived.
        """
        self.assertEqual(
            launch_trigger_label(["terminal_focus", "terminal_set_title"]),
            launch_trigger_label({"terminal_set_title": 3, "terminal_focus": 1}),
        )

    def test_repeated_triggers_collapse_to_one_name(self) -> None:
        self.assertEqual(
            launch_trigger_label(["terminal_set_title", "terminal_set_title"]),
            "terminal_set_title",
        )

    def test_samples_without_a_trigger_contribute_nothing(self) -> None:
        self.assertEqual(launch_trigger_label([None, "terminal_focus", None]), "terminal_focus")
        self.assertEqual(launch_trigger_label([None, None]), "")


class DebugLaneTriggerTests(unittest.TestCase):
    """The debug lane reaches a recorded row with the same label the installed one does.

    `perf-baseline.sh` embeds its summarizer in a heredoc, so this extracts and runs the
    program the script actually runs rather than reimplementing it. The fixture is two
    synthetic run logs: an isolation line, because the lane fails closed without one, and
    a launch sample carrying its trigger.
    """

    @staticmethod
    def embedded_summarizer() -> str:
        script = (REPO_ROOT / "scripts" / "perf-baseline.sh").read_text(encoding="utf-8")
        return script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]

    def summarize(self, triggers: list[str]) -> dict:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            program = out_dir / "summarize.py"
            program.write_text(self.embedded_summarizer(), encoding="utf-8")
            for index, trigger in enumerate(triggers, start=1):
                (out_dir / f"run-{index}.log").write_text(
                    "2026-08-30 10:00:00.000 [LaunchPreferences] domain=scratch "
                    "suite=perf.scratch isolated=true\n"
                    "2026-08-30 10:00:01.000 [Perf] metric=launch_to_first_prompt "
                    f"duration_ms=60{index}.00 trigger={trigger}\n",
                    encoding="utf-8",
                )
            subprocess.run(
                [
                    sys.executable,
                    str(program),
                    str(out_dir),
                    str(REPO_ROOT),
                    str(len(triggers)),
                    "0",
                    "0",  # record: never touch the committed history from a test
                    "2026-08-30T10:00:00-0700",
                    "26.6.2",
                    "25G100",
                    "arm64",
                    "Mac16,13",
                    "no-activate",
                    "0",  # assert_budget
                    "",
                    "clean",
                    "off",
                    "1",
                    "scratch",
                    "perf.scratch",
                    "owner",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
                env={
                    **os.environ,
                    "PYTHONPATH": str(REPO_ROOT / "scripts"),
                    "PERF_SUMMARY_TIMESTAMP": "2026-08-30T10:00:00-0700",
                },
            )
            return json.loads((out_dir / "summary.json").read_text(encoding="utf-8"))

    def test_a_readiness_closed_run_records_its_trigger(self) -> None:
        row = history_row_from_summary(
            self.summarize(["terminal_set_title", "terminal_set_title"]),
            "2026-08-30T10:00:00-0700",
        )

        self.assertEqual(row["launch_trigger"], "terminal_set_title")

    def test_a_focus_close_in_the_debug_lane_reaches_the_row_too(self) -> None:
        """Both lanes, one label — the debug lane is the exposed one under `activate`."""
        row = history_row_from_summary(
            self.summarize(["terminal_focus", "terminal_set_title"]),
            "2026-08-30T10:00:00-0700",
        )

        self.assertEqual(row["launch_trigger"], "terminal_focus+terminal_set_title")


class DebugLaneIsolationTests(unittest.TestCase):
    """The debug lane's isolation check has to be as strict as the installed lane's.

    `perf-runner.sh` and `perf-baseline.sh` make the same promise about the same log
    line, so a shape one lane refuses and the other accepts is a hole in whichever is
    laxer. This runs the summarizer `perf-baseline.sh` actually embeds, against run
    logs whose isolation line is the shape under test.
    """

    SUITE = "perf.scratch"

    def run_summarizer(self, log_bodies: list[str]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            program = out_dir / "summarize.py"
            program.write_text(
                DebugLaneTriggerTests.embedded_summarizer(), encoding="utf-8"
            )
            for index, body in enumerate(log_bodies, start=1):
                (out_dir / f"run-{index}.log").write_text(body, encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(program),
                    str(out_dir),
                    str(REPO_ROOT),
                    str(len(log_bodies)),
                    "0",
                    "0",  # record: never touch the committed history from a test
                    "2026-08-30T10:00:00-0700",
                    "26.6.2",
                    "25G100",
                    "arm64",
                    "Mac16,13",
                    "no-activate",
                    "0",  # assert_budget
                    "",
                    "clean",
                    "off",
                    "1",
                    "scratch",
                    self.SUITE,
                    "owner",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PYTHONPATH": str(REPO_ROOT / "scripts"),
                    "PERF_SUMMARY_TIMESTAMP": "2026-08-30T10:00:00-0700",
                },
            )

    @staticmethod
    def run_log(isolation_line: str) -> str:
        return (
            f"2026-08-30 10:00:00.000 {isolation_line}\n"
            "2026-08-30 10:00:01.000 [Perf] metric=launch_to_first_prompt "
            "duration_ms=601.00 trigger=terminal_set_title\n"
        )

    def test_an_isolated_launch_on_the_expected_suite_is_accepted(self) -> None:
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true"
                )
            ]
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_missing_suite_field_is_an_isolation_failure(self) -> None:
        """No `suite=` is no evidence the lane's own store backed the launch.

        The installed lane refuses this shape; the debug lane treated the field as
        optional and accepted it, so a truncated line reading `domain=scratch
        isolated=true` reached a recorded row carrying an isolation claim nothing in
        the log supports.
        """
        result = self.run_summarizer(
            [self.run_log("[LaunchPreferences] domain=scratch isolated=true")]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ISOLATION FAILURES", result.stdout)
        self.assertIn("reported no suite", result.stdout)

    def test_the_last_resolution_in_the_log_is_the_one_judged(self) -> None:
        """Reading the first entry lets an isolated line vouch for a fallback after it.

        The app logs once per resolution, so a relaunch that fell back appends *after*
        the isolated line that preceded it. Judging the first match means the run that
        actually happened is never the one examined.
        """
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true"
                ).replace(
                    "\n2026-08-30 10:00:01.000 [Perf]",
                    "\n2026-08-30 10:00:00.500 [LaunchPreferences] domain=standard"
                    "\n2026-08-30 10:00:01.000 [Perf]",
                )
            ]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("domain=standard", result.stdout)

    def test_a_later_entry_missing_its_suite_is_not_masked_by_an_earlier_one(self) -> None:
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true"
                ).replace(
                    "\n2026-08-30 10:00:01.000 [Perf]",
                    "\n2026-08-30 10:00:00.500 [LaunchPreferences] domain=scratch isolated=true"
                    "\n2026-08-30 10:00:01.000 [Perf]",
                )
            ]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("reported no suite", result.stdout)

    def test_a_duplicate_domain_on_one_line_is_unreadable_rather_than_resolved(self) -> None:
        """Two values for one field is not a field the reader may pick from."""
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} "
                    "isolated=true domain=standard"
                )
            ]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no readable domain", result.stdout)

    def test_a_truncated_final_entry_is_refused(self) -> None:
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true"
                ).replace(
                    "\n2026-08-30 10:00:01.000 [Perf]",
                    "\n2026-08-30 10:00:00.500 [LaunchPreferences]"
                    "\n2026-08-30 10:00:01.000 [Perf]",
                )
            ]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no readable domain", result.stdout)

    def test_the_marker_must_be_a_field_of_its_own(self) -> None:
        for impostor in (
            f"[Perf] root=/tmp/[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true",
            f"[LaunchPreferences]domain=scratch suite={self.SUITE} isolated=true",
            f"[HostSession] path=/tmp/x [LaunchPreferences] domain=scratch "
            f"suite={self.SUITE} isolated=true",
        ):
            with self.subTest(impostor=impostor):
                result = self.run_summarizer(
                    [
                        self.run_log("[LaunchPreferences] domain=standard").replace(
                            "\n2026-08-30 10:00:01.000 [Perf]",
                            f"\n2026-08-30 10:00:00.500 {impostor}"
                            "\n2026-08-30 10:00:01.000 [Perf]",
                        )
                    ]
                )

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("domain=standard", result.stdout)

    def test_a_carriage_return_does_not_survive_into_the_last_field(self) -> None:
        result = self.run_summarizer(
            [
                self.run_log(
                    f"[LaunchPreferences] domain=scratch suite={self.SUITE} isolated=true"
                ).replace("isolated=true\n", "isolated=true\r\n")
            ]
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_suite_name_containing_the_marker_is_read_as_one_token(self) -> None:
        """The marker is a log prefix, so the first one on a line is the real one.

        Searching backwards through the whole log finds a marker embedded in a suite
        name and reads the tail of that name as the entry, which the installed lane —
        whose grep takes the rest of the line from the first marker — does not do.
        The name is absurd, but a parser disagreement between the two lanes is the
        thing this pair of checks exists to not have.
        """
        suite = "perf.[LaunchPreferences].scratch"
        with_marker_pin = self.SUITE
        try:
            self.SUITE = suite
            result = self.run_summarizer(
                [self.run_log(f"[LaunchPreferences] domain=scratch suite={suite} isolated=true")]
            )
        finally:
            self.SUITE = with_marker_pin

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_foreign_suite_is_still_an_isolation_failure(self) -> None:
        result = self.run_summarizer(
            [
                self.run_log(
                    "[LaunchPreferences] domain=scratch suite=perf.someone-else isolated=true"
                )
            ]
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("expected", result.stdout)


class DebugLaneRunCountTests(unittest.TestCase):
    """A capture that left no log is a failed capture, not a quiet one.

    The summarizer globs the run logs that exist. The app launches in a background
    subshell whose failure is suppressed, so a run that never wrote its log left the
    directory one file short and the lane summarized whatever remained — an empty
    directory summarized clean. Isolation is checked per sample, and a sample that
    does not exist is never examined.
    """

    def run_summarizer(self, logs: int, runs: int) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            program = out_dir / "summarize.py"
            program.write_text(
                DebugLaneTriggerTests.embedded_summarizer(), encoding="utf-8"
            )
            for index in range(1, logs + 1):
                (out_dir / f"run-{index}.log").write_text(
                    "2026-08-30 10:00:00.000 [LaunchPreferences] domain=scratch "
                    "suite=perf.scratch isolated=true\n"
                    "2026-08-30 10:00:01.000 [Perf] metric=launch_to_first_prompt "
                    "duration_ms=601.00 trigger=terminal_set_title\n",
                    encoding="utf-8",
                )
            return subprocess.run(
                [
                    sys.executable, str(program), str(out_dir), str(REPO_ROOT), str(runs),
                    "0", "0", "2026-08-30T10:00:00-0700", "26.6.2", "25G100", "arm64",
                    "Mac16,13", "no-activate", "0", "", "clean", "off", "1",
                    "scratch", "perf.scratch", "owner",
                ],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
                env={
                    **os.environ,
                    "PYTHONPATH": str(REPO_ROOT / "scripts"),
                    "PERF_SUMMARY_TIMESTAMP": "2026-08-30T10:00:00-0700",
                },
            )

    def test_every_requested_run_must_have_left_a_log(self) -> None:
        result = self.run_summarizer(logs=2, runs=3)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("2 of 3", result.stdout + result.stderr)

    def test_no_logs_at_all_is_the_loudest_case_not_the_quietest(self) -> None:
        result = self.run_summarizer(logs=0, runs=3)

        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_a_complete_set_of_logs_summarizes(self) -> None:
        result = self.run_summarizer(logs=3, runs=3)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


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
