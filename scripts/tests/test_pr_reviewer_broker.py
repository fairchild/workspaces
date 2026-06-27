#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit tests for the managed reviewer broker CLI wrapper."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "pr-reviewer-broker.py"


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location("pr_reviewer_broker", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PrReviewerBrokerTests(unittest.TestCase):
    def test_retryable_broker_error_returns_tempfail(self) -> None:
        script = load_script()
        with (
            patch.dict(
                os.environ,
                {"WORKSPACES_WEBHOOK_CANARY_SECRET": "broker-secret"},
            ),
            patch.object(
                script,
                "request_json",
                side_effect=script.BrokerError("read timed out", retryable=True),
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(script.main(["--json"]), script.EX_TEMPFAIL)
        self.assertIn("read timed out", stderr.getvalue())

    def test_nonretryable_broker_error_returns_failure(self) -> None:
        script = load_script()
        with (
            patch.dict(
                os.environ,
                {"WORKSPACES_WEBHOOK_CANARY_SECRET": "broker-secret"},
            ),
            patch.object(
                script,
                "request_json",
                side_effect=script.BrokerError("unauthorized", retryable=False),
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(script.main(["--json"]), 1)
        self.assertIn("unauthorized", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
