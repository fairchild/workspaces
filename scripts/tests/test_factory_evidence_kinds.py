#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Policy tests for first-class `ci` and `diff` evidence kinds (#1120).

Intent: prove classification is fail-closed (no guessed check names), that
ci/diff contracts no longer draw blocked:evidence at open, that the macOS
lane leaves event-completed kinds alone, and that trusted-lane writers can
flip entries without hand-editing markdown.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_contributor = load_module("run_contributor_evidence_kinds", SCRIPT_PATH)

CI_ITEM = "CI: `Lint, Test, Build, E2E & Perf` green on the PR head"
DIFF_ITEM = (
    "The PR diff shows `.`/`..` owner or name segments rejected while "
    "`acme/my.tool` remains valid — the added test rows make this readable "
    "from the diff alone."
)


class EvidenceKindClassificationTests(unittest.TestCase):
    def test_canonical_ci_item_classifies_with_check_name(self) -> None:
        self.assertEqual(run_contributor._evidence_item_kind(CI_ITEM), "ci")
        self.assertEqual(
            run_contributor._ci_check_name(CI_ITEM),
            "Lint, Test, Build, E2E & Perf",
        )

    def test_natural_ci_phrasing_classifies_when_name_precedes_green(self) -> None:
        item = "The `Web CI / test` job must be green on this PR"
        self.assertEqual(run_contributor._evidence_item_kind(item), "ci")
        self.assertEqual(run_contributor._ci_check_name(item), "Web CI / test")

    def test_ci_phrasing_without_extractable_name_stays_other(self) -> None:
        # Real item from the issue that motivated #1120: the only backticked
        # token is a function name after "green" — guessing it as a check
        # name would be wrong, so classification fails closed.
        item = (
            "[ ] web-next CI unit-test job green on the PR (vitest exercises "
            "the new `isValidRepoFullName` cases) — link the passing job in "
            "the PR body."
        )
        self.assertIsNone(run_contributor._ci_check_name(item))
        self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_the_dogfood_item_that_parked_a_pr_on_the_owner_classifies(self) -> None:
        # #1382, proven live on #1377: a two-line docs change whose only
        # evidence was the diff itself drew blocked:evidence and waited on the
        # owner. Written without an owner directive, it now classifies.
        item = (
            "README documentation list shows the `docs/product_overview.md` "
            "link in the PR diff"
        )
        self.assertEqual(run_contributor._evidence_item_kind(item), "diff")

    def test_an_explicit_owner_directive_outranks_every_mechanical_kind(self) -> None:
        # #1377's item verbatim. Reading it as diff-verifiable would silently
        # reassign authority the author took the trouble to name; if the
        # contract is wrong, the fix is to correct the issue text.
        self.assertEqual(
            run_contributor._evidence_item_kind(
                "README documentation list shows the `docs/product_overview.md` "
                "link in the PR diff (owner-attested)"
            ),
            "other",
        )
        for item in (
            "Owner confirms the migration preserves every invariant; the new "
            "column appears in the PR diff",
            "In the PR diff, the new column is visible, and the owner confirms "
            "the migration is safe",
            "In the diff the prose shows good product judgment and is owner-attested",
            "The owner approves the rollout, and the manifest appears in the PR diff",
            "CI: `Web CI` is green, but the maintainer decides whether to ship",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_named_check_classifies_when_a_ci_noun_binds_the_name(self) -> None:
        for item, check in (
            ("The `check-links` check passes on the PR head", "check-links"),
            ("`Web CI / test` job successful on this PR", "Web CI / test"),
            ("`Lint, Test, Build` workflow passed on the head commit", "Lint, Test, Build"),
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "ci")
                self.assertEqual(run_contributor._ci_check_name(item), check)

    def test_the_green_form_is_unchanged_from_before_the_widening(self) -> None:
        # Bounding the gap to make room for the pass verdicts would have
        # regressed these; the green matcher is left exactly as it was.
        for item, check in (
            ("CI: `Web CI` must finish on the exact PR head and stay green", "Web CI"),
            ("CI: `Web CI` (required branch protection) is green", "Web CI"),
            ("Check `foo.ts` passes while `Web CI` is green", "Web CI"),
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._ci_check_name(item), check)

    def test_ordinary_backticked_tokens_never_become_check_names(self) -> None:
        # The reason the pass verdicts need a CI noun binding them: their
        # words are ordinary English, and a `ci` entry naming a check that
        # does not exist never completes -- strictly worse than `other`.
        for item in (
            "`ci/check.py` passes its unit tests",
            "CI: `src/foo.ts` passes TypeScript compilation",
            "`pnpm check` passes locally",
            "CI evidence: `pnpm check` passes on the PR head",
            "The CI regression in `isValidRepoFullName` passes its new cases",
            "The workflow proves `EvidenceStatus` passes decoding",
            "CI on `workspace/1382-evidence-kinds` passes before merge",
            "The CI job for `PR #1377` passed after the docs fix",
            "The CI example in `README.md` passed editorial review",
            "Check that `foo.ts` compiles and the build passes",
            "Check that `foo.ts` passes the build",
        ):
            with self.subTest(item=item):
                self.assertIsNone(run_contributor._ci_check_name(item))
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_a_diff_mentioned_after_the_real_claim_is_not_a_diff_item(self) -> None:
        for item in (
            "The owner must be present for the irreversible sign-off described in the diff",
            "Someone with taste confirms the copy reads well",
            "All tests pass",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_diff_items_classify_by_prefix_and_phrasing(self) -> None:
        for item in (
            "Diff: dot-only segments rejected while valid names still pass",
            DIFF_ITEM,
            "Behavior is verifiable by reading the PR diff",
            "The PR diff contains the new fixture",
            "The new rows are readable from the diff alone",
            "The added guard is visible in the diff",
            "The new column appears in the PR diff",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "diff")

    def test_existing_kind_precedence_is_unchanged(self) -> None:
        self.assertEqual(run_contributor._evidence_item_kind("swift test --filter Foo"), "test")
        self.assertEqual(run_contributor._evidence_item_kind("swift build"), "build")
        self.assertEqual(
            run_contributor._evidence_item_kind("screenshot of the diff view"),
            "screenshot",
        )
        self.assertEqual(
            run_contributor._evidence_item_kind("Other proof recorded by the implementer"),
            "other",
        )

    def test_needs_macos_evidence_excludes_event_completed_kinds(self) -> None:
        self.assertFalse(run_contributor._needs_macos_evidence([CI_ITEM, DIFF_ITEM]))
        self.assertTrue(
            run_contributor._needs_macos_evidence([CI_ITEM, "swift test --filter Foo"])
        )

    def test_has_unautomatable_evidence_flags_only_other_kind(self) -> None:
        self.assertFalse(run_contributor._has_unautomatable_evidence([CI_ITEM, DIFF_ITEM]))
        self.assertTrue(
            run_contributor._has_unautomatable_evidence(
                [CI_ITEM, "Other proof recorded by the implementer"]
            )
        )


class FactoryBlockingLabelTests(unittest.TestCase):
    def test_ci_and_diff_only_contracts_no_longer_block_at_open(self) -> None:
        execution = sys.modules["execution"]
        self.assertFalse(
            execution._factory_evidence_should_block(
                factory_requires_evidence=True,
                needs_macos_evidence=False,
                visual_evidence_blocked=False,
                has_unautomatable_evidence=False,
            )
        )

    def test_other_kind_contracts_still_block(self) -> None:
        execution = sys.modules["execution"]
        self.assertTrue(
            execution._factory_evidence_should_block(
                factory_requires_evidence=True,
                needs_macos_evidence=False,
                visual_evidence_blocked=False,
                has_unautomatable_evidence=True,
            )
        )

    def test_legacy_callers_keep_pre_1120_rule(self) -> None:
        execution = sys.modules["execution"]
        self.assertTrue(
            execution._factory_evidence_should_block(
                factory_requires_evidence=True,
                needs_macos_evidence=False,
                visual_evidence_blocked=False,
            )
        )


class EvidenceSynthesisTests(unittest.TestCase):
    maxDiff = None

    def test_ci_and_diff_items_seed_pending_ci_with_their_completers(self) -> None:
        complete, blocked, pending = run_contributor.synthesize_initial_execution_evidence(
            [CI_ITEM, DIFF_ITEM]
        )

        self.assertEqual(complete, [])
        self.assertEqual(blocked, [])
        self.assertEqual(len(pending), 2)
        self.assertIn("`Lint, Test, Build, E2E & Perf`", pending[0])
        self.assertIn("factory evidence verifier", pending[0])
        self.assertIn("counterpart review", pending[1])

    def test_rendered_contract_stays_fail_closed_and_carries_kinds(self) -> None:
        rendered, errors = run_contributor.build_execution_summary_body(
            {"body": "## Summary\n- change\n\n## Validation\n- notes"},
            requested_evidence=[CI_ITEM, DIFF_ITEM],
        )

        self.assertEqual(errors, [])
        self.assertIn(f"- [pending-ci] {CI_ITEM}", rendered)
        self.assertIn("blocked on evidence", rendered)
        self.assertIn('"kind": "ci"', rendered)
        self.assertIn('"kind": "diff"', rendered)

        accounting, accounting_errors = run_contributor.validate_evidence_accounting(
            rendered, [CI_ITEM, DIFF_ITEM]
        )
        self.assertEqual(accounting_errors, [])
        self.assertEqual(accounting["pending_ci_items"], [CI_ITEM, DIFF_ITEM])


class UpdateEvidenceEntriesTests(unittest.TestCase):
    maxDiff = None

    def rendered_body(self) -> str:
        rendered, errors = run_contributor.build_execution_summary_body(
            {"body": "## Summary\n- change\n\n## Validation\n- notes"},
            requested_evidence=[CI_ITEM, DIFF_ITEM],
        )
        assert not errors
        return rendered

    def test_updates_flip_status_detail_and_record_proof_keys(self) -> None:
        body = self.rendered_body()
        updated = run_contributor.update_evidence_entries(
            body,
            {
                1: {
                    "status": "complete",
                    "detail": "`Lint, Test, Build, E2E & Perf` green on head abc123def456 — https://example.invalid/run",
                    "verified_head_sha": "abc123def456",
                    "proof_url": "https://example.invalid/run",
                }
            },
        )

        self.assertIn(f"- [complete] {CI_ITEM}", updated)
        self.assertIn("green on head abc123def456", updated)
        self.assertIn('"verified_head_sha": "abc123def456"', updated)
        self.assertIn(f"- [pending-ci] {DIFF_ITEM}", updated)

        accounting, errors = run_contributor.validate_evidence_accounting(
            updated, [CI_ITEM, DIFF_ITEM]
        )
        self.assertEqual(errors, [])
        self.assertEqual(accounting["complete_items"], [CI_ITEM])
        self.assertEqual(accounting["pending_ci_items"], [DIFF_ITEM])

    def test_unknown_index_and_invalid_status_change_nothing(self) -> None:
        body = self.rendered_body()
        self.assertEqual(
            run_contributor.update_evidence_entries(body, {9: {"status": "complete", "detail": "x"}}),
            body,
        )
        self.assertEqual(
            run_contributor.update_evidence_entries(body, {1: {"status": "verified", "detail": "x"}}),
            body,
        )

    def test_body_without_structured_metadata_is_unchanged(self) -> None:
        body = "## Evidence Status\n- [pending-ci] item -- detail\n"
        self.assertEqual(
            run_contributor.update_evidence_entries(body, {1: {"status": "complete", "detail": "x"}}),
            body,
        )


class MacOSLaneCoexistenceTests(unittest.TestCase):
    maxDiff = None

    def test_reconcile_resolves_macos_kinds_and_leaves_event_completed_kinds(self) -> None:
        rendered, errors = run_contributor.build_execution_summary_body(
            {"body": "## Summary\n- change\n\n## Validation\n- notes"},
            requested_evidence=["swift test", CI_ITEM],
        )
        self.assertEqual(errors, [])

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            rendered,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
        )

        self.assertIn("- [complete] swift test -- `swift test` succeeded", reconciled)
        self.assertIn(f"- [pending-ci] {CI_ITEM}", reconciled)
        self.assertIn("factory evidence verifier", reconciled)

    def test_markdown_only_bodies_also_leave_event_completed_kinds(self) -> None:
        body = (
            "## Evidence Status\n"
            f"- [pending-ci] {CI_ITEM} -- waiting for checks\n"
            "- [pending-ci] swift build -- macOS lane will build\n"
        )

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
        )

        self.assertIn(f"- [pending-ci] {CI_ITEM} -- waiting for checks", reconciled)
        self.assertIn("- [complete] swift build", reconciled)


