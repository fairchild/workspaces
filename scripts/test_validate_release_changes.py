#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/validate-release-changes.py."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate-release-changes.py"

spec = importlib.util.spec_from_file_location("validate_release_changes", SCRIPT_PATH)
assert spec and spec.loader
validate_release_changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate_release_changes)


class ValidateReleaseChangesTests(unittest.TestCase):
    def test_filters_to_release_sensitive_files(self) -> None:
        files = validate_release_changes.release_files(
            [
                "README.md",
                ".github/workflows/release.yml",
                "scripts/generate-sparkle-appcast.sh",
                "scripts/install-local.sh",
                "scripts/notarize.sh",
                "scripts/release-preflight.sh",
                "scripts/verify-installed-perf.sh",
                "scripts/unrelated.sh",
            ]
        )
        self.assertEqual(
            files,
            [
                ".github/workflows/release.yml",
                "scripts/generate-sparkle-appcast.sh",
                "scripts/install-local.sh",
                "scripts/notarize.sh",
                "scripts/release-preflight.sh",
                "scripts/verify-installed-perf.sh",
            ],
        )

    def test_no_release_files_returns_empty(self) -> None:
        self.assertEqual(validate_release_changes.release_files(["README.md"]), [])


if __name__ == "__main__":
    unittest.main()
