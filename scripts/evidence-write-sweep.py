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
rather than stored, so regenerating the figure needs this file and nothing else.

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
import sys
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
}

# What the author wrote after the section. The successor decides where the
# carried region's tail seam falls, and whether there is a heading below the
# section for the write to be able to lose.
SUCCESSORS = {
    "one h2 below": "## Validation\n\n- ran the suite on this head\n",
    "two h2s below": "## Validation\n\n- ran it\n\n## Risks\n\nNone.\n",
    "an h1 below": "# Release blockers\n\n- [blocked] the signing profile is missing\n\n## Validation\n\n- ran it\n",
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


def reader_lines(text: str) -> list[str]:
    """The lines a reader sees, with the entries this write is rewriting left out.

    `_rendered_lines` is the runtime's own rendering, so what counts as a line
    on the page is one answer rather than two. The status entries come out
    because rewriting them is what the write is FOR -- every other line is one
    the author put there, and a write that ends with fewer of them has taken
    something from a page somebody was reading.
    """
    return [
        line
        for line in evidence._rendered_lines(text)
        if line.strip() and ITEM not in line
    ]


def lines_lost(before: str, after: str) -> list[str]:
    """Every line the page showed before the write and does not show after it.

    Lines rather than headings, because the loss this number is about was a
    line: #1734's defect carried an author's `# Release blockers` into
    `## Evidence Notes` and dropped the `- [blocked]` bullet under it, so a
    heading-only comparison scores that write clean. Moving a line is not
    losing it -- the write moves notes by design -- so the comparison is a
    multiset over the whole body and not a position check.
    """
    remaining = reader_lines(after)
    lost = []
    for line in reader_lines(before):
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
    announced: tuple[str, ...]
    fixed_point: bool

    @property
    def silent(self) -> bool:
        """Whether this body lost a line with nothing said about it.

        The number worth quoting. A block the runtime declines to move and
        says so about is a decision a reader can see and argue with; a line
        that leaves the page with nothing printed is the failure #1725 and
        #1734 were both instances of.
        """
        return bool(self.lost) and not self.announced


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
            bool(outcome.lost) and bool(outcome.announced) for outcome in outcomes
        ),
        "bodies_not_a_fixed_point": sum(not outcome.fixed_point for outcome in outcomes),
        "losses": [
            {
                "body": outcome.label,
                "lost": list(outcome.lost),
                "said": list(outcome.announced),
            }
            for outcome in outcomes
            if outcome.lost
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
    print(f"  bodies not a fixed point on the second write: {summary['bodies_not_a_fixed_point']}")
    for loss in summary["losses"]:
        print(f"  lost {loss['lost']} from: {loss['body']}")
        for said in loss["said"] or ["(nothing said)"]:
            print(f"    {said}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
