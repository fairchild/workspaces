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

The population is every test a `def` creates. A test the loader collects
that no `def` creates -- a `staticmethod(lambda ...)` assigned in a class
body, a method bound by `setattr`, one built by a `load_tests` hook -- is
outside this walk and is asked for no marker; measured over the five files
this branch touches and over all 58 under `scripts/tests`, there are zero
of each today, so the boundary is declared rather than covered. Recognising
assigned names would close the one shape a reader can see statically and
leave the two it cannot, which reads as coverage.

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
import io
import subprocess
import sys
import tempfile
import tokenize
import unittest
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS = REPO_ROOT / "scripts" / "tests"
KINDS = ("fix", "guard", "control")
# Anchored at the start of the comment: a line that MENTIONS a marker in
# prose -- "the `# intent: fix` above" -- is a comment about a marker and not
# one, and a reader that took either would count the prose.
MARKER_RE = re.compile(r"^\s*#\s*intent:\s*(\S+)\s*$")


def comment_lines(source: str) -> dict[int, str]:
    """Every line of this source that IS a comment, by line number.

    Read from the token stream rather than from the characters: a line
    inside a multi-line string can start with `#` and read as a comment to
    a line scanner, so a marker written inside a decorator's own string
    argument made an unmarked test read as marked (#1773, round 19). A
    tokenizer is what says which `#` opens a comment.
    """
    found: dict[int, str] = {}
    try:
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type == tokenize.COMMENT:
                found[token.start[0]] = token.string
    except (tokenize.TokenError, IndentationError, SyntaxError):
        # A source `ast.parse` accepted and `tokenize` refuses is not a
        # shape this walk can read; it answers with no comments rather than
        # with the characters, which is the conservative direction (every
        # test then reads as unmarked and the guard says so).
        return {}
    return found


def _marks_above(node: ast.AST, lines: list[str], comments: dict[int, str]) -> list[str]:
    """The markers belonging to this definition, in source order.

    The CONTIGUOUS run of comment lines immediately above the first
    decorator (or the `def` when there is none), so a marker separated by a
    blank line is not this test's and a marker inside a docstring is not a
    comment at all -- and then the decorator span itself, because a second
    marker sitting BETWEEN two decorators is a marker this test carries and
    a reader that only looked upwards never saw it (#1773, round 17).
    """
    first = node.decorator_list[0].lineno if node.decorator_list else node.lineno
    number = first - 1
    marks: list[str] = []
    while number >= 1 and number in comments:
        match = MARKER_RE.match(comments[number])
        if match:
            marks.append(match.group(1).lower())
        number -= 1
    marks.reverse()
    for line_number in range(first, node.lineno):
        comment = comments.get(line_number)
        if comment is not None and (match := MARKER_RE.match(comment)):
            marks.append(match.group(1).lower())
    return marks


def markers_in(source: str) -> dict[tuple[str, int], list[str]]:
    """Every `def test_*` in this source, keyed by its dotted path AND that path's occurrence.

    Any nesting: a test inside a class inside a `try` is still a test.

    The key is the dotted path rather than the bare name, because a key
    coarser than the thing it identifies loses members: two classes each
    holding a `test_writes_the_body` collapsed to one entry, and an unmarked
    test could hide behind a marked one of the same name (#1773, round 17).
    The OCCURRENCE is beside it for the same reason one level down: a class
    defined in both branches of an `if` has two definitions at one dotted
    path, and the later one overwrote the earlier, so an unmarked test hid
    behind a marked sibling (#1773, round 18). It is the key shape the
    evidence writer uses for the same reason -- no two definitions of one
    list may share a key.

    `def test_*` is the whole population: a name a `def` did not create is
    not here, which the module docstring declares and a control below pins.
    """
    lines = source.split("\n")
    comments = comment_lines(source)
    found: dict[tuple[str, int], list[str]] = {}
    seen: dict[str, int] = {}

    def walk(node: ast.AST, prefix: str) -> None:
        for child in ast.iter_child_nodes(node):
            name = getattr(child, "name", None)
            if (
                isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                and child.name.startswith("test_")
            ):
                dotted = f"{prefix}{child.name}"
                occurrence = seen.get(dotted, 0)
                seen[dotted] = occurrence + 1
                found[(dotted, occurrence)] = _marks_above(child, lines, comments)
            walk(child, f"{prefix}{name}." if name else prefix)

    walk(ast.parse(source), "")
    return found


def names_one(key: tuple[str, int]) -> str:
    """How a test is named to a reader: its dotted path, and which definition."""
    dotted, occurrence = key
    return dotted if occurrence == 0 else f"{dotted} (definition {occurrence + 1})"


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


class Touched(NamedTuple):
    """One test file the diff touches: where it is now, and where to read it at the base."""

    relative: str
    at_base: str | None


# What git says it did to a file, and what that means for the base reading.
# A RENAME keeps its tests, so the base is the OLD path -- reading it at the
# new path finds nothing and every test in the file reads as new, which is
# the direction that fails loudly; but `--diff-filter=AM` dropped the entry
# ENTIRELY, so a renamed suite with an unmarked test appended left the
# population empty and the guard announced "no tests added" over 40 tests
# (#1773, round 19). A COPY is a new file whose source still exists, so its
# tests are new to the census and its base is nothing.
RENAME_STATUS, COPY_STATUS, ADDED_STATUS = "R", "C", "A"


