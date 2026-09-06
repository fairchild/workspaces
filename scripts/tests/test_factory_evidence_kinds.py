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
import itertools
import random
import sys
import time
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


class EvidenceItemReadabilityTests(unittest.TestCase):
    """A correctly authored item must survive the round trip (#1523).

    An item is authored once in the issue and copied into the PR body as a
    status line. Both defects here break that copy: a bullet that wraps loses
    everything after its first physical line, and an item whose own text
    carries an em-dash separator ends at the first one.
    """

    WRAPPED_BODY = """## Requested Evidence

- `ps -Eww` on a late-created surface — not the first one — showing `command`,
  `initial_input` and `env_vars` all applied, compared against a hand-opened control
- A test at the seam that fails if any one of the three is dropped again.
  Asserting only `command` is what let `env_vars` go unnoticed

Scope note: an unindented paragraph is a new block, not part of the bullet.
"""

    EM_DASH_ITEM = (
        "`swift test` passes on the **full** suite, run three times "
        "consecutively — `--filter` runs do not count, since every flake in "
        "this sweep passes in isolation and fails under load. Paste the three "
        "results"
    )

    def test_a_wrapped_bullet_yields_the_whole_item(self) -> None:
        items = run_contributor.extract_requested_evidence(self.WRAPPED_BODY)
        self.assertEqual(len(items), 2)
        self.assertEqual(
            items[0],
            "`ps -Eww` on a late-created surface — not the first one — showing "
            "`command`, `initial_input` and `env_vars` all applied, compared "
            "against a hand-opened control",
        )
        self.assertTrue(items[1].endswith("go unnoticed"))

    def test_an_unindented_paragraph_does_not_join_the_bullet_above(self) -> None:
        items = run_contributor.extract_requested_evidence(self.WRAPPED_BODY)
        self.assertNotIn("Scope note", " ".join(items))

    def test_an_item_with_an_internal_em_dash_round_trips(self) -> None:
        # Authored in the issue, written as a markdown status line in the PR
        # body, matched by the gate -- the whole path, not just the regex.
        body = f"## Requested Evidence\n\n- {self.EM_DASH_ITEM}\n"
        requested = run_contributor.extract_requested_evidence(body)
        self.assertEqual(requested, [self.EM_DASH_ITEM])

        pr_body = (
            "## Evidence Status\n"
            f"- [complete] {self.EM_DASH_ITEM} -- three green runs pasted below\n"
        )
        parsed = run_contributor.extract_evidence_status_entries(pr_body)
        self.assertEqual(parsed["invalid_lines"], [])
        self.assertIn(self.EM_DASH_ITEM, parsed["entries"])
        self.assertEqual(
            parsed["entries"][self.EM_DASH_ITEM]["detail"],
            "three green runs pasted below",
        )

        accounting = run_contributor.evaluate_evidence_accounting(pr_body, requested)
        self.assertEqual(accounting["missing_items"], [])
        self.assertEqual(accounting["complete_items"], requested)

    def test_an_em_dash_separator_splits_at_the_last_one(self) -> None:
        line = (
            "- [complete] the metric — measured under load — is below 5% "
            "— number in PR body"
        )
        split = run_contributor.split_evidence_status_line(line)
        self.assertEqual(
            split,
            (
                "complete",
                "the metric — measured under load — is below 5%",
                "number in PR body",
            ),
        )

    def test_a_rendered_line_splits_on_the_ascii_separator_it_was_written_with(
        self,
    ) -> None:
        # Both halves carry em-dashes; only the `--` this module renders is
        # the separator, so neither half may be cut at a dash.
        line = "- [complete] the item — as authored -- the proof — as measured"
        self.assertEqual(
            run_contributor.split_evidence_status_line(line),
            ("complete", "the item — as authored", "the proof — as measured"),
        )

    def test_a_numeric_only_item_is_a_parse_failure_not_an_item_name(self) -> None:
        line = "- [complete] 1 — CI build-and-test succeeds"
        parsed = run_contributor.extract_evidence_status_entries(
            f"## Evidence Status\n{line}\n"
        )
        self.assertEqual(parsed["entries"], {})
        self.assertEqual(parsed["invalid_lines"], [line])


class EvidenceSplitAnchoringTests(unittest.TestCase):
    """The contract, not a guess, decides where an item ends (#1523 review)."""

    def test_a_detail_carrying_a_separator_does_not_bleed_into_the_item(self) -> None:
        # Taking the LAST separator is only a guess. With the contract in hand
        # the split that reproduces a requested item wins, so a detail written
        # with its own ` -- ` cannot eat the item's boundary.
        line = "- [complete] the item -- proof captured -- see the log"
        self.assertEqual(
            run_contributor.split_evidence_status_line(line, ["the item"]),
            ("complete", "the item", "proof captured -- see the log"),
        )
        self.assertEqual(
            run_contributor.split_evidence_status_line(line),
            ("complete", "the item", "proof captured -- see the log"),
            "without the contract, a rendered line's one `--` is the boundary "
            "and a second is detail prose",
        )

    def test_an_em_dash_in_both_halves_still_finds_the_requested_item(self) -> None:
        item = "the metric — measured under load — is below 5%"
        line = f"- [complete] {item} — the run — logged at 12:00"
        self.assertEqual(
            run_contributor.split_evidence_status_line(line, [item]),
            ("complete", item, "the run — logged at 12:00"),
        )

    def test_a_numeric_item_the_contract_asks_for_is_not_a_parse_failure(self) -> None:
        # `1` is the structured-update key, so a bare index is normally a parse
        # failure. It stops being one when the contract really does name it.
        body = "## Evidence Status\n- [complete] 404 — the page 404s as designed\n"
        self.assertEqual(
            run_contributor.extract_evidence_status_entries(body, ["404"])["entries"],
            {"404": {"status": "complete", "detail": "the page 404s as designed"}},
        )
        self.assertEqual(
            run_contributor.extract_evidence_status_entries(body, ["something else"])["entries"],
            {},
        )

    def test_an_indented_ordered_step_is_not_folded_into_the_item(self) -> None:
        body = """## Requested Evidence

- the item, which wraps
  onto a continuation line
  1. a nested ordered step
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the item, which wraps onto a continuation line"],
        )

    def test_an_indented_quote_is_not_folded_into_the_item(self) -> None:
        body = """## Requested Evidence

