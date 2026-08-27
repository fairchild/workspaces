#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for the CHANGES_REQUESTED response turn (#1378).

Intent: prove the lane never parks silently -- every standing changes-requested
review from a trusted reviewer draws exactly one owner-addressed response
naming the gesture, no one outside the lane can suppress that response, and
manual recovery can reach a second reviewer's standing verdict.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review-response.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review-response.yml"
REPO_VARIABLES_MANIFEST = REPO_ROOT / "config" / "github" / "repo-variables.json"

OWNER = "fairchild"
PLAT = "workspace-agents[bot]"
APRIL = "april-clearwater[bot]"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


response = load_module("factory_review_response_under_test", SCRIPT_PATH)


def evidence_body(*entries: dict[str, object]) -> str:
    payload = json.dumps({"entries": list(entries)}, indent=2)
    return f"## Summary\n\n<!-- evidence-status:v1\n{payload}\n-->\n\n## Evidence Status\n"


def pull_request(
    *,
    state: str = "open",
    draft: bool = False,
    labels: tuple[str, ...] = ("author:april",),
    body: str = "",
) -> dict[str, object]:
    return {
        "number": 1377,
        "state": state,
        "draft": draft,
        "labels": [{"name": name} for name in labels],
        "body": body,
    }


def april_comment(body: str) -> dict[str, object]:
    return {"user": {"login": APRIL}, "body": body}


def review(
    *,
    login: str = PLAT,
    state: str = "CHANGES_REQUESTED",
    submitted_at: str = "2026-08-27T04:00:00Z",
    review_id: int = 900,
) -> dict[str, object]:
    return {
        "id": review_id,
        "state": state,
        "submitted_at": submitted_at,
        "user": {"login": login},
        "html_url": f"https://github.com/fairchild/workspaces/pull/1377#pullrequestreview-{review_id}",
    }


class ReviewSelectionTests(unittest.TestCase):
    def test_latest_changes_requested_from_trusted_reviewer_is_answered(self) -> None:
        found = response.blocking_review(
            [
                review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                review(review_id=2, submitted_at="2026-08-27T02:00:00Z"),
            ],
            OWNER,
            None,
        )
        assert found is not None
        self.assertEqual(found["id"], 2)

    def test_pending_and_dismissed_reviews_neither_block_nor_supersede(self) -> None:
        pending = review(review_id=3, state="PENDING", submitted_at="")
        dismissed = review(
            review_id=4, state="DISMISSED", submitted_at="2026-08-27T09:00:00Z"
        )
        self.assertEqual(response.standing_reviews([pending, dismissed], OWNER), [])
        standing = review(review_id=1, submitted_at="2026-08-27T01:00:00Z")
        found = response.blocking_review([standing, pending, dismissed], OWNER, None)
        assert found is not None
        self.assertEqual(found["id"], 1)

    def test_manual_recovery_reaches_an_older_unanswered_review(self) -> None:
        # Two reviewers, both standing; the newer one is already answered. The
        # older must not be shadowed forever by it.
        newer = review(login=APRIL, review_id=2, submitted_at="2026-08-27T02:00:00Z")
        older = review(login=PLAT, review_id=1, submitted_at="2026-08-27T01:00:00Z")
        found = response.blocking_review(
            [older, newer], OWNER, None, answered=lambda rid: rid == 2
        )
        assert found is not None
        self.assertEqual(found["id"], 1)
        self.assertIsNone(
            response.blocking_review(
                [older, newer], OWNER, None, answered=lambda _: True
            )
        )

    def test_reviewer_supersedes_their_own_verdict_with_an_approval(self) -> None:
        self.assertIsNone(
            response.blocking_review(
                [
                    review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                    review(
                        review_id=2,
                        state="APPROVED",
                        submitted_at="2026-08-27T02:00:00Z",
                    ),
                ],
                OWNER,
                None,
            )
        )

    def test_comment_only_review_does_not_displace_a_standing_verdict(self) -> None:
        found = response.blocking_review(
            [
                review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                review(
                    review_id=2,
                    state="COMMENTED",
                    submitted_at="2026-08-27T02:00:00Z",
                ),
            ],
            OWNER,
            None,
        )
        assert found is not None
        self.assertEqual(found["id"], 1)

    def test_supersede_uses_timestamps_not_api_order(self) -> None:
        # The reviews endpoint's order is not a contract; a newer approval
        # returned before an older rejection must still supersede it.
        self.assertIsNone(
            response.blocking_review(
                [
                    review(
                        review_id=2,
                        state="APPROVED",
                        submitted_at="2026-08-27T02:00:00Z",
                    ),
                    review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                ],
                OWNER,
                None,
            )
        )

    def test_untrusted_reviewer_does_not_earn_a_response(self) -> None:
        self.assertIsNone(
            response.blocking_review([review(login="drive-by-collaborator")], OWNER, None)
        )

    def test_owner_changes_requested_is_trusted(self) -> None:
        self.assertIsNotNone(response.blocking_review([review(login=OWNER)], OWNER, None))

    def test_explicit_review_id_selects_that_review(self) -> None:
        found = response.blocking_review(
            [review(login=PLAT, review_id=7), review(login=APRIL, review_id=8)],
            OWNER,
            8,
        )
        assert found is not None
        self.assertEqual(found["id"], 8)

    def test_explicit_review_id_that_is_no_longer_standing_is_not_answered(self) -> None:
        self.assertIsNone(
            response.blocking_review(
                [
                    review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                    review(
                        review_id=2,
                        state="APPROVED",
                        submitted_at="2026-08-27T02:00:00Z",
                    ),
                ],
                OWNER,
                1,
            )
        )


