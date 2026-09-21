#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Writes a generated corpus of PR bodies through the Evidence Status rewrite, twice, and reports what moved.

The safety claim behind that rewrite is a count -- how many bodies it declines
and how many lose a line a reader had -- and a count in a PR body that no
second party can reproduce is a relayed number (#1738). This is the instrument
that produces it: the corpus is generated here from a cross product of shapes
rather than stored, so regenerating the figure needs this file and the skill
modules it writes through, and no stored corpus to go stale beside them.

Run it with `uv run --script scripts/evidence-write-sweep.py`; add `--json` for
the machine-readable form. It touches no network, no repository state and no
GitHub. `scripts/tests/test_evidence_write_sweep.py` pins its numbers at the
current tree, so a change to the writer that moves them fails there.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_SCRIPTS = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"

INSTRUMENT = "evidence-write-sweep v1"
ITEM = "`swift test` passes"
DETAIL = "the lane has not run yet"
RESOLVED_DETAIL = "214 tests passed"

# What sits under the status line. Each entry is a block the rewrite has to
# carry to `## Evidence Notes`, or a hazard it has to decline -- the two
# outcomes the count is about.
SECTION_TAILS = {
    "nothing but the status line": "",
    "a plain note": "\nA note for the reviewer.\n",
    "a note and a link": "\nA note for the reviewer.\n\nRun: https://example.invalid/actions/runs/1\n",
    "a closed fenced excerpt": "\n```\n214 tests passed\n```\n",
    "an indented code block": "\n    214 tests passed\n\nand a note under it.\n",
    "a table": "\n| run | result |\n| --- | --- |\n| 1 | green |\n",
    "an element left open": "\n<details>\n<summary>More</summary>\n\nplain note\n",
    "a closed details note": "\n<details>\n<summary>More</summary>\n\nplain note\n\n</details>\n",
    "a link reference definition": "\n[run]: https://example.invalid/1\n",
    "a note carrying a fenced heading": "\nA note.\n\n```markdown\n## Not a heading\n```\n",
    "a fence that never closes": "\n```text\na log, never closed\n",
    "a comment that never closes": "\n<!-- a note the author left\n",
    "a note above a line of equals": "\nA note for the reviewer.\n\n===\n",
    # A note that NAMES the item the write is rewriting. The first reading
    # here dropped every line carrying the item's text, so an author's own
    # sentence about it was exempt from the loss check and could go unseen
    # (codex, gpt-5.6-sol, xhigh). `author_lines` matches the entry SHAPE now,
    # and this body is what says so.
    "a note naming the item in prose": f"\nReviewer note: {ITEM} only on this head.\n",
    # The author's OWN status bullet, naming an item the body records nowhere.
    # The writer took it as its own and replaced it while this instrument read
    # it as the author's, which is two answers about one line -- and on this
    # body the answer that won deleted it and said nothing (#1751). It is the
    # author's now at both readers, and this body is what says so on a real
    # write rather than in a docstring.
    "an unrecorded status bullet of the author's": (
        "\nA note for the reviewer.\n"
        "- [blocked] release approval -- the signing profile is missing\n"
    ),
}

# What the author wrote after the section. The successor decides where the
# carried region's tail seam falls, and whether there is a heading below the
# section for the write to be able to lose.
SUCCESSORS = {
    "one h2 below": "## Validation\n\n- ran the suite on this head\n",
    "two h2s below": "## Validation\n\n- ran it\n\n## Risks\n\nNone.\n",
    # The blocked bullet carries a ` -- `, which is what a reader reads as a
    # status entry -- so it is the shape the write's own entry filter would
    # have swallowed if that filter ran outside the section, and it is #1734's
    # own body. Without it the corpus could not see that hazard on a real
    # write (#1738, round 2).
    "an h1 below": "# Release blockers\n\n- [blocked] release approval -- the signing profile is missing\n\n## Validation\n\n- ran it\n",
    "a setext h2 below": "Boundary note\n-------------\n\nunder the underline\n",
    "the author's own dash rule below": "---\n\nA closing remark.\n",
    "nothing below": "",
}

LINE_ENDINGS = {"lf": "\n", "crlf": "\r\n"}


def load(name: str, path: Path):
    """The skill's own modules, by path, with their directory on the path only while they load."""
    sys.path.insert(0, str(SKILL_SCRIPTS))
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(SKILL_SCRIPTS))