- the item, which wraps
  > a nested quote
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the item, which wraps"],
        )

    def test_a_code_span_opening_a_continuation_line_is_not_a_fence(self) -> None:
        # A backtick fence's info string cannot contain a backtick, which is
        # what tells an opening fence from a line that starts with a span.
        body = """## Requested Evidence

- the first item
  ```inline``` proves it
- the second item
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the first item ```inline``` proves it", "the second item"],
        )

    def test_a_quote_marker_needs_no_space_but_a_threshold_is_not_one(self) -> None:
        self.assertEqual(
            run_contributor.extract_requested_evidence(
                "## Requested Evidence\n\n- the item\n  >nested quote\n"
            ),
            ["the item"],
        )
        self.assertEqual(
            run_contributor.extract_requested_evidence(
                "## Requested Evidence\n\n- the pass rate holds at\n  >= 95% of runs\n"
            ),
            ["the pass rate holds at >= 95% of runs"],
        )

    def test_a_bullet_quoted_as_sample_code_is_not_a_requested_item(self) -> None:
        body = """## Requested Evidence

- the real item
- an item showing the shape:

  ```markdown
  - sample bullet
  ```
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the real item", "an item showing the shape:"],
        )

    def test_metadata_naming_a_different_item_is_rejected(self) -> None:
        # Including the item cut at a fold. Metadata is machine-written and
        # cheap to re-render; accepting a prefix would let an entry written
        # for a narrower item complete the wider one the issue now asks for.
        requested = ["the item, which wraps onto a continuation line"]
        for stored in ("an unrelated item", "the item, which wraps"):
            with self.subTest(stored=stored):
                body = (
                    "## Evidence Status\n\n"
                    "<!-- evidence-status:v1\n"
                    '{"entries": [{"index": 1, "item": "' + stored + '", '
                    '"status": "complete", "detail": "proof"}]}\n'
                    "-->\n"
                )
                parsed = run_contributor._structured_evidence_entries(body, requested)
                assert parsed is not None
                self.assertEqual(parsed["source"], "structured-invalid")
                self.assertEqual(parsed["entries"], {})

    def test_two_separators_sharing_one_space_are_both_candidates(self) -> None:
        line = "- [complete] item — -- the detail"
        self.assertEqual(
            run_contributor.split_evidence_status_line(line, ["item —"]),
            ("complete", "item —", "the detail"),
        )
        self.assertEqual(
            run_contributor.split_evidence_status_line(line, ["item"]),
            ("complete", "item", "-- the detail"),
        )

    def test_a_diff_item_whose_detail_carries_a_separator_stays_a_diff_item(
        self,
    ) -> None:
        # The reconciler runs without the contract. Taking the second `--` as
        # the boundary would read `owner confirms later` as part of the item,
        # reclassify it as owner-attested, and resolve on the macOS lane's
        # behalf a line that completes through the review lane.
        body = (
            "## Evidence Status\n"
            "- [pending-ci] The PR diff shows the setting -- owner confirms later "
            "-- see the review\n"
        )
        self.assertEqual(
            run_contributor.reconcile_pending_ci_evidence(
                body,
                build_succeeded=True,
                tests_succeeded=True,
                smoke_succeeded=True,
            ),
            body,
        )

    def test_an_ambiguous_line_is_left_pending_rather_than_completed(self) -> None:
        # The mirror case: this line reads as a `diff` item at the em-dash and
        # as a screenshot at the `--`, and without the contract nothing here
        # can say which. Leaving it pending fails the readiness gate, which is
        # visible and recoverable; resolving it would complete, on the macOS
        # lane's word, an item that completes through the review lane.
        body = (
            "## Evidence Status\n"
            "- [pending-ci] The PR diff shows the launch state — final screenshot "
            "after setup -- evidence job will upload it\n"
        )
        self.assertEqual(
            run_contributor.reconcile_pending_ci_evidence(
                body,
                build_succeeded=True,
                tests_succeeded=True,
                smoke_succeeded=True,
                screenshot_upload_succeeded=True,
                screenshot_urls=[("shot", "https://example.test/shot.png")],
            ),
            body,
        )

    def test_a_separator_inside_a_code_span_is_an_argument(self) -> None:
        # `resolve_persona.py -- mara` is one name, and this shape is real:
        # #1410 and #1550 both write an argument that way.
        line = "- [complete] Screenshot of `tool -- mode` after launch -- the proof"
        self.assertEqual(
            run_contributor.split_evidence_status_line(line),
            ("complete", "Screenshot of `tool -- mode` after launch", "the proof"),
        )

    def test_a_longer_fence_is_not_closed_by_a_shorter_one(self) -> None:
        body = """## Requested Evidence

- the real item

````markdown
```
- sample bullet
```
````

- the second item
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the real item", "the second item"],
        )

    def test_a_tilde_fence_is_not_closed_by_backticks(self) -> None:
        body = """## Requested Evidence