class ResponseDecisionTests(unittest.TestCase):
    def evaluate(self, pr: dict[str, object], **kwargs):
        return response.evaluate_response(
            pr,
            kwargs.pop("blocking", review()),
            repository_owner=OWNER,
            already_responded=kwargs.pop("already_responded", False),
        )

    def test_blocked_evidence_escalates_and_names_the_gesture(self) -> None:
        body = evidence_body(
            {
                "index": 1,
                "item": "README link present in the PR diff (owner-attested)",
                "status": "blocked",
            }
        )
        decision = self.evaluate(
            pull_request(labels=("author:april", "blocked:evidence"), body=body)
        )
        self.assertEqual(decision.action, "respond")
        self.assertTrue(decision.owner_required)
        self.assertEqual(
            [blocker.key for blocker in decision.blockers], ["evidence-attestation"]
        )
        detail = decision.blockers[0].detail
        self.assertIn("## Evidence Status", detail)
        self.assertIn("[complete]", detail)
        self.assertIn("blocked:evidence", detail)

    def test_pending_ci_alone_still_escalates(self) -> None:
        # A pending entry does not prove the review is covered: the lane never
        # reads the review prose, and the entry can sit forever (named check
        # absent, failing, verifier off). Escalate, and list it as context.
        body = evidence_body(
            {
                "index": 1,
                "item": "CI: `check-links` green on the PR head",
                "status": "pending-ci",
            }
        )
        decision = self.evaluate(
            pull_request(labels=("author:april", "blocked:evidence"), body=body)
        )
        self.assertEqual(decision.action, "respond")
        self.assertTrue(decision.owner_required)
        self.assertEqual(
            sorted(blocker.key for blocker in decision.blockers),
            ["evidence-pending-ci", "revision-required"],
        )

    def test_unexplained_review_defaults_to_explicit_escalation(self) -> None:
        # The #1378 invariant: an objection the state model does not explain
        # must surface as an owner ask, never as silence.
        decision = self.evaluate(pull_request(body="## Summary\n\nno evidence block\n"))
        self.assertEqual(decision.action, "respond")
        self.assertTrue(decision.owner_required)
        self.assertEqual(
            [blocker.key for blocker in decision.blockers], ["revision-required"]
        )
        self.assertIn("#1125", decision.blockers[0].detail)

    def test_owner_blocker_alongside_a_self_clearing_one_still_escalates(self) -> None:
        body = evidence_body(
            {"index": 1, "item": "CI: `check-links` green", "status": "pending-ci"},
            {"index": 2, "item": "owner-attested judgement call", "status": "blocked"},
        )
        decision = self.evaluate(pull_request(body=body))
        self.assertTrue(decision.owner_required)
        self.assertEqual(
            sorted(blocker.key for blocker in decision.blockers),
            ["evidence-attestation", "evidence-pending-ci"],
        )

    def test_other_blocking_label_escalates(self) -> None:
        decision = self.evaluate(
            pull_request(labels=("author:april", "blocked:secrets"), body="")
        )
        self.assertTrue(decision.owner_required)
        self.assertIn("label:blocked:secrets", [b.key for b in decision.blockers])

    def test_lingering_blocked_evidence_label_is_its_own_blocker(self) -> None:
        # Every entry complete but the label still applied: the readiness gate
        # fails on the label alone, so it must not fall through unexplained.
        body = evidence_body(
            {"index": 1, "item": "CI: `check-links` green", "status": "complete"}
        )
        decision = self.evaluate(
            pull_request(labels=("author:april", "blocked:evidence"), body=body)
        )
        self.assertTrue(decision.owner_required)
        self.assertEqual(
            [blocker.key for blocker in decision.blockers], ["label:blocked:evidence"]
        )

    def test_needs_human_label_escalates(self) -> None:
        decision = self.evaluate(
            pull_request(labels=("author:april", "needs-human"), body="")
        )
        self.assertIn("needs-human", [b.key for b in decision.blockers])

    def test_closed_draft_unlabeled_and_answered_reviews_are_skipped(self) -> None:
        self.assertEqual(self.evaluate(pull_request(state="closed")).action, "skip")
        self.assertEqual(self.evaluate(pull_request(draft=True)).action, "skip")
        self.assertEqual(self.evaluate(pull_request(labels=())).action, "skip")
        self.assertEqual(
            self.evaluate(pull_request(labels=("author:april", "author:plat"))).action,
            "skip",
        )
        self.assertEqual(self.evaluate(pull_request(), blocking=None).action, "skip")
        self.assertEqual(
            self.evaluate(pull_request(), already_responded=True).action, "skip"
        )


