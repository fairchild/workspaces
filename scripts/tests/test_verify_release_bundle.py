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
complete unsigned bundle and run the structure assertions over it, and one
reads an error message that only a macOS host reaches; all ten skip where
PlistBuddy is absent, which is the Linux CI runner — where this file reports
31 tests with 10 skipped.
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

# Stem of the marker an injected abort prints just before it fires; each case
# appends its own suffix. Without it a test could pass on the exit code the
# argument alone produces, having never run the injection — which is what
# review found the `set -e` case doing. The marker alone is not enough either:
# a helper ignoring its statement still prints it, so each case also asserts
# the signature of the abort it means to exercise.
ABORT_MARKER = "VERIFY_RELEASE_BUNDLE_INJECTION_REACHED"

# Enough of a Mach-O header for `file` to classify, and for a stub not to have to.
MACH_O_MAGIC = b"\xcf\xfa\xed\xfe"


def system_bash_zeroes_a_set_u_abort() -> bool:
    """Does `/bin/bash` hand its EXIT trap a zero after a `set -u` abort?

    True on macOS 3.2.57, false on bash 5 — measured here rather than
    branched on `sys.platform`, because it is the shell's behaviour that
    decides whether the script's sentinel has anything to do. Where this is
    false the abort already carries its own non-zero status out and the
    sentinel stays quiet, which is why the tests below assert the message
    only when it is true.
    """
    probe = 'cleanup() { :; }; trap cleanup EXIT; echo "${VERIFY_RELEASE_BUNDLE_PROBE}"'
    return (
        subprocess.run(
            ["/bin/bash", "-uc", probe],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        ).returncode
        == 0
    )


