#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Argument-parser tests for `scripts/verify-release-bundle.sh`.

The verifier takes exactly one app bundle path, and its argument loop has to
decide "do I already hold one?". A wrong answer there is not a usability bug:
this script is the last assertion between a mis-built bundle and a signed
release, so accepting a second path means verifying something other than the
bundle the caller named while still reporting success (#1534, out of #1498).
Nothing covered the loop before this file.

The tests drive the real script through `bash` and read only the argument
boundary, so they need no network, no secrets, no UI access, no live GitHub
mutation, and no built app bundle. One test needs a macOS host because it
builds a complete unsigned bundle and runs the structure assertions over it;
it skips where PlistBuddy is absent, which is the Linux CI runner.
"""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "verify-release-bundle.sh"
PLIST_BUDDY = Path("/usr/libexec/PlistBuddy")

# Assertions the script can only reach once its argument loop has accepted a
# bundle path. `usage` never prints alongside them, so this list separates
# "rejected while parsing" from "parsed, then went on to verify" without
# needing a real bundle or a macOS host. PlistBuddy is the first of them and
# is the one a Linux runner stops at.
POST_PARSE_MARKERS = (
    "PlistBuddy not found",
    "App bundle not found",
    "must be named WorkSpaces.app",
    "Missing Info.plist",
)

# A path that does not exist, so an accepted parse stops at the first
# post-parse assertion instead of reading anything on disk.
ABSENT_BUNDLE = "/nonexistent/verify-release-bundle-test/WorkSpaces.app"


def run_verifier(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(SCRIPT_PATH), *args],
        check=False,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
    )


class VerifierArgumentTestCase(unittest.TestCase):
    def assert_rejected_while_parsing(self, result: subprocess.CompletedProcess[str]) -> None:
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"expected a non-zero exit\n{output}")
        self.assertIn("Usage:", output, f"expected the argument loop's usage text\n{output}")
        reached = [marker for marker in POST_PARSE_MARKERS if marker in output]
        self.assertEqual(
            reached,
            [],
            "the arguments were accepted and verification began: "
            f"{reached}\n{output}",
        )

    def assert_reached_verification(self, result: subprocess.CompletedProcess[str]) -> None:
        output = result.stdout + result.stderr
        self.assertNotIn("Usage:", output, f"the argument loop rejected the call\n{output}")
        reached = [marker for marker in POST_PARSE_MARKERS if marker in output]
        self.assertNotEqual(
            reached,
            [],
            f"expected a post-parse assertion to run\n{output}",
        )


class EmptyPositionalTests(VerifierArgumentTestCase):
    """The defect #1534 tracks, plus the guarantee it broke.

    `[[ -z "$APP_BUNDLE" ]]` treats an assigned empty string as "no path yet",
    so an empty first positional leaves the slot open and a second path takes
    it. The `[[ $# -eq 1 ]]` check that #1498 replaced rejected any two
    arguments, which is the behaviour these pin back down.

    No caller in this repository can produce the shape today: `ci.yml` and
    `release.yml` pass a literal path, and `build-release.sh` assigns
    `APP_BUNDLE` unconditionally at line 40 to a value ending in `.app`. So
    this restores a guarantee to a release gate rather than closing a live
    bug, and these are what keep it restored.
    """

    def test_an_empty_first_positional_does_not_let_a_second_path_through(self) -> None:
        self.assert_rejected_while_parsing(run_verifier("", ABSENT_BUNDLE))

    def test_an_empty_first_positional_is_rejected_after_a_flag(self) -> None:
        self.assert_rejected_while_parsing(run_verifier("--structure-only", "", ABSENT_BUNDLE))

    def test_an_empty_positional_on_its_own_is_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier(""))

    def test_two_empty_positionals_are_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier("", ""))

    def test_an_empty_second_positional_is_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier(ABSENT_BUNDLE, ""))

    def test_two_bundle_paths_are_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier(ABSENT_BUNDLE, ABSENT_BUNDLE))

    def test_no_arguments_are_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier())


class AcceptedArgumentTests(VerifierArgumentTestCase):
    """What the fix must leave alone: every call shape that parsed before."""

    def test_one_bundle_path_is_still_accepted(self) -> None:
        self.assert_reached_verification(run_verifier(ABSENT_BUNDLE))

    def test_structure_only_before_the_path_still_parses(self) -> None:
        self.assert_reached_verification(run_verifier("--structure-only", ABSENT_BUNDLE))

    def test_structure_only_after_the_path_still_parses(self) -> None:
        self.assert_reached_verification(run_verifier(ABSENT_BUNDLE, "--structure-only"))

    def test_help_after_an_empty_positional_still_answers(self) -> None:
        """`"" --help` printed help and exited 0 before the fix.

        Rejecting the empty path where the loop takes it would have made this
        exit 1, which is why emptiness is judged after the loop instead. Found
        by review, not by design.
        """
        for args in (("", "--help"), ("--structure-only", "", "--help")):
            with self.subTest(args=args):
                result = run_verifier(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Usage:", result.stdout)

    def test_help_prints_usage_and_exits_zero(self) -> None:
        result = run_verifier("--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Usage:", result.stdout)

    def test_an_unknown_flag_is_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier("--no-such-flag", ABSENT_BUNDLE))


@unittest.skipUnless(
    PLIST_BUDDY.is_file(), f"{PLIST_BUDDY} is macOS-only; the structure assertions need it"
)
class StructureOnlyOverARealBundleTests(unittest.TestCase):
    """The parser boundary read from the other side, on a bundle that passes.

    Every assertion above stops at a failure, which cannot distinguish "the
    second path was rejected" from "the second path was verified and found
    wanting". Against a bundle the structure lane accepts, the pre-fix script
    exits **zero** on a call naming two paths — it verified the one it was
    never given cleanly. That is the failure in its plainest form, and it is
    also the only test here that proves `--structure-only` still does its job
    rather than merely parsing.
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="VerifyReleaseBundleTests-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bundle = build_structurally_valid_bundle(self.root)

    def test_a_complete_unsigned_bundle_passes_structure_only(self) -> None:
        result = run_verifier("--structure-only", str(self.bundle))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Verified release bundle structure", result.stdout)

    def test_an_empty_first_positional_never_verifies_the_bundle(self) -> None:
        result = run_verifier("--structure-only", "", str(self.bundle))
        self.assertNotEqual(
            result.returncode,
            0,
            "the empty first positional let the second path through and it "
            f"verified clean\n{result.stdout}{result.stderr}",
        )
        self.assertNotIn("Verified release bundle structure", result.stdout)


def build_structurally_valid_bundle(root: Path) -> Path:
    """A bundle carrying exactly what the structure assertions require."""
    bundle = root / "WorkSpaces.app"
    contents = bundle / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    (resources / "ghostty").mkdir(parents=True)
    (resources / "terminfo" / "78").mkdir(parents=True)
    (resources / "HookForwarders").mkdir(parents=True)

    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleDisplayName": "WorkSpaces",
                "CFBundleName": "WorkSpaces",
                "CFBundleExecutable": "WorkspaceManager",
            },
            handle,
        )

    executable = contents / "MacOS" / "WorkspaceManager"
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o755)

    (resources / "terminfo" / "78" / "xterm-ghostty").write_bytes(b"\x1a\x01")
    for forwarder in ("event-forwarder.sh", "statusline.sh"):
        (resources / "HookForwarders" / forwarder).write_text("#!/bin/sh\n", encoding="utf-8")

    return bundle


if __name__ == "__main__":
    unittest.main()
