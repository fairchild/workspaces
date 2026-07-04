#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit tests for the Fable orchestrator ranking core (no network)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from datetime import UTC, datetime
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "fable-orchestrator.py"
spec = importlib.util.spec_from_file_location("fable", SCRIPT)
assert spec and spec.loader
fable = importlib.util.module_from_spec(spec)
sys.modules["fable"] = fable  # so @dataclass can resolve the module by name
spec.loader.exec_module(fable)

NOW = datetime(2026, 7, 3, tzinfo=UTC)
FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "fable-orchestrator"


def snapshot(prs=None, discussions=None, now=NOW):
    return fable.Snapshot(prs=prs or [], discussions=discussions or [], now=now)


class MergeReadyTests(unittest.TestCase):
    def test_mergeable_label_is_merge_ready(self) -> None:
        pr = {"number": 1, "title": "x", "url": "u", "isDraft": False, "labels": [{"name": "mergeable"}]}
        self.assertTrue(fable.is_merge_ready(pr))

    def test_approved_is_merge_ready(self) -> None:
        pr = {"number": 1, "isDraft": False, "reviewDecision": "APPROVED", "labels": []}
        self.assertTrue(fable.is_merge_ready(pr))

    def test_draft_is_never_merge_ready(self) -> None:
        pr = {"number": 1, "isDraft": True, "labels": [{"name": "mergeable"}]}
        self.assertFalse(fable.is_merge_ready(pr))


class IdeaTests(unittest.TestCase):
    def test_unendorsed_idea_awaits_approval(self) -> None:
        self.assertTrue(fable.is_idea_awaiting_approval("[idea] Do the thing"))

    def test_endorsed_idea_is_excluded(self) -> None:
        self.assertFalse(fable.is_idea_awaiting_approval("[idea][endorsed] Do the thing"))

    def test_non_idea_is_excluded(self) -> None:
        self.assertFalse(fable.is_idea_awaiting_approval("[community] Carl's Commentary"))

    def test_idea_must_be_a_prefix_not_mid_sentence(self) -> None:
        # A rambling post that merely mentions [Idea] is not a real proposal.
        self.assertFalse(
            fable.is_idea_awaiting_approval("what do i need to do to have this an [Idea] discussion?")
        )


class RankingTests(unittest.TestCase):
    def test_merge_ready_outranks_idea(self) -> None:
        snap = snapshot(
            prs=[{"number": 1, "title": "ready", "url": "u1", "isDraft": False, "labels": [{"name": "mergeable"}]}],
            discussions=[{"number": 2, "title": "[idea] later", "url": "u2", "createdAt": "2026-07-01T00:00:00Z"}],
        )
        ranked = fable.score_snapshot(snap)
        self.assertEqual(ranked[0].kind, "merge_ready")
        self.assertEqual(ranked[0].action, "Merge PR #1")

    def test_idea_surfaces_when_no_merge_ready(self) -> None:
        snap = snapshot(
            discussions=[{"number": 44, "title": "[idea] X", "url": "u", "createdAt": "2026-06-01T00:00:00Z"}]
        )
        ranked = fable.score_snapshot(snap)
        self.assertEqual(len(ranked), 1)
        self.assertEqual(ranked[0].kind, "idea_awaiting_approval")
        self.assertIn("plan it", ranked[0].action)

    def test_fresher_idea_ranks_first(self) -> None:
        snap = snapshot(
            discussions=[
                {"number": 1, "title": "[idea] old", "url": "u1", "createdAt": "2026-05-01T00:00:00Z"},
                {"number": 2, "title": "[idea] new", "url": "u2", "createdAt": "2026-07-02T00:00:00Z"},
            ]
        )
        ranked = fable.score_snapshot(snap)
        self.assertEqual(ranked[0].ref, "Discussion #2")

    def test_empty_state_yields_no_candidates(self) -> None:
        self.assertEqual(fable.score_snapshot(snapshot()), [])


class FixtureTests(unittest.TestCase):
    def test_fixture_pack_ranks_merge_ready_first(self) -> None:
        snap = fable.load_fixture(FIXTURES)
        result = fable.build_result(snap)
        self.assertEqual(result["recommendation"]["kind"], "merge_ready")
        # Endorsed idea and draft PR must not appear anywhere.
        blob = result["markdown"]
        self.assertNotIn("#40", blob)  # endorsed idea
        self.assertNotIn("Draft:", blob)
        # Two merge-ready PRs and two awaiting ideas in the fixture.
        self.assertEqual(result["pulse"]["merge_ready"], 2)
        self.assertEqual(result["pulse"]["ideas_awaiting"], 2)

    def test_markdown_points_at_existing_surface(self) -> None:
        snap = fable.load_fixture(FIXTURES)
        md = fable.build_result(snap)["markdown"]
        self.assertIn("Do this first: Merge PR", md)
        self.assertIn("nothing here acts on its own", md)


if __name__ == "__main__":
    unittest.main()