def touched_test_files(base: str, root: Path = REPO_ROOT) -> tuple[Touched, ...]:
    """Every Python file under `scripts/tests/` the diff from `base` to HEAD touches.

    The population is defined by KIND rather than by a list somebody keeps:
    a file this change adds, modifies, renames or copies is a file this
    change is answerable for.

    EVERY `.py`, not only `test_*.py`: the lane runs
    `find scripts/tests -type f -name '*.py'`, so a file it runs is a file
    this guard is about. All 58 there are `test_*.py` today and a test below
    asserts the two filters still agree, which is the part a later
    `regression.py` would break (#1773, round 19).

    A `git diff` that FAILS raises here rather than answering `()`: an empty
    population and a question git could not answer are different results,
    and returning the first for the second is the silence this branch keeps
    closing.
    """
    inside = "scripts/tests/"
    shown = subprocess.run(
        [
            "git", "diff", "--name-status", "-M", "--diff-filter=AMRC",
            base, "HEAD", "--", "scripts/tests",
        ],
        capture_output=True, text=True, cwd=root,
    )
    if shown.returncode != 0:
        raise AssertionError(
            f"the marker census could not read what changed since `{base}`: "
            f"{shown.stderr.strip() or 'git diff failed with no message'}"
        )
    touched: list[Touched] = []
    for row in shown.stdout.split("\n"):
        if not row.strip():
            continue
        status, *paths = row.split("\t")
        if status.startswith(RENAME_STATUS) and len(paths) == 2:
            old, new = paths
            here, there = new, old
        elif status.startswith(COPY_STATUS) and len(paths) == 2:
            here, there = paths[1], None
        elif status.startswith(ADDED_STATUS):
            here, there = paths[0], None
        else:
            here, there = paths[0], paths[0]
        if not (here.startswith(inside) and here.endswith(".py")):
            continue
        touched.append(
            Touched(here[len(inside):], None if there is None else there[len(inside):])
        )
    return tuple(sorted(touched))


# What git says when a path is not in a commit, as against any other reason a
# `git show` can fail. Reading every failure as "absent at the base" published
# old tests as new (#1773, round 19).
ABSENT_AT_BASE = ("exists on disk, but not in", "does not exist in", "path not in")


def source_at_base(base: str, relative: str | None, root: Path = REPO_ROOT) -> str:
    """The file as the base holds it, or empty when the base does not hold it at all."""
    if relative is None:
        return ""
    shown = subprocess.run(
        ["git", "show", f"{base}:scripts/tests/{relative}"],
        capture_output=True, text=True, cwd=root,
    )
    if shown.returncode == 0:
        return shown.stdout
    message = shown.stderr.strip()
    if any(phrase in message for phrase in ABSENT_AT_BASE):
        return ""
    raise AssertionError(
        f"the marker census could not read `{relative}` at `{base}`: "
        f"{message or 'git show failed with no message'}"
    )


def new_tests(path: Path, base: str, touched: Touched, root: Path = REPO_ROOT) -> set[tuple[str, int]]:
    """Which tests in this file the census asks about, and why each one is in.

    A test absent at the base is new. And EVERY definition at a dotted path
    that has more than one definition in this file is in, whatever the base
    held: the occurrence beside the path is a positional ordinal, so it
    names a different definition at the base than at HEAD -- insert an
    unmarked definition ABOVE a marked one and occurrence 0 is the new
    unmarked test while occurrence 1 carries the base's marker, so the
    subtraction checks the wrong definition and passes the added one
    (#1773, round 19).

    Not keyed on the COUNT growing, either: a definition removed and another
    added at one path leaves the count where it was and the same hole opens.
    The walk cannot say WHICH definition of a repeated path is new, so it
    stops trying and asks all of them.
    """
    at_base = set(markers_in(source_at_base(base, touched.at_base, root)))
    here = markers_in(path.read_text(encoding="utf-8"))
    repeated = {dotted for dotted, _ in here if sum(1 for other, _ in here if other == dotted) > 1}
    return {key for key in here if key[0] in repeated or key not in at_base}


def repeated_paths(path: Path) -> set[str]:
    """The dotted paths this file defines more than once."""
    here = markers_in(path.read_text(encoding="utf-8"))
    return {dotted for dotted, _ in here if sum(1 for other, _ in here if other == dotted) > 1}


class Census(NamedTuple):
    """What the walk found for one base: the tests, their kinds, and the offenders."""

    counted: int
    split: dict[str, int]
    offenders: dict[str, list[str]]
    files: tuple[str, ...]


