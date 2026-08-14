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

    def test_perf_gate_grades_the_version_being_built(self) -> None:
        # A dispatch from main has no tag to pass. Feeding the gate the ref
        # meant it graded the literal string HEAD, which sits one release past
        # the tag it rehearses — so the rehearsal blocked where the release
        # itself passed.
        step = self.release_step("Verify release performance benchmarks are current")
        self.assertIn("--tag \"$(./scripts/release-version.sh print-tag)\"", step)
        self.assertNotIn("github.ref_name", step)
        self.assertNotIn("HEAD", step)

    @staticmethod
    def release_step(name: str) -> str:
        """One step's YAML, so a failure prints the step and not the workflow."""
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text()
        _, _, after = workflow.partition(f"- name: {name}\n")
        assert after, f"no step named {name!r} in release.yml"
        return after.split("      - ", 1)[0]


if __name__ == "__main__":
    unittest.main()
