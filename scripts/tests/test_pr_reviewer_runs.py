#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the ReviewRun operator report renderer."""

from __future__ import annotations

import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path


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
            "eligibleRunKeys": 2,
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
        self.assertIn("events eligible=3 run_keys=2 missing_keys=1 attention=2", rendered)
        self.assertIn("projectionFailed=1", rendered)
        self.assertIn("github projection audit: not_checked (scripts/pr-review-health.py)", rendered)
        self.assertIn("Missing ReviewRun keys:", rendered)
        self.assertIn("key=fairchild/workspaces|590|abc123 events=2", rendered)
        self.assertIn("Running too long:", rendered)
        self.assertIn("details: https://spaces.cloudcompute.com/dashboard/review-runs/fp_slow", rendered)
        self.assertIn("slo: breached", rendered)


if __name__ == "__main__":
    unittest.main()
