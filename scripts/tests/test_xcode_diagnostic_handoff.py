#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]>=2.8"]
# ///
"""Tests for the raw-log-free Xcode diagnostic handoff manifest."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("xcode_logs", REPO_ROOT / "scripts/fetch-xcode-cloud-logs.py")
assert spec and spec.loader
logs = importlib.util.module_from_spec(spec)
sys.modules["xcode_logs"] = logs
spec.loader.exec_module(logs)

BUILD_ID = "11111111-1111-4111-8111-111111111111"
ACTION_ID = "22222222-2222-4222-8222-222222222222"
SHA = "a" * 40


class DiagnosticHandoffTests(unittest.TestCase):
    def test_emits_only_validated_missing_uv_ids_without_raw_log_text(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory, patch.dict(
            os.environ, {"GITHUB_RUN_ID": "123456"}, clear=False
        ):
            root = Path(temporary_directory)
            log = root / "ci_pre_xcodebuild.log"
            log.write_text("before\nenv: uv: No such file or directory\nsecret=do-not-export\n")

            observation = logs.diagnostic_observation(BUILD_ID, ACTION_ID, SHA, log)
            report_path = logs.write_diagnostic_report(root, [observation] if observation else [])
            serialized = report_path.read_text()
            report = json.loads(serialized)

        self.assertEqual(report["schema"], 1)
        self.assertEqual(report["repository"], "fairchild/workspaces")
        self.assertEqual(report["runId"], 123456)
        self.assertEqual(report["observations"], [observation])
        self.assertNotIn("do-not-export", serialized)

    def test_generic_exit_failure_does_not_create_a_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            log = Path(temporary_directory) / "ci_pre_xcodebuild.log"
            log.write_text("process exited with code 1\n")
            self.assertIsNone(logs.diagnostic_observation(BUILD_ID, ACTION_ID, SHA, log))

    def test_report_is_capped_below_eight_kib(self) -> None:
        observation = {
            "buildId": BUILD_ID,
            "actionId": ACTION_ID,
            "sha": SHA,
            "signature": "missing-uv",
            "stage": "ci_pre_xcodebuild",
        }
        with tempfile.TemporaryDirectory() as temporary_directory, patch.dict(
            os.environ, {"GITHUB_RUN_ID": "123456"}, clear=False
        ):
            report_path = logs.write_diagnostic_report(Path(temporary_directory), [observation] * 100)
            serialized = report_path.read_bytes()

        self.assertLessEqual(len(serialized), logs.MAX_DIAGNOSTIC_BYTES)
        self.assertEqual(len(json.loads(serialized)["observations"]), logs.MAX_DIAGNOSTIC_OBSERVATIONS)


if __name__ == "__main__":
    unittest.main()
