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
from typing import NamedTuple

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
# The split the body publishes, measured at this head by the walk below and
# by a second reader. A snapshot rather than a bound: the number in the body
# is the claim, and this is what makes a change to it loud.
PUBLISHED_SPLIT = {"fix": 41, "guard": 75, "control": 11}
# Anchored at the start of the comment: a line that MENTIONS a marker in
# prose -- "the `# intent: fix` above" -- is a comment about a marker and not
# one, and a reader that took either would count the prose.
MARKER_RE = re.compile(r"^\s*#\s*intent:\s*(\S+)\s*$")


def _marks_above(node: ast.AST, lines: list[str]) -> list[str]:
    """The markers belonging to this definition, in source order.

    The CONTIGUOUS run of comment lines immediately above the first
    decorator (or the `def` when there is none), so a marker separated by a
    blank line is not this test's and a marker inside a docstring is not a
    comment at all -- and then the decorator span itself, because a second
    marker sitting BETWEEN two decorators is a marker this test carries and
    a reader that only looked upwards never saw it (#1773, round 17).
    """
    first = node.decorator_list[0].lineno if node.decorator_list else node.lineno
    index = first - 2
    marks: list[str] = []
    while index >= 0 and lines[index].strip().startswith("#"):
        match = MARKER_RE.match(lines[index])
        if match:
            marks.append(match.group(1).lower())
        index -= 1
    marks.reverse()
    for line in lines[first - 1 : node.lineno - 1]:
        match = MARKER_RE.match(line)
        if match:
            marks.append(match.group(1).lower())
    return marks


def markers_in(source: str) -> dict[str, list[str]]:
    """Every `def test_*` in this source, keyed by its QUALIFIED name, with its markers.

    Any nesting: a test inside a class inside a `try` is still a test. The
    key is the dotted path to the definition rather than the bare name,
    because a key coarser than the thing it identifies loses members --
    two classes each holding a `test_writes_the_body`, or both branches of
    a conditionally defined class, collapsed to one entry, and an unmarked
    test could hide behind a marked one of the same name (#1773, round 17).
    """
    lines = source.split("\n")
    found: dict[str, list[str]] = {}

    def walk(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            name = getattr(child, "name", None)
            if (
                isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                and child.name.startswith("test_")
            ):
                found[f"{prefix}{child.name}"] = _marks_above(child, lines)
            walk(child, f"{prefix}{name}." if name else prefix)

    walk(ast.parse(source), "")
    return found


# The REFSPEC form, because it is the one that works: on a single-branch
# clone `git fetch origin main` leaves the commit at `FETCH_HEAD` and
# `origin/main` still does not resolve, so a reader following that
# instruction meets this failure again. Measured on a single-branch clone
# (#1773, round 16).
FETCH = "git fetch --no-tags origin main:refs/remotes/origin/main  (or check out with fetch-depth: 0)"


# The refspec form resolves the ref; `--unshallow` gives the history a merge
# base needs. Two instructions because there are two ways to be unable to
# answer, and an instruction that does not fix the shape it is printed for is
# a false claim -- both are RUN by the seeds below (#1773, rounds 16 and 17).
DEEPEN = (
    "git fetch --no-tags --unshallow origin main:refs/remotes/origin/main"
    "  (or check out with fetch-depth: 0)"
)


class Base(NamedTuple):
    """The commit "new" is measured against, or what this checkout needs first."""

    sha: str | None
    missing: str | None


def comparison_base(root: Path = REPO_ROOT, base: str = "origin/main") -> Base:
    """What "new" is measured against here, or None and the reason it cannot be.

    The MERGE BASE of `HEAD` and `origin/main` rather than `origin/main`
    itself: a pull request checkout is the head or a merge commit, and "new"
    has to mean new to this pull request rather than new since whatever main
    has moved to since it branched.

    Never a string that looks like an answer. Returning `base` when
    `git merge-base` fails swapped merge-base semantics for origin/main-tip
    semantics without saying so -- on a shallow checkout, where the ref
    resolves and no history is shared -- and a caller asking "did I get a
    base?" was told yes (#1773, round 17).
    """
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", base],
        capture_output=True, text=True, cwd=root,
    ).returncode != 0:
        return Base(None, f"`{base}` is not in this checkout: {FETCH}")
    found = subprocess.run(
        ["git", "merge-base", "HEAD", base], capture_output=True, text=True, cwd=root
    )
    if found.returncode != 0:
        return Base(
            None,
            f"`{base}` resolves but this checkout shares no history with it, so the "
            f"merge base cannot be computed: {DEEPEN}",
        )
    return Base(found.stdout.strip(), None)


