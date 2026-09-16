#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
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


class DiffCompletionCallerTests(unittest.TestCase):
    """`_pr_evidence_entries` answers a writer as well as the live CI gate.

    `_complete_diff_evidence_after_approval` picks `pending-ci` diff entries
    from that read and then writes completions by index through
    `update_evidence_entries`, which resolves an index against the body's last
    block. So the read has to be the same block the write lands in. When it
    ranged wider, an earlier block's `pending-ci` entry keyed `"02"` survived
    beside a later block's `blocked` entry keyed `"2"` -- two keys to the
    selector -- and then `int("02") == 2` collapsed them at the update step,
    so a reviewer's recorded refusal was flipped to complete and signed with
    the review URL.
    """

    REVIEWER_DETAIL = "the reviewer read the diff and found the claim false"

    def block(self, entries: list[dict[str, object]], ending: str = "\n") -> str:
        text = "<!-- evidence-status:v1\n" + json.dumps({"entries": entries}) + "\n-->\n"
        return text.replace("\n", ending)

    def body(self) -> str:
        earlier = self.block([
            {"index": "02", "item": DIFF_ITEM, "status": "pending-ci", "detail": "awaiting the review"}
        ])
        later = self.block([
            {"index": 2, "item": DIFF_ITEM, "status": "blocked", "detail": self.REVIEWER_DETAIL}
        ])
        return (f"*Persona*\n\n## Summary\n- change\n\n{earlier}\n"
                f"## Evidence Status\n- [blocked] {DIFF_ITEM} -- {self.REVIEWER_DETAIL}\n\n{later}")

    def test_a_reviewers_blocked_diff_entry_is_not_rewritten_to_complete(self) -> None:
        body = self.body()
        edited: list[str] = []
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)),
            mock.patch.object(execution, "_latest_approving_review",
                              return_value={"html_url": "https://github.test/r/1"}),
            mock.patch.object(execution, "_edit_pr_body", side_effect=lambda *a, **k: edited.append(a[1])),
        ):
            execution._complete_diff_evidence_after_approval(42, {})
        self.assertEqual(edited, [])
        entry = run_contributor._extract_evidence_metadata(body)["entries"][0]
        self.assertEqual(entry["status"], "blocked")
        # Byte-for-byte: a status kept while the sentence is overwritten with
        # "diff-verified by the counterpart approving review" is the same bug.
        self.assertEqual(entry["detail"], self.REVIEWER_DETAIL)
        self.assertNotIn("diff-verified", body)


class LiveCiVerificationTests(unittest.TestCase):
    def gate(self, body: str, *, run: object, env: dict[str, str] | None = None) -> str | None:
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)),
            mock.patch.object(sys.modules["evidence"], "check_runs_for", return_value=
                              ([{"id": 1, "name": "Web CI", "head_sha": HEAD, "status": "completed", **run}] if isinstance(run, dict) else [])),
            mock.patch.object(execution, "repo_owner_name", return_value=("fairchild", "workspaces")),
            mock.patch.object(execution, "fetch_detailed_issue", return_value={"body": ""}),
        ):
            return execution._live_ci_evidence_gate_error(42, env or {})

    def test_a_linked_issue_whose_contract_is_cut_blocks_the_verdict(self) -> None:
        # The second of the three readers of the contract. The gate resolves
        # the issue's Requested Evidence to know which checks must be live-
        # green; a section an h1 cuts hands it the items above the cut, so a
        # named check written below one would never be verified and the
        # approval would be over a smaller promise than the issue made.
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "green earlier"}]
        )
        cut = (
            "## Requested Evidence\n\n- `swift test` passes\n\n"
            "# Reviewer notes\n\n- CI: `Web CI` green on the PR head\n"
        )
        with (
            mock.patch.object(execution, "_pr_body_and_head", return_value=(body, HEAD)),
            mock.patch.object(execution, "repo_owner_name", return_value=("fairchild", "workspaces")),
            mock.patch.object(execution, "extract_pr_issue_reference", return_value=(7, "april")),
            mock.patch.object(execution, "fetch_detailed_issue", return_value={"body": cut}),
        ):
            error = execution._live_ci_evidence_gate_error(42, {})
        self.assertIsNotNone(error)
        self.assertIn("cannot be read", error)
        self.assertIn("# Reviewer notes", error)

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

    def test_a_red_check_is_caught_whatever_the_body_s_line_endings(self) -> None:
        # The metadata comment is the only place this CI item is named, so a
        # body the extractor cannot read leaves its check un-reverified (#1710).
        body = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
        )
        for name, ending in (("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")):
            with self.subTest(endings=name):
                error = self.gate(body.replace("\n", ending), run={"conclusion": "failure"})
                self.assertIsNotNone(error)
                self.assertIn("`Web CI`", error)

    def test_a_rewritten_crlf_body_still_has_its_named_check_reverified(self) -> None:
        # What a lane turn makes of a CRLF body. The rewrite strips the block
        # it read, so one block comes out and the entry is still there to
        # re-verify -- which is where the empty-block-last problem is solved,
        # rather than in how this gate reads.
        evidence = sys.modules["evidence"]
        crlf = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
        ).replace("\n", "\r\n")
        rewritten = evidence.update_evidence_entries(
            crlf, {1: {"status": "complete", "detail": "the lane saw it green"}}
        )
        self.assertEqual(rewritten.count("<!-- evidence-status:"), 1)
        error = self.gate(rewritten, run={"conclusion": "failure"})
        self.assertIsNotNone(error)
        self.assertIn("`Web CI`", error)

    def test_a_body_carrying_two_blocks_is_read_at_its_last(self) -> None:
        # Pinned because it is the one shape this change makes read
        # differently: main could not see the trailing CRLF block and found
        # the CI entry in the block ahead of it, so it refused. Both blocks
        # are visible now and the last decides, as it already did for two LF
        # blocks, so the gate approves. Widening this read to reach the
        # earlier block is what round 2 tried, and it changed what a writer
        # downstream selects; the repair for such a body belongs elsewhere.
        empty_block_last = (
            body_with_entries(
                [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
            )
            + "\n"
            + ("<!-- evidence-status:v1\n" + json.dumps({"entries": []}) + "\n-->\n").replace("\n", "\r\n")
        )
        self.assertEqual(execution._pr_evidence_entries(empty_block_last), [])
        self.assertIsNone(self.gate(empty_block_last, run={"conclusion": "failure"}))

    def test_a_rewrite_of_a_crlf_body_leaves_one_metadata_block(self) -> None:
        evidence = sys.modules["evidence"]
        crlf = body_with_entries(
            [{"index": 1, "item": CI_ITEM, "status": "complete", "detail": "claims green"}]
        ).replace("\n", "\r\n")
        updates = {1: {"status": "blocked", "detail": "the lane refused it"}}
        once = evidence.update_evidence_entries(crlf, updates)
        self.assertEqual(once.count("<!-- evidence-status:"), 1)
        self.assertNotIn("\r", once)
        # Idempotent: a second turn applying the same updates writes the same
        # bytes, rather than stacking another block on what it could not strip.
        self.assertEqual(evidence.update_evidence_entries(once, updates), once)

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