- the real item

~~~
```
- sample bullet
```
~~~

- the second item
"""
        self.assertEqual(
            run_contributor.extract_requested_evidence(body),
            ["the real item", "the second item"],
        )

    def test_padding_around_the_line_does_not_move_the_separator(self) -> None:
        # The ASCII-outranks-dash rule reads the separator each candidate was
        # cut at. Deriving it from the item and detail lengths instead would
        # be off by whatever stripping removed.
        for line, expected in (
            ("- [complete]  item -- proof — measured", ("complete", "item", "proof — measured")),
            ("- [complete] item -- proof — measured   ", ("complete", "item", "proof — measured")),
            ("- [complete]  item — a -- the detail", ("complete", "item — a", "the detail")),
            ("- [complete] item  --  the detail", ("complete", "item", "the detail")),
            ("- [complete] item\t--\tthe detail", ("complete", "item", "the detail")),
        ):
            with self.subTest(line=line):
                self.assertEqual(run_contributor.split_evidence_status_line(line), expected)

    def test_an_unterminated_fence_hides_what_follows_it(self) -> None:
        # GitHub renders everything after an unterminated fence as code, so
        # the contract holds what a reader can actually see as a bullet.
        body = "## Requested Evidence\n\n- first\n\n```\n- sample\n\n- never rendered\n"
        self.assertEqual(run_contributor.extract_requested_evidence(body), ["first"])

    def test_the_guard_only_fires_where_the_lane_is_ambiguous(self) -> None:
        # The guard leaves a line alone when a reading is `ci` or `diff`. It
        # must not leave alone a line whose readings all belong to the macOS
        # lane, or a detail carrying its own separator would wedge every
        # ordinary test and screenshot item.
        for item, kwargs in (
            ("`swift test` passes -- some note -- more", {"test_output": "ok"}),
            (
                "a screenshot of the panel -- captured later -- see it",
                {
                    "screenshot_upload_succeeded": True,
                    "screenshot_urls": [("s", "https://example.test/s.png")],
                },
            ),
        ):
            with self.subTest(item=item):
                body = f"## Evidence Status\n- [pending-ci] {item}\n"
                reconciled = run_contributor.reconcile_pending_ci_evidence(
                    body,
                    build_succeeded=True,
                    tests_succeeded=True,
                    smoke_succeeded=True,
                    **kwargs,
                )
                self.assertNotEqual(reconciled, body)
                self.assertIn("- [complete] ", reconciled)

    def test_a_line_whose_only_separator_is_inside_a_span_does_not_parse(self) -> None:
        # Splitting it would name the item "`a" and the detail "b`". Reporting
        # the line as unreadable is what the gate can act on.
        self.assertIsNone(run_contributor.split_evidence_status_line("- [complete] `a -- b`"))

    def test_a_code_span_is_delimited_by_matching_backtick_runs(self) -> None:
        # A span closes on a run of the SAME length, so a double-backtick span
        # holds its own `--` and a lone backtick, and an escaped backtick opens
        # nothing. Pairing backticks left to right instead gets all three wrong.
        for line, expected in (
            (
                "- [complete] ``alpha -- beta`` holds -- proof",
                ("complete", "``alpha -- beta`` holds", "proof"),
            ),
            (
                "- [complete] ``a ` b`` -- proof",
                ("complete", "``a ` b``", "proof"),
            ),
            (
                "- [complete] a literal \\` token -- proof shows a \\` token",
                ("complete", "a literal \\` token", "proof shows a \\` token"),
            ),
        ):
            with self.subTest(line=line):
                self.assertEqual(run_contributor.split_evidence_status_line(line), expected)

    def test_an_over_indented_fence_is_code_not_a_fence(self) -> None:
        # CommonMark allows a fence at most three spaces of indentation. Past
        # that GitHub renders indented code, so treating it as a fence would
        # open a block that swallows every later requested item.
        body = "## Requested Evidence\n\n- first\n\n    ```\n\n- second\n"
        self.assertEqual(
            run_contributor.extract_requested_evidence(body), ["first", "second"]
        )

    def test_an_over_indented_fence_does_not_join_the_bullet_above(self) -> None:
        # It toggles nothing, but it is not prose either: folding it in would
        # put a row of backticks in the item text.
        body = "## Requested Evidence\n\n- the item\n    ```\n- second\n"
        self.assertEqual(
            run_contributor.extract_requested_evidence(body), ["the item", "second"]
        )

    def test_a_tab_indented_fence_is_indented_code_not_a_fence(self) -> None:
        # A tab advances to column four, so this row is indented code by the
        # same rule four spaces are. Counting characters made it a fence, and
        # an opener with no closer takes every later item out of the contract
        # -- the direction that lets the gate pass without evidence a reader
        # can see was asked for.
        body = "## Requested Evidence\n\n- first\n\t```\n- second\n"
        self.assertEqual(
            run_contributor.extract_requested_evidence(body), ["first", "second"]
        )

    def test_indentation_before_a_fence_is_counted_in_columns(self) -> None:
        # The boundary is three columns, whichever characters spend them.
        for indent, opens_a_block in (
            ("", True),
            ("   ", True),
            ("    ", False),
            ("\t", False),
            (" \t", False),
            ("  \t", False),
            ("   \t", False),
        ):
            body = f"## Requested Evidence\n\n- first\n{indent}```\n- second\n"
            with self.subTest(indent=repr(indent)):
                self.assertEqual(
                    run_contributor.extract_requested_evidence(body),
                    ["first"] if opens_a_block else ["first", "second"],
                )

    def test_only_spaces_and_tabs_can_indent_a_fence(self) -> None:
        # CommonMark counts spaces and tabs as indentation and nothing else.
        # A row of backticks behind other whitespace is a paragraph GitHub
        # renders as literal text, so reading it as a fence opens a block that
        # takes every bullet below it out of the contract -- the same unsafe
        # direction the tab rule closed, reached through a different character.
        for space in ("\u00a0", "\u2003", "\u3000", "\x0b", "\x0c"):
            body = f"## Requested Evidence\n\n- first\n{space * 4}```\n- second\n"
            with self.subTest(space=repr(space)):
                self.assertEqual(
                    run_contributor.extract_requested_evidence(body), ["first", "second"]
                )

    def test_an_escape_hides_a_backtick_in_prose_but_not_inside_a_span(self) -> None:
        # CommonMark's asymmetry, and both halves matter here: masking escapes
        # before pairing gets the first line right and erases the second's
        # closer, which would cut the item at a `--` that is span content.
        self.assertEqual(
            run_contributor.split_evidence_status_line(
                "- [complete] a literal \\` token -- proof shows a \\` token"
            ),
            ("complete", "a literal \\` token", "proof shows a \\` token"),
        )
        self.assertEqual(
            run_contributor.split_evidence_status_line("- [complete] `a -- \\` -- proof"),
            ("complete", "`a -- \\`", "proof"),
        )


class EvidenceEntryExclusivityTests(unittest.TestCase):
    """One status entry proves one requirement (#1550)."""

    def test_one_entry_cannot_complete_two_requested_items(self) -> None:
        # The worked case. `alpha` is a prefix of `alpha -- beta`, so the one
        # line the author wrote reads as proof of both: the longer item takes
        # it by exact text, and the shorter one scored 1.0 against it because
        # the overlap was normalized by its own two words. Nothing proved
        # `alpha` on its own, so nothing should report it complete.
        requested = ["alpha", "alpha -- beta"]
        body = "## Evidence Status\n\n- [complete] alpha -- beta -- proof\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["complete_items"], ["alpha -- beta"])
        self.assertEqual(accounting["contested_items"], ["alpha"])
        # A contested item is also unproved, so every count that reads
        # `missing_items` keeps reading it as unaccounted for.
        self.assertEqual(accounting["missing_items"], ["alpha"])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertTrue(
            any("no Evidence Status entry of their own" in error for error in errors),
            errors,
        )

    def test_an_item_and_its_punctuated_twin_are_not_both_proved(self) -> None:
        # `_normalize_evidence_key` strips trailing `.,;:)`, so two requested
        # items that differ only there normalize to one key and one entry
        # answered both. They are two requirements while the contract says so.
        requested = ["proof", "proof."]
        body = "## Evidence Status\n\n- [complete] proof -- the log\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["complete_items"], ["proof"])
        self.assertEqual(accounting["contested_items"], ["proof."])
        self.assertEqual(accounting["missing_items"], ["proof."])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertTrue(
            any("no Evidence Status entry of their own" in error for error in errors),
            errors,
        )

    def test_the_fallback_still_matches_the_wording_it_exists_for(self) -> None:
        # An author writes the item back in their own hand: a code span the
        # issue did not have, a sentence-final period, a different case, a
        # trailing word. Each of these is one requirement with one entry, and
        # each still matches.
        requested = ["The launch state is captured"]
        for entry in (
            "The launch state is captured",
            "the launch state is captured.",
            "`The launch state is captured`",
            "THE LAUNCH STATE IS CAPTURED",
            "The launch state is captured on macOS",
        ):
            body = f"## Evidence Status\n\n- [complete] {entry} -- the shot\n"
            with self.subTest(entry=entry):
                accounting = run_contributor.evaluate_evidence_accounting(body, requested)
                self.assertEqual(accounting["complete_items"], requested)
                self.assertEqual(accounting["contested_items"], [])
                self.assertEqual(accounting["unexpected_items"], [])

    def test_two_items_with_their_own_entries_are_both_proved(self) -> None:
        # Exclusivity is about one entry answering two requirements, not about
        # two requirements that overlap in wording. Both are proved here.
        requested = ["alpha", "alpha -- beta"]
        body = (
            "## Evidence Status\n\n"
            "- [complete] alpha -- the first proof\n"
            "- [complete] alpha -- beta -- the second proof\n"
        )
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["complete_items"], requested)
        self.assertEqual(accounting["contested_items"], [])
        self.assertEqual(accounting["missing_items"], [])

    def test_an_exact_entry_outranks_another_item_reaching_for_it(self) -> None:
        # Assignment walks the tiers across the whole contract, not the
        # contract item by item. Were it item by item, the first item's loose
        # match would take the entry the second item names exactly.
        requested = ["the state", "the state after setup is captured"]
        body = (
            "## Evidence Status\n\n"
            "- [complete] the state after setup is captured -- the shot\n"
        )
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(
            accounting["complete_items"], ["the state after setup is captured"]
        )
        self.assertEqual(accounting["contested_items"], ["the state"])
        self.assertEqual(accounting["missing_items"], ["the state"])

    def test_the_assignment_does_not_depend_on_the_order_of_the_contract(self) -> None:
        # Taking the first free entry is order-dependent: the broad item
        # matches both entries, the narrow one matches only the first, and
        # first-come lets the broad item take the entry the narrow one needs.
        # Augmenting re-places the holder, so both are proved either way.
        broad = "capture parser timing with long contracts across dense status lines"
        narrow = "capture parser timing with long contracts across locally"
        body = (
            "## Evidence Status\n\n"
            "- [complete] capture parser timing with long contracts across -- one\n"
            "- [complete] capture parser timing across dense status lines -- two\n"
        )
        for requested in ([broad, narrow], [narrow, broad]):
            with self.subTest(order=requested[0][-16:]):
                accounting = run_contributor.evaluate_evidence_accounting(body, requested)
                self.assertCountEqual(accounting["complete_items"], requested)
                self.assertEqual(accounting["missing_items"], [])
                self.assertEqual(accounting["contested_items"], [])

    STEM = ["capture", "parser", "timing", "with", "long", "contracts", "across"]
    EXTRA = ["dense", "status", "lines", "locally", "hosted", "nightly", "again"]

    def near_duplicate_contracts(self, seed: int, *, one_tier: bool):
        """Contracts and bodies worded closely enough to compete for entries.

        Words drawn at random almost never reach the overlap floor, so a fuzz
        over them proves nothing. These share a stem and differ by a word or
        two, which is what two requirements in one issue actually look like.
        `one_tier` marks the two sides apart so no text and no normalized key
        can coincide, leaving every edge an overlap edge.
        """
        rng = random.Random(seed)
        for _ in range(300):
            stem = self.STEM[: rng.randint(3, 7)]

            def phrase(mark: str) -> str:
                return " ".join(stem + rng.sample(self.EXTRA, rng.randint(0, 2)) + mark.split())

            items = list(dict.fromkeys(
                phrase("itemside" if one_tier else "") for _ in range(rng.randint(2, 4))
            ))
            keys = list(dict.fromkeys(
                phrase("entryside" if one_tier else "") for _ in range(rng.randint(2, 4))
            ))
            if not items or not keys:
                continue
            yield items, {key: {"status": "complete", "detail": "p"} for key in keys}

    def largest_assignment(self, edges: set[tuple[str, str]], width: int) -> int:
        for size in range(width, 0, -1):
            for chosen in itertools.combinations(sorted(edges), size):
                if len({item for item, _ in chosen}) == size == len({key for _, key in chosen}):
                    return size
        return 0

    def edges_of(self, items: list[str], entries: dict[str, dict[str, str]]):
        # One item against one entry answers "could this pair ever match"
        # without restating the tier rules here.
        return {
            (item, key)
            for item in items
            for key in entries
            if run_contributor._match_evidence_entries([item], {key: entries[key]})[0]
        }

    def test_within_one_tier_the_assignment_is_maximum(self) -> None:
        # The property the augmenting walk exists for, checked against a
        # brute-force maximum rather than against itself: no item is reported
        # unproved while an assignment of distinct entries covering every
        # matchable item exists. Taking the first free entry fails this.
        for items, entries in self.near_duplicate_contracts(20260906, one_tier=True):
            matched, _ = run_contributor._match_evidence_entries(items, entries)
            with self.subTest(items=items, entries=list(entries)):
                self.assertEqual(
                    len(matched),
                    self.largest_assignment(
                        self.edges_of(items, entries), min(len(items), len(entries))
                    ),
                )

    def test_the_assignment_does_not_depend_on_the_order_of_the_contract(self) -> None:
        # Reordering the issue's bullets is not a change to what was proved.
        for items, entries in self.near_duplicate_contracts(20260906, one_tier=False):
            forwards, _ = run_contributor._match_evidence_entries(items, entries)
            backwards, _ = run_contributor._match_evidence_entries(items[::-1], entries)
            with self.subTest(items=items, entries=list(entries)):
                self.assertEqual(len(forwards), len(backwards))

    def test_a_broad_item_does_not_take_the_entry_a_narrow_one_needs(self) -> None:
        # The concrete shape behind the fuzz: the broad item matches both
        # entries, the narrow one matches only the first. First-come lets the
        # broad item take it and reports the narrow one missing; augmenting
        # re-places the holder, so both are proved in either order.
        broad = "capture parser timing with long contracts across dense status lines"
        narrow = "capture parser timing with long contracts across locally"
        body = (
            "## Evidence Status\n\n"
            "- [complete] capture parser timing with long contracts across -- one\n"
            "- [complete] capture parser timing across dense status lines -- two\n"
        )
        for requested in ([broad, narrow], [narrow, broad]):
            with self.subTest(first=requested[0][-16:]):
                accounting = run_contributor.evaluate_evidence_accounting(body, requested)
                self.assertCountEqual(accounting["complete_items"], requested)
                self.assertEqual(accounting["missing_items"], [])
                self.assertEqual(accounting["contested_items"], [])

    def test_reordering_the_contract_changes_nothing_it_proved(self) -> None:
        # Equal cardinality is not enough. Which entry each item takes decides
        # its status, and statuses decide the review gate -- a `[pending-ci]`
        # landing on a `diff` item does not block approval while the same line
        # on any other kind does. Shuffling an issue's bullets must not move
        # that, so assignment walks a canonical order rather than the
        # contract's.
        for items, entries in self.near_duplicate_contracts(4242, one_tier=False):
            if len(items) < 2:
                continue
            forwards, _ = run_contributor._match_evidence_entries(items, entries)
            with self.subTest(items=items, entries=list(entries)):
                for permuted in (items[::-1], sorted(items), sorted(items, reverse=True)):
                    self.assertEqual(
                        run_contributor._match_evidence_entries(permuted, entries)[0],
                        forwards,
                    )

    def test_reordering_the_status_lines_changes_nothing_they_proved(self) -> None:
        # The other side of the same property. The order the author happened
        # to write the status lines in decides which entry an item takes
        # otherwise, and an entry's status decides the review gate.
        for items, entries in self.near_duplicate_contracts(777, one_tier=False):
            if len(entries) < 2:
                continue
            forwards, _ = run_contributor._match_evidence_entries(items, entries)
            with self.subTest(items=items, entries=list(entries)):
                for keys in (list(entries)[::-1], sorted(entries)):
                    permuted = {key: entries[key] for key in keys}
                    self.assertEqual(
                        run_contributor._match_evidence_entries(items, permuted)[0],
                        forwards,
                    )

    def test_the_candidate_limit_counts_entries_still_available(self) -> None:
        # Eight requirements answered exactly, and a ninth loosely worded one
        # against the one entry left. Counting the eight taken entries toward
        # the limit read the ninth as too crowded to name one, when only one
        # entry was ever available to it.
        limit = run_contributor.EVIDENCE_OVERLAP_CANDIDATE_LIMIT
        exact = [f"requirement number {index} proving a distinct thing" for index in range(limit)]
        loose = "requirement number proving a distinct thing"
        keys = exact + ["requirement number nine proving a distinct thing"]
        entries = {key: {"status": "complete", "detail": "p"} for key in keys}
        matched, contested = run_contributor._match_evidence_entries(exact + [loose], entries)
        self.assertEqual(len(matched), limit + 1)
        self.assertEqual(contested, [])

    def test_an_item_reading_as_many_entries_names_none_of_them(self) -> None:
        # A body can be written so every entry overlaps every item, which is
        # both a guess and the shape that makes the augmenting walk expensive.
        # Past the limit the item matches nothing and is reported contested,
        # which fails the gate rather than picking one of them.
        limit = run_contributor.EVIDENCE_OVERLAP_CANDIDATE_LIMIT
        shared = "alpha bravo charlie delta echo foxtrot golf"
        for count, matches in ((limit, True), (limit + 1, False)):
            entries = {
                f"{shared} number{index}": {"status": "complete", "detail": "p"}
                for index in range(count)
            }
            item = f"{shared} hotel"
            matched, contested = run_contributor._match_evidence_entries([item], entries)
            with self.subTest(entries=count):
                self.assertEqual(bool(matched), matches)
                self.assertEqual(contested, [] if matches else [item])

    def test_a_dense_overlap_body_does_not_cost_the_square_of_the_contract(self) -> None:
        # Every one of a million pairs reaching the overlap tier is what makes
        # augmenting expensive; the candidate limit is what stops it. Two
        # orders of magnitude of headroom over the measured cost.
        shared = "alpha bravo charlie delta echo foxtrot golf"
        items = [f"{shared} item{index}" for index in range(300)]
        entries = {
            f"{shared} entry{index}": {"status": "complete", "detail": "p"}
            for index in range(300)
        }
        started = time.perf_counter()
        matched, _ = run_contributor._match_evidence_entries(items, entries)
        self.assertEqual(matched, {})
        self.assertLess(time.perf_counter() - started, 5.0)

    def test_a_stronger_match_outranks_a_larger_assignment(self) -> None:
        # Across tiers the assignment is deliberately NOT maximum. An item may
        # only be re-placed within the tier it matched at, so proving one more
        # requirement never costs an item the entry it names exactly -- the
        # collision is reported instead, which is the whole point of #1550.
        named = "alpha bravo charlie delta"
        other = "alpha bravo charlie delta foxtrot"
        body = (
            "## Evidence Status\n\n"
            f"- [complete] {named} -- one\n"
            "- [complete] alpha bravo charlie delta echo -- two\n"
        )
        # Both items could be proved at once by moving the first onto the
        # second entry, which it overlaps. That is a larger assignment and the
        # wrong one: the first item names its entry, and taking that away to
        # prove the second is exactly the swap #1550 is about.
        accounting = run_contributor.evaluate_evidence_accounting(body, [named, other])
        self.assertEqual(accounting["complete_items"], [named])
        self.assertEqual(accounting["contested_items"], [other])

    def test_a_loose_match_never_takes_the_entry_an_item_names(self) -> None:
        # Re-placement is bounded by the tier the holder matched at, so
        # augmenting cannot move an item off the entry it names exactly onto
        # a weaker one to make room for someone else.
        requested = ["alpha beta gamma delta", "alpha beta gamma"]
        body = "## Evidence Status\n\n- [complete] alpha beta gamma -- one\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["complete_items"], ["alpha beta gamma"])
        self.assertEqual(accounting["contested_items"], ["alpha beta gamma delta"])

    def test_an_item_outbid_at_the_overlap_tier_reads_as_contested(self) -> None:
        # Two requirements differing by one word, one entry naming one of
        # them. The other genuinely competed for that entry and lost, which
        # is what the author needs told -- not that they wrote nothing.
        hosted = "the hosted runner build passes on macos fifteen with signing enabled"
        local = "the local runner build passes on macos fifteen with signing enabled"
        body = f"## Evidence Status\n\n- [complete] {local} -- proof\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, [hosted, local])
        self.assertEqual(accounting["complete_items"], [local])
        self.assertEqual(accounting["contested_items"], [hosted])

    def test_a_contract_asking_twice_is_malformed_rather_than_proved_twice(self) -> None:
        # `matched` is keyed by item text, so two byte-identical items are one
        # key to it and one entry answered both with no error at all. They are
        # the same requirement to everything downstream, so the contract is
        # what is wrong, and the gate says so where the author can fix it.
        requested = ["same requirement", "same requirement"]
        body = "## Evidence Status\n\n- [complete] same requirement -- proof\n"
        accounting, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertEqual(accounting["duplicate_requested_items"], ["same requirement"])
        self.assertIn(
            "evidence_contract_duplicate",
            {entry["category"] for entry in run_contributor.classify_evidence_errors(errors)},
        )
        # `proof` and `proof.` are the same requirement for the same reason:
        # the gate cannot tell one key from the other.
        _, punctuated = run_contributor.validate_evidence_accounting(
            "## Evidence Status\n\n- [complete] proof -- the log\n", ["proof", "proof."]
        )
        self.assertTrue(
            any(error.startswith("requested evidence asks for the same item") for error in punctuated),
            punctuated,
        )

    def test_a_repeated_requested_item_claims_one_entry_not_two(self) -> None:
        # Two byte-identical requested items are one key in the match table,
        # so they are one requirement to it -- an admission-time duplicate
        # check, not a matcher fix. What the matcher must not do is let the
        # second copy consume a second entry: the leftover line is reported
        # `unexpected`, which is what a stray entry should read as.
        requested = ["alpha beta gamma", "alpha beta gamma"]
        body = (
            "## Evidence Status\n\n"
            "- [complete] alpha beta gamma -- one\n"
            "- [complete] alpha beta gamma delta -- two\n"
        )
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["complete_items"], requested)
        self.assertEqual(accounting["unexpected_items"], ["alpha beta gamma delta"])

    def test_an_item_that_normalizes_to_nothing_proves_nothing(self) -> None:
        # `_normalize_evidence_key` strips backticks and trailing punctuation,
        # so an item that is only those normalizes to the empty string. It has
        # no words to overlap and no key to look up, so it matches nothing and
        # is reported missing rather than dividing by zero or matching all.
        body = (
            "## Evidence Status\n\n"
            "- [complete] alpha beta gamma -- one\n"
            "- [complete] alpha beta gamma delta -- two\n"
        )
        accounting = run_contributor.evaluate_evidence_accounting(body, ["`.`"])
        self.assertEqual(accounting["missing_items"], ["`.`"])
        self.assertEqual(accounting["contested_items"], [])
        self.assertEqual(len(accounting["unexpected_items"]), 2)

        # And an entry that normalizes to nothing is not the same requirement
        # as an item that normalizes to nothing: two unreadable strings are
        # two unreadable strings, not a match.
        empty = run_contributor.evaluate_evidence_accounting(
            "## Evidence Status\n\n- [complete] ;;; -- proof\n", ["..."]
        )
        self.assertEqual(empty["missing_items"], ["..."])
        self.assertEqual(empty["unexpected_items"], [";;;"])

    def test_a_contested_item_never_reads_as_an_unexpected_entry(self) -> None:
        # `unexpected_items` is what the gate reports as an entry answering
        # nothing. The contested item's entry does answer something, so the
        # error the author sees names the collision rather than a stray line.
        requested = ["alpha", "alpha -- beta"]
        body = "## Evidence Status\n\n- [complete] alpha -- beta -- proof\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["unexpected_items"], [])
        categories = {
            entry["category"]
            for entry in run_contributor.classify_evidence_errors(
                run_contributor.validate_evidence_accounting(body, requested)[1]
            )
        }
        self.assertIn("evidence_contested", categories)