class ClassifierBlastRadiusTests(unittest.TestCase):
    """A kind is not a label — it decides which lane completes the item.

    Classification tests alone cannot catch a reclassification that lands the
    wrong downstream behavior, so each corpus item is walked all the way to
    the state it produces on a fresh PR: whether `blocked:evidence` is applied,
    which bucket the entry is seeded into, and whether the macOS lane is
    summoned.
    """

    CASES = (
        # (item, kind, initial bucket, blocked:evidence at open, macOS lane)
        (
            "README documentation list shows the `docs/product_overview.md` "
            "link in the PR diff",
            "diff",
            "pending_ci",
            False,
            False,
        ),
        (
            "README documentation list shows the `docs/product_overview.md` "
            "link in the PR diff (owner-attested)",
            "other",
            "blocked",
            True,
            False,
        ),
        ("The `check-links` check passes on the PR head", "ci", "pending_ci", False, False),
        ("CI: `Web CI` green on the PR head", "ci", "pending_ci", False, False),
        ("`pnpm check` passes locally", "other", "blocked", True, False),
        ("The CI job for `PR #1377` passed after the docs fix", "other", "blocked", True, False),
        ("Someone with taste confirms the copy reads well", "other", "blocked", True, False),
        ("`swift test --filter Foo` passes", "test", "pending_ci", False, True),
        ("Screenshots of the new sidebar", "screenshot", "pending_ci", False, True),
    )

    def test_each_kind_lands_the_state_its_lane_expects(self) -> None:
        for item, kind, bucket, blocked_label, macos in self.CASES:
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), kind)
                self.assertEqual(
                    run_contributor._has_unautomatable_evidence([item]),
                    blocked_label,
                    "blocked:evidence at PR open follows from the kind",
                )
                self.assertEqual(
                    run_contributor._needs_macos_evidence([item]),
                    macos,
                    "summoning the macOS evidence lane follows from the kind",
                )
                complete, blocked, pending_ci = (
                    run_contributor.synthesize_initial_execution_evidence([item])
                )
                buckets = {"complete": complete, "blocked": blocked, "pending_ci": pending_ci}
                self.assertEqual(
                    [name for name, rows in buckets.items() if rows],
                    [bucket],
                    "exactly one initial bucket, and the one the lane reads",
                )

    def test_a_ci_item_seeds_the_check_name_the_verifier_will_poll(self) -> None:
        _, _, pending_ci = run_contributor.synthesize_initial_execution_evidence(
            ["The `check-links` check passes on the PR head"]
        )
        self.assertIn("`check-links`", pending_ci[0])

    def test_the_macos_lane_never_resolves_an_event_completed_kind(self) -> None:
        # ci and diff complete through the verifier and the review lane; the
        # macOS lane must leave them alone or it would mark a false name
        # blocked before the verifier ever looks.
        self.assertEqual(
            run_contributor.EVENT_COMPLETED_KINDS & run_contributor.MACOS_EVIDENCE_KINDS,
            frozenset(),
        )
        self.assertIn("ci", run_contributor.EVENT_COMPLETED_KINDS)
        self.assertIn("diff", run_contributor.EVENT_COMPLETED_KINDS)


if __name__ == "__main__":
    unittest.main()
