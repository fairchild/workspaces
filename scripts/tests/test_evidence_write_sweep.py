#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Pins the write sweep's figures at this tree, so the safety number in a PR body is checkable.

Protects the claim, not the writer: `scripts/evidence-write-sweep.py` is the
instrument a reviewer runs to reproduce "N refusals, 0 bodies lose a section",
and a number nobody can reproduce is a relayed number (#1738). These tests fail
when the figures move, when the corpus stops generating, or when the loss
detector stops being able to see a loss.

Safe to run with no network, no secrets, no GitHub and no UI.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

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

    BODIES = 156
    REFUSALS = 22
    ANNOUNCED_LOSSES = 2

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
                self.assertEqual(loss["lost"], ["a log, never closed"])
                self.assertIn("not carried to `## Evidence Notes`", loss["said"][0])
                self.assertIn("code fence with no closing line", loss["said"][0])

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

    def test_the_refusals_are_the_two_hazards_and_not_a_shape_that_should_write(self) -> None:
        # A refusal count is only a cost if it is the cost of the hazards. Both
        # hazards are a block the parser cannot end; the exception is the one
        # the writer documents -- a runaway fence with no heading below it is a
        # cut to the end of the body that the page agrees with, so it writes.
        refused = {outcome.label.split(" / ")[0] for outcome in self.outcomes if outcome.refused}
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
        def outcome(lost: tuple[str, ...], announced: tuple[str, ...]) -> sweep_script.Outcome:
            return sweep_script.Outcome(
                label="probe", refused=False, lost=lost, announced=announced, fixed_point=True
            )

        self.assertTrue(outcome(("a line",), ()).silent)
        self.assertFalse(outcome(("a line",), ("not carried: ...",)).silent)
        self.assertFalse(outcome((), ()).silent)

    def test_the_loss_detector_can_see_a_loss(self) -> None:
        # Anti-vacuity for the headline number. A detector that reported
        # nothing would report zero losses on every corpus forever.
        body = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            sweep_script.SUCCESSORS["an h1 below"],
            "\n",
        )
        self.assertEqual(sweep_script.lines_lost(body, body), [])
        # A heading, and -- the case a heading-only comparison scored clean --
        # a bullet under one. #1734's defect took the bullet and left the
        # heading, so a detector that only counts headings cannot see it.
        self.assertEqual(
            sweep_script.lines_lost(body, body.replace("# Release blockers\n\n", "")),
            ["# Release blockers"],
        )
        self.assertEqual(
            sweep_script.lines_lost(
                body, body.replace("- [blocked] the signing profile is missing\n", "")
            ),
            ["- [blocked] the signing profile is missing"],
        )
        # A setext heading and a rule too, which a `^## ` scan could not see.
        setext = sweep_script.body(
            sweep_script.SECTION_TAILS["a plain note"],
            sweep_script.SUCCESSORS["a setext h2 below"],
            "\n",
        )
        self.assertIn(
            "## Boundary note",
            sweep_script.lines_lost(setext, setext.replace("Boundary note\n-------------\n", "")),
        )
        # And moving a line is not losing it: the write's own job is to move
        # notes, so a detector that scored position would report every write.
        moved = body.replace(
            "A note for the reviewer.\n", ""
        ).replace("## Validation\n", "## Validation\n\nA note for the reviewer.\n")
        self.assertEqual(sweep_script.lines_lost(body, moved), [])


if __name__ == "__main__":
    unittest.main()
