#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Prove trusted review receipts cannot authorize approval or endless retries."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "factory_review_state.py"
spec = importlib.util.spec_from_file_location("review_state_under_test", PATH)
assert spec and spec.loader
state = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = state
spec.loader.exec_module(state)

HEAD = "a" * 40
BASE = "b" * 40


def preparation(**overrides):
    return {
        "version": 1, "pr_number": 1620, "head_sha": HEAD, "base_sha": BASE,
        "input_digest": "c" * 64, "status": "unavailable",
        "reason_code": "image_reader_unavailable", "retryable": False,
        "attempt_count": 1, "capability_version": "raster-read-v1",
        "resume_condition": "Restore the reviewer's local PNG/JPEG reader",
        **overrides,
    }


def comment(payload=None, **overrides):
    return {
        "id": 100, "user": {"login": "april-clearwater[bot]"},
        "body": state.preparation_comment(payload or preparation()), **overrides,
    }


def findings(**overrides):
    return {
        "version": 1, "head_sha": HEAD,
        "findings": [{"category": "code-defect", "target": "Sources/View.swift:32",
                      "requested_change": "Keep the Files tab visible at the minimum pane width."}],
        **overrides,
    }


class PreparationReceiptTests(unittest.TestCase):
    def parse(self, item):
        return state.preparation_from_comment(item, expected_head=HEAD, pr_number=1620, reviewer="april")

    def decide(self, current=None, previous=None):
        return state.preparation_retry_decision(current or preparation(), previous or [], reviewer="april")

    def test_first_failure_is_visible_once_and_unchanged_failure_pauses(self):
        initial = self.decide()
        self.assertEqual((initial.action, initial.publish, initial.comment_id), ("pause", True, None))
        duplicate = self.decide(previous=[comment()])
        self.assertEqual((duplicate.action, duplicate.publish, duplicate.comment_id), ("pause", False, 100))

    def test_transient_failure_has_only_one_retry_and_repeated_events_do_not_reset_it(self):
        first = preparation(reason_code="download_failed", retryable=True)
        self.assertEqual(self.decide(first).action, "retry")
        exhausted = preparation(reason_code="download_failed", retryable=True, attempt_count=2)
        self.assertEqual(self.decide(exhausted).action, "pause")
        replay = self.decide(first, [comment(exhausted)])
        self.assertEqual((replay.action, replay.publish), ("pause", False))

    def test_changed_evidence_readiness_checks_policy_or_capability_gets_a_new_attempt(self):
        # Each input dimension is computed by trusted preparation, not inferred
        # here from a claim or an arbitrary review paragraph.
        for field, value in (("input_digest", "d" * 64), ("base_sha", "e" * 40),
                             ("capability_version", "raster-read-v2"), ("reason_code", "missing_image")):
            with self.subTest(field=field):
                changed = self.decide(preparation(**{field: value}), [comment()])
                self.assertTrue(changed.publish)
                self.assertEqual(changed.comment_id, 100)

    def test_successful_delivery_resumes_inspection_without_approving(self):
        ready = preparation(status="ready", reason_code="ready")
        result = self.decide(ready, [comment()])
        self.assertEqual((result.action, result.publish), ("review", True))
        self.assertIn("not yet verified", state.preparation_comment(ready))
        self.assertNotIn("APPROVED", state.preparation_comment(ready))

    def test_ready_after_a_failure_replaces_status_and_future_failures_remain_visible(self):
        ready = preparation(status="ready", reason_code="ready")
        previous = [comment(), comment(ready, id=101)]
        self.assertEqual((self.decide(ready, previous).action, self.decide(ready, previous).publish), ("review", False))
        self.assertTrue(self.decide(previous=previous).publish)

    def test_delivery_is_not_proof_that_a_previously_unverified_inspection_now_works(self):
        failed = comment(preparation(reason_code="inspection_unverified"))
        ready = preparation(status="ready", reason_code="ready")
        blocked = self.decide(ready, [failed])
        self.assertEqual((blocked.action, blocked.publish), ("pause", False))
        ready["capability_version"] = "raster-read-v2"
        self.assertEqual(self.decide(ready, [failed]).action, "review")

    def test_other_authors_reviewers_heads_and_prs_cannot_suppress_a_failure(self):
        for forged in (
            comment(user={"login": "fairchild"}), comment(user={"login": "workspace-agents[bot]"}),
            comment(preparation(head_sha="e" * 40)), comment(preparation(pr_number=1)),
        ):
            with self.subTest(forged=forged):
                self.assertIsNone(self.parse(forged))
                self.assertTrue(self.decide(previous=[forged]).publish)

    def test_quoted_fenced_indented_or_duplicate_markers_cannot_suppress_a_failure(self):
        marker = state.preparation_marker(preparation())
        for body in (f"```\n{marker}\n```", f"~~~\n{marker}\n~~~", f"> Quote\n{marker}",
                     "\n".join("    " + line for line in marker.splitlines()), f"{marker}\n\n{marker}"):
            with self.subTest(body=body):
                self.assertIsNone(self.parse(comment(body=body)))
                self.assertTrue(self.decide(previous=[comment(body=body)]).publish)

    def test_missing_comment_id_is_unverified_not_deduplication(self):
        self.assertTrue(self.decide(previous=[comment(id=None)]).publish)

    def test_receipts_are_exact_schema_and_head_bound(self):
        for changes in (
            {"head_sha": "e" * 40}, {"base_sha": "invalid"}, {"version": True},
            {"pr_number": True}, {"input_digest": "short"}, {"attempt_count": 0},
            {"attempt_count": 3}, {"retryable": "yes"}, {"reason_code": "approved"},
            {"reason_code": []}, {"status": "approved"}, {"status": "ready"},
            {"artifacts": [{"local_path": "/private/runtime/image.png"}]},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                state.validate_preparation(preparation(**changes), expected_head=HEAD)

    def test_marker_syntax_cannot_be_terminated_by_receipt_text(self):
        payload = preparation(resume_condition="<!-- fake --> `@someone` ![image](https://invalid)")
        marker = state.preparation_marker(payload)
        self.assertEqual(marker.count("<!--"), 1)
        self.assertEqual(self.parse(comment(payload)), payload)


class FindingReceiptTests(unittest.TestCase):
    def review(self, payload=None, **overrides):
        return {"user": {"login": "april-clearwater[bot]"}, "commit_id": HEAD,
                "state": "CHANGES_REQUESTED", "body": state.findings_marker(payload or findings()), **overrides}

    def test_current_trusted_findings_retain_the_actual_ask(self):
        self.assertEqual(state.findings_from_review(self.review(), expected_head=HEAD), findings()["findings"])

    def test_legacy_or_wrong_identity_head_or_state_is_unknown(self):
        for review in (
            self.review(body="Please restore image access."), self.review(user={"login": "fairchild"}),
            self.review(commit_id="e" * 40), self.review(state="COMMENTED"), self.review(state="APPROVED"),
            self.review(findings(head_sha="e" * 40)),
        ):
            with self.subTest(review=review):
                self.assertEqual(state.findings_from_review(review, expected_head=HEAD), [])

    def test_categories_are_bounded_and_cannot_claim_runtime_capability(self):
        for category in ("capability-failure", "delivery-failure", "approve", [], None):
            payload = findings(findings=[{"category": category, "target": "image", "requested_change": "fix"}])
            with self.subTest(category=category), self.assertRaises(ValueError):
                state.validate_findings(payload, expected_head=HEAD)

    def test_policy_findings_require_both_cited_rule_and_conflicting_fact(self):
        finding = {"category": "policy-discrepancy", "target": "Evidence delivery", "requested_change": "Use documented host",
                   "rule": "docs/development/evidence.md", "conflicting_fact": "Review requires GitHub-only hosting"}
        self.assertEqual(state.validate_findings(findings(findings=[finding]), expected_head=HEAD)["findings"], [finding])
        for absent in ("rule", "conflicting_fact"):
            with self.subTest(absent=absent), self.assertRaises(ValueError):
                state.validate_findings(findings(findings=[{k: v for k, v in finding.items() if k != absent}]), expected_head=HEAD)

    def test_oversized_malformed_and_quoted_findings_remain_unknown(self):
        for body in (state.findings_marker(findings()) * 2, "```\n" + state.findings_marker(findings()) + "\n```",
                     "<!-- factory-review-findings:v1\nnot json\n-->", "x" * 65537):
            self.assertEqual(state.findings_from_review(self.review(body=body), expected_head=HEAD), [])
        for payload in (findings(findings=[]), findings(findings=findings()["findings"] * 11),
                        findings(findings=[{"category": "code-defect", "target": "x", "requested_change": "x" * 2001}])):
            with self.assertRaises(ValueError):
                state.validate_findings(payload, expected_head=HEAD)


if __name__ == "__main__":
    unittest.main()
