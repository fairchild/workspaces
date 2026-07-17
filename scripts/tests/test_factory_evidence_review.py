#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Policy tests for review-time evidence handling (#1120 step 3).

Intent: pending diff items alone don't block approve (the approving review is
the verification act, completed immediately after with review URL + head SHA),
while the PR body stays untrusted — every named-check entry is re-verified
live against the current head before an approve counts.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Registered as "run_contributor" so route_action's `_mod` indirection sees
# the same module these tests patch.
run_contributor = load_module("run_contributor", SCRIPT_PATH)
execution = sys.modules["execution"]

HEAD = "c" * 40
OTHER_HEAD = "d" * 40
CI_ITEM = "CI: `Web CI` green on the PR head"
DIFF_ITEM = "Diff: dot-only segments rejected, readable from the diff alone"


def body_with_entries(entries: list[dict[str, object]]) -> str:
    payload = json.dumps({"entries": entries}, indent=2, ensure_ascii=False)
    lines = "\n".join(
        f"- [{entry['status']}] {entry['item']} -- {entry['detail']}" for entry in entries
    )
    return (
        "*Persona*\n\n## Summary\n- change\n\n"
        f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
        f"## Evidence Status\n{lines}\n\n"
        "## Validation\n- blocked on evidence: pending\n\n"
        "Closes #99\n\n<!-- contributor:issue=99;agent=test -->"
    )


def accounting(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "blocked_items": [],
        "pending_ci_items": [],
        "missing_items": [],
        "complete_items": [],
    }
    base.update(overrides)
    return base


class ApproveGateDiffExemptionTests(unittest.TestCase):
    def test_pending_diff_items_alone_do_not_block_approve(self) -> None:
        self.assertIsNone(
            run_contributor.review_evidence_gate_error(
                "approve", accounting(pending_ci_items=[DIFF_ITEM]), []
            )
        )

    def test_pending_non_diff_items_still_block_approve(self) -> None:
        error = run_contributor.review_evidence_gate_error(
            "approve", accounting(pending_ci_items=[CI_ITEM, DIFF_ITEM]), []
        )
        self.assertIsNotNone(error)
        self.assertIn(CI_ITEM, error)
        self.assertNotIn(DIFF_ITEM, error)

    def test_blocked_diff_items_still_block_approve(self) -> None:
        error = run_contributor.review_evidence_gate_error(
            "approve", accounting(blocked_items=[DIFF_ITEM]), []
        )
        self.assertIsNotNone(error)
        self.assertIn("blocked", error)

    def test_request_changes_never_gates(self) -> None:
        self.assertIsNone(
            run_contributor.review_evidence_gate_error(
                "request_changes", accounting(pending_ci_items=[CI_ITEM]), ["boom"]
            )
        )


class LiveCiVerificationTests(unittest.TestCase):
    def gate(self, body: str, *, run: object, env: dict[str, str] | None = None) -> str | None:
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)),
            mock.patch.object(execution, "latest_completed_check_run", return_value=run),
        ):
            return execution._live_ci_evidence_gate_error(42, env or {})

    def test_green_live_check_passes(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "green earlier"}]
        )
        self.assertIsNone(self.gate(body, run={"conclusion": "success"}))

    def test_recorded_complete_is_not_trusted_when_live_check_is_red(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
        )
        error = self.gate(body, run={"conclusion": "failure"})
        self.assertIsNotNone(error)
        self.assertIn("`Web CI`", error)
        self.assertIn("live conclusion: failure", error)

    def test_missing_live_run_blocks_approve(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
        )
        error = self.gate(body, run=None)
        self.assertIsNotNone(error)
        self.assertIn("live conclusion: none", error)

    def test_expected_head_mismatch_blocks_approve(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "green"}]
        )
        error = self.gate(
            body,
            run={"conclusion": "success"},
            env={"FACTORY_EXPECTED_PR_HEAD_SHA": OTHER_HEAD},
        )
        self.assertEqual(error, "PR head changed during Factory review")

    def test_bodies_without_ci_entries_pass(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": DIFF_ITEM, "status": "pending-ci", "detail": "d"}]
        )
        self.assertIsNone(self.gate(body, run=None))
        self.assertIsNone(self.gate("plain body without metadata", run=None))


class ApprovingReviewBindingTests(unittest.TestCase):
    def reviews(self, payload: object) -> object:
        env = {"GITHUB_REPOSITORY": "acme/widgets"}
        with mock.patch.object(execution, "run_optional", return_value=json.dumps(payload)):
            return execution._latest_approving_review(42, HEAD, env)

    def test_only_head_bound_approvals_qualify(self) -> None:
        self.assertIsNone(
            self.reviews(
                [{"state": "APPROVED", "commit_id": OTHER_HEAD, "submitted_at": "2026-07-17T00:00:00Z"}]
            )
        )
        self.assertIsNone(
            self.reviews(
                [{"state": "CHANGES_REQUESTED", "commit_id": HEAD, "submitted_at": "2026-07-17T00:00:00Z"}]
            )
        )

    def test_latest_head_bound_approval_wins(self) -> None:
        review = self.reviews(
            [
                {
                    "state": "APPROVED",
                    "commit_id": HEAD,
                    "submitted_at": "2026-07-17T00:00:00Z",
                    "html_url": "https://example.invalid/review/1",
                },
                {
                    "state": "APPROVED",
                    "commit_id": HEAD,
                    "submitted_at": "2026-07-17T01:00:00Z",
                    "html_url": "https://example.invalid/review/2",
                },
            ]
        )
        self.assertEqual(review["html_url"], "https://example.invalid/review/2")


