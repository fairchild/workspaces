#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the ReviewRun operator report renderer."""

from __future__ import annotations

import importlib.util
import io
import os
import socket
import sys
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "pr-reviewer-runs.py"

spec = importlib.util.spec_from_file_location("pr_reviewer_runs", SCRIPT_PATH)
assert spec and spec.loader
pr_reviewer_runs = importlib.util.module_from_spec(spec)
sys.modules["pr_reviewer_runs"] = pr_reviewer_runs
spec.loader.exec_module(pr_reviewer_runs)


class PRReviewerRunsTests(unittest.TestCase):
    def test_print_report_uses_reviewrun_buckets_and_separate_projection_audit(self) -> None:
        payload = {
            "ok": False,
            "health": "unhealthy",
            "repo": "fairchild/workspaces",
            "windowMinutes": 90,
            "eligibleEvents": 3,
            "candidateRunKeys": 3,
            "eligibleRunKeys": 2,
            "terminalRunKeys": 1,
            "supersededTriggerRunKeys": 0,
            "missingRunKeys": 1,
            "attentionRequired": 2,
            "starting": 0,
            "stuckStarting": 0,
            "running": 0,
            "runningTooLong": 1,
            "completedAwaitingProjection": 1,
            "failedExecution": 0,
            "projectionFailed": 1,
            "superseded": 1,
            "published": 4,
            "failedRunCount": 0,
            "projectionFailedCount": 1,
            "staleOrSupersededCount": 2,
            "slo": {
                "pickupTimeoutMinutes": 5,
                "runningTimeoutMinutes": 45,
                "projectionTimeoutMinutes": 30,
                "maxPickupLatencyMinutes": 4,
                "maxExecutionDurationMinutes": 53,
                "maxProjectionLatencyMinutes": 31,
            },
            "githubProjectionAudit": {
                "status": "not_checked",
                "script": "scripts/pr-review-health.py",
            },
            "missing": [
                {
                    "key": "fairchild/workspaces|590|abc123",
                    "eventCount": 2,
                    "prNumber": 590,
                    "triggerKind": "synchronize",
                    "headSha": "abc123456",
                }
            ],
            "runs": {
                "runningTooLong": [
                    {
                        "prNumber": 590,
                        "shortHeadSha": "abc1234",
                        "state": "running_too_long",
                        "agentStatus": "started",
                        "projectionStatus": "pending",
                        "ageMinutes": 53,
                        "executionDurationMinutes": 53,
                        "sloBreached": True,
                        "sessionId": "sesn_slow",
                        "detailsUrl": "https://spaces.cloudcompute.com/dashboard/review-runs/fp_slow",
                    }
                ],
                "completedAwaitingProjection": [],
                "projectionFailed": [],
                "superseded": [],
            },
        }

        output = io.StringIO()
        with redirect_stdout(output):
            pr_reviewer_runs.print_report(503, payload)

        rendered = output.getvalue()
        self.assertIn("ReviewRun report for fairchild/workspaces over 90m: unhealthy", rendered)
        self.assertIn(
            "events eligible=3 candidate_keys=3 run_keys=2 terminal_keys=1 superseded_keys=0 missing_keys=1 attention=2",
            rendered,
        )
        self.assertIn("projectionFailed=1", rendered)
        self.assertIn("github projection audit: not_checked (scripts/pr-review-health.py)", rendered)
        self.assertIn("Missing ReviewRun keys:", rendered)
        self.assertIn("key=fairchild/workspaces|590|abc123 events=2", rendered)
        self.assertIn("Running too long:", rendered)
        self.assertIn("details: https://spaces.cloudcompute.com/dashboard/review-runs/fp_slow", rendered)
        self.assertIn("slo: breached", rendered)


class PRReviewerRunsTransportTests(unittest.TestCase):
    """A timeout/transport failure reaching the monitor is a structured transient
    outcome (exit EX_TEMPFAIL), not an uncaught traceback."""

    def _run_with_urlopen_error(self, error: Exception) -> tuple[int, str]:
        with (
            patch.dict(os.environ, {"WORKSPACES_WEBHOOK_CANARY_SECRET": "runs-secret"}),
            patch.object(
                pr_reviewer_runs.urllib.request, "urlopen", side_effect=error
            ),
            redirect_stderr(io.StringIO()) as stderr,
        ):
            code = pr_reviewer_runs.main([])
        return code, stderr.getvalue()

    def test_socket_timeout_returns_tempfail(self) -> None:
        code, stderr = self._run_with_urlopen_error(socket.timeout("timed out"))
        self.assertEqual(code, pr_reviewer_runs.EX_TEMPFAIL)
        self.assertIn("timed out", stderr)

    def test_timeout_error_returns_tempfail(self) -> None:
        code, _ = self._run_with_urlopen_error(TimeoutError("timed out"))
        self.assertEqual(code, pr_reviewer_runs.EX_TEMPFAIL)

    def test_url_error_returns_tempfail(self) -> None:
        code, stderr = self._run_with_urlopen_error(
            urllib.error.URLError("connection refused")
        )
        self.assertEqual(code, pr_reviewer_runs.EX_TEMPFAIL)
        self.assertIn("failed", stderr)


if __name__ == "__main__":
    unittest.main()
