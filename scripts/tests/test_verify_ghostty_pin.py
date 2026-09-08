#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests that `scripts/verify-ghostty-pin.sh` catches a framework built at the
wrong Ghostty commit.

Frameworks/GhosttyKit.xcframework is gitignored and expensive to build, so it
is copied between checkouts by hand. When the pin moved to upstream trunk
(#1564) the copies already on disk kept building against source that no longer
matched them, and an incremental Swift build across that change links stale
code rather than failing — the expensive way to find out.

The cases here are the states a checkout is actually found in: no framework at
all (a fresh worktree), a stamped framework that agrees with the pin, a stamped
one that does not, and the two unstamped shapes that predate stamping — one
whose archive name alone proves it is stale, one that can only be reported as
unverified.

The tests drive the real script over fixture directories, so they need no
network, no secrets, no Zig toolchain, and no built framework.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "verify-ghostty-pin.sh"
BUILD_GHOSTTYKIT = REPO_ROOT / "scripts" / "build-ghosttykit.sh"


def pin_manifest() -> dict[str, str]:
    out = subprocess.run(
        ["bash", str(BUILD_GHOSTTYKIT), "--print-pin"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return dict(line.split("=", 1) for line in out.strip().splitlines())


class VerifyGhosttyPinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = pin_manifest()
        cls.commit = cls.manifest["GHOSTTY_COMMIT"]
        cls.archive = cls.manifest["GHOSTTY_ARCHIVE_NAME"]
        cls.stamp_name = cls.manifest["GHOSTTY_PIN_STAMP_NAME"]

    def run_script(self, framework: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), str(framework)],
            capture_output=True,
            text=True,
        )

    def make_framework(self, root: Path, archive: str | None, stamp: str | None) -> Path:
        framework = root / "GhosttyKit.xcframework"
        slice_dir = framework / "macos-arm64"
        slice_dir.mkdir(parents=True)
        (framework / "Info.plist").write_text("<plist/>")
        if archive is not None:
            (slice_dir / archive).write_text("")
        if stamp is not None:
            (framework / self.stamp_name).write_text(stamp + "\n")
        return framework

    def test_manifest_exposes_every_constant_consumers_need(self) -> None:
        self.assertRegex(self.commit, r"^[0-9a-f]{40}$")
        self.assertTrue(self.archive.endswith(".a"))
        self.assertTrue(self.stamp_name.startswith("."))

    def test_absent_framework_names_both_ways_to_get_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_script(Path(tmp) / "GhosttyKit.xcframework")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no GhosttyKit.xcframework", result.stderr)
        self.assertIn("build-ghosttykit.sh", result.stderr)
        self.assertIn(self.commit, result.stderr)

    def test_stamp_matching_the_pin_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            framework = self.make_framework(Path(tmp), self.archive, self.commit)
            result = self.run_script(framework)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.commit, result.stdout)

    def test_stamp_from_another_commit_fails_naming_both(self) -> None:
        stale = "0" * 40
        with tempfile.TemporaryDirectory() as tmp:
            framework = self.make_framework(Path(tmp), self.archive, stale)
            result = self.run_script(framework)
        self.assertEqual(result.returncode, 1)
        self.assertIn(stale, result.stderr)
        self.assertIn(self.commit, result.stderr)

    def test_unstamped_framework_with_an_older_archive_name_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            framework = self.make_framework(Path(tmp), "libghostty-fat.a", None)
            result = self.run_script(framework)
        self.assertEqual(result.returncode, 1)
        self.assertIn("libghostty-fat.a", result.stderr)
        self.assertIn(self.archive, result.stderr)

    def test_unstamped_framework_at_the_current_archive_warns_but_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            framework = self.make_framework(Path(tmp), self.archive, None)
            result = self.run_script(framework)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no pin stamp", result.stdout)

    def test_empty_framework_directory_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            framework = self.make_framework(Path(tmp), None, None)
            result = self.run_script(framework)
        self.assertEqual(result.returncode, 1)
        self.assertIn(self.archive, result.stderr)


if __name__ == "__main__":
    unittest.main()