helpers = load("_helpers", SKILL_SCRIPTS / "_helpers.py")
evidence = load("evidence", SKILL_SCRIPTS / "evidence.py")
MARKDOWN_LINE_ENDING_RE = helpers.MARKDOWN_LINE_ENDING_RE


def body(tail: str, successor: str, ending: str) -> str:
    """One PR body: the metadata the writer reads, the section, the tail under it, and the author's next block."""
    meta = {
        "entries": [
            {"index": 1, "item": ITEM, "status": "pending-ci", "detail": DETAIL, "kind": "test"}
        ]
    }
    section = f"- [pending-ci] {ITEM} -- {DETAIL}\n" + tail
    text = (
        "<!-- evidence-status:v1\n"
        + json.dumps(meta)
        + "\n-->\n\n## Evidence Status\n\n"
        + section.rstrip("\n")
        + "\n\n"
        + successor
    )
    return text.replace("\n", ending)


# The shape a reader reads as an entry, which is the shape #1734 lost. The
# filter below does not match on it -- whose line this is, shape included, is
# `evidence.is_recorded_status_line` and nowhere else (#1751) -- and the
# fixtures name it to say which shape they are built out of.
ENTRY_LINE_RE = re.compile(r"^\s*- \[(?:complete|blocked|pending-ci)\] .+ -- .+$")


def _recorded_items(text: str) -> set[str]:
    """The items this write is rewriting, read from the body's own metadata.

    The write renders its status lines from the recorded entries and from
    nothing else, so the metadata is what it owns. This is the condition that
    does not move when the thing being measured moves: scoping by the SECTION
    alone reads the section with the same predicate the writer uses, and a
    defect in that predicate widens the section and the instrument's own frame
    together -- under #1734 restored, the author's bullet lands inside the
    section, is read as the machine's in both bodies, and the loss this whole
    instrument exists to count reads as nothing (#1738, round 2).
    """
    metadata = evidence._extract_evidence_metadata(text)
    entries = metadata.get("entries") if isinstance(metadata, dict) else None
    if not isinstance(entries, list):
        return set()
    return {
        str(entry["item"]).strip()
        for entry in entries
        if isinstance(entry, dict) and entry.get("item")
    }


def _entry_line_numbers(lines: list[str], text: str, recorded: set[str]) -> set[int]:
    """Which lines are the status entries this write owns.

    Three conditions, and each one answers a way the filter was wrong.

    It is entry-SHAPED, rather than carrying the item's text anywhere: a line
    naming the item in prose is the author's sentence about it.

    It names an item the metadata RECORDS -- asked of `evidence`, which is the
    same function the write asks (`is_recorded_status_line`), and asked of the
    page's reading of the line, which is where the write asks it from. A
    status-shaped line inside the section that names no recorded item is the
    author's, wherever it sits, and the write moves it to `## Evidence Notes`
    like any other block. Answering it here in a pattern of this file's own was
    two definitions of one rule, and on the author's own `- [blocked] release
    approval -- the signing profile is missing` written under the heading they
    disagreed: the write replaced it and this instrument called the
    replacement a silent loss (#1751). Asking the one rule with the raw line
    while the write asked it with the parser's reading was the same
    disagreement one markup form over -- a bold status token, an emphasised
    item, an ordered or `*` marker -- so the reading comes from `evidence` too
    (#1751, round 2). What a loss REPORTS is still the author's own bytes:
    this decides ownership, not what a line looks like when it goes.

    And it sits INSIDE the section, so an author's copy of a recorded item
    under their own `## Validation` stays theirs.

    A body with no metadata has no entries the write owns, and a body with no
    readable section has none either: both are the conservative answer, which
    is that every line is the author's.

    `recorded` is read from the body BEFORE its metadata comment is stripped,
    and `text` is the body after -- the comment is not the author's and does
    not take part in the comparison, but it is where the entries are written
    down.
    """
    if not recorded:
        return set()
    bounds = helpers._section_bounds(text, "Evidence Status")
    if bounds is None:
        return set()
    starts, offset = [], 0
    for line in lines:
        starts.append(offset)
        offset += len(line) + 1
    return {
        index
        for index, start in enumerate(starts)
        if bounds[1] <= start < bounds[2]
        and evidence.is_recorded_status_line(
            evidence.status_line_as_page_reads_it(lines[index]), recorded
        )
    }


