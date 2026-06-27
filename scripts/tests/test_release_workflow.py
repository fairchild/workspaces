#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Release workflow contract tests."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_manual_main_dispatch_is_tester_prerelease_only(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text()
        for expected in (
            "workflow_dispatch:",
            "Manual Release dispatch from main publishes tester prerelease",
            "push or dispatch a v<version> tag for stable releases",
            'TAG="workspaces-v${VERSION}-main.${GITHUB_RUN_NUMBER}"',
            "--prerelease",
            "--latest=false",
        ):
            self.assertIn(expected, workflow)
        self.assertNotIn("release_channel", workflow)
        self.assertNotIn("refresh-stable-assets", workflow)


if __name__ == "__main__":
    unittest.main()
