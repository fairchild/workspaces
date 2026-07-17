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

    def test_diff_items_classify_by_prefix_and_phrasing(self) -> None:
        for item in (
            "Diff: dot-only segments rejected while valid names still pass",
            DIFF_ITEM,
            "Behavior is verifiable by reading the PR diff",
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


if __name__ == "__main__":
    unittest.main()