def census(base: str, root: Path = REPO_ROOT) -> Census:
    """The marker census over the diff's own population, for one base.

    ONE function, called by the committed guard and by `--census`, so the
    number a pull request body publishes and the number CI checks come from
    the same walk. What the guard asserts is the INVARIANT -- every test
    added relative to the base carries exactly one marker of a known kind --
    and what a body quotes is the split, which is a fact about one branch
    and belongs where facts about one branch belong (#1773, round 18).
    """
    offenders: dict[str, list[str]] = {"unmarked": [], "multi-marked": [], "unknown kind": []}
    split = {kind: 0 for kind in KINDS}
    counted = 0
    files = touched_test_files(base, root)
    for touched in files:
        path = root / "scripts" / "tests" / touched.relative
        found = markers_in(path.read_text(encoding="utf-8"))
        repeated = repeated_paths(path)
        for key in sorted(new_tests(path, base, touched, root)):
            marks = found[key]
            counted += 1
            named = f"{touched.relative}::{names_one(key)}"
            if key[0] in repeated:
                # Why this one is here even if the base held a definition of
                # that name: the walk cannot say which of them is new.
                named += " (this path has repeated definitions, so all of them are checked)"
            if not marks:
                offenders["unmarked"].append(named)
            elif len(marks) > 1:
                offenders["multi-marked"].append(f"{named} {marks}")
            elif marks[0] not in KINDS:
                offenders["unknown kind"].append(f"{named} {marks[0]}")
            else:
                split[marks[0]] += 1
    return Census(
        counted, split, {k: v for k, v in offenders.items() if v},
        tuple(touched.relative for touched in files),
    )


def print_census(base: str, root: Path = REPO_ROOT) -> int:
    """`--census <base>`: the split and the offenders for that base, for a body to quote."""
    found = census(base, root)
    print(f"marker census over {base}..HEAD, {len(found.files)} test file(s) touched")
    for relative in found.files:
        print(f"  {relative}")
    print(
        f"{found.counted} new test(s): "
        + " / ".join(f"{found.split[kind]} {kind}" for kind in KINDS)
    )
    if not found.counted:
        print(f"no tests added relative to {base}; the census has no population here")
    for kind, names in found.offenders.items():
        for name in names:
            print(f"OFFENDER ({kind}): {name}")
    return 1 if found.offenders else 0