def author_lines(text: str) -> list[str]:
    """Every line of the body the author wrote, with what this write owns taken out.

    The author's own bytes, not a rendering. A rendering was the first reading
    here and it was a lossy one: `_rendered_lines` never interprets HTML by
    design, so deleting `<details>`, its `<summary>` or its closer was a change
    it could not see, and the corpus carries three bodies built out of exactly
    those lines (codex, gpt-5.6-sol, xhigh). Source lines see every one of
    them, and a fence marker and an indent besides.

    Two things come out, and both are this write's to change. The metadata
    comment is re-rendered on every write. And the status entries -- matched on
    the SHAPE a reader reads as an entry rather than on the item's text,
    because a line naming the item in prose is the author's, and matched only
    where the write owns them, which is inside the section and nowhere else.
    """
    source = MARKDOWN_LINE_ENDING_RE.sub("\n", text)
    normalized = evidence._strip_evidence_metadata(source)
    lines = normalized.split("\n")
    owned = _entry_line_numbers(lines, normalized, _recorded_items(source))
    return [
        line
        for index, line in enumerate(lines)
        if line.strip() and index not in owned
    ]


def author_seams(text: str) -> list[tuple[str, str]]:
    """Each pair of the author's lines this body puts next to each other with nothing between.

    The other half of what a write can take, and the half a multiset of lines
    is blind to: `A note for the reviewer.` and `===` are two paragraphs with a
    blank line between them and one setext h1 without it, and both lines
    survive either way (#1738, round 2).

    A blank line separates, and so does a status entry. The author did not make
    the gap an entry fills -- but this instrument counts what the WRITE did, and
    a write that takes an entry out from between two of the author's lines has
    put those lines next to each other. `note above`, an entry, and `===`
    becomes `note above` over `===`, which is a setext h1 nobody wrote. So the
    entry separates in the source and its removal is a seam the write made, and
    `seams_closed` reports it (#1738, round 3).

    Pairs and not blocks. A block multiset reports every carried note, because
    the writer's own `## Evidence Notes` lands directly above the first one and
    makes a block the source never had. A PAIR is a seam only when both its
    lines were already in the source, which `seams_closed` is what asks.
    """
    source = MARKDOWN_LINE_ENDING_RE.sub("\n", text)
    normalized = evidence._strip_evidence_metadata(source)
    lines = normalized.split("\n")
    owned = _entry_line_numbers(lines, normalized, _recorded_items(source))
    seams, previous = [], None
    for index, line in enumerate(lines):
        if not line.strip() or index in owned:
            previous = None
            continue
        if previous is not None:
            seams.append((previous, line))
        previous = line
    return seams


def seams_closed(before: str, after: str) -> list[tuple[str, str]]:
    """Every pair of the author's lines the write put next to each other that were not.

    Only pairs whose BOTH lines the author already wrote: the writer adds
    `## Evidence Notes` directly above the first carried block, and a heading
    it wrote is not a seam it closed.

    Counted, not collected. Subtracting a SET of the source's seams let a pair
    that already appeared once anywhere in the body mask the same pair being
    newly made somewhere else -- `A\nB` once plus `A` and `B` apart becoming
    `A\nB` twice reported nothing, which is a quiet failure on the half of this
    instrument that exists to catch a quiet failure (#1738, round 3).
    """
    source = set(author_lines(before))
    already = Counter(author_seams(before))
    closed = Counter(
        pair
        for pair in author_seams(after)
        if pair[0] in source and pair[1] in source
    )
    return sorted((closed - already).elements())


def lines_lost(before: str, after: str) -> list[str]:
    """Every line the page showed before the write and does not show after it.

    Lines rather than headings, because the loss this number is about was a
    line: #1734's defect carried an author's `# Release blockers` into
    `## Evidence Notes` and dropped the `- [blocked]` bullet under it, so a
    heading-only comparison scores that write clean. Moving a line is not
    losing it -- the write moves notes by design -- so the comparison is a
    multiset over the whole body and not a position check.
    """
    remaining = author_lines(after)
    lost = []
    for line in author_lines(before):
        if line in remaining:
            remaining.remove(line)
        else:
            lost.append(line)
    return lost


