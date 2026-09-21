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
import re
import subprocess
import sys
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


def new_tests(path: Path, base: str = "origin/main") -> set[str] | None:
    """Which tests in this file are absent from `base`, or None if git cannot say."""
    relative = path.relative_to(REPO_ROOT).as_posix()
    # Two different "no": a base this checkout cannot resolve means the walk
    # has nothing to compare against and says so; a FILE absent at a base it
    # can resolve means every test in it is new. Reading both as the first
    # skipped the whole guard the day a new suite was added.
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", base],
        capture_output=True, text=True, cwd=REPO_ROOT,
    ).returncode != 0:
        return None
    shown = subprocess.run(
        ["git", "show", f"{base}:{relative}"],
        capture_output=True, text=True, cwd=REPO_ROOT,
    )
    at_base = set(markers_in(shown.stdout)) if shown.returncode == 0 and shown.stdout else set()
    return set(markers_in(path.read_text(encoding="utf-8"))) - at_base


class TheMarkersThisBranchWritesAreCheckedByCITests(unittest.TestCase):
    """The census over the real tree, which is the part a hand-run script was doing."""

    # intent: fix
    def test_every_test_this_branch_adds_declares_exactly_one_intent(self) -> None:
        offenders: dict[str, list[str]] = {"unmarked": [], "multi-marked": [], "unknown kind": []}
        counted = 0
        for name in MARKED_FILES:
            path = TESTS / name
            added = new_tests(path)
            if added is None:
                self.skipTest("git cannot read origin/main here")
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