class TheMarkersThisBranchWritesAreCheckedByCITests(unittest.TestCase):
    """The census over the real tree, which is the part a hand-run script was doing."""

    # intent: guard
    # marker: `fix` until round 16, and its own base says otherwise -- every test in this
    # file is green at `f9f522f2`, where the file did not exist, so nothing here can be
    # behaviourally red at it; a test that pins a property the base already has is a guard
    # (#1773, round 16). The fix this round is the sibling below.
    def test_every_test_this_change_adds_declares_exactly_one_intent(self) -> None:
        """The INVARIANT, over the population the diff defines.

        What this asserts is per test and not a count: every test added
        relative to the base carries exactly one marker of a known kind.
        There is no lower bound, because a lower bound is a claim about ONE
        branch committed into a test that runs on every later pull request --
        measured at `7bf61433` in a clone whose `origin/main` is that head, a
        later change touching only `.agents/**` gives `0 not greater than
        100` and one adding three correctly marked tests gives `3 not greater
        than 100`. Round 17 closed `base == HEAD` and called the shape
        closed; it was one instance of it (#1773, round 18).

        An empty population is a normal result. It is announced with the base
        it was measured against rather than passing silently, because a green
        over nothing and a green over a hundred tests should not read the
        same to whoever opens the log.

        This branch's own numbers live in the pull request body, produced by
        `--census <base>` on this same walk.
        """
        base = comparison_base()
        if base.sha is None:
            # The two cases are different and the difference is the whole
            # point of this branch. A LOCAL checkout with no remote cannot
            # say what is new, and refusing there would fail on a clone
            # somebody made to read the code. In CI this guard is the only
            # thing standing between a marker somebody forgot and a green
            # lane, and a skipped guard reads as a green one -- which is the
            # silence this test was committed to end, so it fails and says
            # what to fetch (#1773, round 16).
            if os.environ.get("GITHUB_ACTIONS"):
                self.fail(f"the marker census could not run: {base.missing}")
            self.skipTest(
                f"what is new cannot be measured here; this fails rather than skips "
                f"under GITHUB_ACTIONS ({base.missing})"
            )
        found = census(base.sha)
        self.assertEqual(found.offenders, {}, "markers to fix")
        if not found.counted:
            print(
                f"marker census: no tests added relative to {base.sha[:8]}; "
                "the guard has no population here",
                file=sys.stderr,
            )

    MARKED = "class T{n}:\n    # intent: fix\n    def test_{n}(self):\n        pass\n"
    UNMARKED = "class U{n}:\n    def test_undeclared_{n}(self):\n        pass\n"

    def upstream_with_a_branch(
        self,
        root: Path,
        work: dict[str, str] | None = None,
        main: dict[str, str] | None = None,
        outside: bool = False,
        renames: dict[str, str] | None = None,
    ) -> Path:
        """A repository with `main` and a `work` branch carrying this file.

        One builder for every seed below, because six temporary repositories
        built six ways would be six shapes nobody compares. `main` is what
        the base commit holds, `work` what the branch adds or modifies on top
        of it -- paths relative to `scripts/tests`, nested ones included --
        and `outside` puts the branch's only change outside that directory,
        which is what a later pull request touching `.agents/**` looks like.
        """
        upstream = root / "upstream"
        tests = upstream / "scripts" / "tests"
        tests.mkdir(parents=True)

        def git(*args: str) -> None:
            subprocess.run(["git", *args], cwd=upstream, capture_output=True, check=True)

        def write(where: dict[str, str]) -> None:
            for relative, source in where.items():
                path = tests / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

        # This file is on MAIN, which is where it is once this branch merges
        # -- so the branch under test changes only what the seed asks for,
        # and the census's own tests are out of every seed's population.
        write({
            "test_stub.py": "",
            "test_intent_markers.py": Path(__file__).read_text(encoding="utf-8"),
        } | (main or {}))
        git("init", "--initial-branch=main")
        git("config", "user.email", "tests@example.invalid")
        git("config", "user.name", "tests")
        git("add", "-A")
        git("commit", "-m", "main")
        git("checkout", "-b", "work")
        for old_path, new_path in (renames or {}).items():
            (tests / new_path).parent.mkdir(parents=True, exist_ok=True)
            git("mv", f"scripts/tests/{old_path}", f"scripts/tests/{new_path}")
        write(work or {})
        if outside:
            (upstream / ".agents").mkdir(exist_ok=True)
            (upstream / ".agents" / "note.md").write_text("a later change\n", encoding="utf-8")
        git("add", "-A")
        # `--allow-empty`, because a branch that changes nothing is one of the
        # shapes below and is a legitimate population: empty.
        git("commit", "--allow-empty", "-m", "work")
        return upstream

    def clone_with_the_base(self, root: Path, upstream: Path) -> Path:
        """The branch checked out with `origin/main` resolvable, as the lane has it."""
        sandbox = root / "checkout"
        subprocess.run(
            ["git", "clone", "--quiet", "--branch", "work", str(upstream), str(sandbox)],
            capture_output=True, check=True,
        )
        subprocess.run(
            ["git", "fetch", "--no-tags", "origin", "main:refs/remotes/origin/main"],
            cwd=sandbox, capture_output=True, check=True,
        )
        return sandbox

    def census_in(self, sandbox: Path, ci: bool) -> str:
        """This file, run inside another checkout, the way the lane runs it."""
        environment = {**os.environ, "PYTHONPYCACHEPREFIX": str(sandbox / ".pyc")}
        environment.pop("GITHUB_ACTIONS", None)
        if ci:
            environment["GITHUB_ACTIONS"] = "true"
        finished = subprocess.run(
            [sys.executable, str(sandbox / "scripts" / "tests" / "test_intent_markers.py"), "-v",
             "TheMarkersThisBranchWritesAreCheckedByCITests"
             ".test_every_test_this_change_adds_declares_exactly_one_intent"],
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
            # The seed's OWN literal copy of the printed line, so a change to
            # the constant reds this and forces a re-read. `assertIn(FETCH,
            # ...)` compared the constant against text that constant
            # produced, and a false clause -- `fetch-depth: 1` in both
            # instructions -- passed it (#1773, round 18).
            self.assertIn(
                "git fetch --no-tags origin main:refs/remotes/origin/main"
                "  (or check out with fetch-depth: 0)",
                in_ci,
                "the failure does not print the instruction this seed runs",
            )
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
            # And the other half of the same sentence, run rather than read:
            # `fetch-depth: 0` is a full clone, so a full clone of the same
            # upstream must resolve the base where the single-branch one did
            # not. An instruction in an error message is a claim, and both
            # halves of this one are now claims this seed checks.
            full = root / "full"
            subprocess.run(
                ["git", "clone", "--quiet", "--branch", "work", str(upstream), str(full)],
                capture_output=True, check=True,
            )
            subprocess.run(
                ["git", "fetch", "--no-tags", "origin", "main:refs/remotes/origin/main"],
                cwd=full, capture_output=True, check=True,
            )
            self.assertIsNotNone(
                comparison_base(full).sha,
                "a full clone does not resolve the base the instruction offers it for",
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
            # The deeper instruction's own whole line, owned here.
            self.assertIn(
                "git fetch --no-tags --unshallow origin main:refs/remotes/origin/main"
                "  (or check out with fetch-depth: 0)",
                shallow,
                "the failure does not print the deeper instruction this seed runs",
            )
            # The deeper instruction, taken from what it printed and run.
            subprocess.run(
                self.instruction_printed_in(shallow), cwd=sandbox, capture_output=True, check=True
            )
            self.assertIsNotNone(
                comparison_base(sandbox).sha,
                "the deeper instruction the guard prints does not give it a merge base",
            )

    def planted(self, marked: bool, n: int) -> str:
        """One class, one test, marked or not -- the seeds' only planted shape."""
        marker = "    # intent: fix\n" if marked else ""
        return f"class T{n}:\n{marker}    def test_{n}(self):\n        pass\n"

    # intent: guard
    # marker: GREEN at `ad8b6416`, its own base, and measured there: the base
    # reads every touched file already, so there is no behaviour to be red
    # about. What it pins is that narrowing the population cannot go
    # unnoticed -- finding 4 was that no committed seed could tell an
    # all-files population from a first-file one, and this is red on the
    # `[:1]`, `[:2]`, `[:-1]`, first-plus-last and reversed mutants
    # (#1773, round 19).
    def test_every_touched_file_is_in_the_population_wherever_the_offender_sits(self) -> None:
        """The population is every file the diff touches, and the seeds vary both dimensions.

        `touched_test_files(...)[:1]` left every seed green while dropping
        the real census from 131 tests across five files to 6 across one,
        because no seed's branch touched more than one test file. One
        two-file seed would only move the constant: the number of files is a
        parameter here, driven at one, two and three, and the offender's
        POSITION among them is a second parameter, driven first, middle and
        last -- a population read back to front, or stopped one short, is
        what an offender-always-last seed cannot see.
        """
        for count in (1, 2, 3):
            for position in range(count):
                with self.subTest(files=count, offender_at=position):
                    work = {
                        f"test_seed_{n}.py": self.planted(n != position, n)
                        for n in range(count)
                    }
                    with tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        upstream = self.upstream_with_a_branch(root, work=work)
                        sandbox = self.clone_with_the_base(root, upstream)
                        reported = self.census_in(sandbox, ci=True)
                    self.assertIn("FAILED", reported, f"{count} files, offender {position}")
                    self.assertIn(f"test_seed_{position}.py::T{position}.test_{position}", reported)

    # intent: fix
    # marker: red at `ad8b6416`, its own base, behaviourally: a renamed suite
    # leaves the population empty there and the guard announces "no tests
    # added" over a file carrying an unmarked one (#1773, round 19).
    def test_a_rename_keeps_its_file_in_the_population(self) -> None:
        """`--diff-filter=AM` drops `R`, and an empty population then stands for a real change.

        Four shapes, because `-M` is similarity-thresholded and the path a
        rename takes through git depends on how much of the file changed: a
        rename with a small edit arrives as `R`, a rename with a heavy one
        as add-plus-delete, a rename with no edit at all is a file with
        nothing new in it, and a COPY is a new file whose source still
        exists -- so its tests are new to the census and its base is
        nothing.
        """
        keep = "".join(self.planted(True, n) for n in range(6))
        with self.subTest(shape="a rename with a small edit, plus an unmarked test"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                upstream = self.upstream_with_a_branch(
                    root,
                    main={"test_suite.py": keep},
                    renames={"test_suite.py": "test_renamed.py"},
                    work={"test_renamed.py": keep + self.planted(False, 9)},
                )
                sandbox = self.clone_with_the_base(root, upstream)
                reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, reported)
            self.assertIn("test_renamed.py::T9.test_9", reported)
        with self.subTest(shape="a rename with nothing added"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                upstream = self.upstream_with_a_branch(
                    root,
                    main={"test_suite.py": keep},
                    renames={"test_suite.py": "test_renamed.py"},
                )
                sandbox = self.clone_with_the_base(root, upstream)
                reported = self.census_in(sandbox, ci=True)
                found = census(comparison_base(sandbox).sha, sandbox)
            self.assertIn("OK", reported, reported)
            self.assertEqual(found.counted, 0, "a rename alone added a test")
        with self.subTest(shape="a rename heavy enough to arrive as add plus delete"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                upstream = self.upstream_with_a_branch(
                    root,
                    main={"test_suite.py": keep},
                    renames={"test_suite.py": "test_rewritten.py"},
                    work={"test_rewritten.py": self.planted(False, 9)},
                )
                sandbox = self.clone_with_the_base(root, upstream)
                reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, reported)
            self.assertIn("test_rewritten.py::T9.test_9", reported)
        with self.subTest(shape="a copy is an added file"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                upstream = self.upstream_with_a_branch(
                    root,
                    main={"test_suite.py": keep},
                    work={"test_copy.py": keep + self.planted(False, 9)},
                )
                sandbox = self.clone_with_the_base(root, upstream)
                reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, reported)
            self.assertIn("test_copy.py::T9.test_9", reported)

    # intent: fix
    # marker: red at `ad8b6416`, its own base, behaviourally: the positional
    # subtraction there checks the definition that was always present and
    # passes the one the branch added (#1773, round 19).
    def test_every_definition_of_a_repeated_path_is_asked(self) -> None:
        """The occurrence is positional, so it names a different definition at each end.

        With one marked definition at the base and an unmarked one inserted
        ABOVE it, occurrence 0 at HEAD is the new unmarked test and
        occurrence 1 carries the base's marker -- so a subtraction keyed on
        the ordinal calls occurrence 1 new, checks the marker that was
        always there, and passes the addition.

        Not keyed on the count growing either: a definition removed and
        another added at one path leaves the count where it was. Every
        definition at a path with more than one definition is asked,
        whatever the base held.
        """
        marked = "class A:\n    # intent: fix\n    def test_same(self):\n        pass\n"
        unmarked = "class A:\n    def test_same(self):\n        pass\n"
        for shape, main_source, work_source, offends in (
            ("unmarked inserted above a marked base definition", marked,
             unmarked + marked, True),
            ("marked removed and unmarked added, count unchanged", marked + marked,
             unmarked + marked, True),
            ("the same repeated path, unchanged", marked + marked, marked + marked, False),
        ):
            with self.subTest(shape=shape):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    upstream = self.upstream_with_a_branch(
                        root, main={"test_pair.py": main_source},
                        work=None if work_source == main_source else {"test_pair.py": work_source},
                    )
                    sandbox = self.clone_with_the_base(root, upstream)
                    reported = self.census_in(sandbox, ci=True)
                if offends:
                    self.assertIn("FAILED", reported, reported)
                    self.assertIn("repeated definitions", reported)
                else:
                    self.assertIn("OK", reported, reported)

    # intent: fix
    # marker: red at `ad8b6416`, its own base, behaviourally: every non-zero
    # `git show` reads there as "the file is absent at the base", so a base
    # blob this checkout cannot read publishes that file's old tests as new
    # and the census exits 0 on a question git refused (#1773, round 19).
    def test_a_base_reading_git_refuses_is_not_an_empty_base(self) -> None:
        """Absent and unreadable are different answers, and only one of them is empty.

        An added file has no base reading and every test in it is new -- the
        first half here, so the two directions are one measurement. A base
        reading git REFUSED is a question with no answer, and calling it ""
        moves every test in that file into the new population, so the split
        a body publishes describes a file the census never read.

        The unreadable half is CONSTRUCTED rather than mocked: the base
        blob's object is removed from the store, which is what a corrupt or
        half-fetched object store gives. `git diff` still answers there --
        asserted below, because that is what makes this reachable: there is
        nothing upstream of the base reading to catch it. Driven through
        `census`, which is what `--census` and the invariant both call, so
        the measurement is of behaviour rather than of a name this round
        adds.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(
                root,
                main={"test_suite.py": self.planted(True, 1)},
                work={
                    "test_suite.py": self.planted(True, 1) + self.planted(True, 2),
                    "test_added.py": self.planted(True, 3),
                },
            )

            def asked(*arguments: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    ["git", *arguments], cwd=upstream, capture_output=True, text=True,
                )

            base = asked("rev-parse", "main").stdout.strip()
            # The added file: no base reading, every test in it new, nothing
            # raised. The census counts three -- one added file's test and
            # the two in the modified suite, of which one was there at the
            # base and is not new; that is the next assertion's business.
            found = census(base, upstream)
            self.assertEqual(found.offenders, {}, found.offenders)
            self.assertEqual(found.split["fix"], 2, found.split)

            blob = asked("rev-parse", "main:scripts/tests/test_suite.py").stdout.strip()
            (upstream / ".git" / "objects" / blob[:2] / blob[2:]).unlink()
            self.assertEqual(
                asked("diff", "--name-status", base, "HEAD", "--", "scripts/tests").returncode,
                0,
                "the diff still answers with the base blob gone, so the failure lands here",
            )
            with self.assertRaises(AssertionError) as refused:
                census(base, upstream)
        said = str(refused.exception)
        self.assertIn("test_suite.py", said)
        self.assertIn("could not read", said)
        # git's own words about what it refused, measured, not a sentence
        # this file invented about them.
        self.assertIn("bad object", said)

    # intent: fix
    # marker: red at `ad8b6416`, its own base, behaviourally: the census
    # there keeps `test_*` basenames only, so a branch adding
    # `scripts/tests/regression.py` with an unmarked test in it has the lane
    # running that file and the census never asking about it (#1773, round
    # 19).
    def test_the_census_reads_every_file_the_lane_runs(self) -> None:
        """Two filters over one directory is the shape this file keeps closing.

        The census's population is every `.py` the diff touches under
        `scripts/tests`; the lane runs every `*.py` it finds there. Those
        are the same predicate, and this asserts it over the real tree by
        running the lane's own command rather than by restating it -- with
        the workflow line checked too, because a find that changes shape
        makes this test a comparison against a command nobody runs.
        """
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci-agents.yml").read_text(
            encoding="utf-8"
        )
        found = subprocess.run(
            ["find", "scripts/tests", "-type", "f", "-name", "*.py"],
            capture_output=True, text=True, cwd=REPO_ROOT, check=True,
        )
        self.assertIn(
            "find scripts/tests -type f -name '*.py'",
            workflow,
            "the lane's command changed shape; this comparison is against a command nobody runs",
        )
        lane = {line[len("scripts/tests/"):] for line in found.stdout.split("\n") if line.strip()}
        census_population = {
            path.relative_to(TESTS).as_posix() for path in TESTS.rglob("*.py")
        }
        self.assertEqual(
            lane,
            census_population,
            "the lane runs files the census does not read, or the other way about",
        )
        # And what the old filter would have dropped, named rather than
        # counted: today nothing, which is why the basename filter looked
        # right for eighteen rounds -- so the agreement above is a fact
        # about this tree, and the seed below is the one about the filter.
        self.assertEqual(
            sorted(name for name in lane if not Path(name).name.startswith("test_")),
            [],
            "a `.py` under scripts/tests that the old `test_*` filter would have left out "
            "of the population while the lane ran it",
        )
        # The filter itself, driven: a file the lane runs and the basename
        # filter drops, carrying an unmarked test. Green here and at every
        # earlier head without this seed, because the tree has no such file
        # to distinguish the two filters with.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(
                root, work={"regression.py": self.planted(False, 7)}
            )
            sandbox = self.clone_with_the_base(root, upstream)
            reported = self.census_in(sandbox, ci=True)
        self.assertIn("FAILED", reported, reported)
        self.assertIn("regression.py::T7.test_7", reported)

    # intent: fix
    # marker: red at `7bf61433`, its own base, behaviourally: the census there
    # reads a nested added file at the wrong path and raises
    # `FileNotFoundError` (#1773, round 18).
    def test_a_test_file_the_change_adds_is_read_where_it_is(self) -> None:
        """Three marked tests in a nested new file are three tests, and pass.

        The population was a hand list plus the files the branch ADDS, and
        the added ones were looked up by `.name` -- so
        `scripts/tests/sub/test_new.py`, a path the lane's own filter covers,
        was read at `scripts/tests/test_new.py` and raised. Measured at
        `7bf61433` in a clone: `FileNotFoundError`.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = "".join(self.MARKED.format(n=n) for n in (1, 2, 3))
            upstream = self.upstream_with_a_branch(root, work={"sub/test_new.py": nested})
            sandbox = self.clone_with_the_base(root, upstream)
            reported = self.census_in(sandbox, ci=True)
            self.assertNotIn("FileNotFoundError", reported, reported)
            self.assertIn("OK", reported, reported)
            found = census(comparison_base(sandbox).sha, sandbox)
            self.assertEqual(found.files, ("sub/test_new.py",), "the nested file is the population")
            self.assertEqual(found.counted, 3, "three tests, counted")
            self.assertEqual(found.split["fix"], 3)

    # intent: fix
    # marker: red at `7bf61433`, its own base, behaviourally: the unmarked
    # test in a nested added file is never reached there, because the lookup
    # raises before it (#1773, round 18).
    def test_an_unmarked_test_in_an_added_file_is_named(self) -> None:
        # What the enumerator should REJECT, beside what it should find.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = "".join(self.MARKED.format(n=n) for n in (1, 2, 3)) + self.UNMARKED.format(n=4)
            upstream = self.upstream_with_a_branch(root, work={"sub/test_new.py": source})
            sandbox = self.clone_with_the_base(root, upstream)
            reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, reported)
            self.assertIn("sub/test_new.py::U4.test_undeclared_4", reported)

    # intent: fix
    # marker: red at `7bf61433`, its own base, behaviourally: `Ran 16 tests`
    # / `OK` with the unmarked test invisible, which is the one shape this
    # file's docstring promises to catch (#1773, round 18).
    def test_an_unmarked_test_appended_to_an_existing_suite_is_named(self) -> None:
        """The population is what the diff TOUCHES, not what it adds.

        An unmarked test appended to a suite the hand list did not name was
        invisible: measured at `7bf61433`, appending one to an existing file
        left `Ran 16 tests` / `OK`. A file this change modifies is a file
        this change is answerable for.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(
                root,
                main={"test_runners.py": self.MARKED.format(n=1)},
                work={"test_runners.py": self.MARKED.format(n=1) + self.UNMARKED.format(n=2)},
            )
            sandbox = self.clone_with_the_base(root, upstream)
            reported = self.census_in(sandbox, ci=True)
            self.assertIn("FAILED", reported, reported)
            self.assertIn("test_runners.py::U2.test_undeclared_2", reported)

    # intent: fix
    # marker: red at `7bf61433`, its own base, behaviourally: a failed `git
    # diff` reads as an empty population there and the census passes in
    # silence (#1773, round 18).
    def test_a_diff_git_cannot_answer_is_not_an_empty_population(self) -> None:
        # Two different answers wearing one shape, which is the silence this
        # branch keeps closing: `()` said "nothing changed" for "git could
        # not say". The stderr git printed travels with the failure.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(root)
            sandbox = self.clone_with_the_base(root, upstream)
            with self.assertRaises(AssertionError) as raised:
                touched_test_files("0000000000000000000000000000000000000000", sandbox)
            message = str(raised.exception)
            self.assertIn("could not read what changed", message)
            self.assertIn("0000000", message)
            self.assertNotEqual(message.strip().endswith("since `0000000000000000000000000000000000000000`:"), True)

    # intent: fix
    # marker: red at `7bf61433`, its own base, behaviourally: `0 not greater
    # than 100` on a later change that touches no test file (#1773, round 18).
    def test_a_later_change_outside_the_tests_passes_and_says_why(self) -> None:
        """Every LATER pull request is this shape, which is what makes it blocking.

        `ci-agents.yml` runs this suite on every push and pull request
        touching its path patterns, so once this branch merges a change to
        `.agents/**` alone gets a genuine-ancestor base and a population of
        zero. Round 17 read that as "the empty population happens on exactly
        one branch"; it happens on every branch after this one. Measured at
        `7bf61433` in a clone whose `origin/main` is that head: `0 not
        greater than 100`.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = self.upstream_with_a_branch(root, outside=True)
            sandbox = self.clone_with_the_base(root, upstream)
            reported = self.census_in(sandbox, ci=True)
            self.assertIn("OK", reported, reported)
            self.assertNotIn("FAILED", reported)
            self.assertIn("no tests added relative to", reported)
            base = comparison_base(sandbox)
            self.assertIn(base.sha[:8], reported, "the reason does not name the base it measured")

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
    # TWO decorators, with the second marker between them: the shape this is
    # named for. It carried one, so the seed passed without constructing the
    # case (#1773, round 18).
    BETWEEN = (
        "class T:\n    # intent: guard\n    @unittest.skip('why')\n    # intent: fix\n"
        "    @staticmethod\n    def test_between():\n        pass\n"
    )

    # intent: guard
    def test_one_marker_is_read_as_one(self) -> None:
        self.assertEqual(markers_in(self.ONE), {("T.test_one", 0): ["fix"]})

    # intent: guard
    def test_a_second_marker_is_reported_rather_than_taken(self) -> None:
        # The defect round 12 left and round 13 had to come back for: a
        # reader that takes the first marker reports `guard` and says nothing.
        self.assertEqual(markers_in(self.DOUBLE), {("T.test_two", 0): ["guard", "fix"]})

    # intent: guard
    def test_a_test_with_no_marker_reads_as_none(self) -> None:
        self.assertEqual(markers_in(self.NONE), {("T.test_bare", 0): []})

    # intent: guard
    def test_a_marker_inside_a_docstring_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.IN_DOCSTRING), {("T.test_doc", 0): []})

    # intent: guard
    def test_a_marker_a_blank_line_away_is_not_this_tests(self) -> None:
        self.assertEqual(markers_in(self.BLANK_LINE), {("T.test_far", 0): []})

    # intent: guard
    def test_a_marker_quoted_in_prose_is_not_a_marker(self) -> None:
        self.assertEqual(markers_in(self.PROSE), {("T.test_prose", 0): []})

    # intent: guard
    def test_a_nested_test_is_still_a_test(self) -> None:
        self.assertEqual(markers_in(self.NESTED), {("T.Inner.test_deep", 0): ["control"]})

    # intent: guard
    def test_a_decorated_test_keeps_the_marker_above_its_decorator(self) -> None:
        self.assertEqual(markers_in(self.DECORATED), {("T.test_decorated", 0): ["guard"]})

    # intent: fix
    def test_two_tests_of_one_name_are_two_tests(self) -> None:
        # The key is the dotted path, so the unmarked one is still there to
        # report. Keyed on the bare name this read as a single marked test
        # and the census counted one where there are two (#1773, round 17).
        self.assertEqual(markers_in(self.TWICE), {("A.test_same", 0): ["fix"], ("B.test_same", 0): []})

    # A class defined in both branches of an `if`, the UNMARKED one first:
    # two definitions at one dotted path, which a key without the occurrence
    # collapses into the marked one.
    TWO_DEFINITIONS = (
        "if False:\n    class A:\n        def test_same(self):\n            pass\n"
        "else:\n    class A:\n        # intent: fix\n        def test_same(self):\n"
        "            pass\n"
    )

    # intent: fix
    def test_two_definitions_of_one_dotted_path_are_two_tests(self) -> None:
        # The bare-name key's defect one level down: the later definition
        # overwrote the earlier and the marked one won, so an unmarked test
        # hid behind a marked sibling. The occurrence beside the path is what
        # keeps them apart, and the offender is named by which definition it
        # is (#1773, round 18).
        self.assertEqual(
            markers_in(self.TWO_DEFINITIONS),
            {("A.test_same", 0): [], ("A.test_same", 1): ["fix"]},
        )
        self.assertEqual(names_one(("A.test_same", 1)), "A.test_same (definition 2)")

    # intent: fix
    def test_a_marker_between_two_decorators_is_still_this_tests(self) -> None:
        # Reported as multi-marked rather than missed: the walk reads the
        # decorator span as well as the run above it (#1773, round 17).
        self.assertEqual(markers_in(self.BETWEEN), {("T.test_between", 0): ["guard", "fix"]})

    # A marker inside a DECORATOR's own string argument. A line scanner over
    # the decorator span reads it as a comment because the line starts with
    # `#`; a tokenizer reads the bytes it is, part of a string.
    IN_DECORATOR_STRING = (
        'class T:\n    @unittest.skip("""reason\n# intent: fix\n""")\n'
        "    def test_unmarked(self):\n        pass\n"
    )
    # A test the loader can collect that no `def` creates: the population
    # boundary this walk declares rather than covers.
    ASSIGNED = "class T:\n    # intent: fix\n    test_made = staticmethod(lambda self: None)\n"

    # intent: fix
    def test_a_marker_inside_a_decorators_string_is_not_a_marker(self) -> None:
        # The docstring case one level down: the run ABOVE the decorator was
        # read from comment tokens, the decorator SPAN from raw lines, so a
        # `#` line inside a multi-line decorator argument made an unmarked
        # test read as marked and the guard passed it (#1773, round 19).
        self.assertEqual(markers_in(self.IN_DECORATOR_STRING), {("T.test_unmarked", 0): []})

    # intent: control
    def test_a_test_no_def_creates_is_outside_this_walk(self) -> None:
        # Green at `ad8b6416` and at `016d94ba`: the boundary is the same
        # before and after this round, and this is where it is written down.
        # `test_made` is collectable by unittest and invisible here, so the
        # census asks no marker of it -- declared in the module docstring and
        # in the body's Enumerated line as an unchecked member kind, with the
        # measurement that none exists: zero assignments binding a `test_*`
        # name in a class body and zero `setattr` calls binding a test
        # method, over the five files this branch touches and over all 58
        # (#1773, round 19).
        self.assertEqual(markers_in(self.ASSIGNED), {})


if __name__ == "__main__":
    # `--census <base>` prints this change's split and its offenders for that
    # base and exits non-zero on one. It is the committed command a pull
    # request body's marker numbers name: the numbers are a fact about one
    # branch, so they belong in that branch's body, produced by the same walk
    # CI runs rather than by a script that does not merge (#1773, round 18).
    if len(sys.argv) > 1 and sys.argv[1] == "--census":
        if len(sys.argv) != 3:
            print("usage: test_intent_markers.py --census <base>", file=sys.stderr)
            raise SystemExit(2)
        raise SystemExit(print_census(sys.argv[2]))
    unittest.main()
