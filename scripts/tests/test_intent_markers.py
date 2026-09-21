#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""The intent-marker census, committed as a test rather than run by hand.

Every test this branch adds declares what it is for -- `fix`, `guard` or
`control` -- and the count of those markers is load-bearing in the pull
request body's red-first line. That count was wrong three times, each time
because the reader that produced it was a script somebody ran once: a stray
second marker under a truncated note, a test added after the count, a
population that stopped at one file. A number a body publishes should be
produced by something CI runs.

The walk is a function over SOURCE TEXT, not over the tree, so this file's
own examples of the defects it reports -- a double marker, a missing one, a
marker inside a docstring -- are synthetic strings rather than real test
definitions. A scanner whose fixtures live in the tree it scans needs an
exclusion list keyed on a name, and an exclusion list is the next place a
defect hides.
"""

from __future__ import annotations

import ast
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS = REPO_ROOT / "scripts" / "tests"
# The files this branch marks. Every other suite under `scripts/tests/` is
# unmarked, so the guard's population is stated here rather than implied by
# the directory (#1773, round 15).
MARKED_FILES = (
    "test_factory_evidence_kinds.py",
    "test_evidence_write_sweep.py",
    "test_run_contributor.py",
    "test_pr_readiness.py",
    # This file's own tests declare their intent too, so it is inside the
    # population it walks -- its SEEDS are source strings rather than test
    # definitions, which is what keeps that from needing an exclusion list.
    "test_intent_markers.py",
)
KINDS = ("fix", "guard", "control")
# Anchored at the start of the comment: a line that MENTIONS a marker in
# prose -- "the `# intent: fix` above" -- is a comment about a marker and not
# one, and a reader that took either would count the prose.
MARKER_RE = re.compile(r"^\s*#\s*intent:\s*(\S+)\s*$")


def markers_in(source: str) -> dict[str, list[str]]:
    """Every `def test_*` in this source, with the markers directly above it.

    Any nesting: a test inside a class inside a `try` is still a test. The
    block read is the CONTIGUOUS run of comment lines immediately above the
    `def`, so a marker separated from it by a blank line is not this test's,
    and a marker inside a docstring is not a comment at all.
    """
    tree = ast.parse(source)
    lines = source.split("\n")
    found: dict[str, list[str]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if not node.name.startswith("test_"):
            continue
        first = node.decorator_list[0].lineno if node.decorator_list else node.lineno
        index = first - 2
        marks: list[str] = []
        while index >= 0 and lines[index].strip().startswith("#"):
            match = MARKER_RE.match(lines[index])
            if match:
                marks.append(match.group(1).lower())
            index -= 1
        found[node.name] = marks[::-1]
    return found


FETCH = "git fetch --no-tags --depth=1 origin main  (or check out with fetch-depth: 0)"


def comparison_base(base: str = "origin/main") -> str | None:
    """What "new" is measured against, or None if this checkout cannot say.

    The MERGE BASE of `HEAD` and `origin/main` rather than `origin/main`
    itself: a pull request checkout is the head or a merge commit, and "new"
    has to mean new to this pull request rather than new since whatever main
    has moved to since it branched.
    """
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", base],
        capture_output=True, text=True, cwd=REPO_ROOT,
    ).returncode != 0:
        return None
    merge_base = subprocess.run(
        ["git", "merge-base", "HEAD", base], capture_output=True, text=True, cwd=REPO_ROOT
    )
    return merge_base.stdout.strip() if merge_base.returncode == 0 else base


def new_tests(path: Path, base: str | None) -> set[str] | None:
    """Which tests in this file are absent from `base`, or None if git cannot say."""
    if base is None:
        return None
    relative = path.relative_to(REPO_ROOT).as_posix()
    # Two different "no": a base this checkout cannot resolve means the walk
    # has nothing to compare against and says so (`comparison_base` above); a
    # FILE absent at a base it can resolve means every test in it is new.
    # Reading both as the first skipped the whole guard the day a new suite
    # was added.
    shown = subprocess.run(
        ["git", "show", f"{base}:{relative}"],
        capture_output=True, text=True, cwd=REPO_ROOT,
    )
    at_base = set(markers_in(shown.stdout)) if shown.returncode == 0 and shown.stdout else set()
    return set(markers_in(path.read_text(encoding="utf-8"))) - at_base


def comparison_base_in(root: Path, base: str = "origin/main") -> str | None:
    """`comparison_base` asked about another checkout, for the seed below."""
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", base],
        capture_output=True, text=True, cwd=root,
    ).returncode != 0:
        return None
    found = subprocess.run(["git", "merge-base", "HEAD", base], capture_output=True, text=True, cwd=root)
    return found.stdout.strip() if found.returncode == 0 else base


class TheMarkersThisBranchWritesAreCheckedByCITests(unittest.TestCase):
    """The census over the real tree, which is the part a hand-run script was doing."""

    # intent: guard
    # marker: `fix` until round 16, and its own base says otherwise -- every test in this
    # file is green at `f9f522f2`, where the file did not exist, so nothing here can be
    # behaviourally red at it; a test that pins a property the base already has is a guard
    # (#1773, round 16). The fix this round is the sibling below.
    def test_every_test_this_branch_adds_declares_exactly_one_intent(self) -> None:
        offenders: dict[str, list[str]] = {"unmarked": [], "multi-marked": [], "unknown kind": []}
        counted = 0
        base = comparison_base()
        if base is None:
            # The two cases are different and the difference is the whole
            # point of this branch. A LOCAL checkout with no remote cannot
            # say what is new, and refusing there would fail on a clone
            # somebody made to read the code. In CI this guard is the only
            # thing standing between the body's marker counts and a number
            # nobody checks, and a skipped guard reads as a green one --
            # which is the silence this test was committed to end, so it
            # fails and says what to fetch (#1773, round 16).
            if os.environ.get("GITHUB_ACTIONS"):
                self.fail(
                    "the comparison base is missing from this checkout, so the marker census "
                    f"could not run: {FETCH}"
                )
            self.skipTest(
                "no `origin/main` in this checkout, so what is new cannot be measured; "
                f"this fails rather than skips under GITHUB_ACTIONS ({FETCH})"
            )
        for name in MARKED_FILES:
            path = TESTS / name
            added = new_tests(path, base)
            found = markers_in(path.read_text(encoding="utf-8"))
            for test in sorted(added):
                marks = found[test]
                counted += 1
                if not marks:
                    offenders["unmarked"].append(f"{name}::{test}")
                elif len(marks) > 1:
                    offenders["multi-marked"].append(f"{name}::{test} {marks}")
                elif marks[0] not in KINDS:
                    offenders["unknown kind"].append(f"{name}::{test} {marks[0]}")
        self.assertEqual({k: v for k, v in offenders.items() if v}, {}, "markers to fix")
        self.assertGreater(counted, 100, "the population collapsed; the walk read too few tests")

    # intent: fix
    def test_a_checkout_without_the_base_fails_in_ci_and_skips_on_a_laptop(self) -> None:
        """A skipped guard reads as a green one, and CI is where that matters.

        The lane that runs this file checks out with `actions/checkout`'s
        default -- one ref, no history -- so `origin/main` does not resolve,
        the comparison base is None, and the census SKIPPED: measured on a
        single-branch clone of this branch at `2f614b05`, `Ran 10 tests` /
        `OK (skipped=1)`. In the one lane that runs it the guard guarded
        nothing, which is the silence it was committed to end (#1773, round
        16).

        The two cases answer differently because they are different: a laptop
        clone with no remote cannot say what is new and skips with the
        reason; a run under `GITHUB_ACTIONS` fails and says what to fetch.
        This drives THIS FILE inside a temporary repository that has no
        `origin/main`, rather than restating either sentence here -- a second
        spelling of a rule is how the rule drifts.
        """
        with tempfile.TemporaryDirectory() as directory:
            sandbox = Path(directory)
            tests = sandbox / "scripts" / "tests"
            tests.mkdir(parents=True)
            (tests / "test_intent_markers.py").write_text(
                Path(__file__).read_text(encoding="utf-8"), encoding="utf-8"
            )
            for name in MARKED_FILES:
                if name != "test_intent_markers.py":
                    (tests / name).write_text("", encoding="utf-8")
            for args in (
                ("init", "--initial-branch=work"),
                ("config", "user.email", "tests@example.invalid"),
                ("config", "user.name", "tests"),
                ("add", "-A"),
                ("commit", "-m", "a checkout with no origin/main"),
            ):
                subprocess.run(["git", *args], cwd=sandbox, capture_output=True, check=True)
            self.assertIsNone(
                comparison_base_in(sandbox), "a checkout with no `origin/main` resolved one"
            )

            def run(ci: bool) -> str:
                environment = {**os.environ, "PYTHONPYCACHEPREFIX": str(sandbox / ".pyc")}
                environment.pop("GITHUB_ACTIONS", None)
                if ci:
                    environment["GITHUB_ACTIONS"] = "true"
                finished = subprocess.run(
                    [sys.executable, str(tests / "test_intent_markers.py"), "-v",
                     "TheMarkersThisBranchWritesAreCheckedByCITests"
                     ".test_every_test_this_branch_adds_declares_exactly_one_intent"],
                    cwd=sandbox, capture_output=True, text=True, env=environment,
                )
                return finished.stdout + finished.stderr

            in_ci = run(ci=True)
            self.assertIn("FAILED", in_ci, "CI did not fail on a missing base")
            self.assertIn("could not run", in_ci)
            self.assertIn("git fetch", in_ci, "the failure does not say what to fetch")
            on_a_laptop = run(ci=False)
            self.assertIn("OK (skipped=1)", on_a_laptop, "a laptop clone did not skip")
            self.assertIn("what is new cannot be measured", on_a_laptop)

    # intent: guard
    def test_the_files_outside_the_guard_are_named_rather_than_implied(self) -> None:
        # The other suites under `scripts/tests/` carry no markers at all, so
        # the population is the four files above rather than the directory.
        # This asserts that statement rather than leaving it in prose.
        unmarked_elsewhere = [
            path.name
            for path in sorted(TESTS.glob("test_*.py"))
            if path.name not in MARKED_FILES
            and any(marks for marks in markers_in(path.read_text(encoding="utf-8")).values())
        ]
        self.assertEqual(
            unmarked_elsewhere,
            [],
            "a file outside the guard's population has started carrying markers; widen the list",
        )


class TheWalkReadsMarkersTheWayItClaimsTests(unittest.TestCase):
    """The walk's own shapes, fed as SOURCE rather than written into the tree."""

    ONE = "class T:\n    # intent: fix\n    def test_one(self):\n        pass\n"
    DOUBLE = "class T:\n    # intent: guard\n    # intent: fix\n    def test_two(self):\n        pass\n"
    NONE = "class T:\n    def test_bare(self):\n        pass\n"
    IN_DOCSTRING = 'class T:\n    def test_doc(self):\n        """# intent: fix"""\n'
    BLANK_LINE = "class T:\n    # intent: fix\n\n    def test_far(self):\n        pass\n"
    PROSE = "class T:\n    # the `# intent: fix` line above a test is its marker\n    def test_prose(self):\n        pass\n"
    NESTED = "class T:\n    class Inner:\n        # intent: control\n        def test_deep(self):\n            pass\n"
    DECORATED = (
        "class T:\n    # intent: guard\n    @unittest.skip('why')\n    def test_decorated(self):\n        pass\n"
    )

    # intent: guard
    def test_one_marker_is_read_as_one(self) -> None:
        self.assertEqual(markers_in(self.ONE), {"test_one": ["fix"]})

    # intent: guard
    def test_a_second_marker_is_reported_rather_than_taken(self) -> None:
        # The defect round 12 left and round 13 had to come back for: a
        # reader that takes the first marker reports `guard` and says nothing.
        self.assertEqual(markers_in(self.DOUBLE), {"test_two": ["guard", "fix"]})

    # intent: guard
    def test_a_test_with_no_marker_reads_as_none(self) -> None:
        self.assertEqual(markers_in(self.NONE), {"test_bare": []})

    # intent: guard
    def test_a_marker_inside_a_docstring_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.IN_DOCSTRING), {"test_doc": []})

    # intent: guard
    def test_a_marker_a_blank_line_away_is_not_this_tests(self) -> None:
        self.assertEqual(markers_in(self.BLANK_LINE), {"test_far": []})

    # intent: guard
    def test_a_marker_quoted_in_prose_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.PROSE), {"test_prose": []})

    # intent: guard
    def test_a_nested_test_is_still_a_test(self) -> None:
        self.assertEqual(markers_in(self.NESTED), {"test_deep": ["control"]})

    # intent: guard
    def test_a_decorated_test_keeps_the_marker_above_its_decorator(self) -> None:
        self.assertEqual(markers_in(self.DECORATED), {"test_decorated": ["guard"]})


if __name__ == "__main__":
    unittest.main()
