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

import contextlib
import io
import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "evidence-write-sweep.py"

spec = importlib.util.spec_from_file_location("evidence_write_sweep", SCRIPT_PATH)
assert spec and spec.loader
sweep_script = importlib.util.module_from_spec(spec)
sys.modules["evidence_write_sweep"] = sweep_script
spec.loader.exec_module(sweep_script)

helpers = sys.modules["_helpers"]

# What a run with no token raises, in the words the runtime uses. The
# environment is an INPUT to this suite rather than something it inherits: the
# figures below depend on whether the placement check can see the page, and a
# suite that reads that off the ambient environment says one thing on a laptop
# and another on the CI leg that carries a token -- which is what it did
# (#1773, round 7). It also keeps the suite off the network, the way the kinds
# suite's module-wide refusal does.
NO_TOKEN = "no GH_TOKEN or GITHUB_TOKEN in the environment"


@contextlib.contextmanager
def page_unavailable(*, transient: bool):
    """The renderer seam raising one named cause, whatever the environment holds.

    `transient=False` is the tokenless laptop: a permanent local condition, so
    the write refuses rather than placing a section on a weaker check than a
    lane runs. `transient=True` is a blip -- an HTTP failure, an unreachable
    renderer -- where the write proceeds unverified and says so.
    """
    reason = NO_TOKEN if not transient else "the renderer answered HTTP 503"

    def refuse(text: str) -> str:
        raise helpers.RendererUnavailable(
            reason,
            # The cause names the family and the repair together: a raise site
            # cannot pair them wrongly (#1773, round 9).
            cause="server error" if transient else "no token",
        )

    with (
        mock.patch.object(helpers, "render_markdown", side_effect=refuse),
        mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
    ):
        yield


