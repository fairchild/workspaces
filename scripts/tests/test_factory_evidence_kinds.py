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

if __name__ == "__main__":
    unittest.main()