class ResponseCommentTests(unittest.TestCase):
    def render(self, pr: dict[str, object], blocking: dict[str, object]) -> str:
        decision = response.evaluate_response(
            pr, blocking, repository_owner=OWNER, already_responded=False
        )
        return response.response_comment(decision, blocking, repository_owner=OWNER)

    def test_escalation_names_the_owner_the_reviewer_and_the_review(self) -> None:
        body = evidence_body({"index": 1, "item": "owner-attested item", "status": "blocked"})
        text = self.render(pull_request(body=body), review())
        self.assertIn(f"This needs @{OWNER}", text)
        self.assertIn("workspace-agents's", text)
        self.assertIn("pullrequestreview-900", text)
        self.assertIn(response.response_marker(900), text)

    def test_every_response_addresses_the_owner(self) -> None:
        # The invariant: there is no "you are not needed" outcome. A response
        # that promised one and was wrong would recreate the silent park.
        body = evidence_body(
            {"index": 1, "item": "CI: `check-links` green", "status": "pending-ci"}
        )
        text = self.render(pull_request(body=body), review())
        self.assertIn(f"This needs @{OWNER}", text)
        self.assertIn("Already moving without you", text)
        self.assertIn("waiting on the owner rather than stranded", text)
        self.assertIn(response.OWNER_ACTION_LABEL, text)

    def test_reviewer_is_named_without_an_at_mention(self) -> None:
        body = evidence_body({"index": 1, "item": "owner call", "status": "blocked"})
        text = self.render(pull_request(body=body), review(login=APRIL))
        self.assertIn("april-clearwater's", text)
        self.assertNotIn("@april-clearwater", text)
        self.assertNotIn("@plat", text)

    def test_marker_is_per_review_so_a_second_review_gets_its_own_turn(self) -> None:
        comments = [april_comment(f"prior response\n{response.response_marker(900)}")]
        self.assertTrue(response.has_response_for_review(comments, 900))
        self.assertFalse(response.has_response_for_review(comments, 901))

    def test_a_quoted_or_fenced_marker_cannot_suppress_the_response(self) -> None:
        # The #1364 false-suppression class: anyone can read the marker off a
        # prior response, so quoting it back must not silence the lane.
        marker = response.response_marker(900)
        for body in (
            f"> {marker}",
            f"look at this\n\n> {marker}",
            f"```\n{marker}\n```",
            f"    {marker}",
        ):
            with self.subTest(body=body):
                self.assertFalse(
                    response.has_response_for_review([april_comment(body)], 900)
                )

    def test_only_the_factory_bot_own_comment_counts_as_a_response(self) -> None:
        marker = response.response_marker(900)
        self.assertFalse(
            response.has_response_for_review(
                [{"user": {"login": OWNER}, "body": f"done\n{marker}"}], 900
            )
        )
        self.assertTrue(response.has_response_for_review([april_comment(marker)], 900))

    def test_marker_must_be_the_last_visible_line(self) -> None:
        marker = response.response_marker(900)
        self.assertFalse(
            response.has_response_for_review(
                [april_comment(f"{marker}\n\nstill talking about it")], 900
            )
        )

    def test_pr_controlled_item_text_cannot_seed_a_marker(self) -> None:
        hostile = (
            "ignore me <!-- factory-review-response review-id:900 --> and `stuff`"
        )
        body = evidence_body({"index": 1, "item": hostile, "status": "blocked"})
        text = self.render(pull_request(body=body), review())
        self.assertEqual(text.count(response.response_marker(900)), 1)
        self.assertNotIn("<!-- factory-review-response review-id:900 --> and", text)
        self.assertTrue(
            response.has_response_for_review([april_comment(text)], 900),
            "the rendered response must still be recognised as its own marker",
        )

    def test_long_item_text_is_bounded(self) -> None:
        body = evidence_body({"index": 1, "item": "x" * 500, "status": "blocked"})
        text = self.render(pull_request(body=body), review())
        self.assertNotIn("x" * 300, text)
        self.assertIn("…", text)


