#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for the CHANGES_REQUESTED response turn (#1378).

Intent: prove the lane never parks silently -- every standing changes-requested
review from a trusted reviewer produces exactly one response, escalation is the
default when the factory cannot prove it clears a blocker, and the escalation
names the gesture the owner has to make.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path


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


class BlockingReviewTests(unittest.TestCase):
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

    def test_pending_ci_only_clears_without_the_owner(self) -> None:
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
        self.assertFalse(decision.owner_required)
        self.assertEqual(
            [blocker.key for blocker in decision.blockers], ["evidence-pending-ci"]
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
        self.assertIn(f"@{PLAT}", text)
        self.assertIn("pullrequestreview-900", text)
        self.assertIn(response.response_marker(900), text)

    def test_self_clearing_response_states_no_owner_action(self) -> None:
        body = evidence_body(
            {"index": 1, "item": "CI: `check-links` green", "status": "pending-ci"}
        )
        text = self.render(pull_request(body=body), review())
        self.assertIn("No owner action needed", text)
        self.assertNotIn(f"This needs @{OWNER}", text)

    def test_marker_is_per_review_so_a_second_review_gets_its_own_turn(self) -> None:
        comments = [{"body": f"prior response\n{response.response_marker(900)}"}]
        self.assertTrue(response.has_response_for_review(comments, 900))
        self.assertFalse(response.has_response_for_review(comments, 901))


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

    def test_responds_only_to_changes_requested(self) -> None:
        self.assertIn("github.event.review.state == 'changes_requested'", self.workflow)

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