class EvidenceStatusLineCostTests(unittest.TestCase):
    """The parser reads a body an author controls, so its cost is bounded."""

    # The separator match is zero-width on both sides, so consecutive
    # separators share the space between them and a boundary lands every two
    # characters. This is the densest candidate field a status line can carry;
    # `` `x -- y` -- `` looks denser and is six times sparser.
    FRAGMENT = " —"
    # A separator every twelve characters, half of them inside a code span.
    SPAN_FRAGMENT = "`x -- y` -- "

    def status_line(self, length: int, fragment: str | None = None) -> str:
        prefix, tail = "- [complete] ", " tail"
        fragment = fragment or self.FRAGMENT
        fill = fragment * (1 + length // len(fragment))
        line = prefix + fill[: length - len(prefix) - len(tail)] + tail
        self.assertEqual(len(line), length)
        return line

    def test_the_dense_fixture_is_the_dense_one(self) -> None:
        # The claim the budget rests on. If a denser shape exists the budget
        # is measuring the wrong input, which is how the first version of
        # these tests passed while a real body took ten times as long.
        limit = run_contributor.EVIDENCE_STATUS_LINE_LIMIT
        counts = {
            name: len(
                run_contributor._evidence_status_boundaries(
                    self.status_line(limit, fragment)[len("- [complete] "):]
                )
            )
            for name, fragment in (("dash", self.FRAGMENT), ("span", self.SPAN_FRAGMENT))
        }
        self.assertGreater(counts["dash"], 5 * counts["span"])

    def test_a_status_line_past_the_limit_is_unreadable_not_slow(self) -> None:
        # Reading every candidate split is worth doing for a line a person
        # wrote and pointless for one no person wrote. Past the limit the line
        # is not split at all, so it lands in `invalid_lines` where the gate
        # reports it -- visible, and the direction that fails closed.
        limit = run_contributor.EVIDENCE_STATUS_LINE_LIMIT
        self.assertIsNone(
            run_contributor.split_evidence_status_line(self.status_line(limit + 1))
        )
        self.assertIsNotNone(
            run_contributor.split_evidence_status_line(self.status_line(limit))
        )

    def test_an_overlong_status_line_is_reported_rather_than_dropped(self) -> None:
        overlong = self.status_line(run_contributor.EVIDENCE_STATUS_LINE_LIMIT + 1)
        body = f"## Evidence Status\n\n{overlong}\n"
        accounting = run_contributor.evaluate_evidence_accounting(body, ["an item"])
        self.assertEqual(accounting["invalid_lines"], [overlong])

    def test_a_full_size_body_parses_within_a_fixed_budget(self) -> None:
        # GitHub bodies run to 65,536 characters. Every line sits at the limit
        # and carries the densest candidate field, and the contract matches
        # none of them, so no loop exits early. Two orders of magnitude of
        # headroom, which only a return to per-candidate work can spend.
        for name, fragment in (("dash", self.FRAGMENT), ("span", self.SPAN_FRAGMENT)):
            line = self.status_line(run_contributor.EVIDENCE_STATUS_LINE_LIMIT, fragment)
            lines = [line] * (65_536 // (len(line) + 1))
            body = "## Evidence Status\n\n" + "\n".join(lines) + "\n"
            with self.subTest(fragment=name):
                self.assertGreater(len(body), 60_000)
                started = time.perf_counter()
                run_contributor.evaluate_evidence_accounting(body, ["an item"])
                self.assertLess(time.perf_counter() - started, 2.0)

    def test_the_reconciler_refuses_a_line_of_too_many_readings(self) -> None:
        # It already refuses whenever the boundary guess is load-bearing, and
        # a line carrying more readings than a person writes is that. Refusing
        # leaves it `pending-ci`, which fails the readiness gate and is seen.
        limit = run_contributor.EVIDENCE_STATUS_READING_LIMIT
        for dashes, resolves in ((limit - 1, True), (limit, False)):
            item = "`swift test` passes" + " — a" * dashes
            rest = f"{item} -- upload pending"
            body = f"## Evidence Status\n\n- [pending-ci] {rest}\n"
            with self.subTest(readings=dashes + 1):
                self.assertEqual(
                    len(run_contributor._evidence_status_boundaries(rest)), dashes + 1
                )
                out = run_contributor.reconcile_pending_ci_evidence(
                    body,
                    build_succeeded=True,
                    tests_succeeded=True,
                    smoke_succeeded=True,
                    test_output="ok",
                    screenshot_upload_succeeded=False,
                    screenshot_urls=[],
                    text_upload_required=False,
                    text_upload_succeeded=False,
                    text_urls=[],
                )
                self.assertEqual("[pending-ci]" not in out, resolves)

    def test_the_floor_never_skips_the_candidate_the_contract_wants(self) -> None:
        # Skipping a candidate before normalizing it is only safe if the floor
        # can never exceed the key it stands in for. The tight case is a long
        # item that IS the requested one, at the far end of a dense line: its
        # floor sits exactly at the longest requested key's length.
        for item in (
            "a — b — c — d — e — f — g — h — i — j — k — l — m — n — o — p",
            "`a run of words — with a span — and trailing punctuation`.",
            "x" * 300 + " — tail words here",
        ):
            line = f"- [complete] {item} -- {'a — b — ' * 30}done"
            with self.subTest(item=item[:32]):
                split = run_contributor.split_evidence_status_line(line, [item])
                self.assertIsNotNone(split)
                self.assertEqual(split[1], item)


if __name__ == "__main__":
    unittest.main()