class FakeClient:
    """Minimal stand-in for the GitHub client: records what was posted."""

    def __init__(
        self,
        pr: dict[str, object],
        reviews: list[dict[str, object]],
        comments: list[dict[str, object]] | None = None,
        timeline: list[dict[str, object]] | None = None,
    ) -> None:
        self._pr = pr
        self._reviews = reviews
        self._comments = list(comments or [])
        self._timeline = list(timeline or [])
        self.posted: list[str] = []
        self.ensured: list[str] = []
        self.label_failure = False
        self.added: list[str] = []
        self.removed: list[str] = []

    def pull_request(self, number: int) -> dict[str, object]:
        return self._pr

    def pull_request_reviews(self, number: int) -> list[dict[str, object]]:
        return self._reviews

    def comments(self, number: int) -> list[dict[str, object]]:
        return self._comments

    def comment(self, number: int, body: str) -> None:
        self.posted.append(body)
        self._comments.append({"user": {"login": APRIL}, "body": body})

    def ensure_label(self, name: str, color: str, description: str) -> bool:
        self.ensured.append(name)
        return not self.label_failure

    def add_label(self, number: int, name: str) -> None:
        self.added.append(name)
        self._pr["labels"] = [*self._pr["labels"], {"name": name}]

    def remove_label(self, number: int, name: str) -> None:
        self.removed.append(name)
        self._pr["labels"] = [
            label for label in self._pr["labels"] if label.get("name") != name
        ]

    def timeline(self, number: int) -> list[dict[str, object]]:
        return self._timeline