class DiffCompletionWriteTests(unittest.TestCase):
    maxDiff = None

    BODY = None

    def setUp(self) -> None:
        self.body = body_with_entries(
            [
                {
                    "index": 1,
                    "item": CI_ITEM,
                    "status": "complete",
                    "detail": "green",
                    "verified_head_sha": HEAD,
                },
                {"index": 2, "item": DIFF_ITEM, "status": "pending-ci", "detail": "awaiting review"},
            ]
        )
        self.review = {
            "state": "APPROVED",
            "commit_id": HEAD,
            "submitted_at": "2026-07-17T01:00:00Z",
            "html_url": "https://example.invalid/review/2",
        }

    def test_approval_completes_pending_diff_entries_with_proof(self) -> None:
        written: dict[str, str] = {}

        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(self.body, HEAD)),
            mock.patch.object(execution, "_latest_approving_review", return_value=self.review),
            mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=True),
            mock.patch.object(
                execution,
                "_edit_pr_body",
                side_effect=lambda pr, body, env: written.__setitem__("body", body),
            ),
        ):
            execution._complete_diff_evidence_after_approval(42, {})

        self.assertIn(f"- [complete] {DIFF_ITEM}", written["body"])
        self.assertIn("diff-verified by the counterpart approving review", written["body"])
        self.assertIn("https://example.invalid/review/2", written["body"])
        self.assertIn(f'"verified_head_sha": "{HEAD}"', written["body"])
        self.assertIn(f"- [complete] {CI_ITEM}", written["body"])

    def test_no_head_bound_approval_leaves_entries_pending(self) -> None:
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(self.body, HEAD)),
            mock.patch.object(execution, "_latest_approving_review", return_value=None),
            mock.patch.object(execution, "_edit_pr_body") as edit,
        ):
            execution._complete_diff_evidence_after_approval(42, {})
        edit.assert_not_called()

    def test_head_movement_before_write_skips_the_write(self) -> None:
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(self.body, HEAD)),
            mock.patch.object(execution, "_latest_approving_review", return_value=self.review),
            mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=False),
            mock.patch.object(execution, "_edit_pr_body") as edit,
        ):
            execution._complete_diff_evidence_after_approval(42, {})
        edit.assert_not_called()

    def test_bodies_without_pending_diff_entries_do_nothing(self) -> None:
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "green"}]
        )
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)),
            mock.patch.object(execution, "_latest_approving_review") as lookup,
            mock.patch.object(execution, "_edit_pr_body") as edit,
        ):
            execution._complete_diff_evidence_after_approval(42, {})
        lookup.assert_not_called()
        edit.assert_not_called()


class ReviewActionWiringTests(unittest.TestCase):
    def action_json(self) -> str:
        return json.dumps(
            {
                "action": "review_pr",
                "pr_number": 42,
                "body": "review body",
                "persona": "Reviewer Persona",
                "verdict": "approve",
            }
        )

    def test_live_gate_failure_stops_the_approve_before_posting(self) -> None:
        with (
            mock.patch.object(run_contributor, "find_pr_review_state", return_value=None),
            mock.patch.object(
                run_contributor,
                "_live_ci_evidence_gate_error",
                return_value="named check `Web CI` is not green",
            ),
            mock.patch.object(run_contributor, "run_checked") as run_checked,
            mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=True),
        ):
            result = run_contributor.route_action(self.action_json(), dry_run=False, env={})

        self.assertEqual(result, 1)
        run_checked.assert_not_called()

    def test_successful_approve_posts_review_then_completes_diff_evidence(self) -> None:
        calls: list[str] = []

        with (
            mock.patch.object(run_contributor, "find_pr_review_state", return_value=None),
            mock.patch.object(run_contributor, "_live_ci_evidence_gate_error", return_value=None),
            mock.patch.object(
                run_contributor,
                "run_checked",
                side_effect=lambda cmd, **kwargs: calls.append("review-post"),
            ),
            mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=True),
            mock.patch.object(execution, "detect_bot_login", return_value=""),
            mock.patch.object(
                run_contributor,
                "_complete_diff_evidence_after_approval",
                side_effect=lambda pr, env: calls.append("diff-complete"),
            ),
            mock.patch.object(
                run_contributor,
                "_update_mergeable_label",
                side_effect=lambda pr, verdict, env: calls.append("mergeable-label"),
            ),
        ):
            result = run_contributor.route_action(self.action_json(), dry_run=False, env={})

        self.assertEqual(result, 0)
        self.assertEqual(calls, ["review-post", "diff-complete", "mergeable-label"])


if __name__ == "__main__":
    unittest.main()
