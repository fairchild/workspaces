#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests that `scripts/build-release.sh` fails the build when a resource tree
does not make it into the app bundle.

The bundle's resources arrive as whole directories copied from elsewhere: SPM's
generated resource bundle (PrivacyInfo, the asset catalog, the Claude hook
forwarders) and Ghostty's `share` tree (the shell integration files and the
compiled terminfo entry the terminal needs). Both copies discarded stderr and
forced exit zero, then logged success, so a copy that moved nothing produced an
app that builds clean, packages clean, and misbehaves at runtime — the failure
only became visible in `verify-release-bundle.sh`, which until #1498 ran after
signing, on a tag (#1502).

`build-release.sh` runs its work at the top level, so it cannot be sourced.
These tests lift `copy_tree_or_fail` and the logging helpers it calls out of the
real script by name and run them under bash against throwaway directories:
no build, no network, no signing material, no repo state touched. The last case
is a text assertion instead, because the wiring — that the two resource copies
actually route through the helper — is not reachable from the helper itself;
the end-to-end `./scripts/build-release.sh --no-sign` in the PR's evidence is
what proves the wired script still produces a complete bundle.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "build-release.sh"
SCRIPT_SOURCE = SCRIPT_PATH.read_text(encoding="utf-8")

# The helper under test plus everything it calls. Extraction is by name, and a
# missing name raises rather than silently testing a shorter harness.
HARNESS_FUNCTIONS = ("log_success", "log_warning", "log_error", "fail", "copy_tree_or_fail")


def bash_function(name: str) -> str:
    """Return the text of a top-level `name() { ... }` definition."""
    lines = SCRIPT_SOURCE.splitlines()
    opener = f"{name}() {{"
    starts = [i for i, line in enumerate(lines) if line.startswith(opener)]
    if not starts:
        raise AssertionError(f"{SCRIPT_PATH.name} defines no top-level {opener}")
    start = starts[0]
    for index in range(start + 1, len(lines)):
        if lines[index] == "}":
            return "\n".join(lines[start : index + 1])
    raise AssertionError(f"{opener} in {SCRIPT_PATH.name} is never closed at column 0")


def harness() -> str:
    definitions = "\n\n".join(bash_function(name) for name in HARNESS_FUNCTIONS)
    # Colours are emptied so assertions read the message, not the escapes.
    return f"""
set -e
set -o pipefail
RED=''
GREEN=''
YELLOW=''
BLUE=''
NC=''

{definitions}

copy_tree_or_fail "$1" "$2" "$3"
"""


class CopyTreeOrFailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.src = self.root / "source"
        self.dst = self.root / "Resources"
        self.src.mkdir()
        self.dst.mkdir()
        self.addCleanup(self.tmp.cleanup)

    def run_copy(self, src: Path, dst: Path, label: str = "Copied test resources") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", harness(), "copy_tree_or_fail", str(src), str(dst), label],
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_an_empty_source_directory_fails_the_build(self) -> None:
        result = self.run_copy(self.src, self.dst)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("empty", output)
        self.assertIn(str(self.src), output)
        self.assertIn(str(self.dst), output)
        self.assertNotIn("Copied test resources\n", result.stdout)

    def test_a_populated_source_lands_in_the_destination(self) -> None:
        (self.src / "HookForwarders").mkdir()
        (self.src / "HookForwarders" / "statusline.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (self.src / "PrivacyInfo.xcprivacy").write_text("<plist/>\n", encoding="utf-8")

        result = self.run_copy(self.src, self.dst)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.dst / "HookForwarders" / "statusline.sh").is_file())
        self.assertTrue((self.dst / "PrivacyInfo.xcprivacy").is_file())
        self.assertIn("Copied test resources", result.stdout)

    def test_dotfiles_at_the_top_of_the_source_are_copied_too(self) -> None:
        """The emptiness guard counts dotfiles, so the copy has to move them:
        a `$src/*` glob would pass the guard on a mixed tree and then leave the
        dotfiles behind, reporting success for a partial copy."""
        (self.src / ".resource-manifest").write_text("v1\n", encoding="utf-8")
        (self.src / "ghostty").mkdir()
        (self.src / "ghostty" / "shell-integration").write_text("# integration\n", encoding="utf-8")

        result = self.run_copy(self.src, self.dst)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.dst / "ghostty" / "shell-integration").is_file())
        self.assertTrue((self.dst / ".resource-manifest").is_file())

    def test_a_copy_that_cannot_write_fails_the_build(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root writes through the permission bits this case depends on")
        (self.src / "terminfo").mkdir()
        (self.src / "terminfo" / "xterm-ghostty").write_bytes(b"\x1a\x01")
        self.dst.chmod(0o555)
        self.addCleanup(self.dst.chmod, 0o755)

        result = self.run_copy(self.src, self.dst)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(str(self.src), output)
        self.assertIn(str(self.dst), output)

    def test_a_missing_source_directory_fails_the_build(self) -> None:
        missing = self.root / "never-built"
        result = self.run_copy(missing, self.dst)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(str(missing), output)
        self.assertIn(str(self.dst), output)

    def test_a_missing_destination_directory_fails_the_build(self) -> None:
        (self.src / "ghostty").mkdir()
        missing = self.root / "no-bundle" / "Resources"
        result = self.run_copy(self.src, missing)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(str(missing), output)


class ResourceCopyCallSiteTests(unittest.TestCase):
    """The helper only protects the bundle if the resource copies use it."""

    def test_both_resource_trees_are_copied_through_the_helper(self) -> None:
        calls = [line.strip() for line in SCRIPT_SOURCE.splitlines() if line.strip().startswith("copy_tree_or_fail ")]
        self.assertEqual(len(calls), 2, f"expected the SPM and Ghostty copies, found: {calls}")
        self.assertTrue(any("SPM_RESOURCES" in call for call in calls), calls)
        self.assertTrue(any("GHOSTTY_SHARE_DIR_RESOLVED" in call for call in calls), calls)

    def test_the_spm_copy_is_unconditional(self) -> None:
        """Routing through the helper is not enough on its own: wrapping the call
        in `if [[ -d "$SPM_RESOURCES" ]]` restores the original skip while every
        other assertion here still passes. The SPM copy therefore has to sit at
        column zero, outside any branch, and nothing may test that path for
        existence."""
        lines = SCRIPT_SOURCE.splitlines()
        spm_calls = [line for line in lines if line.startswith("copy_tree_or_fail \"$SPM_RESOURCES\"")]
        self.assertEqual(len(spm_calls), 1, f"the SPM copy is indented, so it sits inside a branch: {spm_calls}")
        guards = [line.strip() for line in lines if "-d" in line and "SPM_RESOURCES" in line]
        self.assertEqual(guards, [], f"the SPM bundle is guarded by an existence test again: {guards}")

    def test_no_tree_copy_forces_success(self) -> None:
        offenders = [
            line.strip()
            for line in SCRIPT_SOURCE.splitlines()
            if line.strip().startswith("cp -R ") and line.strip().endswith("|| true")
        ]
        self.assertEqual(offenders, [], f"a tree copy still swallows its failure: {offenders}")


if __name__ == "__main__":
    unittest.main()
