#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyjwt[crypto]>=2.8",
# ]
# ///
"""Regression tests for bounded, redacted Xcode Cloud log failure excerpts."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "fetch-xcode-cloud-logs.py"

spec = importlib.util.spec_from_file_location("fetch_xcode_cloud_logs", SCRIPT_PATH)
assert spec and spec.loader
logs = importlib.util.module_from_spec(spec)
sys.modules["fetch_xcode_cloud_logs"] = logs
spec.loader.exec_module(logs)


class ExcerptTests(unittest.TestCase):
    def test_interesting_log_keeps_early_failure_context_bounded_and_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "ci_post_clone.log"
            path.write_text(
                "setup begins\n"
                "uv: command not found\n"
                "token=private-value\n"
                "setup aborts\n"
                + "\n".join(f"tail line {index}" for index in range(logs.TAIL_LINES + 10))
            )

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                logs.excerpt(path)

        rendered = output.getvalue()
        self.assertIn("failure context", rendered)
        self.assertIn("uv: command not found", rendered)
        self.assertIn("token= <redacted>", rendered)
        self.assertNotIn("private-value", rendered)
        self.assertIn(f"tail -{logs.TAIL_LINES}", rendered)
        self.assertLessEqual(len(rendered.splitlines()), logs.TAIL_LINES + 12)

    def test_runtime_failure_wins_over_hundreds_of_successful_test_names(self) -> None:
        lines = [f'✔ Test "error behavior {index}" passed' for index in range(300)]
        runtime_index = len(lines)
        lines.extend(["setup begins", "env: uv: No such file or directory", "setup aborts"])

        contexts = logs.failure_contexts(lines, before=len(lines))

        self.assertTrue(any(start <= runtime_index < end for start, end in contexts))
        self.assertLessEqual(len(contexts), logs.MAX_FAILURE_CONTEXTS)

    def test_zero_before_means_no_lines_before_the_tail(self) -> None:
        self.assertEqual(logs.failure_contexts(["env: uv: No such file or directory"], before=0), [])


if __name__ == "__main__":
    unittest.main()
