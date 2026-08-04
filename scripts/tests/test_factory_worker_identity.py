#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for scripts/factory-worker-identity.sh.

Runs the real script under `bash -c 'source ...'` with a controlled
environment (subprocess, no network) and asserts on exit code, stdout/stderr,
and whether GH_TOKEN ends up exported in the caller's shell — the actual
contract the script promises. Covers the two bugs a codex review caught
(#1180): sourcing it must not leak `set -u`/`set -o pipefail` into the
caller even on the no-op path, and it must fail loudly rather than report
success when FACTORY_WORKER_IDENTITY=app is set but minting fails.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "factory-worker-identity.sh"


def run_sourced(overrides: dict[str, str], *, extra_after: str = "") -> subprocess.CompletedProcess[str]:
    """Source the script in a clean subshell and report on the caller's state."""
    command = f"""
set +u +o pipefail
before_nounset=$(set -o | awk '$1=="nounset"{{print $2}}')
before_pipefail=$(set -o | awk '$1=="pipefail"{{print $2}}')
source "{SCRIPT}"
status=$?
after_nounset=$(set -o | awk '$1=="nounset"{{print $2}}')
after_pipefail=$(set -o | awk '$1=="pipefail"{{print $2}}')
echo "STATUS=$status"
echo "GH_TOKEN_SET=${{GH_TOKEN:+yes}}"
echo "NOUNSET_BEFORE=$before_nounset"
echo "NOUNSET_AFTER=$after_nounset"
echo "PIPEFAIL_BEFORE=$before_pipefail"
echo "PIPEFAIL_AFTER=$after_pipefail"
{extra_after}
"""
    clean_env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"FACTORY_WORKER_IDENTITY", "FACTORY_WORKER_APP_ID", "FACTORY_WORKER_APP_KEY", "FACTORY_WORKER_BOT_EMAIL", "GH_TOKEN"}
    }
    return subprocess.run(
        ["bash", "-c", command],
        cwd=REPO_ROOT,
        env={**clean_env, **overrides},
        capture_output=True,
        text=True,
        timeout=30,
    )


def parse_markers(stdout: str) -> dict[str, str]:
    markers = {}
    for line in stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            markers[key] = value
    return markers


class NoOpTests(unittest.TestCase):
    def test_unset_flag_is_a_true_no_op(self):
        result = run_sourced({})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "0")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])

    def test_non_app_value_is_also_a_no_op(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "owner"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "0")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])


class AppModeWithoutCredentialsTests(unittest.TestCase):
    def test_fails_loudly_and_does_not_export_gh_token(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "app"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "1")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertIn("minting a workspaces-factory token failed", result.stderr)

    def test_does_not_leak_shell_options_either(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "app"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])


if __name__ == "__main__":
    unittest.main()
