#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests that `scripts/verify-release-bundle.sh` cannot report an unearned pass.

This script is the last assertion between a mis-built bundle and a signed
release, so the failure that matters is not a crash — it is exit 0 without
having looked at the thing it was asked to verify. Two routes to that shape
are covered here.

The first is its argument loop, which has to decide "do I already hold a
path?". Answering with `[[ -z "$APP_BUNDLE" ]]` read an assigned empty string
as "not set", so a second path claimed the slot and was verified in place of
the one named (#1534, out of #1498).

The second is the exit status itself (#1562). `/bin/bash` on macOS is 3.2.57,
and on its `set -u` fatal path the status reaching the EXIT trap is already
zero, so an abort is indistinguishable from a clean run — the script exited 0
having run no assertion at all. These tests therefore run the script under
`/bin/bash` specifically; under bash 5 the same aborts already exit 1.

The tests drive the real script and read either the argument boundary or the
exit status, so they need no network, no secrets, no UI access, no live GitHub
mutation, and no built app bundle. Four need a macOS host because they build a
complete unsigned bundle and run the structure assertions over it; all four
skip where PlistBuddy is absent, which is the Linux CI runner — where this
file reports 24 tests with 4 skipped.
"""

from __future__ import annotations

import os
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


def run_verifier(
    *args: str,
    env: dict[str, str] | None = None,
    script: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run the verifier under `/bin/bash` — the shell the defect needs.

    macOS ships bash 3.2.57 there, and the release lane and every local run
    reach the script through it. Running these under a modern bash would pass
    for the wrong reason.
    """
    return subprocess.run(
        ["/bin/bash", str(script or SCRIPT_PATH), *args],
        check=False,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        env=env,
    )


def environment_without_home() -> dict[str, str]:
    env = dict(os.environ)
    env.pop("HOME", None)
    return env


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

    def test_help_does_not_rescue_a_call_that_already_named_two_paths(self) -> None:
        """The one shape where `--help` stops answering, and deliberately.

        `"" <path> --help` exits 0 on `main` — the empty positional leaves the
        slot open, the real path fills it, and `--help` is reached. That is the
        defect wearing a help flag. The second positional is rejected where it
        is seen, so `--help` behind it is never read. Rejecting a call that
        named two paths outranks answering a help flag buried after them.
        """
        for args in (("", ABSENT_BUNDLE, "--help"), ("--structure-only", "", ABSENT_BUNDLE, "-h")):
            with self.subTest(args=args):
                self.assert_rejected_while_parsing(run_verifier(*args))

    def test_help_prints_usage_and_exits_zero(self) -> None:
        result = run_verifier("--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Usage:", result.stdout)

    def test_an_unknown_flag_is_rejected(self) -> None:
        self.assert_rejected_while_parsing(run_verifier("--no-such-flag", ABSENT_BUNDLE))


class FailClosedUnderTheSystemBashTests(VerifierArgumentTestCase):
    r"""#1562: an abort under macOS bash 3.2 read as a clean pass.

    Measured rather than inferred. An unbound-variable abort under
    `/bin/bash` exits 1 with no EXIT trap installed, but the status handed to
    an EXIT trap on that path is already 0, and bash keeps that 0 unless the
    trap says otherwise. Bash 5 hands the trap 1. So preserving `$?` in
    `cleanup` preserves a zero and changes nothing; a zero exit has to be
    earned instead, by reaching one of the three places that mean success.

    `${APP_BUNDLE/#\~/$HOME}` at line 195 was one such abort, and it read
    `$HOME` for every path rather than only a tilde-prefixed one, so any
    invocation without `HOME` exited 0 without reaching `-d`,
    `verify_bundle_identity`, or a single signing assertion.
    """

    def test_an_unset_home_does_not_pass_a_tilde_path_unverified(self) -> None:
        result = run_verifier(
            "--structure-only",
            "~/nonexistent/WorkSpaces.app",
            env=environment_without_home(),
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"the verifier reported success\n{output}")
        self.assertIn("HOME", output, output)

    def test_an_unset_home_no_longer_stops_an_absolute_path(self) -> None:
        """The guard is on the tilde branch, not on the whole run.

        `ci.yml`, `release.yml`, and `build-release.sh` all pass an absolute
        path, which needs no `HOME` at all. Before the fix they aborted anyway,
        because the replacement expanded `$HOME` unconditionally.
        """
        result = run_verifier(
            "--structure-only", ABSENT_BUNDLE, env=environment_without_home()
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_reached_verification(result)

    def test_help_still_exits_zero_without_home(self) -> None:
        """The control: a deliberate exit 0 is still an exit 0."""
        result = run_verifier("--help", env=environment_without_home())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Usage:", result.stdout)

    def test_a_normal_invocation_with_home_set_is_unchanged(self) -> None:
        result = run_verifier("--structure-only", ABSENT_BUNDLE)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_reached_verification(result)

    def test_a_set_u_abort_in_the_body_is_not_reported_as_success(self) -> None:
        """The class, not the instance.

        Guarding `$HOME` closes today's abort. This asserts the next one is
        closed too: an unbound variable injected into the body must not reach
        exit 0, whoever adds it.
        """
        with tempfile.TemporaryDirectory(prefix="VerifyReleaseBundleAbort-") as root:
            script = script_with_injected_abort(
                Path(root), 'echo "${VERIFY_RELEASE_BUNDLE_UNSET_PROBE}"'
            )
            result = run_verifier("--structure-only", ABSENT_BUNDLE, script=script)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"an abort exited 0\n{output}")
        self.assertIn("refusing to report success", output, output)

    def test_a_set_e_abort_in_the_body_is_not_reported_as_success(self) -> None:
        """The other abort path, which was already sound.

        The issue read the trap as losing the status for `set -e` too. It does
        not: bash 3.2 carries a `set -e` abort out as 1 whether or not
        `cleanup` preserves `$?`. This pins that, so a later change to the
        trap cannot quietly break the half that worked.
        """
        with tempfile.TemporaryDirectory(prefix="VerifyReleaseBundleAbort-") as root:
            script = script_with_injected_abort(Path(root), "false")
            result = run_verifier("--structure-only", ABSENT_BUNDLE, script=script)
        self.assertNotEqual(
            result.returncode, 0, f"an abort exited 0\n{result.stdout}{result.stderr}"
        )


def script_with_injected_abort(root: Path, statement: str) -> Path:
    """A copy of the verifier that aborts right after its EXIT trap is armed.

    Injecting into a copy rather than asserting on today's one abort is what
    makes the test about the failure class. The statement lands after the trap
    so the trap is what has to carry the status out.
    """
    source = SCRIPT_PATH.read_text(encoding="utf-8")
    anchor = "trap cleanup EXIT\n"
    if anchor not in source:
        raise AssertionError(f"{SCRIPT_PATH} no longer arms its EXIT trap as expected")
    script = root / "verify-release-bundle.sh"
    script.write_text(source.replace(anchor, f"{anchor}{statement}\n", 1), encoding="utf-8")
    script.chmod(0o755)
    return script


@unittest.skipUnless(
    PLIST_BUDDY.is_file(), f"{PLIST_BUDDY} is macOS-only; the structure assertions need it"
)
class StructureOnlyOverARealBundleTests(unittest.TestCase):
    """The defect read from the other side, on a bundle that passes.

    The marker assertions above do separate rejection from verification, and
    they are red against `main` on their own. What they cannot show is the
    shape of the failure: against a bundle the structure lane accepts, the
    pre-fix script exits **zero** on a call naming two paths, having verified
    the one it was never given and said so. A gate that passes while looking
    at the wrong thing is the reason this issue is worth fixing, and only a
    bundle that passes can demonstrate it.
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="VerifyReleaseBundleTests-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bundle = build_structurally_valid_bundle(self.root)

    def test_a_complete_unsigned_bundle_passes_structure_only(self) -> None:
        result = run_verifier("--structure-only", str(self.bundle))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Verified release bundle structure", result.stdout)

    def test_a_complete_unsigned_bundle_passes_structure_only_without_home(self) -> None:
        """A `HOME`-less environment verifies for real now, instead of exiting 0 blind.

        Same bundle, same assertions, same exit 0 — but reached by running
        them. Before the fix this exit 0 meant the opposite of what it says.
        """
        result = run_verifier(
            "--structure-only", str(self.bundle), env=environment_without_home()
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Verified release bundle structure", result.stdout)

    def test_a_tilde_path_still_expands_against_home(self) -> None:
        """The expansion the guard wraps still expands."""
        env = dict(os.environ)
        env["HOME"] = str(self.root)
        result = run_verifier("--structure-only", "~/WorkSpaces.app", env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(str(self.bundle), result.stdout)

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