class TheSweepReportsTheFiguresAPullRequestQuotesTests(unittest.TestCase):
    """The instrument's numbers at this tree, named so a body can cite them (#1738).

    #1737's body reported a 45-body sweep -- refusals 16 to 22, 0 bodies losing
    a section -- and neither the corpus nor a script was committed, so a second
    party could not run it. This corpus is not that one and does not claim to
    reproduce its figures; it is a corpus that exists in the repository, which
    is the property that was missing.
    """

    BODIES = 168
    REFUSALS = 22
    # Bodies this run could not ask the page about: the ones whose shape
    # reaches a placement check. The same 24 under a permanent cause (the
    # write stands down) and under a transient one (it goes ahead unverified)
    # -- what the page can say changes what this instrument SEES, never what
    # it counts as a cost (#1773, round 11).
    UNASKED_BODIES = 24
    ANNOUNCED_LOSSES = 2

    @classmethod
    def setUpClass(cls) -> None:
        # Driven, not inherited: see `page_unavailable`. These are the figures
        # a tokenless run prints, which is the run the committed instrument
        # makes on a laptop and in any lane without a token.
        with page_unavailable(transient=False):
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
            len(sweep_script.SECTION_TAILS)
            * len(sweep_script.SUCCESSORS)
            * len(sweep_script.LINE_ENDINGS),
        )
        self.assertEqual(self.summary["refusals"], self.REFUSALS)

    # intent: control
    def test_the_bodies_this_run_could_not_measure_are_counted_and_named(self) -> None:
        """What a run without a page cannot see, said rather than absorbed (#1773, round 6).

        Every corpus body carrying a `<details>` is one the placement check
        asks the page about, and a permanent local condition -- no token --
        means there is no page to ask. The write refuses those rather than
        placing a section on a weaker check than a lane runs: the right answer
        for the write, and a blind spot for this instrument, so the instrument
        names it. A figure a pull request quotes is worth quoting only with
        its denominator, and the denominator here is 168 minus these.

        Round 6 wrote this test against the ambient environment, so it passed
        on a laptop and failed on the CI leg that carries a token. The
        environment is an input now: the cause is raised inside the test, and
        the sibling below drives the other one.
        """
        unmeasured = [outcome for outcome in self.outcomes if outcome.unasked]
        self.assertEqual(self.summary["bodies_the_page_could_not_be_asked_about"], len(unmeasured))
        self.assertEqual(
            {outcome.label.split(" / ")[0] for outcome in unmeasured},
            {"a closed details note", "an element left open"},
        )
        self.assertEqual(self.summary["refusals"], self.REFUSALS)
        # Disjoint over this corpus: a hazard refusal and an unasked page are
        # never the same body, so the two figures add up to every refusal.
        self.assertEqual(
            self.summary["refusals"] + self.summary["bodies_the_page_could_not_be_asked_about"],
            sum(outcome.refused for outcome in self.outcomes),
        )

    # intent: fix
    # marker: `control` until round 13, and the measurement says otherwise -- at
    # `9a5db027` this method fails `0 != 24`, because its own assertion moved from
    # `== 0` to `== 24` when this round's production changed what the field reads
    # (#1773, round 13).
    def test_a_cause_the_write_proceeds_past_leaves_nothing_unmeasured(self) -> None:
        """The sibling: the count tracks the CAUSE, not the corpus (#1773, round 7).

        A blip -- an HTTP failure, an unreachable renderer -- is not a reason
        to refuse, so the write goes ahead unverified and every body is
        measured. The hazard refusals are the same 22 either way, which is the
        property worth having: what the page can or cannot say changes what
        this instrument can SEE and never changes what it counts as a cost.

        Which half asks reality: neither of these two drives a real page --
        both raise a named cause at the seam, so they answer the same on a
        laptop and on a lane with a token. The live both-mode figures are in
        the pull request body, measured by running the committed instrument
        each way.
        """
        with page_unavailable(transient=True):
            summary = sweep_script.report(sweep_script.sweep())
        # 24, not 0: a transient cause is not a reason to refuse, so every
        # body is written -- and the page was not asked about the 24 that
        # reach a placement check, which is exactly what this field counts.
        # It read 0 until round 11, because the seam that says so built its
        # note without the prefix the reading keys on and the count grepped
        # the step log for a phrase instead of asking the predicate.
        self.assertEqual(
            summary["bodies_the_page_could_not_be_asked_about"],
            self.UNASKED_BODIES,
        )
        self.assertEqual(summary["refusals"], self.REFUSALS)
        self.assertEqual(summary["bodies_losing_a_line_silently"], 0)
        self.assertEqual(summary["bodies_not_a_fixed_point"], 0)

    def test_the_refusals_are_the_two_hazards_and_not_a_shape_that_should_write(self) -> None:
        # A refusal count is only a cost if it is the cost of the hazards. Both
        # hazards are a block the parser cannot end; the exception is the one
        # the writer documents -- a runaway fence with no heading below it is a
        # cut to the end of the body that the page agrees with, so it writes.
        #
        # A body the page could not be asked about is not a hazard refusal and
        # is counted separately: this instrument runs with no token, and a
        # placement that cannot see the page refuses rather than proceeding on
        # a weaker check (#1773, round 6).
        refused = {
            outcome.label.split(" / ")[0]
            for outcome in self.outcomes
            if outcome.refused and not outcome.unasked
        }
        self.assertEqual(refused, {"a fence that never closes", "a comment that never closes"})
        wrote = {
            outcome.label
            for outcome in self.outcomes
            if not outcome.refused and outcome.label.startswith("a fence that never closes")
        }
        self.assertEqual(
            wrote,
            {
                "a fence that never closes / nothing below / lf",
                "a fence that never closes / nothing below / crlf",
            },
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
                unasked=False,
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
        written, refused, _, said = sweep_script.write_once(body)
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
        written, _, _, _ = sweep_script.write_once(seam)
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
        written, _, _, _ = sweep_script.write_once(prose)
        self.assertNotEqual(written, prose)
        self.assertEqual(sweep_script.lines_lost(prose, written), [])


class TheInstrumentAsksAValueRatherThanAPhraseTests(unittest.TestCase):
    """What the runtime SAID stopped being load-bearing (#1773, round 11).

    `unasked` grepped the step log for "the page could not be asked", and the
    seam that says it built its note without that prefix -- so the field read
    0 for 24 bodies the page had not been asked about, the same mismatch that
    sent the author's note under the wrong headline. The count reads the
    announcements through the predicate the writer exposes now, so a reworded
    sentence moves nothing.
    """

    # intent: guard
    def test_the_count_survives_a_write_that_announces_without_logging(self) -> None:
        """Driven through the instrument's own entry points (#1773, round 12).

        The first version of this test patched `update_evidence_entries` to
        announce and read `write_once`'s fourth return value, so it was red at
        `9a5db027` because that tuple had three members there -- an API
        difference, not a behaviour one, and a user of this instrument runs
        `sweep()` and `report()`. Under a blip the real seam announces the
        note and logs nothing that the old grep could see, so the field is
        the whole corpus here and read 0 at the previous head.
        """
        with page_unavailable(transient=True):
            outcomes = sweep_script.sweep()
        summary = sweep_script.report(outcomes)
        # Measured under the blip: 24 of the 168 generated bodies reach a
        # placement the page has to answer, and every one of them is counted
        # here and was counted 0 at `9a5db027`.
        self.assertEqual(summary["bodies"], 168)
        self.assertEqual(
            summary["bodies_the_page_could_not_be_asked_about"],
            24,
            "the count read the step log rather than what the write said",
        )
        # The write PROCEEDED on each of those: a blip is not a hazard in the
        # body, so none of the 24 is in the refusal count beside it, and what
        # the old grep searched the step log for was never printed.
        self.assertEqual(
            sum(outcome.unasked and outcome.refused for outcome in outcomes),
            0,
            "a blip was counted as a refusal",
        )

    # intent: guard
    # marker: `fix` until round 15, and its own base says otherwise -- round 13 added it and
    # round 13 changed only test files, so nothing it asserts can be behaviourally red at
    # `dca75200`; it is green there, which is a guard by the rule this body states
    # (#1773, round 15).
    def test_a_renderer_that_answers_on_the_retry_is_not_a_page_that_went_unasked(self) -> None:
        """The two readings, separated through the instrument's public seam.

        Round 12 said the by-value reading's advantage was not observable
        through `write_once`, `sweep()` or `report()`, because the seam that
        announces also prints. That had it backwards, and the case that shows
        it is a renderer that FAILS ONCE and answers on the retry: the write
        asks again, the page answers, the announcement is RETRACTED -- and
        the step log still carries the first failure's sentence. Measured
        over the whole generated corpus, one `write_once` per body with a
        stub that raises on its first call and answers after: the predicate
        says 0 bodies went unasked and the old grep says 24. The grep is the
        one that is wrong, and the public path is where you can see it
        (#1773, round 13).

        Round 19 makes the retraction name its section, and this shape is
        where that shows: the render that failed was the `## Evidence Notes`
        insert's, and the render that answered was the status placement's.
        Retracting every unverified note on that answer told an author the
        page had been reached about a section nothing asked about again. So
        the by-value reading is 24 here now, and what it counts is the notes
        placement -- the status one is still retracted, which is what the
        round-13 property above was about (#1773, round 19).
        """
        def flaky():
            state = {"calls": 0}

            def render(text: str) -> str:
                state["calls"] += 1
                if state["calls"] == 1:
                    raise helpers.RendererUnavailable(
                        "the renderer answered HTTP 503", cause="server error"
                    )
                return "<p>ok</p>"

            return render

        evidence = sys.modules["evidence"]
        by_value = by_grep = bodies = 0
        standing: dict[str, int] = {}
        for tail in sweep_script.SECTION_TAILS.values():
            for successor in sweep_script.SUCCESSORS.values():
                for ending in sweep_script.LINE_ENDINGS.values():
                    source = sweep_script.body(tail, successor, ending)
                    announced: list[str] = []
                    with (
                        mock.patch.object(helpers, "render_markdown", side_effect=flaky()),
                        mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
                        contextlib.redirect_stderr(io.StringIO()),
                    ):
                        evidence.update_evidence_entries(
                            source,
                            {1: {"status": "complete", "detail": sweep_script.RESOLVED_DETAIL}},
                            announcements=announced,
                        )
                    with (
                        mock.patch.object(helpers, "render_markdown", side_effect=flaky()),
                        mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
                    ):
                        _, _, unasked, said = sweep_script.write_once(source)
                    bodies += 1
                    by_value += bool(unasked)
                    by_grep += any("the page could not be asked" in line for line in said)
                    for note in announced:
                        if helpers.is_unverified_announcement(note):
                            heading = str(helpers.unverified_heading(note))
                            standing[heading] = standing.get(heading, 0) + 1
        self.assertEqual(bodies, 168)
        # WHICH section is left unchecked, not how many notes survive: the
        # notes insert's render is the one that failed here and nothing
        # asked about it again, so its note stands; the status placement
        # answered on the retry and its note is retracted.
        self.assertEqual(standing, {"Evidence Notes": 24}, standing)
        self.assertEqual(by_value, 24, "the notes placement went unchecked and nothing says so")
        self.assertEqual(
            by_grep, 24, "the step log no longer carries the first failure; the case is not built"
        )

    # intent: guard
    # marker: red at `016d94ba`, its round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold there and no
    # drive that makes it behaviourally red (#1773, round 12).
    def test_only_a_write_that_announces_without_logging_tells_the_two_apart(self) -> None:
        """The complementary direction: a write that announces and does not print.

        Under a blip that never lifts, both readings agree -- round 11 gave
        the note's constructor the prefix the old grep searched the step log
        for, so the log carries those words too and `sweep()` counts the same
        24 either way. Round 12 concluded from that that the by-value
        reading's advantage was not observable publicly, which was wrong: the
        sibling above separates them through `write_once`, where a renderer
        that answers on the retry leaves the grep over-counting 24 bodies the
        page was reached about.

        What no seam produces today is the other direction, a writer that
        ANNOUNCES WITHOUT LOGGING, so this one reaches into the module rather
        than using it and is declared as the guard it is. It is the shape the
        by-value reading exists to survive (#1773, rounds 12 and 13).
        """
        evidence = sys.modules["evidence"]
        note = sys.modules["_helpers"].unverified_announcement(
            "Evidence Status", "the renderer answered HTTP 503"
        )

        def announce_only(text, updates, announcements=None):
            if announcements is not None:
                announcements.append(note)
            return text

        with mock.patch.object(evidence, "update_evidence_entries", side_effect=announce_only):
            written, refused, unasked, said = sweep_script.write_once(
                "## Evidence Status\n\n- [pending-ci] x -- y\n"
            )
        self.assertEqual(said, (), "the probe logged after all; the assertion below proves nothing")
        self.assertTrue(unasked, "the count read the step log rather than what the write said")

    # intent: guard
    def test_a_stand_down_carries_its_reason_behind_a_known_prefix(self) -> None:
        # The other half: a refusal's reason is read out from behind the
        # stand-down prefix rather than searched for in the sentence.
        evidence = sys.modules["evidence"]
        helpers = sys.modules["_helpers"]
        refusal = helpers._unasked_refusal("Evidence Status", "no token", "export one")
        self.assertTrue(
            sweep_script._says_the_page_was_not_asked(
                f"{evidence.STOOD_DOWN_ANNOUNCEMENT_PREFIX}{refusal}"
            )
        )
        self.assertFalse(
            sweep_script._says_the_page_was_not_asked(
                f"{evidence.STOOD_DOWN_ANNOUNCEMENT_PREFIX}a fence with no closing line"
            )
        )


if __name__ == "__main__":
    unittest.main()