class RespondTests(unittest.TestCase):
    """End-to-end over the real respond() -- the selection and rendering tests
    above all still pass if the posting call is deleted."""

    def setUp(self) -> None:
        # respond() writes step outputs; give it a file so they do not land in
        # the test log.
        handle = tempfile.NamedTemporaryFile("w", delete=False)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        patcher = mock.patch.dict(os.environ, {"GITHUB_OUTPUT": handle.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        buffer = io.StringIO()
        redirect = contextlib.redirect_stdout(buffer)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def blocked_pr(self) -> dict[str, object]:
        return pull_request(
            labels=("author:april", "blocked:evidence"),
            body=evidence_body(
                {"index": 1, "item": "owner-attested item", "status": "blocked"}
            ),
        )

    def test_a_standing_review_gets_exactly_one_posted_response(self) -> None:
        client = FakeClient(self.blocked_pr(), [review()])
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(len(client.posted), 1)
        self.assertIn(f"This needs @{OWNER}", client.posted[0])
        # Re-delivery of the same review must not double-post.
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(len(client.posted), 1)

    def test_a_quoted_marker_from_a_human_does_not_suppress_the_post(self) -> None:
        client = FakeClient(
            self.blocked_pr(),
            [review()],
            comments=[
                {
                    "user": {"login": OWNER},
                    "body": f"as in\n\n> {response.response_marker(900)}",
                }
            ],
        )
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(len(client.posted), 1)

    def test_a_second_reviewer_gets_its_own_turn_from_manual_recovery(self) -> None:
        plat_review = review(login=PLAT, review_id=1, submitted_at="2026-08-27T01:00:00Z")
        april_review = review(login=APRIL, review_id=2, submitted_at="2026-08-27T02:00:00Z")
        client = FakeClient(self.blocked_pr(), [plat_review, april_review])
        response.respond(client, 1377, None, OWNER)  # newest unanswered: 2
        response.respond(client, 1377, None, OWNER)  # now the older one: 1
        response.respond(client, 1377, None, OWNER)  # nothing left standing
        self.assertEqual(len(client.posted), 2)
        self.assertIn(response.response_marker(2), client.posted[0])
        self.assertIn(response.response_marker(1), client.posted[1])

    def labeled_event(self, actor: str, at: str = "2026-08-27T01:00:00Z"):
        return {
            "event": "labeled",
            "label": {"name": response.OWNER_ACTION_LABEL},
            "actor": {"login": actor},
            "created_at": at,
        }

    def test_escalating_marks_the_pr_as_waiting_on_the_owner(self) -> None:
        # #1381: a PR waiting on the owner used to look exactly like a stranded
        # one. The label is what makes the two distinguishable at a glance and
        # queryable in the digest.
        client = FakeClient(self.blocked_pr(), [review()])
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])
        self.assertEqual(client.ensured, [response.OWNER_ACTION_LABEL])
        self.assertIn(response.OWNER_ACTION_LABEL, client.posted[0])

    def test_the_label_is_applied_once_not_on_every_review(self) -> None:
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(pr, [review()])
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(client.added, [])
        self.assertEqual(client.ensured, [])

    def test_an_approval_withdraws_the_factory_own_label(self) -> None:
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(
            pr,
            [review(state="APPROVED")],
            timeline=[self.labeled_event(APRIL)],
        )
        response.respond(client, 1377, None, OWNER)
        self.assertEqual(client.removed, [response.OWNER_ACTION_LABEL])
        self.assertEqual(client.posted, [])

    def test_a_hand_applied_label_is_left_alone(self) -> None:
        # A person applying it is making a statement, not leaving machine
        # state, and the factory has no business withdrawing it.
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(
            pr,
            [review(state="APPROVED")],
            timeline=[self.labeled_event(OWNER)],
        )
        response.respond(client, 1377, None, OWNER)
        self.assertEqual(client.removed, [])

    def test_a_relabel_by_the_factory_after_a_hand_application_counts(self) -> None:
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(
            pr,
            [review(state="APPROVED")],
            timeline=[
                self.labeled_event(OWNER, "2026-08-27T01:00:00Z"),
                self.labeled_event(PLAT, "2026-08-27T02:00:00Z"),
            ],
        )
        response.respond(client, 1377, None, OWNER)
        self.assertEqual(client.removed, [response.OWNER_ACTION_LABEL])

    def test_a_still_standing_rejection_keeps_the_label(self) -> None:
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(
            pr,
            [
                review(login=PLAT, review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                review(login=APRIL, review_id=2, state="APPROVED", submitted_at="2026-08-27T02:00:00Z"),
            ],
            timeline=[self.labeled_event(APRIL)],
        )
        response.respond(client, 1377, None, OWNER)
        self.assertEqual(client.removed, [])

    def test_an_approval_does_not_clear_while_another_reviewer_blocks(self) -> None:
        # The webhook passes the approving review's id, and blocking_review
        # filters to that review -- so reading "nothing to answer" as "nobody
        # is blocking" clears the marker the moment ONE reviewer approves.
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(
            pr,
            [
                review(login=PLAT, review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                review(
                    login=APRIL,
                    review_id=2,
                    state="APPROVED",
                    submitted_at="2026-08-27T02:00:00Z",
                ),
            ],
            timeline=[self.labeled_event(APRIL)],
        )
        response.respond(client, 1377, 2, OWNER)  # the approving review's id
        self.assertEqual(client.removed, [])

    def test_an_already_answered_rejection_still_gets_its_marker(self) -> None:
        # Level-triggered: repairs a failed application, a hand-removed label,
        # and any escalation that predates the marker.
        pr = self.blocked_pr()
        client = FakeClient(
            pr,
            [review()],
            comments=[
                {
                    "user": {"login": APRIL},
                    "body": f"prior\n{response.response_marker(900)}",
                }
            ],
        )
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(client.posted, [])
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])

    def test_incomplete_review_data_never_clears_the_marker(self) -> None:
        # Absence of a standing rejection only means something if every
        # trusted reviewer's record could be read.
        pr = self.blocked_pr()
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        for name, broken in (
            ("no login", {"id": 5, "state": "APPROVED", "user": {}, "submitted_at": "x"}),
            (
                "unknown state",
                {"id": 5, "state": "ESCALATED", "user": {"login": PLAT}, "submitted_at": "x"},
            ),
            (
                "no timestamp",
                {"id": 5, "state": "APPROVED", "user": {"login": PLAT}, "submitted_at": ""},
            ),
            ("not a dict", "APPROVED"),
        ):
            with self.subTest(case=name):
                client = FakeClient(pr, [broken], timeline=[self.labeled_event(APRIL)])
                response.respond(client, 1377, None, OWNER)
                self.assertEqual(client.removed, [])

    def test_a_label_that_cannot_be_applied_is_not_claimed_in_the_comment(self) -> None:
        client = FakeClient(self.blocked_pr(), [review()])
        client.label_failure = True
        response.respond(client, 1377, 900, OWNER)
        self.assertEqual(len(client.posted), 1)
        self.assertIn("could not be applied", client.posted[0])
        self.assertNotIn("stays on this PR", client.posted[0])

    def test_a_closed_pull_request_is_left_untouched(self) -> None:
        pr = pull_request(state="closed")
        pr["labels"] = [*pr["labels"], {"name": response.OWNER_ACTION_LABEL}]
        client = FakeClient(pr, [], timeline=[self.labeled_event(APRIL)])
        response.respond(client, 1377, None, OWNER)
        self.assertEqual(client.removed, [])
        self.assertEqual(client.posted, [])

    def test_a_superseded_review_draws_no_post(self) -> None:
        client = FakeClient(
            self.blocked_pr(),
            [
                review(review_id=1, submitted_at="2026-08-27T01:00:00Z"),
                review(
                    review_id=2, state="APPROVED", submitted_at="2026-08-27T02:00:00Z"
                ),
            ],
        )
        response.respond(client, 1377, 1, OWNER)
        self.assertEqual(client.posted, [])


class WorkflowContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_every_entry_path_is_gated_by_both_kill_switches(self) -> None:
        gate = self.workflow.split("runs-on:", 1)[0]
        self.assertEqual(gate.count("vars.AGENT_AUTOMATIONS_ENABLED == 'true'"), 2)
        self.assertEqual(gate.count("vars.FACTORY_REVIEW_RESPONSE_ENABLED == 'true'"), 2)

    def test_manual_dispatch_is_owner_only(self) -> None:
        self.assertIn("github.actor == github.repository_owner", self.workflow)
        self.assertIn("github.triggering_actor == github.repository_owner", self.workflow)

    def test_only_same_repository_heads_reach_the_credentialed_lane(self) -> None:
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            self.workflow,
        )

    def test_only_a_marked_pull_request_earns_a_cleanup_run(self) -> None:
        # An ordinary approval on an unmarked PR must skip before a runner
        # starts or an App token is minted.
        gate = self.workflow.split("runs-on:", 1)[0]
        self.assertIn(
            "contains(github.event.pull_request.labels.*.name, 'owner-action')", gate
        )
        self.assertIn(f"'{response.OWNER_ACTION_LABEL}'", gate)

    def test_a_dismissal_also_withdraws_the_marker(self) -> None:
        self.assertIn("types: [submitted, dismissed]", self.workflow)
        self.assertIn("github.event.review.state == 'dismissed'", self.workflow)

    def test_responds_to_changes_requested_and_to_approval(self) -> None:
        # Approval is the event that withdraws the marker: the reviewer has
        # stopped blocking, so the factory's claim about the owner has stopped
        # being true and should not linger.
        self.assertIn("github.event.review.state == 'changes_requested'", self.workflow)
        self.assertIn("github.event.review.state == 'approved'", self.workflow)
        self.assertNotIn("'commented'", self.workflow)

    def test_untrusted_reviewers_never_reach_the_app_token_step(self) -> None:
        # The allowlist lives in the job `if:` as well as the script, so an
        # untrusted CHANGES_REQUESTED never starts a credentialed job at all.
        gate = self.workflow.split("runs-on:", 1)[0]
        self.assertIn("github.event.review.user.login == github.repository_owner", gate)
        for bot in sorted(response.factory_review.REVIEWER_BOTS.values()):
            self.assertIn(f"github.event.review.user.login == '{bot}'", gate)

    def test_a_third_party_rerun_cannot_replay_a_trusted_review(self) -> None:
        gate = self.workflow.split("runs-on:", 1)[0]
        self.assertIn("github.triggering_actor == github.actor", gate)

    def test_runs_trusted_default_branch_scripts_and_never_checks_out_pr_code(self) -> None:
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", self.workflow)
        self.assertNotIn("head.sha", self.workflow)
        self.assertNotIn("head.ref", self.workflow)

    def test_serialized_per_pull_request(self) -> None:
        self.assertIn("group: factory-review-response-", self.workflow)
        self.assertIn("cancel-in-progress: false", self.workflow)

    def test_token_scope_is_comment_only(self) -> None:
        self.assertIn("permission-issues: write", self.workflow)
        self.assertIn("permission-pull-requests: read", self.workflow)
        self.assertNotIn("permission-contents: write", self.workflow)

    def test_actions_are_sha_pinned(self) -> None:
        refs = re.findall(r"uses:\s+(?!\./)(\S+)@(\S+)", self.workflow)
        self.assertTrue(refs)
        for action, ref in refs:
            self.assertRegex(ref, r"^[0-9a-f]{40}$", f"{action} is not SHA-pinned")

    def test_kill_switch_variable_is_in_the_repo_variable_manifest(self) -> None:
        manifest = json.loads(REPO_VARIABLES_MANIFEST.read_text(encoding="utf-8"))
        self.assertIn("FACTORY_REVIEW_RESPONSE_ENABLED", manifest)


if __name__ == "__main__":
    unittest.main()