@dataclass(frozen=True)
class Outcome:
    label: str
    refused: bool
    lost: tuple[str, ...]
    closed: tuple[tuple[str, str], ...]
    announced: tuple[str, ...]
    fixed_point: bool

    @property
    def took(self) -> bool:
        """Whether this write took anything from the page a reader had.

        A line gone and a seam closed are the same kind of loss: one takes a
        line away, the other takes the blank that kept two blocks two, and the
        page a reader gets back is not the page they wrote (#1738, round 2).
        """
        return bool(self.lost) or bool(self.closed)

    @property
    def silent(self) -> bool:
        """Whether this body lost a line with nothing said about it.

        The number worth quoting. A block the runtime declines to move and
        says so about is a decision a reader can see and argue with; a line
        that leaves the page with nothing printed is the failure #1725 and
        #1734 were both instances of.

        Attribution is at the level of the BODY, not the line: a body that
        printed one "not carried" line has every loss in it counted as
        announced, so a write that dropped a second line quietly beside an
        announced one would read as clean here (codex, gpt-5.6-sol, xhigh).
        Tightening it needs the announcement to carry the lines rather than
        the block and its line number, which is a change to the runtime's
        message. The test pins which lines went and which message went with
        them, so the two cases that exist are attributed by hand.
        """
        return self.took and not self.announced


def write_once(text: str) -> tuple[str, bool, tuple[str, ...]]:
    """The body after one rewrite, whether the writer declined it, and what it said.

    Both are read from what the runtime prints rather than inferred from the
    body: stderr is where the person reading a workflow log meets them, so a
    change that stops announcing something shows up here as silence.
    """
    spoke = io.StringIO()
    with contextlib.redirect_stderr(spoke):
        written = evidence.update_evidence_entries(
            text, {1: {"status": "complete", "detail": RESOLVED_DETAIL}}
        )
    said = tuple(line for line in spoke.getvalue().splitlines() if line.strip())
    refused = any("refusing to rewrite" in line for line in said)
    return written, refused, said


def sweep() -> list[Outcome]:
    """Every generated body, written twice, with what the write cost it."""
    outcomes = []
    for tail_name, tail in SECTION_TAILS.items():
        for successor_name, successor in SUCCESSORS.items():
            for ending_name, ending in LINE_ENDINGS.items():
                source = body(tail, successor, ending)
                written, refused, said = write_once(source)
                again, _, _ = write_once(written)
                outcomes.append(
                    Outcome(
                        label=f"{tail_name} / {successor_name} / {ending_name}",
                        refused=refused,
                        lost=tuple(lines_lost(source, written)),
                        closed=tuple(seams_closed(source, written)),
                        announced=tuple(line for line in said if "not carried" in line),
                        fixed_point=again == written,
                    )
                )
    return outcomes


def report(outcomes: list[Outcome]) -> dict[str, object]:
    return {
        "instrument": INSTRUMENT,
        "bodies": len(outcomes),
        "refusals": sum(outcome.refused for outcome in outcomes),
        "bodies_losing_a_line_silently": sum(outcome.silent for outcome in outcomes),
        "bodies_losing_a_line_with_a_reason_given": sum(
            outcome.took and bool(outcome.announced) for outcome in outcomes
        ),
        "seams_closed": sum(bool(outcome.closed) for outcome in outcomes),
        "bodies_not_a_fixed_point": sum(not outcome.fixed_point for outcome in outcomes),
        "losses": [
            {
                "body": outcome.label,
                "lost": list(outcome.lost),
                "closed": [list(pair) for pair in outcome.closed],
                "said": list(outcome.announced),
            }
            for outcome in outcomes
            if outcome.took
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    args = parser.parse_args(argv)
    summary = report(sweep())
    if args.json:
        print(json.dumps(summary, indent=2))
        return 0
    print(f"{summary['instrument']}: {summary['bodies']} bodies, written twice")
    print(f"  refusals: {summary['refusals']}")
    print(f"  bodies losing a line silently: {summary['bodies_losing_a_line_silently']}")
    print(
        "  bodies losing a line with a reason given: "
        f"{summary['bodies_losing_a_line_with_a_reason_given']}"
    )
    print(f"  bodies whose seam a write closed: {summary['seams_closed']}")
    print(f"  bodies not a fixed point on the second write: {summary['bodies_not_a_fixed_point']}")
    for loss in summary["losses"]:
        if loss["lost"]:
            print(f"  lost {loss['lost']} from: {loss['body']}")
        if loss["closed"]:
            print(f"  closed {loss['closed']} in: {loss['body']}")
        for said in loss["said"] or ["(nothing said)"]:
            print(f"    {said}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