SYSTEM_BASH_ZEROES_A_SET_U_ABORT = system_bash_zeroes_a_set_u_abort()


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

    def run_with_injected_abort(
        self, statement: str, marker: str
    ) -> subprocess.CompletedProcess[str]:
        """Run a copy of the verifier that aborts, and prove the abort is why.

        `ABSENT_BUNDLE` exits non-zero on its own, so a bare status assertion
        would pass whether or not the injection ran. Requiring the marker
        proves it ran, and requiring that no post-parse assertion was reached
        proves it stopped the script rather than merely printing.
        """
        with tempfile.TemporaryDirectory(prefix="VerifyReleaseBundleAbort-") as root:
            script = script_with_injected_abort(Path(root), statement, marker)
            result = run_verifier("--structure-only", ABSENT_BUNDLE, script=script)
        output = result.stdout + result.stderr
        self.assertIn(marker, output, f"the injection never ran\n{output}")
        reached = [marker for marker in POST_PARSE_MARKERS if marker in output]
        self.assertEqual(reached, [], f"the abort did not stop the run: {reached}\n{output}")
        return result

    def test_an_empty_home_is_refused_rather_than_expanded(self) -> None:
        """`HOME=""` is refused, which `main` did not do — deliberately.

        The guard is `-n`, not `${HOME+x}`, so an assigned-but-empty `HOME` is
        rejected as well. On `main` it expanded: `~user/WorkSpaces.app` became
        the *relative* `user/WorkSpaces.app`, which resolved against the
        working directory and verified whatever it found there. Naming the
        wrong bundle and passing is the shape this script exists to refuse, so
        the difference is the point rather than a cost.
        """
        env = dict(os.environ)
        env["HOME"] = ""
        result = run_verifier("--structure-only", "~user/WorkSpaces.app", env=env)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_unset_home_does_not_pass_a_tilde_path_unverified(self) -> None:
        """Runs everywhere; only red against `main` where bash 3.2 is `/bin/bash`.

        On a host without PlistBuddy the run stops earlier, at the tool check,
        which is a non-zero exit for a different reason. That still holds the
        line this test is about — the verifier must not report success — so
        the exit status is asserted here and the cause below.
        """
        result = run_verifier(
            "--structure-only",
            "~/nonexistent/WorkSpaces.app",
            env=environment_without_home(),
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"the verifier reported success\n{output}")

    @unittest.skipUnless(
        PLIST_BUDDY.is_file(), f"{PLIST_BUDDY} is macOS-only; the HOME guard sits after it"
    )
    def test_an_unset_home_names_home_as_the_cause(self) -> None:
        empty_home = dict(os.environ)
        empty_home["HOME"] = ""
        for label, env in (("unset", environment_without_home()), ("empty", empty_home)):
            with self.subTest(home=label):
                result = run_verifier(
                    "--structure-only", "~/nonexistent/WorkSpaces.app", env=env
                )
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn("HOME is not set", output, output)

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

        Where `/bin/bash` is 3.2 the sentinel is the only thing holding this,
        so its message is asserted as well; where `/bin/bash` is 5 the abort
        carries its own status out and the sentinel correctly says nothing.
        The probe decides which, so this reads the same defect on both.
        """
        result = self.run_with_injected_abort(
            'echo "${VERIFY_RELEASE_BUNDLE_UNSET_PROBE}"', f"{ABORT_MARKER}_SET_U"
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"an abort exited 0\n{output}")
        self.assertIn("unbound variable", output, f"this was not a `set -u` abort\n{output}")
        if SYSTEM_BASH_ZEROES_A_SET_U_ABORT:
            self.assertIn("refusing to report success", output, output)

    def test_a_set_e_abort_in_the_body_is_not_reported_as_success(self) -> None:
        """The other abort path, which was already sound.

        The issue read the trap as losing the status for `set -e` too. It does
        not: bash 3.2 carries a `set -e` abort out as 1 whether or not
        `cleanup` preserves `$?`. This pins that, so a later change to the
        trap cannot quietly break the half that worked.
        """
        result = self.run_with_injected_abort("false", f"{ABORT_MARKER}_SET_E")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"an abort exited 0\n{output}")
        # Review's attack: a helper that ignored its statement and always
        # injected an unbound variable passed both cases. The marker cannot
        # catch that, because the marker is not the statement. This can.
        self.assertNotIn("unbound variable", output, f"this was not a `set -e` abort\n{output}")


def script_with_injected_abort(root: Path, statement: str, marker: str) -> Path:
    """A copy of the verifier that aborts right after its EXIT trap is armed.

    Injecting into a copy rather than asserting on today's one abort is what
    makes the test about the failure class. The statement lands after the trap
    so the trap is what has to carry the status out, and a marker goes in ahead
    of it so a test cannot pass on an exit code the injection never caused.
    """
    source = SCRIPT_PATH.read_text(encoding="utf-8")
    anchor = "trap cleanup EXIT\n"
    if anchor not in source:
        raise AssertionError(f"{SCRIPT_PATH} no longer arms its EXIT trap as expected")
    injection = f'echo "{marker}" >&2\n{statement}\n'
    script = root / "verify-release-bundle.sh"
    script.write_text(source.replace(anchor, f"{anchor}{injection}", 1), encoding="utf-8")
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


@unittest.skipUnless(
    PLIST_BUDDY.is_file(), f"{PLIST_BUDDY} is macOS-only; the structure assertions run first"
)
class SigningEnumerationTests(unittest.TestCase):
    """The one place left where the sentinel could still be told a lie.

    `collect_code_objects` read `find` through a process substitution, which
    discards the producer's status. A `find` that failed handed the loop a
    short list, the loop consumed it without complaint, and the run reported a
    signed bundle having enumerated nothing — `COMPLETED=true` on a
    verification that did not happen. Found in review, not by the issue.

    `codesign` is stubbed to a passing Developer ID report so the run reaches
    the end on a bundle no one signed; that is what lets the failing case be
    about enumeration rather than about signing.
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="VerifyReleaseBundleSigning-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bundle = build_structurally_valid_bundle(self.root)
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        write_stub(
            self.stubs / "codesign",
            "cat <<'REPORT'\n"
            "Executable=stub\n"
            "Identifier=com.example.stub\n"
            "TeamIdentifier=ABCDE12345\n"
            "Authority=Developer ID Application: Example (ABCDE12345)\n"
            "REPORT\n",
        )

    def run_signing_lane(self) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env["PATH"] = f"{self.stubs}:{env['PATH']}"
        return run_verifier(str(self.bundle), env=env)

    def test_a_failing_find_does_not_report_a_signed_bundle(self) -> None:
        write_stub(self.stubs / "find", 'echo "synthetic find failure" >&2\nexit 42\n')
        result = self.run_signing_lane()
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"enumeration failed and it passed\n{output}")
        self.assertNotIn("Verified Developer ID signing", result.stdout, output)
        self.assertIn("Failed to enumerate", output, output)

    def test_a_file_that_cannot_be_inspected_is_not_assumed_safe(self) -> None:
        """`file` failing meant "not Mach-O", so the object was dropped silently.

        Not being able to tell whether something needs a signature is not the
        same answer as deciding it does not. Before the fix the run skipped the
        helper and reported a signed bundle.
        """
        helper = self.bundle / "Contents" / "MacOS" / "UnsignedHelper"
        helper.write_bytes(MACH_O_MAGIC)
        helper.chmod(0o755)
        write_stub(
            self.stubs / "file",
            'for arg in "$@"; do\n'
            '  case "$arg" in *UnsignedHelper) exit 42 ;; esac\n'
            "done\n"
            'exec /usr/bin/file "$@"\n',
        )
        result = self.run_signing_lane()
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"an uninspectable object passed\n{output}")
        self.assertNotIn("Verified Developer ID signing", result.stdout, output)
        self.assertIn("Failed to inspect", output, output)

    def test_an_unreadable_code_object_is_not_assumed_safe(self) -> None:
        """The real tool's contract, not a stub's.

        macOS `/usr/bin/file` prints `cannot open: Permission denied` and exits
        **0**, so checking its status is not enough — the case above forces a
        non-zero exit and would miss this entirely. Nothing is stubbed here but
        `codesign`, so it reads the behaviour the release lane would meet.
        """
        helper = self.bundle / "Contents" / "MacOS" / "UnreadableHelper"
        helper.write_bytes(MACH_O_MAGIC)
        helper.chmod(0o000)
        self.addCleanup(helper.chmod, 0o644)
        if os.access(helper, os.R_OK):
            self.skipTest("this user can read a mode-000 file, so the case cannot be set up")

        result = self.run_signing_lane()
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"an unreadable object passed\n{output}")
        self.assertNotIn("Verified Developer ID signing", result.stdout, output)
        self.assertIn("Cannot read", output, output)

    def test_a_newline_in_a_code_object_name_does_not_skip_a_signature(self) -> None:
        """The list was newline-delimited, so one object became two wrong ones.

        `grep -Fqx` reads a pattern containing a newline as two patterns, so
        `…/Helper` matched the first line of `…/Helper\nExtra` and was dropped
        as a duplicate. The consumer then split the surviving entry back into
        two, and ran `codesign` on `…/Helper` and on a bare `Extra` — neither
        of which is the object that was found. The count came out plausible
        either way, which is why this asserts *what* was verified.

        The shape is remote: it needs a Mach-O inside the bundle whose name
        carries a newline. It is here because it is the same failure the rest
        of this file is about — a signature reported over something other than
        what was enumerated.
        """
        macos = self.bundle / "Contents" / "MacOS"
        names = ("Helper", "Helper\nExtra")
        for name in names:
            target = macos / name
            target.write_bytes(MACH_O_MAGIC)
            target.chmod(0o755)
        write_stub(self.stubs / "file", 'echo "Mach-O 64-bit executable arm64"\n')

        log = self.root / "codesign-targets"
        write_stub(
            self.stubs / "codesign",
            f'printf "%s\\0" "${{@: -1}}" >> "{log}"\n'
            "cat <<'REPORT'\n"
            "TeamIdentifier=ABCDE12345\n"
            "Authority=Developer ID Application: Example (ABCDE12345)\n"
            "REPORT\n",
        )

        result = self.run_signing_lane()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)

        verified = {entry for entry in log.read_bytes().split(b"\0") if entry}
        for name in names:
            with self.subTest(name=name):
                self.assertIn(
                    str(macos / name).encode(),
                    verified,
                    f"{name!r} was enumerated but never signed\n{output}",
                )

    def test_the_signing_lane_still_passes_when_find_works(self) -> None:
        """The control, without which the case above proves nothing."""
        result = self.run_signing_lane()
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("Verified Developer ID signing", result.stdout, output)


def write_stub(path: Path, body: str) -> None:
    path.write_text(f"#!/bin/bash\n{body}", encoding="utf-8")
    path.chmod(0o755)


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
