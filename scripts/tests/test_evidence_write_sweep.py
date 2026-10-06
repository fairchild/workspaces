#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Pins the write sweep's figures at this tree, so the safety number in a PR body is checkable.

Protects the claim, not the writer: `scripts/evidence-write-sweep.py` is the
instrument a reviewer runs to reproduce "N refusals, and no body loses a line
the author wrote without the runtime saying so", and a number nobody can
reproduce is a relayed number (#1738). These tests fail when the figures move,
when the corpus stops generating, or when the loss detector stops being able to
see a loss.

Safe to run with no network, no secrets, no GitHub and no UI.
"""

from __future__ import annotations

import importlib.util
import itertools
import json
import re
import sys
import unittest
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "evidence-write-sweep.py"

spec = importlib.util.spec_from_file_location("evidence_write_sweep", SCRIPT_PATH)
assert spec and spec.loader
sweep_script = importlib.util.module_from_spec(spec)
sys.modules["evidence_write_sweep"] = sweep_script
spec.loader.exec_module(sweep_script)


class TheSweepReportsTheFiguresAPullRequestQuotesTests(unittest.TestCase):
    """The instrument's numbers at this tree, named so a body can cite them (#1738).

    #1737's body reported a 45-body sweep -- refusals 16 to 22, 0 bodies losing
    a section -- and neither the corpus nor a script was committed, so a second
    party could not run it. This corpus is not that one and does not claim to
    reproduce its figures; it is a corpus that exists in the repository, which
    is the property that was missing.
    """

    # Every tail/successor/ending combination is written once per recorded
    # item, because whose a status line is depends on the item matching.
    BODIES = 408
    REFUSALS = 44
    ANNOUNCED_LOSSES = 4

    @classmethod
    def setUpClass(cls) -> None:
        cls.outcomes = sweep_script.sweep()
        cls.summary = sweep_script.report(cls.outcomes)

    def test_no_body_loses_a_line_without_the_runtime_saying_so(self) -> None:
        # The claim the count is made for, and the reason it is about SILENCE
        # rather than about loss: a block the runtime declines to move and
        # announces is a decision a reader can see and argue with, and a line
        # that leaves the page with nothing printed is what #1725 and #1734
        # were each an instance of.
        silent = [loss for loss in self.summary["losses"] if not loss["said"]]
        self.assertEqual(silent, [])
        self.assertEqual(self.summary["bodies_losing_a_line_silently"], 0)

    def test_the_lines_that_do_go_are_the_ones_the_runtime_names(self) -> None:
        # Two bodies lose a line at this tree, and both are the documented
        # case: a fence with no closing line cannot be moved -- wherever it
        # lands it shows what follows as code -- so it is dropped and said.
        # Pinned rather than left in the headline, so the day one goes quiet
        # the count moves and this fails.
        self.assertEqual(
            self.summary["bodies_losing_a_line_with_a_reason_given"], self.ANNOUNCED_LOSSES
        )
        # The silent count above is only a property if an announcement is
        # attributable: a reading that found one on every body would score
        # every loss announced and report zero silences forever. An
        # announcement appears on the bodies that lost a line and nowhere else.
        self.assertEqual(
            sum(bool(outcome.announced) for outcome in self.outcomes), self.ANNOUNCED_LOSSES
        )
        for loss in self.summary["losses"]:
            with self.subTest(body=loss["body"]):
                self.assertEqual(loss["lost"], ["```text", "a log, never closed"])
                self.assertIn("not carried to `## Evidence Notes`", loss["said"][0])
                self.assertIn("code fence with no closing line", loss["said"][0])

    def test_no_write_closes_a_seam_the_author_wrote(self) -> None:
        # The other half of the headline. A blank line between two of the
        # author's blocks is structure a reader sees, and a write that takes
        # it turns two paragraphs into a heading.
        self.assertEqual(self.summary["seams_closed"], 0)

    def test_the_second_write_changes_nothing(self) -> None:
        # A write that is not a fixed point moves a body every lane run, which
        # is a section travelling one write at a time rather than all at once.
        self.assertEqual(self.summary["bodies_not_a_fixed_point"], 0)

    def test_the_corpus_and_the_refusal_count_are_what_the_body_may_cite(self) -> None:
        self.assertEqual(self.summary["instrument"], "evidence-write-sweep v1")
        self.assertEqual(self.summary["bodies"], self.BODIES)
        self.assertEqual(
            self.summary["bodies"],
            len(sweep_script.ITEMS)
            * len(sweep_script.SECTION_TAILS)
            * len(sweep_script.SUCCESSORS)
            * len(sweep_script.LINE_ENDINGS),
        )
        self.assertEqual(self.summary["refusals"], self.REFUSALS)

    def test_the_refusals_are_the_two_hazards_and_not_a_shape_that_should_write(self) -> None:
        # A refusal count is only a cost if it is the cost of the hazards. Both
        # hazards are a block the parser cannot end; the exception is the one
        # the writer documents -- a runaway fence with no heading below it is a
        # cut to the end of the body that the page agrees with, so it writes.
        # A label leads with the recorded item, so the tail is the second field.
        refused = {outcome.label.split(" / ")[1] for outcome in self.outcomes if outcome.refused}
        self.assertEqual(refused, {"a fence that never closes", "a comment that never closes"})
        wrote = {
            " / ".join(outcome.label.split(" / ")[1:])
            for outcome in self.outcomes
            if not outcome.refused and outcome.label.split(" / ")[1] == "a fence that never closes"
        }
        self.assertEqual(
            wrote,
            {
                "a fence that never closes / nothing below / lf",
                "a fence that never closes / nothing below / crlf",
            },
        )
        # Each hazard refuses under both recorded items.
        self.assertEqual(
            len([outcome for outcome in self.outcomes if outcome.refused]), self.REFUSALS
        )
        # And the great majority of the corpus is written rather than declined,
        # or "0 bodies lose a section" is a property of a writer that declines.
        self.assertGreater(self.BODIES - self.REFUSALS, 100)

    def test_a_loss_with_nothing_said_is_what_counts_as_silent(self) -> None:
        # The classifier behind the headline, on both answers. Without this the
        # number is satisfied by a classifier that calls nothing silent, which
        # is how "0 silent losses" becomes a sentence about the reading rather
        # than about the writer.
        def outcome(
            lost: tuple[str, ...],
            announced: tuple[str, ...],
            closed: tuple[tuple[str, str], ...] = (),
        ) -> sweep_script.Outcome:
            return sweep_script.Outcome(
                label="probe",
                refused=False,
                lost=lost,
                closed=closed,
                announced=announced,
                fixed_point=True,
            )

        self.assertTrue(outcome(("a line",), ()).silent)
        self.assertFalse(outcome(("a line",), ("not carried: ...",)).silent)
        self.assertFalse(outcome((), ()).silent)
        # A closed seam is a loss on the same terms as a missing line.
        self.assertTrue(outcome((), (), (("a", "b"),)).silent)
        self.assertFalse(outcome((), ("not carried: ...",), (("a", "b"),)).silent)

    BLOCKED_UNDER_AN_H1 = "- [blocked] release approval -- the signing profile is missing"

    def test_the_loss_detector_can_see_the_loss_it_exists_to_count(self) -> None:
        """#1734's own loss, which this detector could not see (#1738, round 2).

        The entry filter ran over the WHOLE body, so an author's
        `- [blocked] release approval -- the signing profile is missing` under
        their own `# Release blockers` was read as the machine's line and
        deleting it cost nothing. That is #1734 exactly -- a `[blocked]` bullet
        outside the section, dropped -- and it is what "0 bodies lose a line
        silently" was a reading from.

        The check that was here could not catch it: its bullet carried no
        ` -- `, which is the one shape `ENTRY_LINE_RE` does not match, so the
        detector saw it whether the filter was scoped or not. This one uses the
        shape the filter matches, which is the shape #1734 lost.
        """
        body = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            sweep_script.SUCCESSORS["an h1 below"],
            "\n",
        )
        self.assertIn(self.BLOCKED_UNDER_AN_H1, body)
        self.assertTrue(
            sweep_script.ENTRY_LINE_RE.match(self.BLOCKED_UNDER_AN_H1),
            "the fixture no longer carries the shape the filter matches",
        )
        self.assertEqual(sweep_script.lines_lost(body, body), [])
        self.assertEqual(
            sweep_script.lines_lost(body, body.replace(self.BLOCKED_UNDER_AN_H1 + "\n", "")),
            [self.BLOCKED_UNDER_AN_H1],
        )
        # A heading on its own, and the bullet under it stays the author's --
        # which is what says the detector's frame does not move with the
        # section. Removing the author's `# Release blockers` widens the
        # Evidence Status section over their bullet, and a reading that asked
        # only "is this line inside the section" would then call that bullet
        # the machine's in both bodies and report nothing.
        self.assertEqual(
            sweep_script.lines_lost(body, body.replace("# Release blockers\n\n", "")),
            ["# Release blockers"],
        )
        self.assertEqual(
            sweep_script.lines_lost(body, body.replace("## Validation\n\n", "")),
            ["## Validation"],
        )
        setext = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            sweep_script.SUCCESSORS["a setext h2 below"],
            "\n",
        )
        self.assertEqual(
            sweep_script.lines_lost(setext, setext.replace("-------------\n", "")),
            ["-------------"],
        )
        # And moving a line is not losing it: the write's own job is to move
        # notes, so a detector that scored position would report every write.
        moved = body.replace("A note for the reviewer.\n", "").replace(
            "## Validation\n", "## Validation\n\nA note for the reviewer.\n"
        )
        self.assertEqual(sweep_script.lines_lost(body, moved), [])

    def test_an_entry_the_write_owns_is_exempt_only_inside_the_section(self) -> None:
        # The other direction of the same scoping. A status line under the
        # heading is the write's to rewrite and its going is not a loss; the
        # same shape anywhere else is the author's.
        body = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            sweep_script.SUCCESSORS["an h1 below"],
            "\n",
        )
        owned = f"- [pending-ci] {sweep_script.ITEM} -- {sweep_script.DETAIL}"
        self.assertIn(owned, body)
        self.assertEqual(sweep_script.lines_lost(body, body.replace(owned + "\n", "")), [])
        self.assertIn(self.BLOCKED_UNDER_AN_H1, sweep_script.author_lines(body))
        self.assertNotIn(owned, sweep_script.author_lines(body))

    def test_a_line_is_the_write_s_only_when_it_is_both_recorded_and_in_the_section(self) -> None:
        """Each condition on its own, because each alone lets a loss through.

        SECTION alone reads the section with the same predicate the writer
        uses, so a defect in that predicate widens the section and the
        instrument's frame together: under #1734 restored, the author's bullet
        lands inside the section, is called the machine's in both bodies, and
        the loss goes unseen. METADATA alone exempts an author's own copy of a
        recorded item written under their `## Validation`.

        Dropping either condition leaves the sweep reporting zero, which is why
        neither is pinned by the headline and both are pinned here (#1738,
        round 2).
        """
        recorded = f"- [pending-ci] {sweep_script.ITEM} -- {sweep_script.DETAIL}"
        unrecorded = self.BLOCKED_UNDER_AN_H1

        # Entry-shaped and inside the section, but naming an item the metadata
        # does not record: the author's.
        inside = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"] + unrecorded + "\n",
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )
        self.assertIn(unrecorded, sweep_script.author_lines(inside))
        self.assertNotIn(recorded, sweep_script.author_lines(inside))
        self.assertEqual(
            sweep_script.lines_lost(inside, inside.replace(unrecorded + "\n", "")), [unrecorded]
        )

        # Naming a recorded item, but outside the section: also the author's.
        outside = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            f"## Validation\n\n{recorded}\n",
            "\n",
        )
        self.assertEqual(outside.count(recorded), 2)
        self.assertEqual(sweep_script.author_lines(outside).count(recorded), 1)
        self.assertEqual(
            sweep_script.lines_lost(
                outside, outside.replace(f"## Validation\n\n{recorded}\n", "## Validation\n\n")
            ),
            [recorded],
        )

    @staticmethod
    def _body_with_item(item: str, detail: str, *, tail: str = "", successor: str = "## Validation\n\n- ran it\n") -> str:
        """A body whose recorded item is whatever the caller needs, metadata and all."""
        meta = {
            "entries": [
                {"index": 1, "item": item, "status": "pending-ci", "detail": detail, "kind": "test"}
            ]
        }
        section = f"- [pending-ci] {item} -- {detail}\n" + tail
        return (
            "<!-- evidence-status:v1\n"
            + json.dumps(meta)
            + "\n-->\n\n## Evidence Status\n\n"
            + section.rstrip("\n")
            + "\n\n"
            + successor
        )

    def test_a_recorded_item_that_holds_a_dash_pair_is_still_the_write_s(self) -> None:
        """Ownership is decided by the recorded item, not by where a regex splits (#1738, round 3).

        The item was read out of the line with a non-greedy group up to the
        first ` -- `, so a recorded item that itself holds one -- `build --
        release` -- was cut to `build`, which no metadata records. The write's
        own entry then read as the author's, and an ordinary write of that body
        reported the entry it had just rewritten as a silent loss. A false
        positive on the headline number, which is the same failure as a false
        negative for anyone reading it.

        Each recorded item is matched whole now, escaped, against the line.
        """
        item, detail = "build -- release", "d"
        body = self._body_with_item(item, detail)
        entry = f"- [pending-ci] {item} -- {detail}"
        self.assertIn(entry, body)
        self.assertNotIn(entry, sweep_script.author_lines(body))
        written, refused, said = sweep_script.write_once(body)
        self.assertFalse(refused)
        self.assertEqual(sweep_script.lines_lost(body, written), [])
        self.assertEqual(sweep_script.seams_closed(body, written), [])
        # And an author's line naming a DIFFERENT item is still the author's,
        # whatever dashes it carries.
        theirs = "- [blocked] build -- staging -- someone else's line"
        with_theirs = self._body_with_item(item, detail, successor=f"## Validation\n\n{theirs}\n")
        self.assertIn(theirs, sweep_script.author_lines(with_theirs))

    def test_a_seam_closed_beside_one_that_was_already_there_is_still_reported(self) -> None:
        """Seams are counted, not collected (#1738, round 3).

        The comparison subtracted a SET of the source's seams from the result's,
        so a pair that already appeared once anywhere in the body masked the
        same pair being newly made somewhere else. `A\nB` once and `A`, `B`
        apart becomes `A\nB` twice, and the detector reported nothing -- the
        quiet failure, on the half of the instrument that exists to catch a
        quiet failure.
        """
        before = "A\nB\n\nA\n\nB"
        after = "A\nB\n\nA\nB"
        self.assertEqual(sweep_script.author_seams(before), [("A", "B")])
        self.assertEqual(sweep_script.author_seams(after), [("A", "B"), ("A", "B")])
        self.assertEqual(sweep_script.seams_closed(before, after), [("A", "B")])
        # A pair that was already there and is still there once is not a report.
        self.assertEqual(sweep_script.seams_closed(before, before), [])
        self.assertEqual(sweep_script.seams_closed("A\nB\n\nC", "C\n\nA\nB"), [])

    def test_an_entry_the_write_removed_from_between_two_lines_is_a_seam_it_made(self) -> None:
        """Which of the two readings of an owned entry is right, decided (#1738, round 3).

        `author_seams` treats an owned entry as a separator, so two of the
        author's lines with one between them are not a pair in the source and
        are a pair once the write takes it out -- and the detector reports it.
        The docstring said an entry between two author lines "is not a seam the
        author made", which is true and is not the question: the author did not
        make it, and the WRITE made it, which is what this instrument counts.

        It matters because touching is what a seam is. An author who wrote
        `note above`, an entry, and `===` gets a setext h1 out of the write, and
        a reading that called that nothing would be the seam blindness this
        half of the detector was added for.
        """
        meta = {"entries": [{"index": 1, "item": "x", "status": "pending-ci", "detail": "d", "kind": "test"}]}
        source = (
            "<!-- evidence-status:v1\n"
            + json.dumps(meta)
            + "\n-->\n\n## Evidence Status\n\nnote above\n- [pending-ci] x -- d\n===\n\n"
            "## Validation\n\n- ran\n"
        )
        self.assertEqual(sweep_script.author_seams(source), [])
        removed = source.replace("- [pending-ci] x -- d\n", "")
        self.assertEqual(sweep_script.author_seams(removed), [("note above", "===")])
        self.assertEqual(sweep_script.seams_closed(source, removed), [("note above", "===")])
        # And what it costs the page, which is why it counts: the two lines
        # that now touch are a setext h1 nobody wrote.
        helpers = sys.modules["_helpers"]
        self.assertEqual(
            [
                token.tag
                for token in helpers.MARKDOWN.parse("note above\n===")
                if token.type == "heading_open"
            ],
            ["h1"],
        )

    def test_the_detector_sees_a_seam_a_write_closed(self) -> None:
        """A blank line is structure, and losing it is losing something (#1738, round 2).

        `A note for the reviewer.` and `===` are two paragraphs with a blank
        line between them and one setext h1 without it. Both lines survive
        either way, so a multiset of lines reads the change as nothing --
        which is the seam the placement fixtures in
        `test_factory_evidence_kinds.py` pin, and the instrument that counts
        losses could not see it.

        Pairs rather than blocks, because the writer's own `## Evidence Notes`
        lands directly above the first carried block and makes a block the
        source never had: a pair counts only when the author wrote both of its
        lines.
        """
        seam = sweep_script.body(
            sweep_script.SECTION_TAILS["a note above a line of equals"],
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )
        closed = seam.replace("A note for the reviewer.\n\n===", "A note for the reviewer.\n===")
        self.assertNotEqual(closed, seam)
        self.assertEqual(sweep_script.lines_lost(seam, closed), [], "the lines all survive")
        self.assertEqual(
            sweep_script.seams_closed(seam, closed), [("A note for the reviewer.", "===")]
        )
        # The real write closes none of them, on this body or any other.
        written, _, _ = sweep_script.write_once(seam)
        self.assertEqual(sweep_script.seams_closed(seam, written), [])
        # And the heading the writer adds above a carried note is not a seam it
        # closed, which is the false positive a block comparison would report.
        self.assertIn("## Evidence Notes\nA note for the reviewer.", written)

    def test_the_reading_sees_the_lines_a_rendering_of_the_body_would_not(self) -> None:
        """The blind spots the first reading had, each closed by a body in the corpus.

        The detector read `_rendered_lines` to begin with, which never
        interprets HTML by design -- so deleting `<details>`, its `<summary>`
        or its closer was a change it could not see, on three bodies built out
        of exactly those lines. And it dropped every line carrying the item's
        text, which exempted an author's own sentence about the item. Both
        found by codex (gpt-5.6-sol, xhigh); both are the author's bytes now,
        and this is the test that says so rather than the docstring.
        """
        html = sweep_script.body(
            sweep_script.SECTION_TAILS["a closed details note"],
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )
        for line in ("<details>", "<summary>More</summary>", "</details>"):
            with self.subTest(line=line):
                self.assertEqual(sweep_script.lines_lost(html, html.replace(line + "\n", "")), [line])
        prose = sweep_script.body(
            sweep_script.SECTION_TAILS["a note naming the item in prose"],
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )
        note = f"Reviewer note: {sweep_script.ITEM} only on this head."
        self.assertIn(note, prose)
        self.assertEqual(sweep_script.lines_lost(prose, prose.replace(note + "\n", "")), [note])
        # And the lines the write really does own stay out of it, or every
        # write in the corpus would report a loss.
        written, _, _ = sweep_script.write_once(prose)
        self.assertNotEqual(written, prose)
        self.assertEqual(sweep_script.lines_lost(prose, written), [])

    # intent: guard
    def test_an_unrecorded_status_bullet_under_the_heading_survives_the_write(self) -> None:
        """A status line naming no recorded item is the author's and moves to the notes (#1751)."""
        tail = sweep_script.SECTION_TAILS["an unrecorded status bullet of the author's"]
        self.assertIn(self.BLOCKED_UNDER_AN_H1, tail)
        for successor in sweep_script.SUCCESSORS:
            for ending_name, ending in sweep_script.LINE_ENDINGS.items():
                with self.subTest(successor=successor, ending=ending_name):
                    source = sweep_script.body(tail, sweep_script.SUCCESSORS[successor], ending)
                    written, refused, said = sweep_script.write_once(source)
                    self.assertFalse(refused)
                    self.assertEqual(sweep_script.lines_lost(source, written), [])
                    self.assertEqual(sweep_script.seams_closed(source, written), [])
                    # Nothing is taken, so nothing is announced.
                    self.assertEqual([line for line in said if "not carried" in line], [])
                    self.assertIn(
                        self.BLOCKED_UNDER_AN_H1,
                        sweep_script.MARKDOWN_LINE_ENDING_RE.sub("\n", written),
                    )

    # intent: guard
    def test_the_instrument_and_the_writer_ask_one_function_whose_line_it_is(self) -> None:
        # The sweep and the writer both ask `evidence.is_recorded_status_line`.
        evidence = sys.modules["evidence"]
        source = sweep_script.body(
            sweep_script.SECTION_TAILS["an unrecorded status bullet of the author's"],
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )
        recorded = sweep_script._recorded_items(source)
        self.assertEqual(recorded, {sweep_script.ITEM})
        self.assertTrue(
            evidence.is_recorded_status_line(
                f"- [pending-ci] {sweep_script.ITEM} -- {sweep_script.DETAIL}", recorded
            )
        )
        self.assertFalse(evidence.is_recorded_status_line(self.BLOCKED_UNDER_AN_H1, recorded))
        self.assertIn(self.BLOCKED_UNDER_AN_H1, sweep_script.author_lines(source))
        self.assertNotIn(
            f"- [pending-ci] {sweep_script.ITEM} -- {sweep_script.DETAIL}",
            sweep_script.author_lines(source),
        )

    # One status line in several spellings, with what the write does to it.
    # "replaced" lines leave the section with an announcement; "carried" lines
    # are the author's and move to the notes. The page keeps every line.
    WRAPPED_FORMS = {
        # Byte-identical to the line the write renders, so nothing is said.
        "plain": ("- [pending-ci] {item} -- {detail}", "the write's own bytes"),
        "a bold status token": ("- **[pending-ci]** {item} -- {detail}", "replaced"),
        "an italic status token": ("- _[pending-ci]_ {item} -- {detail}", "replaced"),
        "a bold item": ("- [pending-ci] **{item}** -- {detail}", "replaced"),
        "an ordered marker": ("1. [pending-ci] {item} -- {detail}", "replaced"),
        "a star marker": ("* [pending-ci] {item} -- {detail}", "replaced"),
        # `inline_text` keeps a code span's backticks, so this status token
        # names no status and the line is the author's.
        "a status token in code": ("- `[pending-ci]` {item} -- {detail}", "carried"),
        "a wrapped unrecorded bullet": (
            "- **[blocked]** release approval -- the signing profile is missing",
            "carried",
        ),
    }

    def _wrapped_body(self, line: str) -> str:
        """The corpus body with one more status line under the heading, written as given."""
        return sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"] + line + "\n",
            sweep_script.SUCCESSORS["one h2 below"],
            "\n",
        )

    # intent: fix
    def test_a_status_line_however_it_is_written_keeps_its_bytes_on_the_page(self) -> None:
        """The page keeps every spelling; the rows differ only in what the write says.

        The instrument exempts only bytes the write rendered, so every row
        reads as the author's to it.
        """
        for name, (template, outcome) in self.WRAPPED_FORMS.items():
            with self.subTest(form=name):
                line = template.format(item=sweep_script.ITEM, detail=sweep_script.DETAIL)
                source = self._wrapped_body(line)
                written, refused, said = sweep_script.write_once(source)
                self.assertFalse(refused)
                # Nothing left the page and nothing was pushed together.
                self.assertEqual(sweep_script.lines_lost(source, written), [], name)
                self.assertEqual(sweep_script.seams_closed(source, written), [], name)
                self.assertEqual([note for note in said if "not carried" in note], [])
                replaced = [note for note in said if "replaced in" in note]
                if outcome == "the write's own bytes":
                    # A second copy of the rendered line. The first copy
                    # spends the claim, so this one is kept below the section
                    # without a word.
                    self.assertIn(line, sweep_script.author_lines(source), name)
                    self.assertIn(line.strip(), written, name)
                    self.assertEqual(replaced, [], f"{name}: {said}")
                    continue
                # Every other row is somebody's own bytes, kept below the section.
                self.assertIn(line, sweep_script.author_lines(source), name)
                self.assertIn(line.strip(), written, name)
                self.assertNotIn(
                    line.strip(),
                    sys.modules["evidence"].markdown_section(written, "Evidence Status"),
                    f"{name}: the line stayed in the section the write rewrites",
                )
                if outcome == "replaced":
                    self.assertEqual(len(replaced), 1, f"{name}: {said}")
                else:
                    self.assertEqual(replaced, [], f"{name}: a note was announced as replaced")

    # intent: guard
    def test_the_reading_the_rule_is_asked_of_is_one_function(self) -> None:
        # The sweep takes its reading from `evidence`, not from its own normalisation.
        evidence = sys.modules["evidence"]
        plain = f"- [pending-ci] {sweep_script.ITEM} -- {sweep_script.DETAIL}"
        for name, (template, _) in self.WRAPPED_FORMS.items():
            if "unrecorded" in name or "code" in name:
                continue
            with self.subTest(form=name):
                line = template.format(item=sweep_script.ITEM, detail=sweep_script.DETAIL)
                self.assertEqual(evidence.status_line_as_page_reads_it(line), plain)
        # A reported loss quotes the author's bytes, not the reading.
        theirs = self.WRAPPED_FORMS["a wrapped unrecorded bullet"][0]
        source = self._wrapped_body(theirs)
        self.assertIn(theirs, sweep_script.author_lines(source))
        self.assertEqual(
            sweep_script.lines_lost(source, source.replace(theirs + "\n", "")), [theirs]
        )


# Every status line the grammar below can make. The table above holds readable
# examples; this product covers the forms nobody listed. Each axis is one way a
# line can differ: the status token, the item's markup, the token's wrapper, the
# list marker, an item carrying its own ` -- `, the detail's wrapper, and
# trailing and leading whitespace.
ITEM_MARKUP = {
    "plain": "Manual QA on device",
    "bold": "**Manual QA** on device",
    "italic": "*Manual QA* on device",
    "underscore": "_Manual QA_ on device",
    "inline HTML": "Manual <span>QA</span> on device",
    "a backslash escape": r"Manual \[QA\] on device",
    "a code span": "`Manual QA` on device",
    "a link": "[Manual QA](https://example.invalid/qa) on device",
    "strikethrough": "~~Manual QA~~ on device",
}
ITEM_BASE = {"plain": "{text}", "carrying its own separator": "{text} -- release"}
# Whether the page resolves each wrapper. `inline_text` keeps code spans and
# strikethrough, so a token inside one names no status and the line is the
# author's. The expected answer comes from the axis, not from the code under test.
TOKEN_WRAPPERS = {
    "none": ("[{status}]", True),
    "bold": ("**[{status}]**", True),
    "bold underscores": ("__[{status}]__", True),
    "italic star": ("*[{status}]*", True),
    "italic underscore": ("_[{status}]_", True),
    "nested emphasis": ("**_[{status}]_**", True),
    "a code span": ("`[{status}]`", False),
    "strikethrough": ("~~[{status}]~~", False),
    "emphasis around a code span": ("**`[{status}]`**", False),
}
STATUS_TOKENS = ("complete", "blocked", "pending-ci")
LIST_MARKERS = {"dash": "-", "star": "*", "plus": "+", "ordered dot": "1.", "ordered paren": "1)"}
DETAIL_WRAPPERS = {"none": "{detail}", "a code span": "`{detail}`"}
TRAILING_WHITESPACE = {"none": "", "one space": " ", "a tab": "\t"}
LEADING_INDENT = {"none": "", "one space": " ", "two spaces": "  "}
# Distinct from the corpus's resolved detail, so a replaced line cannot pass
# for the line it was written as.
GENERATED_STATUS_RE = re.compile(r"\[(?:complete|blocked|pending-ci)\]")
GENERATED_DETAIL = "the reviewer ran it by hand"


class Form(NamedTuple):
    """One generated status line, with the axis values it was built from."""

    axes: dict[str, str]
    line: str
    item: str
    resolves: bool


def generated_status_forms():
    """Every line the wrapper grammar can make, as `Form`s."""
    axes = itertools.product(
        STATUS_TOKENS,
        ITEM_MARKUP.items(),
        ITEM_BASE.items(),
        TOKEN_WRAPPERS.items(),
        LIST_MARKERS.items(),
        DETAIL_WRAPPERS.items(),
        TRAILING_WHITESPACE.items(),
        LEADING_INDENT.items(),
    )
    for status, markup, base, wrapper, marker, detail, trailing, indent in axes:
        item = base[1].format(text=markup[1])
        token = wrapper[1][0].format(status=status)
        yield Form(
            axes={
                "status": status,
                "item markup": markup[0],
                "item base": base[0],
                "token wrapper": wrapper[0],
                "list marker": marker[0],
                "detail wrapper": detail[0],
                "trailing whitespace": trailing[0],
                "leading indent": indent[0],
            },
            line=(
                f"{indent[1]}{marker[1]} {token} {item} -- "
                f"{detail[1].format(detail=GENERATED_DETAIL)}{trailing[1]}"
            ),
            item=item,
            resolves=wrapper[1][1],
        )


def writers_reading(line: str) -> str:
    """The write's reading of a line, taken from a parsed section."""
    evidence = sys.modules["evidence"]
    helpers = sys.modules["_helpers"]
    tokens = helpers.MARKDOWN.parse(f"## Evidence Status\n\n{line}\n")
    for index, token in enumerate(tokens):
        if token.type == "list_item_open":
            return evidence._status_item_reading(tokens, index) or line
    return line


class TheTwoProducersOfOneReadingAgreeAcrossTheGrammarTests(unittest.TestCase):
    """Both producers of a line's reading agree, and the rule classifies, across the whole grammar.

    `_status_item_reading` serves the write, which holds a parsed section, and
    `status_line_as_page_reads_it` serves this instrument, which holds source
    bytes (#1751).
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.forms = list(generated_status_forms())

    # intent: control
    def test_the_product_covers_every_axis_it_claims_to(self) -> None:
        # A product missing an axis value covers less than it claims.
        self.assertEqual(len(self.forms), 43_740)
        seen: dict[str, set[str]] = {}
        for form in self.forms:
            for axis, value in form.axes.items():
                seen.setdefault(axis, set()).add(value)
        self.assertEqual(
            {axis: len(values) for axis, values in sorted(seen.items())},
            {
                "detail wrapper": 2,
                "item base": 2,
                "item markup": 9,
                "leading indent": 3,
                "list marker": 5,
                "status": 3,
                "token wrapper": 9,
                "trailing whitespace": 3,
            },
        )

    # intent: guard
    def test_the_two_producers_read_every_form_the_same_way(self) -> None:
        evidence = sys.modules["evidence"]
        disagreements = [
            (form.axes, form.line)
            for form in self.forms
            if writers_reading(form.line) != evidence.status_line_as_page_reads_it(form.line)
        ]
        self.assertEqual(len(disagreements), 0, disagreements[:5])

    # intent: fix
    def test_the_rule_classifies_every_form_the_way_its_axis_says(self) -> None:
        # A line naming a recorded item is the machine's whatever the item's
        # markup; a token inside a code span or strikethrough names no status.
        evidence = sys.modules["evidence"]
        wrong = [
            (form.axes, form.line)
            for form in self.forms
            if evidence.is_recorded_status_line(writers_reading(form.line), [form.item])
            is not form.resolves
        ]
        self.assertEqual(len(wrong), 0, wrong[:5])

    # intent: guard
    def test_a_crlf_line_reads_the_same_as_its_lf_form(self) -> None:
        evidence = sys.modules["evidence"]
        form = next(f for f in self.forms if f.axes["item markup"] == "bold")
        self.assertEqual(
            evidence.status_line_as_page_reads_it(form.line + "\r\n"),
            evidence.status_line_as_page_reads_it(form.line),
        )


class AWriteOverTheGeneratedFormsKeepsEveryLineTests(unittest.TestCase):
    """Two real writes over a covering sample of the grammar keep every line and reach a fixed point.

    A sample rather than the product, because each case is two whole-body
    writes. Every axis value appears at least once.
    """

    def covering_sample(self) -> list:
        """One form per axis value."""
        forms = list(generated_status_forms())
        chosen: dict[tuple[str, str], int] = {}
        for index, form in enumerate(forms):
            for axis, value in form.axes.items():
                chosen.setdefault((axis, value), index)
        return [forms[index] for index in sorted(set(chosen.values()))]

    # intent: guard
    def test_every_axis_value_is_written_without_losing_or_duplicating_a_line(self) -> None:
        sample = self.covering_sample()
        # A sample that skipped an axis value would miss a defect there.
        covered: dict[str, set[str]] = {}
        for form in sample:
            for axis, value in form.axes.items():
                covered.setdefault(axis, set()).add(value)
        self.assertEqual(
            {axis: sorted(values) for axis, values in covered.items()},
            {
                "detail wrapper": sorted(DETAIL_WRAPPERS),
                "item base": sorted(ITEM_BASE),
                "item markup": sorted(ITEM_MARKUP),
                "leading indent": sorted(LEADING_INDENT),
                "list marker": sorted(LIST_MARKERS),
                "status": sorted(STATUS_TOKENS),
                "token wrapper": sorted(TOKEN_WRAPPERS),
                "trailing whitespace": sorted(TRAILING_WHITESPACE),
            },
        )
        for form in sample:
            with self.subTest(**form.axes):
                source = sweep_script.body(
                    sweep_script.SECTION_TAILS["a plain note"] + form.line + "\n",
                    sweep_script.SUCCESSORS["one h2 below"],
                    "\n",
                    form.item,
                )
                written, refused, said = sweep_script.write_once(source)
                self.assertFalse(refused)
                # Nothing left the page and nothing was pushed together.
                self.assertEqual(sweep_script.lines_lost(source, written), [])
                self.assertEqual(sweep_script.seams_closed(source, written), [])
                # A fixed point, so a second write recognises the first one's line.
                again, _, _ = sweep_script.write_once(written)
                self.assertEqual(again, written)
                notes = (
                    written.split("## Evidence Notes", 1)[1]
                    if "## Evidence Notes" in written
                    else ""
                )
                evidence = sys.modules["evidence"]
                status_section = evidence.markdown_section(written, "Evidence Status")
                if form.resolves:
                    # The write replaces the line in the section. Its detail
                    # is somebody's own words, so the text moves to the notes
                    # with an announcement.
                    self.assertNotIn(form.line.strip(), status_section)
                    self.assertIn(form.line.strip(), notes)
                    self.assertTrue(
                        any("replaced in" in line for line in said),
                        f"the replacement went without a word: {said}",
                    )
                    # The write never carries a copy of the line it just rendered.
                    for line in evidence.rendered_entry_lines(
                        evidence.evidence_entries_of(written)
                    ):
                        self.assertNotIn(
                            line, notes, "the write carried the line it had just rendered"
                        )
                else:
                    # The author's line, kept in the notes.
                    self.assertIn(form.line.strip(), notes)


if __name__ == "__main__":
    unittest.main()