def head_of(root: Path = REPO_ROOT) -> str:
    """This checkout's HEAD, for the one question the base cannot answer alone."""
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=root
    ).stdout.strip()


def added_test_files(base: str, root: Path = REPO_ROOT) -> tuple[str, ...]:
    """Test files this branch ADDS under `scripts/tests/`, named rather than assumed.

    Not `test_files_added_since`: the walk below reads every `def test_*` in
    this file as a test, so a helper named that way is an unmarked test to
    its own census. Caught by this guard on the commit that added it.

    The guard's population was the five files somebody listed, so a new
    suite added with no markers at all was invisible to it AND to the
    check for files outside it, which only notices an outside file once it
    carries a marker. A file this branch adds is this branch's to mark
    (#1773, round 17).
    """
    shown = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=A", base, "HEAD", "--", "scripts/tests"],
        capture_output=True, text=True, cwd=root,
    )
    if shown.returncode != 0:
        return ()
    return tuple(sorted(
        Path(line).name
        for line in shown.stdout.split("\n")
        if line.endswith(".py") and Path(line).name.startswith("test_")
    ))


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
        split = {kind: 0 for kind in KINDS}
        base = comparison_base()
        if base.sha is None:
            # The two cases are different and the difference is the whole
            # point of this branch. A LOCAL checkout with no remote cannot
            # say what is new, and refusing there would fail on a clone
            # somebody made to read the code. In CI this guard is the only
            # thing standing between the body's marker counts and a number
            # nobody checks, and a skipped guard reads as a green one --
            # which is the silence this test was committed to end, so it
            # fails and says what to fetch (#1773, round 16).
            if os.environ.get("GITHUB_ACTIONS"):
                self.fail(f"the marker census could not run: {base.missing}")
            self.skipTest(
                f"what is new cannot be measured here; this fails rather than skips "
                f"under GITHUB_ACTIONS ({base.missing})"
            )
        population = MARKED_FILES + tuple(
            name for name in added_test_files(base.sha) if name not in MARKED_FILES
        )
        for name in population:
            path = TESTS / name
            added = new_tests(path, base.sha)
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
                else:
                    split[marks[0]] += 1
        self.assertEqual({k: v for k, v in offenders.items() if v}, {}, "markers to fix")
        if base.sha == head_of():
            # The population of "what this branch adds" is EMPTY on the branch
            # this guard protects, the moment it merges: on a main checkout
            # the merge base is HEAD, nothing is new, and a lower bound over
            # nothing fails. Measured at `22e2bd46` in a clone where
            # `origin/main == HEAD`: `0 not greater than 100`, which would
            # have redded the agent lane on main and kept it red. A guard
            # whose subject is a diff says what it does when the diff is
            # empty, and passing silently is not that: the reason is printed
            # (#1773, round 17).
            self.assertEqual(counted, 0, "the base is HEAD and the walk still found new tests")
            print(
                "marker census: nothing added relative to the base; the guard has no "
                "population here",
                file=sys.stderr,
            )
            return
        self.assertGreater(counted, 100, "the population collapsed; the walk read too few tests")
        # The split the pull request body publishes, pinned as a snapshot the
        # way a fixture's names are pinned. Without it the guard holds the
        # kinds are known and holds nothing about how many of each, so a
        # marker flipped `guard` -> `control` left the suite green while the
        # body's red-first line went false (#1773, round 17). A change here
        # is meant to be loud: re-measure, and update this in the same commit
        # as the tests that moved it.
        self.assertEqual(
            split, PUBLISHED_SPLIT,
            "the marker split moved; re-measure and update PUBLISHED_SPLIT and the body's "
            "red-first line in the same commit",
        )

    def upstream_with_a_branch(self, root: Path, extra: dict[str, str] | None = None) -> Path:
        """A repository with `main` and a `work` branch carrying this file.

        One builder for every seed below, because three temporary
        repositories built three ways would be three shapes nobody compares.
        """
        upstream = root / "upstream"
        tests = upstream / "scripts" / "tests"
        tests.mkdir(parents=True)

        def git(*args: str) -> None:
            subprocess.run(["git", *args], cwd=upstream, capture_output=True, check=True)

        (tests / "test_stub.py").write_text("", encoding="utf-8")
        git("init", "--initial-branch=main")
        git("config", "user.email", "tests@example.invalid")
        git("config", "user.name", "tests")
        git("add", "-A")
        git("commit", "-m", "main")
        git("checkout", "-b", "work")
        (tests / "test_intent_markers.py").write_text(
            Path(__file__).read_text(encoding="utf-8"), encoding="utf-8"
        )
        for name in MARKED_FILES:
            if name != "test_intent_markers.py":
                (tests / name).write_text("", encoding="utf-8")
        for name, source in (extra or {}).items():
            (tests / name).write_text(source, encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "work")
        return upstream

    def census_in(self, sandbox: Path, ci: bool) -> str:
        """This file, run inside another checkout, the way the lane runs it."""
        environment = {**os.environ, "PYTHONPYCACHEPREFIX": str(sandbox / ".pyc")}
        environment.pop("GITHUB_ACTIONS", None)
        if ci:
            environment["GITHUB_ACTIONS"] = "true"
        finished = subprocess.run(
            [sys.executable, str(sandbox / "scripts" / "tests" / "test_intent_markers.py"), "-v",
             "TheMarkersThisBranchWritesAreCheckedByCITests"
             ".test_every_test_this_branch_adds_declares_exactly_one_intent"],
            cwd=sandbox, capture_output=True, text=True, env=environment,
        )
        return finished.stdout + finished.stderr

    def instruction_printed_in(self, output: str) -> list[str]:
        """The command the failure PRINTED, taken from the output rather than rebuilt.

        Re-deriving it from the constant is what let the printed form and
        the tested form drift: the false `--depth 1` instruction round 16
        exists to eliminate could be put back and the seed stayed green,
        because it ran `FETCH` and asserted only the substring `git fetch`
        (#1773, round 17).
        """
        printed = [line for line in output.splitlines() if "git fetch" in line]
        self.assertTrue(printed, f"nothing in the output says what to fetch: {output}")
        said = printed[0]
        return said[said.index("git fetch"):].split("  (")[0].strip().split()

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
        spelling of a rule is how the rule drifts. And the instruction it
        runs is the one the failure PRINTED, read back out of the captured
        output, so the sentence and the command cannot drift apart either.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(root)
            # The shape the lane had: one branch, no history of `main`.
            subprocess.run(
                ["git", "clone", "--quiet", "--single-branch", "--branch", "work",
                 str(upstream), str(root / "checkout")],
                capture_output=True, check=True,
            )
            sandbox = root / "checkout"
            self.assertIsNone(
                comparison_base(sandbox).sha, "a single-branch clone resolved `origin/main`"
            )
            in_ci = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", in_ci, "CI did not fail on a missing base")
            self.assertIn("could not run", in_ci)
            self.assertIn(FETCH, in_ci, "the failure does not print the instruction that works")
            on_a_laptop = self.census_in(sandbox, ci=False)
            self.assertIn("OK (skipped=1)", on_a_laptop, "a laptop clone did not skip")
            self.assertIn("what is new cannot be measured", on_a_laptop)
            # And the printed instruction is RUN here, against that clone: a
            # reader who follows it has to end up somewhere other than this
            # failure. `git fetch origin main` alone does not -- it leaves the
            # commit at `FETCH_HEAD` -- which is why the refspec is in the
            # sentence (#1773, round 16).
            subprocess.run(
                self.instruction_printed_in(in_ci), cwd=sandbox, capture_output=True, check=True
            )
            self.assertIsNotNone(
                comparison_base(sandbox).sha,
                "the instruction the guard prints does not resolve the base it asks for",
            )
            self.assertNotIn(
                "could not run", self.census_in(sandbox, ci=True),
                "the base is there and the census still refuses",
            )

    # intent: fix
    def test_a_shallow_checkout_is_told_so_rather_than_given_the_tip(self) -> None:
        """A ref that resolves is not a base, and saying it is hides the swap.

        On a `--depth 1` checkout the printed fetch resolves `origin/main`
        and `git merge-base HEAD origin/main` still fails -- no shared
        history -- and the helper returned the literal string `origin/main`.
        The walk then measured "new" against main's TIP instead of the merge
        base, which is the substitution its own docstring exists to prevent,
        and a caller asking whether it got a base was told yes. Measured on a
        genuine shallow clone at `22e2bd46`: `comparison_base()` returned
        `'origin/main'` and the census ran green on it.

        It answers None with the deeper instruction now, and the seed runs
        THAT instruction and asserts the census can then measure (#1773,
        round 17).
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(root)
            # `file://` because a local-path clone ignores `--depth`.
            subprocess.run(
                ["git", "clone", "--quiet", "--depth", "1", "--single-branch",
                 "--branch", "work", f"file://{upstream}", str(root / "checkout")],
                capture_output=True, check=True,
            )
            sandbox = root / "checkout"
            subprocess.run(self.instruction_printed_in(self.census_in(sandbox, ci=True)),
                           cwd=sandbox, capture_output=True, check=True)
            resolved = subprocess.run(
                ["git", "rev-parse", "--verify", "--quiet", "origin/main"],
                cwd=sandbox, capture_output=True, text=True,
            )
            self.assertEqual(resolved.returncode, 0, "the first instruction did not resolve the ref")
            base = comparison_base(sandbox)
            self.assertIsNone(base.sha, "a shallow checkout was handed a base it cannot have")
            self.assertIn("shares no history", base.missing or "")
            shallow = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", shallow, "CI did not fail on a checkout with no merge base")
            self.assertIn("shares no history", shallow)
            # The deeper instruction, taken from what it printed and run.
            subprocess.run(
                self.instruction_printed_in(shallow), cwd=sandbox, capture_output=True, check=True
            )
            self.assertIsNotNone(
                comparison_base(sandbox).sha,
                "the deeper instruction the guard prints does not give it a merge base",
            )

    # intent: fix
    def test_a_new_test_file_this_branch_adds_is_in_the_population(self) -> None:
        """The guard's population was a list somebody wrote, not what the branch adds.

        A new suite added with no markers at all was invisible twice over:
        the census walks `MARKED_FILES`, and the check for files outside it
        only notices an outside file once it CARRIES a marker. So the one
        shape the file's docstring promises to catch -- a test added without
        declaring what it is for -- passed when it arrived in a new file.
        The population is the listed files plus the test files this branch
        adds (#1773, round 17).
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(
                root,
                extra={"test_zz_added_suite.py": "class T:\n    def test_undeclared(self):\n        pass\n"},
            )
            subprocess.run(
                ["git", "clone", "--quiet", "--branch", "work", str(upstream),
                 str(root / "checkout")],
                capture_output=True, check=True,
            )
            sandbox = root / "checkout"
            subprocess.run(["git", "fetch", "--no-tags", "origin", "main:refs/remotes/origin/main"],
                           cwd=sandbox, capture_output=True, check=True)
            reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, "a new file's unmarked test was invisible")
            self.assertIn("test_zz_added_suite.py::T.test_undeclared", reported)

    # intent: fix
    def test_a_checkout_whose_base_is_head_passes_and_says_why(self) -> None:
        """The population is empty on the branch this guard protects, once it merges.

        `ci-agents.yml` runs on push to `main` with `scripts/tests/**` in
        its paths and the test job has no event gate, so the first push to
        main after this merges runs this census in a checkout where
        `origin/main` IS `HEAD`. Nothing is new there, and a lower bound over
        an empty population fails: measured at `22e2bd46` in such a clone,
        `AssertionError: 0 not greater than 100`, red on main and red for
        every later push touching those paths.

        A guard whose subject is a diff has to say what it does when the
        diff is empty. It passes, and prints the reason rather than passing
        silently -- a green with no population and a green over 122 tests
        should not read the same to whoever opens the log (#1773, round 17).
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(root)
            subprocess.run(
                ["git", "clone", "--quiet", "--branch", "work", str(upstream),
                 str(root / "checkout")],
                capture_output=True, check=True,
            )
            sandbox = root / "checkout"
            # What a main checkout after the merge looks like: the branch's
            # own commit is what `origin/main` points at.
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                           cwd=sandbox, capture_output=True, check=True)
            base = comparison_base(sandbox)
            self.assertEqual(base.sha, head_of(sandbox), "the sandbox is not a base-equals-head one")
            merged = self.census_in(sandbox, ci=True)
            self.assertIn("OK", merged, f"the census did not pass with an empty population: {merged}")
            self.assertNotIn("FAILED", merged)
            self.assertIn("the guard has no population here", merged,
                          "it passed without saying why, which is the silence this replaces")

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
    # Two classes, one test name: the shape a bare-name key loses. The second
    # is unmarked, so a reader keying on the name reports one marked test and
    # the unmarked one is simply gone.
    TWICE = (
        "class A:\n    # intent: fix\n    def test_same(self):\n        pass\n"
        "class B:\n    def test_same(self):\n        pass\n"
    )
    # A second marker below the first decorator, where a reader that only
    # looks upwards from the decorator never reaches it.
    BETWEEN = (
        "class T:\n    # intent: guard\n    @unittest.skip('why')\n    # intent: fix\n"
        "    def test_between(self):\n        pass\n"
    )

    # intent: guard
    def test_one_marker_is_read_as_one(self) -> None:
        self.assertEqual(markers_in(self.ONE), {"T.test_one": ["fix"]})

    # intent: guard
    def test_a_second_marker_is_reported_rather_than_taken(self) -> None:
        # The defect round 12 left and round 13 had to come back for: a
        # reader that takes the first marker reports `guard` and says nothing.
        self.assertEqual(markers_in(self.DOUBLE), {"T.test_two": ["guard", "fix"]})

    # intent: guard
    def test_a_test_with_no_marker_reads_as_none(self) -> None:
        self.assertEqual(markers_in(self.NONE), {"T.test_bare": []})

    # intent: guard
    def test_a_marker_inside_a_docstring_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.IN_DOCSTRING), {"T.test_doc": []})

    # intent: guard
    def test_a_marker_a_blank_line_away_is_not_this_tests(self) -> None:
        self.assertEqual(markers_in(self.BLANK_LINE), {"T.test_far": []})

    # intent: guard
    def test_a_marker_quoted_in_prose_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.PROSE), {"T.test_prose": []})

    # intent: guard
    def test_a_nested_test_is_still_a_test(self) -> None:
        self.assertEqual(markers_in(self.NESTED), {"T.Inner.test_deep": ["control"]})

    # intent: guard
    def test_a_decorated_test_keeps_the_marker_above_its_decorator(self) -> None:
        self.assertEqual(markers_in(self.DECORATED), {"T.test_decorated": ["guard"]})

    # intent: fix
    def test_two_tests_of_one_name_are_two_tests(self) -> None:
        # The key is the dotted path, so the unmarked one is still there to
        # report. Keyed on the bare name this read as a single marked test
        # and the census counted one where there are two (#1773, round 17).
        self.assertEqual(markers_in(self.TWICE), {"A.test_same": ["fix"], "B.test_same": []})

    # intent: fix
    def test_a_marker_between_two_decorators_is_still_this_tests(self) -> None:
        # Reported as multi-marked rather than missed: the walk reads the
        # decorator span as well as the run above it (#1773, round 17).
        self.assertEqual(markers_in(self.BETWEEN), {"T.test_between": ["guard", "fix"]})


if __name__ == "__main__":
    unittest.main()
