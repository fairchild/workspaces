#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Policy tests for first-class `ci` and `diff` evidence kinds (#1120).

Intent: prove classification is fail-closed (no guessed check names), that
ci/diff contracts no longer draw blocked:evidence at open, that the macOS
lane leaves event-completed kinds alone, and that trusted-lane writers can
flip entries without hand-editing markdown.
"""

from __future__ import annotations

import ast
import bisect
import contextlib
import importlib.util
import io
import inspect
import itertools
import os
import json
import random
import re
import sys
import time
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def entries_for(lines):
    """Entries whose rendered lines are exactly these, for a test that holds lines.

    The one helper round 12 keeps, with its reason: these cases are about what
    the write CARRIES -- a block it moves, a refusal it makes -- and they are
    written in the lines the case is about rather than in the metadata behind
    them. Building entries by hand at twenty-one call sites would put the
    composer's shape in twenty-one places.

    It cannot drift from the composer, because it checks itself against it:
    the entries it returns render back to the lines it was given, byte for
    byte, or it raises. A line no entry can produce is passed over rather
    than invented.
    """
    evidence = sys.modules["evidence"]
    shape = re.compile(r"^- \[(complete|blocked|pending-ci)\] (.+?) -- (.+)$")
    entries, expected = [], []
    for line in lines:
        match = shape.match(line)
        if not match:
            continue
        entries.append(
            {
                "index": len(entries) + 1,
                "item": match[2],
                "status": match[1],
                "detail": match[3],
                "kind": "test",
            }
        )
        expected.append(line)
    rendered = evidence.rendered_entry_lines(entries)
    assert rendered == expected, f"the helper and the composer disagree: {rendered} != {expected}"
    return entries


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_contributor = load_module("run_contributor_evidence_kinds", SCRIPT_PATH)
sync_execution_state = load_module(
    "sync_execution_state_evidence_kinds", SCRIPT_PATH.with_name("sync-execution-state.py")
)

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
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")
        # "All tests pass" was in this list as a third non-diff example. It is
        # still not a diff item; it is now a `test-attested` one, which is the
        # whole point of the widening.
        self.assertEqual(
            run_contributor._evidence_item_kind("All tests pass"), "test-attested"
        )

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


class EvidenceStatusHeadingCaseTests(unittest.TestCase):
    """The lane finds `## evidence status` where it finds `## Evidence Status` (#1609).

    The readiness gate reads a status section under either spelling, so a
    writer that looks only for the exact one leaves a lower-case section's
    `pending-ci` lines pending after the lane has run.
    """

    def test_the_lane_resolves_pending_lines_under_a_lower_case_heading(self) -> None:
        body = "## evidence status\n- [pending-ci] swift build -- macOS lane will build\n"
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
        )
        self.assertIn("- [complete] swift build", reconciled)
        self.assertTrue(reconciled.startswith("## evidence status\n"))

    def test_metadata_lands_above_a_lower_case_heading_and_keeps_its_case(self) -> None:
        body = (
            "## Summary\nx\n\n"
            "## Evidence Status\n- [complete] item -- proof\n\n"
            "## Validation\n- ran it\n"
        )
        payload: dict[str, object] = {"entries": []}
        canonical = run_contributor._insert_evidence_metadata(body, payload)
        self.assertLess(canonical.index("<!-- evidence-status:"), canonical.index("## Evidence Status"))
        lower = run_contributor._insert_evidence_metadata(
            body.replace("## Evidence Status", "## evidence status"), payload
        )
        self.assertEqual(lower, canonical.replace("## Evidence Status", "## evidence status"))


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
        items = run_contributor.requested_evidence_contract(self.WRAPPED_BODY)[0]
        self.assertEqual(len(items), 2)
        self.assertEqual(
            items[0],
            "`ps -Eww` on a late-created surface — not the first one — showing "
            "`command`, `initial_input` and `env_vars` all applied, compared "
            "against a hand-opened control",
        )
        self.assertTrue(items[1].endswith("go unnoticed"))

    def test_an_unindented_paragraph_does_not_join_the_bullet_above(self) -> None:
        items = run_contributor.requested_evidence_contract(self.WRAPPED_BODY)[0]
        self.assertNotIn("Scope note", " ".join(items))

    def test_an_item_with_an_internal_em_dash_round_trips(self) -> None:
        # Authored in the issue, written as a markdown status line in the PR
        # body, matched by the gate -- the whole path, not just the regex.
        body = f"## Requested Evidence\n\n- {self.EM_DASH_ITEM}\n"
        requested = run_contributor.requested_evidence_contract(body)[0]
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


class SectionHeadingCaseTests(unittest.TestCase):
    """A heading's case does not decide whether its section exists (#1598).

    #1450 wrote `## Requested evidence` and was read as having no contract at
    all, while #1558, one letter away, was held to every item. GitHub renders
    the two headings alike, so neither author could see the difference.
    """

    ITEMS = "- `swift test` passes\n- Screenshots of the new sidebar\n"

    def test_a_lower_case_requested_evidence_heading_is_the_same_contract(self) -> None:
        canonical = run_contributor.requested_evidence_contract(
            f"## Requested Evidence\n\n{self.ITEMS}"
        )[0]
        self.assertEqual(canonical, ["`swift test` passes", "Screenshots of the new sidebar"])
        for heading in ("Requested evidence", "requested evidence", "REQUESTED EVIDENCE"):
            with self.subTest(heading=heading):
                self.assertEqual(
                    run_contributor.requested_evidence_contract(f"## {heading}\n\n{self.ITEMS}")[0],
                    canonical,
                )

    def test_a_lower_case_evidence_status_heading_is_the_status_section(self) -> None:
        requested = ["The launch state is captured"]
        body = "## evidence status\n- [complete] The launch state is captured -- the shot, attached above\n"
        self.assertTrue(run_contributor.has_markdown_section(body, "Evidence Status"))
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        self.assertEqual(accounting["missing_items"], [])
        self.assertEqual(accounting["complete_items"], requested)

    def test_re_rendering_a_section_replaces_it_whatever_its_case(self) -> None:
        # Presence tolerating case while the strip does not would leave the
        # hand-written section beside the rendered one: two status sections.
        body = (
            "## Summary\nx\n\n"
            "## evidence status\n- [pending-ci] the item\n\n"
            "## Validation\n- ran it\n"
        )
        rendered = run_contributor.insert_markdown_section(
            body, "Evidence Status", "- [complete] the item -- proof", before_heading="Validation"
        )
        self.assertEqual(rendered.casefold().count("## evidence status"), 1)
        self.assertIn("- [complete] the item -- proof", rendered)
        self.assertNotIn("[pending-ci]", rendered)

    def test_inserting_before_a_lower_case_heading_keeps_the_new_section(self) -> None:
        # Presence and placement are two matches. If only presence tolerates
        # case, placement finds nothing to insert before and the new section
        # is dropped without a word.
        body = "## Summary\nx\n\n## risks\n- none\n"
        rendered = run_contributor.insert_markdown_section(
            body, "Validation", "- ran it", before_heading="Risks"
        )
        self.assertIn("## Validation\n- ran it", rendered)
        self.assertLess(rendered.index("## Validation"), rendered.index("## risks"))

    def test_the_inserted_section_is_written_as_text(self) -> None:
        # Placement is a substitution. Handed a replacement string, `re.sub`
        # reads a backslash in the section as one of its own escapes, and a
        # `\d` in a validation note raised instead of being inserted.
        note = r"- ran `rg '\d+ tests'` over the log"
        rendered = run_contributor.insert_markdown_section(
            "## Risks\n- none\n", "Validation", note, before_heading="Risks"
        )
        self.assertIn(f"## Validation\n{note}\n\n## Risks", rendered)

    def test_both_readers_of_blocked_by_take_a_lower_case_heading(self) -> None:
        # The rule belongs to the helper, not to the evidence headings: a fix
        # scoped to those two would leave this one behind. sync-execution-state.py
        # carries its own copy of the match, and if the two disagreed, one would
        # call an issue blocked and the other would not.
        body = "## Blocked by\n\n- #12\n- #34\n"
        self.assertEqual(run_contributor.blocked_by_contract(body)[0], [12, 34])
        self.assertEqual(sync_execution_state.blocked_by_contract(body)[0], [12, 34])


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
            run_contributor.requested_evidence_contract(body)[0],
            ["the item, which wraps onto a continuation line"],
        )

    def test_an_indented_quote_is_not_folded_into_the_item(self) -> None:
        body = """## Requested Evidence

- the item, which wraps
  > a nested quote
"""
        self.assertEqual(
            run_contributor.requested_evidence_contract(body)[0],
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
            run_contributor.requested_evidence_contract(body)[0],
            ["the first item ```inline``` proves it", "the second item"],
        )

    def test_a_quote_marker_needs_no_space_but_a_threshold_is_not_one(self) -> None:
        self.assertEqual(
            run_contributor.requested_evidence_contract(
                "## Requested Evidence\n\n- the item\n  >nested quote\n"
            )[0],
            ["the item"],
        )
        self.assertEqual(
            run_contributor.requested_evidence_contract(
                "## Requested Evidence\n\n- the pass rate holds at\n  >= 95% of runs\n"
            )[0],
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
            run_contributor.requested_evidence_contract(body)[0],
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
            run_contributor.requested_evidence_contract(body)[0],
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
            run_contributor.requested_evidence_contract(body)[0],
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
        self.assertEqual(run_contributor.requested_evidence_contract(body)[0], ["first"])

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
            run_contributor.requested_evidence_contract(body)[0], ["first", "second"]
        )

    def test_an_over_indented_fence_does_not_join_the_bullet_above(self) -> None:
        # It toggles nothing, but it is not prose either: folding it in would
        # put a row of backticks in the item text.
        body = "## Requested Evidence\n\n- the item\n    ```\n- second\n"
        self.assertEqual(
            run_contributor.requested_evidence_contract(body)[0], ["the item", "second"]
        )

    def test_a_tab_indented_fence_is_indented_code_not_a_fence(self) -> None:
        # A tab advances to column four, so this row is indented code by the
        # same rule four spaces are. Counting characters made it a fence, and
        # an opener with no closer takes every later item out of the contract
        # -- the direction that lets the gate pass without evidence a reader
        # can see was asked for.
        body = "## Requested Evidence\n\n- first\n\t```\n- second\n"
        self.assertEqual(
            run_contributor.requested_evidence_contract(body)[0], ["first", "second"]
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
                    run_contributor.requested_evidence_contract(body)[0],
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
                    run_contributor.requested_evidence_contract(body)[0], ["first", "second"]
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


class ReconcilerContractTests(unittest.TestCase):
    """The macOS lane reads the contract the gate reads (#1551)."""

    # Reads as a `diff` item at the em-dash and a screenshot item at the
    # `--`. Which one it is decides which lane completes it, and nothing in
    # the line itself can say.
    AMBIGUOUS_LINE = (
        "- [pending-ci] The PR diff shows the launch state — final screenshot "
        "after setup -- evidence job will upload it"
    )
    DIFF_READING = "The PR diff shows the launch state"
    SCREENSHOT_READING = (
        "The PR diff shows the launch state — final screenshot after setup"
    )

    def reconcile(self, body: str, requested: list[str] | None):
        return run_contributor.reconcile_pending_ci_evidence(
            body,
            requested_evidence=requested,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[("shot", "https://example.test/shot.png")],
        )

    def test_the_contract_decides_which_reading_the_macos_lane_owns(self) -> None:
        body = f"## Evidence Status\n{self.AMBIGUOUS_LINE}\n"

        resolved = self.reconcile(body, [self.SCREENSHOT_READING])
        self.assertIn(f"- [complete] {self.SCREENSHOT_READING} -- ", resolved)
        self.assertIn("https://example.test/shot.png", resolved)

        # The same line, same capture, same successful upload. The contract
        # asks for the diff reading, which completes through the review lane,
        # so the macOS lane leaves it where it found it.
        self.assertEqual(self.reconcile(body, [self.DIFF_READING]), body)

    def test_a_line_no_reading_of_which_is_requested_is_still_refused(self) -> None:
        # The contract in hand does not anchor this line, so the boundary is a
        # guess again and the guess is load-bearing: one reading is a `diff`
        # item. It stays pending, which fails the readiness gate and is seen.
        body = f"## Evidence Status\n{self.AMBIGUOUS_LINE}\n"
        for requested in ([], ["something else entirely"], None):
            with self.subTest(requested=requested):
                self.assertEqual(self.reconcile(body, requested), body)

    def test_the_contract_reaches_past_the_reading_limit(self) -> None:
        # The reading limit refuses a line the reconciler would be guessing
        # at. An anchored line is not a guess, so the limit does not apply to
        # it -- and the walk that counts readings is skipped entirely.
        item = "final screenshot after setup" + " — a" * (
            run_contributor.EVIDENCE_STATUS_READING_LIMIT + 4
        )
        body = f"## Evidence Status\n- [pending-ci] {item} -- upload pending\n"
        self.assertEqual(self.reconcile(body, None), body)
        self.assertIn("- [complete] ", self.reconcile(body, [item]))

    def test_an_anchored_numeric_item_is_the_item_the_contract_named(self) -> None:
        # A bare index is the structured-update key, so the reconciler skips
        # it -- unless the contract really does ask for it, which is the same
        # rule `extract_evidence_status_entries` follows. `404` is an `other`
        # kind, so the lane says it cannot reconcile it rather than leaving
        # the line unexplained; both states fail the readiness gate.
        body = "## Evidence Status\n- [pending-ci] 404 -- capture pending\n"
        self.assertEqual(self.reconcile(body, None), body)
        self.assertIn(
            "- [blocked] 404 -- self-hosted macOS CI cannot reconcile",
            self.reconcile(body, ["404"]),
        )

    def test_the_contract_changes_nothing_the_lane_already_read_right(self) -> None:
        # An unambiguous line resolves the same way with the contract and
        # without it, and a `ci` item is left to the verifier either way.
        body = (
            "## Evidence Status\n"
            f"- [pending-ci] {CI_ITEM} -- waiting for checks\n"
            "- [pending-ci] swift build -- macOS lane will build\n"
        )
        for requested in (None, [CI_ITEM, "swift build"]):
            with self.subTest(requested=requested):
                reconciled = self.reconcile(body, requested)
                self.assertIn(f"- [pending-ci] {CI_ITEM} -- waiting for checks", reconciled)
                self.assertIn("- [complete] swift build", reconciled)


class EvidenceEntryExclusivityTests(unittest.TestCase):
    """One status entry proves one requirement (#1550)."""

    def test_no_test_in_this_file_shadows_another(self) -> None:
        # Python keeps the last definition of a name, so a copy-pasted method
        # name silently drops the earlier test and the file still reports OK.
        # Nothing in CI lints these files, and this collision reached two
        # review rounds before a reader caught it.
        source = Path(__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if not isinstance(node, ast.ClassDef):
                continue
            names = [
                child.name
                for child in node.body
                if isinstance(child, ast.FunctionDef) and child.name.startswith("test_")
            ]
            with self.subTest(test_class=node.name):
                self.assertEqual(sorted(names), sorted(set(names)))

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
        # each still matches. Only a line naming the item as written completes
        # it: the trailing word changes what the line claims to a reader, so
        # that one matches and reads as blocked (`_hand_completion_refusal`).
        requested = ["The launch state is captured"]
        for entry, completes in (
            ("The launch state is captured", True),
            ("the launch state is captured.", True),
            ("`The launch state is captured`", True),
            ("THE LAUNCH STATE IS CAPTURED", True),
            ("The launch state is captured on macOS", False),
        ):
            body = f"## Evidence Status\n\n- [complete] {entry} -- the shot\n"
            with self.subTest(entry=entry):
                accounting = run_contributor.evaluate_evidence_accounting(body, requested)
                self.assertEqual(accounting["missing_items"], [])
                self.assertEqual(accounting["contested_items"], [])
                self.assertEqual(accounting["unexpected_items"], [])
                self.assertEqual(accounting["complete_items"], requested if completes else [])

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
                # Neither line names its item as written, so both read as blocked;
                # which line each item is assigned is what this test is about.
                self.assertCountEqual(accounting["blocked_items"], requested)
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

    def test_an_available_swap_is_not_searched_for(self) -> None:
        # The assignment is deliberately not maximum. Both items could be
        # proved by moving the first onto the second entry, which it also
        # overlaps; the gate reports the second unproved instead. Failing here
        # costs the author one restated status line, and searching for the
        # swap cost an augmenting walk, a per-tier re-placement rule and a
        # candidate cap that changed nothing on any live or cross-product
        # pair in the repository.
        stem = "alpha bravo charlie delta echo foxtrot golf"
        items = [f"{stem} aa", f"{stem} bb"]
        entries = {
            f"{stem} aa bb": {"status": "complete", "detail": "one"},
            f"{stem} aa zz yy": {"status": "complete", "detail": "two"},
        }
        matched, contested = run_contributor._match_evidence_entries(items, entries)
        self.assertEqual(list(matched), [f"{stem} aa"])
        self.assertEqual(contested, [f"{stem} bb"])

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

    def test_two_entries_the_gate_cannot_tell_apart_are_malformed(self) -> None:
        # One entry answers one requirement, which needs both sides to be
        # distinguishable. Two entries normalizing to one key are two answers
        # the gate cannot choose between, and which one a requirement takes
        # decides its status -- here, whether a `pending-ci` lands on the
        # `diff` item, which does not block approval, or on the other one,
        # which does.
        requested = [
            "`Diff: alpha beta gamma delta echo foxtrot`",
            "alpha beta gamma delta echo foxtrot",
        ]
        body = (
            "## Evidence Status\n\n"
            "- [pending-ci] DIFF: ALPHA BETA GAMMA DELTA ECHO FOXTROT -- a\n"
            "- [complete] Diff: alpha beta gamma delta echo foxtrot. -- b\n"
        )
        accounting, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertEqual(len(accounting["indistinguishable_entries"]), 1)
        self.assertTrue(
            any(error.startswith("two Evidence Status entries read as the same item")
                for error in errors),
            errors,
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


class AttestedTestKindTests(unittest.TestCase):
    """Tests a person runs and reports, instead of an owner escalation.

    `_evidence_item_kind` recognised two runners, both Swift, so 74% of the
    real items written in this repo since 2026-08-24 landed in `other` --
    blocked at PR open, parked on the owner, cleared by hand afterwards.
    Michael's bar: "if not ui change or similar, then just stating the tests
    that ran and covered the feature, and/or anything done locally, can
    suffice."
    """

    RUNNERS = (
        "`pnpm test` in `web-next` passes",
        "cd web-next && pnpm test passes",
        "`bun test` passes",
        "`pytest` over the changed module passes",
        "`python3 -m pytest` (or the repo's runner) over `evidence.py`'s tests passes",
        "`uv run --script scripts/tests/test_factory_evidence_kinds.py` and every other "
        "`scripts/tests/*.py` pass",
    )
    STATEMENTS = (
        "A test in `scripts/tests/test_upload_evidence.py` that exercises a local-worker "
        "base URL, fails on `main`, and passes after",
        "A case in `web-next/scripts/evidence-core.test.mjs`, red before the change, "
        "asserting a server group that ignores SIGTERM is escalated on timeout",
        "A test asserting the EXIT trap does not convert a failing run into exit 0",
        "Every `scripts/tests/*.py` passes under `uv run --script`",
        "Named tests that ran: FooTests, BarTests, all green",
    )

    def test_runners_the_hosted_lane_cannot_execute_classify_as_attested(self) -> None:
        for item in self.RUNNERS:
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "test-attested")

    def test_named_test_statements_classify_as_attested(self) -> None:
        for item in self.STATEMENTS:
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "test-attested")

    def test_swift_test_stays_on_the_hosted_lane(self) -> None:
        self.assertEqual(
            run_contributor._evidence_item_kind("swift test --filter FooTests"), "test"
        )
        self.assertTrue(
            run_contributor._needs_macos_evidence(["swift test --filter FooTests"])
        )
        self.assertFalse(run_contributor._needs_macos_evidence(list(self.RUNNERS)))

    def test_judgement_calls_are_still_the_owner_s(self) -> None:
        # Each of these was `other` before and has to stay there: no test run
        # answers any of them.
        for item in (
            "Someone with taste confirms the copy reads well",
            "The PR body states the verdict, keep or remove, and the reasoning (owner-attested)",
            "A written audit of every exit path in `scripts/verify-release-bundle.sh`",
            "**A captured real restart, not a unit test.** `log stream` across a cold start",
            "A statement of whether the shared state is reachable from production code",
            "A case where the sidebar is scrolled away from the active row and the "
            "context is still readable.",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_a_capitalised_test_path_reads_the_same_as_a_lowercase_one(self) -> None:
        # `Tests/` is where the Swift ones live, and reading only the
        # lowercase spelling would undercount every one of them.
        self.assertEqual(
            run_contributor._evidence_item_kind(
                "Every `Tests/WorkspaceManagerTests/FooTests.swift` case passes"
            ),
            "test-attested",
        )

    def test_a_path_that_merely_contains_the_letters_is_not_a_test_path(self) -> None:
        self.assertEqual(
            run_contributor._evidence_item_kind("The `docs/latest.md` entry passes review"),
            "other",
        )

    def test_a_ci_check_name_is_not_a_test_path(self) -> None:
        # `build-and-test` is a check; `scripts/tests/*.py` is where tests
        # live. Reading the first as the second would send it down a lane that
        # polls no check and it would never complete.
        for item in ("CI `build-and-test` succeeds", "CI: `build-and-test` succeeds."):
            with self.subTest(item=item):
                self.assertNotEqual(
                    run_contributor._evidence_item_kind(item), "test-attested"
                )

    def test_an_owner_directive_still_outranks_the_widening(self) -> None:
        self.assertEqual(
            run_contributor._evidence_item_kind(
                "`pnpm test` in `web-next` passes (owner-attested)"
            ),
            "other",
        )

    def test_an_attested_contract_no_longer_blocks_at_open(self) -> None:
        self.assertFalse(run_contributor._has_unautomatable_evidence(list(self.RUNNERS)))
        self.assertFalse(
            run_contributor._has_unautomatable_evidence(list(self.STATEMENTS))
        )

    def test_the_open_prs_that_were_blocked_on_this_are_not_any_more(self) -> None:
        # #1578 and #1579 both carried `blocked:evidence` + `owner-action` on
        # exactly these two items.
        for item in (
            "`pnpm test` in `web-next` passes",
            "Every `scripts/tests/*.py` passes under `uv run --script`",
        ):
            with self.subTest(item=item):
                _, blocked, _ = run_contributor.synthesize_initial_execution_evidence(
                    [item]
                )
                self.assertEqual(blocked, [])

    def test_a_named_run_in_the_body_completes_the_item(self) -> None:
        body = (
            "## Summary\n\nFixed it.\n\n"
            "## Validation\n\n"
            "- `cd web-next && pnpm test` -> 214 tests passed\n"
        )
        complete, blocked, pending = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"], body=body
        )
        self.assertEqual((blocked, pending), ([], []))
        self.assertEqual(len(complete), 1)
        self.assertIn("214 tests passed", complete[0])

    def test_a_body_with_no_run_leaves_the_item_pending_not_blocked(self) -> None:
        complete, blocked, pending = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"], body="## Summary\n\nFixed it.\n"
        )
        self.assertEqual((complete, blocked), ([], []))
        self.assertIn("state the command and the line it printed", pending[0])

    def test_evidence_a_person_produces_is_still_the_owner_s(self) -> None:
        # A test noun does not make an item runnable. Each of these names
        # something someone does by hand, by eye, or by following a protocol.
        for item in (
            "A test protocol covering a manual production restart",
            "The `docs/test-plan.md` pass/fail protocol is followed manually",
            "A test suite run by hand against the installed build",
            "Someone runs the smoke tests and says whether it feels right",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_a_result_for_another_path_completes_nothing(self) -> None:
        # A path is specific. A pytest run of `test_bar.py` is not evidence
        # about `test_foo.py`, even though both are pytest.
        body = "## Validation\n\n- `pytest scripts/tests/test_bar.py` -> 12 passed\n"
        complete, _, pending = run_contributor.synthesize_initial_execution_evidence(
            ["`pytest` over `scripts/tests/test_foo.py` passes"], body=body
        )
        self.assertEqual(complete, [])
        self.assertEqual(len(pending), 1)

    def test_a_run_that_did_not_happen_completes_nothing(self) -> None:
        # "was not run" beside another runner's passing count read as a pass,
        # because the window crossed from one statement into the next.
        body = (
            "## Validation\n\n"
            "- `pnpm test` was not run in this environment\n"
            "- `pytest` -> 214 tests passed\n"
        )
        complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"], body=body
        )
        self.assertEqual(complete, [])

    def test_a_completed_attestation_says_who_attested_it(self) -> None:
        # The reviewer weighs "the lane ran it" against "the author says they
        # ran it". The line has to say which one this is.
        body = "## Validation\n\n- `cd web-next && pnpm test` -> 214 tests passed\n"
        complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"], body=body
        )
        self.assertIn("attested by the PR author, not run by the factory", complete[0])

    def test_a_statement_about_another_runner_completes_nothing(self) -> None:
        # Body-global matching let one `pnpm test` sentence complete a
        # `pytest` requirement sitting beside it, which evidences nothing.
        body = "## Validation\n\n- `cd web-next && pnpm test` -> 214 tests passed\n"
        complete, _, pending = run_contributor.synthesize_initial_execution_evidence(
            ["`pytest` over `scripts/tests/` passes"], body=body
        )
        self.assertEqual(complete, [])
        self.assertEqual(len(pending), 1)

    def test_a_statement_about_this_runner_completes_it(self) -> None:
        body = (
            "## Validation\n\n"
            "- `cd web-next && pnpm test` -> 214 tests passed\n"
            "- `uv run --script scripts/tests/test_foo.py` -> Ran 12 tests, OK\n"
        )
        complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
            ["`pytest` over `scripts/tests/test_foo.py` passes"], body=body
        )
        self.assertEqual(len(complete), 1)
        self.assertIn("test_foo.py", complete[0])

    def test_a_command_that_was_not_run_completes_nothing(self) -> None:
        # The guard read the command line only, so a "was not run" under the
        # command and a count under that was one statement to the window and
        # two to the guard. This is the shape that reached the contributor
        # gate after the readiness gate had already been fixed.
        for body in (
            "`pnpm test`\nwas not run in this environment\nThe suite has 214 tests passed\n",
            "We will run `pnpm test` after review\nThe suite has 214 tests passed\n",
            "`pnpm test`\nskipped on this runner\n214 tests passed elsewhere\n",
        ):
            with self.subTest(body=body):
                self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_a_label_beside_a_path_is_not_an_alternative(self) -> None:
        # An item naming both a test path and the runner it runs on is about
        # the path; offering the label let an unrelated run complete the item
        # by mentioning `macos-26`.
        _, paths = run_contributor._item_evidence_tokens(
            "A test in `scripts/tests/test_foo.py` on `macos-26` passes"
        )
        self.assertEqual(paths, ["scripts/tests/test_foo.py"])
        self.assertIsNone(
            run_contributor._attested_test_statement(
                "- `pytest scripts/tests/test_bar.py` on macos-26 -> 12 passed\n",
                "A test in `scripts/tests/test_foo.py` on `macos-26` passes",
            )
        )

    def test_a_bare_label_still_binds_where_it_is_all_there_is(self) -> None:
        _, paths = run_contributor._item_evidence_tokens(
            "`pnpm test` in `web-next` passes"
        )
        self.assertIn("web-next", paths)

    def test_a_nonzero_exit_is_not_a_pass(self) -> None:
        for body in (
            "- `pytest` -> Ran 12 tests; Process completed with exit code 1\n",
            "- `pnpm test` -> 12 tests passed; exit status 1\n",
            "- `swift test` -> ran, exit code 2\n",
            "- `pytest` -> Ran 12 tests; Process completed with exit code 127\n",
            "- `pnpm test` -> 12 tests passed; process exited with status 127\n",
            "- `pnpm test` -> 12 tests passed; exited with status 1\n",
            "- `swift test` -> 12 tests passed; status: ERROR\n",
        ):
            with self.subTest(body=body):
                self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_a_negation_cannot_swallow_a_real_failure(self) -> None:
        # "no failures but errors=2" was matched whole by the negation
        # remover, leaving "=2" and reading a red run as clean.
        for body in (
            "- `pytest` -> Ran 12 tests, no failures but errors=2\n",
            "- `pytest` -> 0 tests failed\n",
            "- `pytest` -> no warnings but 3 errors\n",
        ):
            with self.subTest(body=body):
                self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_an_ordinary_passing_report_is_not_read_as_a_failure(self) -> None:
        self.assertIsNotNone(
            run_contributor._attested_test_statement(
                "- `pnpm test` -> 12 tests passed, covering error handling\n"
            )
        )

    def test_a_failed_run_is_not_a_pass(self) -> None:
        # "Ran 12 tests" carries a count and a test noun. Read without the
        # line under it, a red run completed the item and the quote showed
        # only the first half.
        for body in (
            "- `pnpm test`\n  Ran 12 tests\n  FAILED (failures=2)\n",
            "- `pnpm test` -> 12 tests failed\n",
            "- `pytest` -> collected 0 items\n",
            "- `pnpm test` -> 3 tests passed, 2 errored\n",
        ):
            with self.subTest(body=body):
                self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_a_pass_reported_as_an_absence_is_still_a_pass(self) -> None:
        # A failure guard spelled with a bare `errors?` swallows the pass
        # phrasings that name what did not happen.
        self.assertIsNotNone(
            run_contributor._attested_test_statement(
                "- `pnpm test` -> 214 tests passed, no lint errors\n"
            )
        )

    def test_a_mechanical_item_naming_an_environment_is_not_external(self) -> None:
        # The environment word alone is not enough; it has to be somewhere
        # someone goes and does something.
        for item in (
            "Unit coverage for the production configuration loader",
            "Release notes mention the live-migration flag",
            "A test asserting the staging URL is rejected",
        ):
            with self.subTest(item=item):
                self.assertFalse(run_contributor._needs_a_person_to_look(item))

    def test_a_docs_item_naming_a_release_is_not_external_verification(self) -> None:
        self.assertFalse(
            run_contributor._needs_a_person_to_look(
                "Verify the release notes mention the new flag"
            )
        )
        self.assertTrue(
            run_contributor._needs_a_person_to_look(
                "Verify the live endpoint returns the new field"
            )
        )

    def test_a_neighbouring_path_is_not_this_path(self) -> None:
        # Substring matching made `web-next` answer an item about `web`, and
        # `not_test_foo.py` answer one about `test_foo.py`.
        for item, body in (
            (
                "`pnpm test` in `web` passes",
                "- `cd web-next && pnpm test` -> 214 tests passed\n",
            ),
            (
                "`pnpm test` in `web-next` passes",
                "- `cd web-next-old && pnpm test` -> 214 tests passed\n",
            ),
            (
                "`pytest` over `scripts/tests/test_foo.py` passes",
                "- `pytest scripts/tests/not_test_foo.py` -> 12 passed\n",
            ),
        ):
            with self.subTest(item=item):
                complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
                    [item], body=body
                )
                self.assertEqual(complete, [])

    def test_a_bare_directory_binds_the_statement(self) -> None:
        complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"],
            body="- `cd web-next && pnpm test` -> 214 tests passed\n",
        )
        self.assertEqual(len(complete), 1)

    def test_a_run_in_another_directory_completes_nothing(self) -> None:
        # `web-next` is what tells a `pnpm test` there apart from one in
        # `web`, and dropping a directory-only span made them one claim.
        body = "## Validation\n\n- `cd web && pnpm test` -> 214 tests passed\n"
        complete, _, _ = run_contributor.synthesize_initial_execution_evidence(
            ["`pnpm test` in `web-next` passes"], body=body
        )
        self.assertEqual(complete, [])

    def test_a_conditional_is_not_a_result(self) -> None:
        # "if all tests pass, merge" says nothing ran. Every accepted result
        # carries a count, because a runner that ran printed one.
        for body in (
            "Run `pnpm test`; if all tests pass, merge.",
            "`pnpm test` should be green before merge.",
            "All tests pass with `pnpm test`.",
        ):
            with self.subTest(body=body):
                self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_a_command_without_a_result_is_not_a_statement(self) -> None:
        # A command with no result is a plan. Completing on it would make the
        # bar "say you will run tests".
        self.assertIsNone(
            run_contributor._attested_test_statement("Run `pnpm test` before merging.")
        )
        self.assertIsNone(
            run_contributor._attested_test_statement("Everything is green.")
        )

    def test_a_statement_stops_at_the_next_heading(self) -> None:
        body = (
            "## Validation\n\n- ran `pnpm test`\n\n"
            "## Performance\n\n- Before Summary: 214 ms passed\n"
        )
        self.assertIsNone(run_contributor._attested_test_statement(body))

    def test_the_macos_lane_leaves_attested_items_alone(self) -> None:
        item = "`pnpm test` in `web-next` passes"
        body = (
            "## Evidence Status\n"
            f"- [pending-ci] {item} -- waiting on the author's run\n"
        )
        self.assertEqual(
            run_contributor.reconcile_pending_ci_evidence(
                body,
                requested_evidence=[item],
                build_succeeded=True,
                tests_succeeded=True,
                smoke_succeeded=True,
            ),
            body,
        )


class PerfEvidenceKindTests(unittest.TestCase):
    """Numbers are evidence. The classifier had no kind for them."""

    ITEMS = (
        "Before/after measurements on the same workload",
        "Before and after perf numbers from `scripts/perf-runner.sh`, same workload",
        "p50 launch latency before and after, canonical scenario `debug_no_activate`",
        "Main thread measured at or below 5% of one core; before/after/delta recorded",
    )

    def test_before_after_measurement_phrasing_classifies_as_perf(self) -> None:
        for item in self.ITEMS:
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "perf")

    def test_a_perf_contract_no_longer_blocks_at_open(self) -> None:
        self.assertFalse(run_contributor._has_unautomatable_evidence(list(self.ITEMS)))

    def test_numbers_in_the_performance_section_complete_the_item(self) -> None:
        body = (
            "## Summary\n\nFaster.\n\n"
            "## Performance\n\n"
            "- Scenario ID: debug_no_activate\n"
            "- Before Summary: p50 1.31s\n"
            "- After Summary: p50 1.02s\n"
            "- Delta Summary: -0.29s\n"
        )
        complete, blocked, pending = run_contributor.synthesize_initial_execution_evidence(
            [self.ITEMS[0]], body=body
        )
        self.assertEqual((blocked, pending), ([], []))
        self.assertIn("p50 1.31s", complete[0])
        self.assertIn("p50 1.02s", complete[0])

    def test_one_side_of_a_comparison_measures_nothing(self) -> None:
        body = "## Performance\n\n- Before Summary: p50 1.31s\n- After Summary:\n"
        complete, _, pending = run_contributor.synthesize_initial_execution_evidence(
            [self.ITEMS[0]], body=body
        )
        self.assertEqual(complete, [])
        self.assertIn("Performance section", pending[0])

    def test_an_unfilled_template_section_completes_nothing(self) -> None:
        body = (
            "## Performance\n\n"
            "- [ ] Not a performance-sensitive change\n"
            "- Scenario ID:\n- Before Summary:\n- After Summary:\n- Delta Summary:\n"
        )
        self.assertIsNone(run_contributor._perf_numbers(body))

    def test_a_section_measuring_something_else_completes_nothing(self) -> None:
        # A launch-latency contract is not answered by a section that
        # measured setup, and one Performance section is not four different
        # measurements.
        body = (
            "## Performance\n\n"
            "- Before Summary: setup took 2.0s\n- After Summary: setup took 1.0s\n"
        )
        self.assertIsNone(
            run_contributor._perf_numbers(
                body, "p50 launch latency before and after, same workload"
            )
        )

    def test_a_section_measuring_the_named_metric_completes_it(self) -> None:
        body = (
            "## Performance\n\n"
            "- Before Summary: p50 launch 1.31s\n- After Summary: p50 launch 1.02s\n"
        )
        self.assertIsNotNone(
            run_contributor._perf_numbers(
                body, "p50 launch latency before and after, same workload"
            )
        )

    def test_the_two_sides_have_to_measure_the_same_thing(self) -> None:
        body = (
            "## Performance\n\n- Before Summary: launch 1s\n- After Summary: memory 4GB\n"
        )
        self.assertIsNone(
            run_contributor._perf_numbers(body, "launch latency before and after")
        )

    def test_a_percentile_alone_is_not_the_same_measurement(self) -> None:
        # `p50 setup` shares only the percentile with `p50 launch latency`.
        body = (
            "## Performance\n\n- Before Summary: p50 setup 2.0s\n"
            "- After Summary: p50 setup 1.0s\n"
        )
        self.assertIsNone(
            run_contributor._perf_numbers(body, "p50 launch latency before and after")
        )

    def test_the_perf_producers_own_output_completes_a_perf_item(self) -> None:
        # `scripts/pr-evidence.sh` writes this shape. It wrote JSON paths into
        # both fields before, so the producer could not satisfy the parser.
        body = (
            "## Performance\n\n"
            "- Scenario ID: `debug_no_activate`\n"
            "- Before Summary: p50_launch_ms 1310.00 ms\n"
            "- After Summary: p50_launch_ms 1020.00 ms\n"
            "- Delta Summary: -290 ms (-22.1%)\n"
        )
        self.assertIsNotNone(
            run_contributor._perf_numbers(
                body, "p50 launch latency before and after on the same workload"
            )
        )

    def test_a_metric_named_only_in_the_heading_completes_nothing(self) -> None:
        # A section mentioning the metric somewhere, over values that measured
        # something else, is not an answer.
        body = (
            "## Performance\n\nlaunch latency work\n\n"
            "- Before Summary: setup 10s, memory 4GB\n"
            "- After Summary: deploy 20ms, memory 3GB\n"
        )
        self.assertIsNone(
            run_contributor._perf_numbers(body, "launch latency before and after")
        )

    def test_a_shared_unit_on_an_unrelated_measurement_is_not_a_comparison(self) -> None:
        body = (
            "## Performance\n\n"
            "- Before Summary: launch 1s, memory 4GB\n"
            "- After Summary: deploy 20ms, memory 3GB\n"
        )
        self.assertIsNone(
            run_contributor._perf_numbers(body, "launch latency before and after")
        )

    def test_a_number_without_a_unit_measures_nothing(self) -> None:
        # "Before Summary: issue #123" carries a digit and measures nothing;
        # a unit is what makes the two sides comparable.
        body = (
            "## Performance\n\n"
            "- Before Summary: issue #123\n- After Summary: issue #124\n"
        )
        self.assertIsNone(run_contributor._perf_numbers(body))

    def test_evidence_judged_by_eye_is_not_a_perf_item(self) -> None:
        self.assertEqual(
            run_contributor._evidence_item_kind(
                "Performance comparison of animation smoothness judged by eye"
            ),
            "other",
        )

    def test_a_word_count_before_and_after_is_not_a_perf_item(self) -> None:
        # It is a diff you can read, and routing it through the Performance
        # section would leave it pending on a section it never wanted.
        self.assertNotEqual(
            run_contributor._evidence_item_kind(
                "Word count of root `AGENTS.md` before and after, both numbers in the PR body"
            ),
            "perf",
        )


class RenderedStatementTests(unittest.TestCase):
    """A statement of what ran, and a measurement, count only where a reader can see them.

    `_attested_test_statement` and `_perf_numbers` read the raw body, so a
    command and its count written inside an HTML comment completed an item
    while GitHub showed nothing, and the writer -- which calls the same two
    functions -- recorded that invisible completion as the PR's answer (#1709).
    Both read rendered text now (`_rendered_lines`), and the pair is tested
    together: a body the reader refuses is one the writer records nothing for.

    Code renders, so a fenced block still counts. That is not a concession:
    `pr-evidence.sh` writes `perf-compare.py`'s comparison lines inside a
    fence, and those lines are the numbers.
    """

    TEST_ITEM = "`pnpm test` in `web-next` passes"
    PERF_ITEM = "p50 launch latency before and after on the same workload"

    VISIBLE_TEST = "## Validation\n\n- `cd web-next && pnpm test` -> 214 tests passed\n"
    HIDDEN_TEST = "## Validation\n\n<!-- `cd web-next && pnpm test` -> 214 tests passed -->\n"
    INLINE_HIDDEN_TEST = "## Validation\n\n- `cd web-next && pnpm test` <!-- 214 tests passed -->\n"
    FENCED_TEST = "## Validation\n\n```\ncd web-next && pnpm test -> 214 tests passed\n```\n"
    VISIBLE_PERF = (
        "## Performance\n\n"
        "- Before Summary: p50 launch 1.31s\n"
        "- After Summary: p50 launch 1.02s\n"
    )
    HIDDEN_PERF = (
        "## Performance\n\n<!--\n"
        "- Before Summary: p50 launch 1.31s\n"
        "- After Summary: p50 launch 1.02s\n-->\n"
    )
    FENCED_PERF = (
        "## Performance\n\n"
        "- Scenario ID: `debug_no_activate`\n\n"
        "Every metric:\n\n"
        "```\n- p50_launch_ms: 1310.00 -> 1020.00; -290.00 ms (-22.1%)\n```\n"
    )

    def test_a_statement_only_in_a_comment_is_not_a_statement(self) -> None:
        self.assertIsNone(
            run_contributor._attested_test_statement(self.HIDDEN_TEST, self.TEST_ITEM)
        )
        # Also with no item, the reading that took the comment's own text as
        # the quoted proof.
        self.assertIsNone(run_contributor._attested_test_statement(self.HIDDEN_TEST))

    def test_a_count_inside_an_inline_comment_is_not_a_result(self) -> None:
        # The command renders and the count does not, which is a plan.
        self.assertIsNone(
            run_contributor._attested_test_statement(
                self.INLINE_HIDDEN_TEST, self.TEST_ITEM
            )
        )

    def test_numbers_only_in_a_comment_measure_nothing(self) -> None:
        self.assertIsNone(
            run_contributor._perf_numbers(self.HIDDEN_PERF, self.PERF_ITEM)
        )
        self.assertIsNone(run_contributor._perf_numbers(self.HIDDEN_PERF))

    def test_the_visible_forms_still_complete(self) -> None:
        self.assertIsNotNone(
            run_contributor._attested_test_statement(self.VISIBLE_TEST, self.TEST_ITEM)
        )
        self.assertIsNotNone(
            run_contributor._perf_numbers(self.VISIBLE_PERF, self.PERF_ITEM)
        )

    def test_the_producers_own_fenced_output_still_completes(self) -> None:
        # `pr-evidence.sh` pastes the comparison block into the section; the
        # bullet the parser matches is inside the fence.
        self.assertIsNotNone(
            run_contributor._perf_numbers(self.FENCED_PERF, self.PERF_ITEM)
        )
        self.assertIsNotNone(
            run_contributor._attested_test_statement(self.FENCED_TEST, self.TEST_ITEM)
        )

    def test_the_rendered_read_keeps_the_structure_the_readers_read(self) -> None:
        # A heading ends a statement, a comparison line starts with a bullet,
        # and a block sits a blank line from its neighbour -- so the read has
        # to give those back, not one flattened string.
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(
                "Intro <!-- hidden -->\n\n## Validation\n\n"
                "- `pnpm test` -> 12 tests passed\n- second\n\n"
                "```\nraw line\n```\n\n<!-- a block comment -->\n\n"
                "## Performance\n\n1. one\n2. two\n"
            ),
            [
                "Intro",
                "",
                "## Validation",
                "",
                "- `pnpm test` -> 12 tests passed",
                "- second",
                "",
                "raw line",
                "",
                "## Performance",
                "",
                "1. one",
                "2. two",
            ],
        )

    def test_one_section_is_read_where_a_section_is_asked_for(self) -> None:
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(self.VISIBLE_PERF, "Performance"),
            ["- Before Summary: p50 launch 1.31s", "- After Summary: p50 launch 1.02s"],
        )
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(self.VISIBLE_PERF, "Validation"), []
        )

    def test_bullets_written_one_under_the_next_stay_one_under_the_next(self) -> None:
        # A blank line anywhere in a list makes the whole list loose, and
        # CommonMark says nothing about where the source put its blank lines.
        # Rebuilding the gaps from a looseness rule pushed three adjacent
        # bullets apart, and the window that carries a result up to the run
        # above it then stopped one line short of the result. The gaps come
        # from the source map instead.
        body = (
            "## Validation\n\n"
            "- `uv run --script scripts/tests/test_foo.py` -> OK (exit 0)\n"
            "- `python3 scripts/check.py` -> OK\n"
            "- Scripts loop: Ran 55 tests, OK\n\n"
            "- a later bullet, after a blank line, is what makes this list loose\n"
        )
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(body),
            [
                "## Validation",
                "",
                "- `uv run --script scripts/tests/test_foo.py` -> OK (exit 0)",
                "- `python3 scripts/check.py` -> OK",
                "- Scripts loop: Ran 55 tests, OK",
                "",
                "- a later bullet, after a blank line, is what makes this list loose",
            ],
        )
        self.assertIsNotNone(
            run_contributor._attested_test_statement(
                body, "`pytest` over `scripts/tests/test_foo.py` passes"
            )
        )

    def test_a_result_only_the_rendered_view_can_read_is_refused_on_purpose(self) -> None:
        # `**1017 / 1017** passed` is a passing run to a reader, and the
        # rendered view reads it: the markup that sat between the count and the
        # word is gone. The written view does not, and the rule is that both
        # have to accept -- so this refuses. Buying it would mean accepting
        # every other reading the rendered view has on its own, and those are
        # the window overreaches `MonotoneStatementReadTests` covers. One real
        # body in the repository has this shape, and it lists no requested
        # evidence at all, so nothing of its was ever decided here.
        body = "## Validation\n\n- `swift test` — **1017 / 1017** passed, 161 suites\n"
        self.assertIsNotNone(
            sys.modules["evidence"]._attested_statement_in(
                sys.modules["evidence"]._rendered_lines(body), ["swift test"]
            )
        )
        self.assertIsNone(
            run_contributor._attested_test_statement(body, "`swift test` passes")
        )

    def test_the_reader_and_the_writer_agree(self) -> None:
        # One table over both, because the bug was that they agreed with each
        # other and disagreed with the page. Each item is written plainly, so
        # the kind the writer reads from the item and the kind the reader
        # decides from it are the same kind; where they are not, the two
        # callers are asking different questions (`_hand_completion_kind`).
        cases = (
            ("a visible statement", self.TEST_ITEM, self.VISIBLE_TEST, True),
            ("a statement in a comment", self.TEST_ITEM, self.HIDDEN_TEST, False),
            ("a count in an inline comment", self.TEST_ITEM, self.INLINE_HIDDEN_TEST, False),
            ("a statement in a fence", self.TEST_ITEM, self.FENCED_TEST, True),
            ("visible measurements", self.PERF_ITEM, self.VISIBLE_PERF, True),
            ("measurements in a comment", self.PERF_ITEM, self.HIDDEN_PERF, False),
            ("the producer's fenced block", self.PERF_ITEM, self.FENCED_PERF, True),
            ("nothing at all", self.TEST_ITEM, "", False),
            ("nothing at all", self.PERF_ITEM, "", False),
        )
        for name, item, body, completes in cases:
            with self.subTest(case=name, item=item):
                kind, _ = sys.modules["evidence"]._hand_completion_kind(item)
                read = sys.modules["evidence"]._proof_form_completion(body, item, kind)
                written, _, pending = run_contributor.synthesize_initial_execution_evidence(
                    [item], body=body
                )
                self.assertEqual(bool(read), completes)
                self.assertEqual(bool(written), completes)
                self.assertEqual(bool(pending), not completes)

    def test_the_gate_refuses_a_completion_nobody_can_see(self) -> None:
        # Through `evaluate_evidence_accounting`, whose own first statement
        # only normalises line endings -- so the CRLF copy reaches the same
        # read rather than being turned aside before it.
        for item, body in (
            (self.TEST_ITEM, self.HIDDEN_TEST),
            (self.PERF_ITEM, self.HIDDEN_PERF),
        ):
            section = f"## Evidence Status\n\n- [complete] {item} -- stated in this body\n\n"
            for endings, rewrite in (("lf", str), ("crlf", lambda text: text.replace("\n", "\r\n"))):
                with self.subTest(item=item, endings=endings):
                    accounting = run_contributor.evaluate_evidence_accounting(
                        rewrite(section + body), [item]
                    )
                    self.assertEqual(accounting["complete_items"], [])
                    self.assertEqual(accounting["pending_ci_items"], [item])

    def test_the_gate_still_completes_the_visible_statement(self) -> None:
        for item, body in (
            (self.TEST_ITEM, self.VISIBLE_TEST),
            (self.PERF_ITEM, self.VISIBLE_PERF),
        ):
            with self.subTest(item=item):
                accounting = run_contributor.evaluate_evidence_accounting(
                    f"## Evidence Status\n\n- [complete] {item} -- stated in this body\n\n{body}",
                    [item],
                )
                self.assertEqual(accounting["complete_items"], [item])


class MonotoneStatementReadTests(unittest.TestCase):
    """Rendering the body gives a block fewer lines than it occupies, and the scan counts lines.

    `_attested_test_statement` scans forward a fixed number of lines from a
    runner mention to bind a result to the run named above it. An HTML block
    collapses to nothing, a fence loses its markers, and a run of blank lines
    collapses to one -- so on the rendered view alone the window reaches across
    material it could not cross before and lands on a result the statement does
    not own. `_perf_numbers` has the matching problem from the other side:
    `PERF_FIELD_RE` and `PERF_COMPARISON_RE` were shaped against written lines,
    and stripping markup hands them lines they were never shaped to see.

    Both readers now accept only where the written view and the rendered view
    both accept, and quote the rendered one. That makes this change able to
    tighten and unable to loosen, whatever the next such shape turns out to be,
    instead of asking anyone to enumerate them.
    """

    ITEM = "`pnpm test` in `web-next` passes"
    PERF_ITEM = "p50 launch latency before and after"

    def _raw_read(self, body: str, item: str = "") -> str | None:
        """The written-view read, which is the read this file had before the rendered one."""
        evidence = sys.modules["evidence"]
        runners, paths = evidence._item_evidence_tokens(item) if item else ([], [])
        return evidence._attested_statement_in(
            evidence.MARKDOWN_LINE_ENDING_RE.split(body), paths or runners
        )

    def test_a_gap_in_the_source_is_not_a_line_the_window_may_cross(self) -> None:
        # No HTML and no fence: three blank lines between a command and a
        # count. The rendered view collapses them to one, and the window then
        # binds a count written four lines away from the run.
        body = (
            "## Validation\n\n"
            "- `cd web-next && pnpm test` at this head.\n\n\n\n"
            "- 12 tests passed\n"
        )
        self.assertIsNone(self._raw_read(body, self.ITEM))
        self.assertIsNone(run_contributor._attested_test_statement(body, self.ITEM))

    def test_a_count_the_body_attributes_to_main_does_not_complete_the_item(self) -> None:
        # The factory's own metadata comment sat between the command and the
        # sentence about `main`. It renders as nothing, so the window closed
        # the gap and credited this head with main's count.
        body = (
            "## Validation\n\n"
            "- `cd web-next && pnpm test` at this head.\n\n"
            '<!-- evidence-status:v1\n{"entries": {}}\n-->\n\n'
            "For context, `main` currently reports 2004 tests passed.\n"
        )
        self.assertIsNone(self._raw_read(body, self.ITEM))
        complete, _, pending = run_contributor.synthesize_initial_execution_evidence(
            [self.ITEM], body=body
        )
        self.assertEqual(complete, [])
        self.assertEqual(len(pending), 1)

    def test_a_fence_holding_another_commands_output_does_not_complete_this_one(self) -> None:
        body = (
            "## Validation\n\n"
            "`cd web-next && pnpm test` covers the new parser.\n\n"
            "```\n$ bash scripts/other.sh\n14 tests passed\n```\n"
        )
        self.assertIsNone(self._raw_read(body, self.ITEM))
        self.assertIsNone(run_contributor._attested_test_statement(body, self.ITEM))

    def test_a_grammar_the_written_lines_never_carried_is_not_a_measurement(self) -> None:
        # Each of these measures nothing to the reader that has always read
        # this section, and became a completed comparison once markup was
        # stripped from the line before the pattern saw it.
        for name, body in (
            (
                "bold labels",
                "## Performance\n\n**Before**: p50 launch latency 120 ms\n\n"
                "**After**: p50 launch latency 100 ms\n",
            ),
            (
                "table cells",
                "## Performance\n\n| Measurement |\n| --- |\n"
                "| Before Summary: p50 launch latency 120 ms |\n"
                "| After Summary: p50 launch latency 100 ms |\n",
            ),
            (
                "a plus bullet",
                "## Performance\n\n+ p50 launch latency: 120 ms -> 100 ms; -20 ms\n",
            ),
            (
                "another PR's numbers, quoted",
                "## Performance\n\nNot measured on this head yet.\n\n"
                "> Quoting an older PR for context:\n>\n"
                "> - Before Summary: p50 launch latency 900 ms\n"
                "> - After Summary: p50 launch latency 410 ms\n",
            ),
        ):
            with self.subTest(case=name):
                self.assertIsNone(run_contributor._perf_numbers(body, self.PERF_ITEM))

    def test_the_section_ends_where_the_written_read_ends_it(self) -> None:
        # One boundary for both reads, which is what makes an item complete or
        # not for a single reason. An h1 ends a section for both of them, the
        # way the page ends one there (#1734); `***` and `___` end one for
        # neither, and a `---` rule ends one for both.
        fields = (
            "- Before Summary: p50 launch latency 900 ms\n\n{divider}\n\n"
            "- After Summary: p50 launch latency 410 ms\n"
        )
        for divider, still_reads in (("# Aside", False), ("***", True), ("___", True), ("---", False)):
            body = "## Performance\n\n" + fields.format(divider=divider)
            with self.subTest(divider=divider):
                read = run_contributor._perf_numbers(body, self.PERF_ITEM)
                self.assertEqual(read is not None, still_reads)
                self.assertEqual(read is not None, self._perf_raw_reads(body))

    def _perf_raw_reads(self, body: str) -> bool:
        evidence = sys.modules["evidence"]
        wanted = {m.group(0).casefold() for m in evidence.PERF_METRIC_RE.finditer(self.PERF_ITEM)}
        written = evidence.MARKDOWN_LINE_ENDING_RE.split(
            evidence.markdown_section(body, "Performance")
        )
        return evidence._perf_numbers_in(written, wanted, set()) is not None

    def test_no_statement_case_in_this_file_reads_where_the_written_view_does_not(self) -> None:
        # The property, over the file's own fixtures: every string literal here
        # that names a test runner is a body someone wrote to exercise this
        # reader, and none of them may complete on the rendered view alone.
        source = Path(__file__).read_text(encoding="utf-8")
        bodies = {
            node.value
            for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and sys.modules["evidence"].TEST_RUNNER_MENTION_RE.search(node.value)
        }
        self.assertGreater(len(bodies), 20)
        for body in sorted(bodies):
            for item in ("", self.ITEM, "`swift test` passes"):
                if run_contributor._attested_test_statement(body, item) is None:
                    continue
                with self.subTest(body=body[:60], item=item):
                    self.assertIsNotNone(self._raw_read(body, item))


class RenderedViewIsWrongAboutThePageTests(unittest.TestCase):
    """Two places the rendered view showed less than the page does.

    Both refuse where the page reads, so the monotone rule cannot reach them:
    it only stops the rendered view from accepting more than the written one.
    """

    ITEM = "`pnpm test` in `web-next` passes"

    def test_a_break_tag_is_a_break_and_not_an_erasure(self) -> None:
        # `<br>` arrives as inline HTML and was dropped with the rest, gluing
        # the words on either side: `1<br>2 tests passed` became `12 tests
        # passed`, a count nobody wrote, quoted into a line a reviewer reads as
        # the author's own attestation.
        body = (
            "## Validation\n\n"
            "- `cd web-next && pnpm test` ran. Shards: 1<br>2 tests passed\n"
        )
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(body),
            [
                "## Validation",
                "",
                "- `cd web-next && pnpm test` ran. Shards: 1",
                "  2 tests passed",
            ],
        )
        read = run_contributor._attested_test_statement(body, self.ITEM)
        self.assertIsNotNone(read)
        self.assertNotIn("12", read)

    def test_every_other_inline_tag_still_contributes_nothing(self) -> None:
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines("<span>a</span>b<em>c</em>\n"),
            ["abc"],
        )

    def test_text_beside_a_closed_comment_is_text_a_reader_sees(self) -> None:
        # An HTML block runs to a blank line and carries whatever shares its
        # lines. GitHub hides the comment and prints the rest; the read
        # returned no lines at all and the statement vanished.
        body = "## Validation\n\n<!-- note --> ran `cd web-next && pnpm test`: 12 tests passed\n"
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(body),
            ["## Validation", "", "ran `cd web-next && pnpm test`: 12 tests passed"],
        )
        self.assertIsNotNone(run_contributor._attested_test_statement(body, self.ITEM))

    def test_a_block_that_is_not_a_closed_comment_stays_nothing(self) -> None:
        # Which elements are still open is a second renderer, and the one this
        # file had disagreed with GitHub.
        for name, block in (
            ("an unclosed comment", "<!-- open ran `cd web-next && pnpm test`: 12 tests passed"),
            ("a wrapper element", "<div>ran `cd web-next && pnpm test`: 12 tests passed</div>"),
        ):
            with self.subTest(case=name):
                body = f"## Validation\n\n{block}\n"
                self.assertEqual(
                    sys.modules["evidence"]._rendered_lines(body), ["## Validation"]
                )
                self.assertIsNone(
                    run_contributor._attested_test_statement(body, self.ITEM)
                )

    def test_the_factorys_own_metadata_comment_still_shows_nothing(self) -> None:
        body = '## Validation\n\n<!-- evidence-status:v1\n{"entries": {}}\n-->\n'
        self.assertEqual(
            sys.modules["evidence"]._rendered_lines(body), ["## Validation"]
        )


class CompleteDetailTests(unittest.TestCase):
    """The accounting layer read the status word and never the words after it.

    `- [complete] <item> -- done` and an image link closed a test item just as
    well as a result line did. It was strict about form and silent about
    proof, which is the inversion this closes.
    """

    ITEM = "`swift test --filter FooTests` passes"
    SCREENSHOT = "Screenshots of the new sidebar"

    def errors_for(self, item: str, detail: str) -> list[str]:
        # The completion is the metadata's, where a lane writes one: a body with
        # no metadata never reads a lane item as complete, which would leave the
        # proof rule nothing to judge.
        payload = json.dumps(
            {"entries": [{"index": 1, "item": item, "status": "complete", "detail": detail, "kind": run_contributor._evidence_item_kind(item)}]}
        )
        body = f"<!-- evidence-status:v1\n{payload}\n-->\n\n## Evidence Status\n- [complete] {item} -- {detail}\n"
        _, errors = run_contributor.validate_evidence_accounting(body, [item])
        return errors

    def test_a_one_word_detail_proves_nothing(self) -> None:
        for detail in ("done", "proof", "yes", "."):
            with self.subTest(detail=detail):
                errors = self.errors_for(self.ITEM, detail)
                self.assertTrue(
                    any("proves nothing" in error for error in errors), errors
                )

    def test_an_image_alone_does_not_close_a_test_item(self) -> None:
        # The reward hack, stated as a rule: a picture of a test summary is
        # not a test summary.
        errors = self.errors_for(
            self.ITEM,
            "![tests](https://evidence.cloudcompute.com/workspaces/pr-1/tests.svg)",
        )
        self.assertTrue(any("image of text" in error for error in errors), errors)

    def test_an_image_does_close_a_screenshot_item(self) -> None:
        errors = self.errors_for(
            self.SCREENSHOT,
            "![sidebar](https://evidence.cloudcompute.com/workspaces/pr-1/sidebar.png)",
        )
        self.assertEqual([e for e in errors if "proves nothing" in e], [])

    def test_a_crafted_detail_does_not_hang_the_gate(self) -> None:
        # The detail is PR-controlled text. The obvious spelling of "one
        # image plus padding, repeated" nests a quantifier in a quantifier,
        # and this input backtracked exponentially against it.
        hostile = "![" * 400 + "](http://(" * 400
        start = time.monotonic()
        self.errors_for(self.ITEM, hostile)
        self.assertLess(time.monotonic() - start, 1.0)

    def test_every_way_a_picture_reaches_a_body_is_read_as_one(self) -> None:
        # One lowercase inline form was the only shape recognised, so an
        # uppercase scheme, an autolink, a reference image, an HTML tag or a
        # bare image URL each closed a test item on their own.
        for detail in (
            "![tests](https://evidence.cloudcompute.com/pr-1/tests.svg)",
            "![tests](HTTPS://evidence.cloudcompute.com/pr-1/tests.PNG)",
            "<https://evidence.cloudcompute.com/pr-1/tests.png>",
            "![tests][store]",
            '<img src="https://evidence.cloudcompute.com/pr-1/tests.png">',
            "https://evidence.cloudcompute.com/pr-1/tests.svg",
        ):
            with self.subTest(detail=detail):
                errors = self.errors_for(self.ITEM, detail)
                self.assertTrue(
                    any("image of text" in error for error in errors), errors
                )

    def test_a_sentence_without_spaces_is_not_one_word(self) -> None:
        # "One word" is not a count in every script. A Japanese sentence
        # written without spaces is one `\w+` run and a real answer.
        errors = self.errors_for(self.ITEM, "\u5168\u30c6\u30b9\u30c8\u304c\u6210\u529f\u3057\u307e\u3057\u305f")
        self.assertEqual([e for e in errors if "proves nothing" in e], [])

    def test_a_result_word_a_runner_prints_is_a_result(self) -> None:
        for detail in ("PASS", "OK", "green"):
            with self.subTest(detail=detail):
                errors = self.errors_for(self.ITEM, detail)
                self.assertEqual([e for e in errors if "proves nothing" in e], [])

    def test_a_hand_edit_does_not_clear_the_gate_by_itself(self) -> None:
        # On an item the factory completes, reading a visible edit straight
        # into the accounting is an authorization hole: text differing from
        # the metadata is a signal any PR author or bot with write access can
        # produce, so it would clear an item the lane refused. The gesture is
        # honoured where provenance is known -- the next factory turn carries
        # a published line forward. Only an owner's own item reads the line at
        # once (`OwnerKindHandEditTests`).
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1,
                        "item": self.ITEM,
                        "status": "pending-ci",
                        "detail": "waiting on the author's run",
                        "kind": "test-attested",
                    }
                ]
            },
            indent=2,
        )
        body = (
            "## Summary\n\nA change.\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            "## Evidence Status\n"
            f"- [complete] {self.ITEM} -- I ran it: 214 tests passed\n"
        )
        accounting = run_contributor.evaluate_evidence_accounting(body, [self.ITEM])
        self.assertEqual(accounting["complete_items"], [])
        self.assertEqual(accounting["pending_ci_items"], [self.ITEM])

    def test_a_host_lookalike_is_not_our_evidence_store(self) -> None:
        # `https://evil.example/evidence.cloudcompute.com/x.png` is not an
        # upload of ours, and a substring test said it was.
        errors = self.errors_for(
            self.SCREENSHOT,
            "![x](https://evil.example/evidence.cloudcompute.com/x.png) and nothing else",
        )
        self.assertEqual([e for e in errors if "proves nothing" in e], [])

    def test_a_real_result_line_is_accepted(self) -> None:
        for detail in (
            "Test run with 1992 tests in 214 suites passed",
            "all passed",
            "succeeded on self-hosted macOS CI: [test-output](https://example.com/o.txt)",
        ):
            with self.subTest(detail=detail):
                errors = self.errors_for(self.ITEM, detail)
                self.assertEqual([e for e in errors if "proves nothing" in e], [])


class BlockedItemVerdictTests(unittest.TestCase):
    """Where "use judgement, rounding on the side of more evidence" lives.

    Any blocked item forced `request_changes`, whatever the change touched.
    The reviewer is the only actor in the pipeline that reads the diff, so
    the gate now permits the judgement it can safely permit and refuses the
    one it cannot.
    """

    # Neither visual, nor owner-attested, nor a protocol someone follows: the
    # residue the classifier does not recognise, which is what a reviewer who
    # has read the diff can actually weigh.
    WEIGHABLE = "The observability counter from that run, quoted in the PR body"
    GREEN = "`pnpm test` in `web-next` passes"

    def accounting(self, blocked: list[str], complete: list[str]) -> dict[str, object]:
        return {"blocked_items": blocked, "complete_items": complete, "pending_ci_items": []}

    def test_an_item_that_needs_a_person_to_look_still_forces_request_changes(self) -> None:
        # Not only a screenshot request. On-screen copy someone has to read, a
        # protocol someone has to follow, and a call someone has to make are
        # all things no amount of diff-reading answers.
        for item in (
            "Screenshots of the new sidebar",
            "Someone with taste confirms the copy reads well",
            "A test protocol covering a manual production restart",
            "The verdict, keep or remove, with the reasoning (owner-attested)",
        ):
            accounting = self.accounting([item], [self.GREEN])
            for verdict in ("approve", "approve_with_followups"):
                with self.subTest(item=item, verdict=verdict):
                    error = run_contributor.review_evidence_gate_error(
                        verdict, accounting, []
                    )
                    self.assertIsNotNone(error)
                    self.assertIn("needs a person", error)

    def test_the_message_names_the_item_it_is_about(self) -> None:
        # Previewing the whole blocked set in a sentence about needing a
        # person sends the reader to the wrong line.
        error = run_contributor.review_evidence_gate_error(
            "approve_with_followups",
            self.accounting(
                [self.WEIGHABLE, "Screenshots of the new sidebar"], [self.GREEN]
            ),
            [],
        )
        self.assertIsNotNone(error)
        self.assertIn("Screenshots of the new sidebar", error)
        self.assertNotIn(self.WEIGHABLE, error)

    def test_verification_outside_this_repo_still_needs_a_person(self) -> None:
        # A test suite says nothing about a deployed app. Each of these
        # classifies `other`, and each needs somebody to go and do it.
        for item in (
            "Production smoke against the deployed app",
            "Verify the live endpoint returns the new field",
            "A real restart on the production host succeeds",
            "A smoke test against the deployed app",
            "The installed build launches from a cold start",
            "Confirm the TestFlight build launches on an iPhone",
            "Verify the signed DMG opens after download",
        ):
            with self.subTest(item=item):
                error = run_contributor.review_evidence_gate_error(
                    "approve_with_followups",
                    self.accounting([item], [self.GREEN]),
                    [],
                )
                self.assertIsNotNone(error)
                self.assertIn("needs a person", error)

    def test_a_weighable_gap_with_green_tests_can_be_approved_with_followups(self) -> None:
        self.assertIsNone(
            run_contributor.review_evidence_gate_error(
                "approve_with_followups",
                self.accounting([self.WEIGHABLE], [self.GREEN]),
                [],
            )
        )

    def test_a_bare_approve_still_needs_a_whole_contract(self) -> None:
        self.assertIsNotNone(
            run_contributor.review_evidence_gate_error(
                "approve", self.accounting([self.WEIGHABLE], [self.GREEN]), []
            )
        )

    def test_a_green_check_is_not_a_green_test(self) -> None:
        # `check-links` and `actionlint` are green checks that run no tests.
        # Reading one as "the tests pass" would make the softened verdict
        # available on a PR whose tests nobody ran.
        for complete in (
            "CI: `check-links` green on the PR head",
            "Diff: the README links the overview page",
        ):
            with self.subTest(complete=complete):
                error = run_contributor.review_evidence_gate_error(
                    "approve_with_followups",
                    self.accounting([self.WEIGHABLE], [complete]),
                    [],
                )
                self.assertIsNotNone(error)
                self.assertIn("named test", error)

    def test_request_changes_is_never_gated(self) -> None:
        accounting = self.accounting(["Screenshots of the new sidebar"], [])  # noqa: E501
        self.assertIsNone(
            run_contributor.review_evidence_gate_error("request_changes", accounting, [])
        )


class OwnerWrittenEvidenceTests(unittest.TestCase):
    """The revise lane replaced the whole section on every turn.

    An owner who pasted a test summary lost it to the next revision. Every
    lane writes the hidden metadata beside the markdown in the same pass, so
    a line that has drifted from its metadata is a person's -- but only in
    the body GitHub holds. A model asked to rewrite a PR body can write any
    line it likes, so its output is never read as what a person wrote.
    """

    ITEM = "`pnpm test` in `web-next` passes"

    def body(self, detail: str, machine_detail: str) -> str:
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1,
                        "item": self.ITEM,
                        "status": "complete",
                        "detail": machine_detail,
                        "kind": "test-attested",
                    }
                ]
            },
            indent=2,
        )
        return (
            "## Summary\n\nFixed it.\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            "## Evidence Status\n"
            f"- [complete] {self.ITEM} -- {detail}\n"
        )

    def render(self, published: str, model_body: str = "## Summary\n\nFixed it.\n"):
        return run_contributor.render_execution_summary_body(
            model_body,
            requested_evidence=[self.ITEM],
            evidence_complete=None,
            evidence_blocked=None,
            evidence_pending_ci=["1 -- waiting on the author's run"],
            published_body=published,
        )

    def test_a_hand_written_detail_survives_the_next_turn(self) -> None:
        owner_text = "ran it locally: 214 tests passed on this head"
        rendered, errors = self.render(self.body(owner_text, "the factory's own words"))
        self.assertEqual(errors, [])
        self.assertIn(owner_text, rendered)
        self.assertNotIn("waiting on the author's run", rendered)

    def test_a_carried_line_says_it_was_written_before_this_revision(self) -> None:
        # This turn may change the code under it. A green that looks freshly
        # earned when it was attested against an earlier head is the whole
        # hazard of carrying anything forward.
        owner_text = "ran it locally: 214 tests passed"
        rendered, _ = self.render(self.body(owner_text, "the factory's own words"))
        self.assertIn(
            f"{owner_text} {run_contributor.CARRIED_FORWARD_NOTE}", rendered
        )

    def test_the_note_is_not_added_twice(self) -> None:
        carried = f"ran it locally {run_contributor.CARRIED_FORWARD_NOTE}"
        rendered, _ = self.render(self.body(carried, "the factory's own words"))
        self.assertEqual(rendered.count(run_contributor.CARRIED_FORWARD_NOTE), 2)

    def test_a_status_a_person_changed_survives_too(self) -> None:
        # `[blocked]` to `[complete]` with the same words after it is the
        # commonest edit of all, and the gesture the factory asks for by name.
        published = self.body("the factory's own words", "the factory's own words").replace(
            "- [complete]", "- [blocked]", 1
        )
        rendered, errors = self.render(published)
        self.assertEqual(errors, [])
        self.assertIn(f"- [blocked] {self.ITEM} -- the factory's own words", rendered)

    def test_a_machine_written_detail_is_replaced_as_before(self) -> None:
        machine_text = "the factory's own words"
        rendered, errors = self.render(self.body(machine_text, machine_text))
        self.assertEqual(errors, [])
        self.assertIn("waiting on the author's run", rendered)
        self.assertNotIn(machine_text, rendered)

    def test_a_model_cannot_launder_a_completion_through_its_own_body(self) -> None:
        # The contributor writes `data["body"]`. Reading its Evidence Status
        # as "what a person wrote" would let it complete an item the lane
        # refused, with any words it liked.
        forged = (
            "## Summary\n\nFixed it.\n\n"
            "## Evidence Status\n"
            f"- [complete] {self.ITEM} -- trust me\n"
        )
        rendered, errors = self.render("", model_body=forged)
        self.assertEqual(errors, [])
        self.assertIn("waiting on the author's run", rendered)
        self.assertNotIn("trust me", rendered)

    def test_a_published_body_the_machine_never_wrote_preserves_nothing(self) -> None:
        # No metadata means no line the machine wrote, so nothing has drifted
        # -- it is a first draft, not an edit.
        published = (
            "## Summary\n\nFixed it.\n\n"
            "## Evidence Status\n"
            f"- [complete] {self.ITEM} -- I ran it: 214 tests passed\n"
        )
        self.assertEqual(
            run_contributor._owner_written_entries(published, [self.ITEM]), {}
        )

    def test_the_preserved_line_becomes_the_record(self) -> None:
        # Preserved once, then it is the machine state too -- so the next turn
        # sees no drift and nothing is preserved twice over.
        owner_text = "ran it locally: 214 tests passed on this head"
        rendered, _ = self.render(self.body(owner_text, "the factory's own words"))
        self.assertEqual(
            run_contributor._owner_written_entries(rendered, [self.ITEM]), {}
        )


class OwnerKindHandEditTests(unittest.TestCase):
    """An owner's item is completed by the owner's hand, and by nothing else.

    No lane completes an `other` item, so the machine writes it `[blocked]`
    in the visible list and in the hidden metadata and asks the owner to
    rewrite the line. The reviewer read the metadata, refused every verdict,
    and the factory turn that would have copied the line across never came
    (#1612, on #1602). A line written over an item a lane or the factory's
    own parser completes is not that gesture, and reads as the metadata says
    (#1590).
    """

    OWNER_ITEM = (
        "A statement of whether the shared state is reachable from production "
        "code or only from the test fixture"
    )
    MACHINE_DETAIL = (
        "automation cannot reconcile this evidence item automatically; owner "
        "follow-up required"
    )
    PROOF = (
        "reachable from production code: the app and the `workspaces` CLI both "
        "use `WorkspaceService.shared`"
    )

    def body(
        self, item: str, *, machine_status: str, visible_status: str, visible_detail: str
    ) -> str:
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1,
                        "item": item,
                        "status": machine_status,
                        "detail": self.MACHINE_DETAIL,
                        "kind": run_contributor._evidence_item_kind(item),
                    }
                ]
            },
            indent=2,
        )
        return (
            "## Summary\n\nA change.\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            "## Evidence Status\n"
            f"- [{visible_status}] {item} -- {visible_detail}\n\n"
            "## Validation\n- `uv run --script scripts/tests/test_foo.py`: Ran 3 tests, OK\n"
        )

    def review(self, body: str, item: str, verdict: str = "approve") -> tuple[dict[str, object], str | None]:
        accounting, errors = run_contributor.validate_evidence_accounting(
            body, [item], review_ci=[]
        )
        return accounting, run_contributor.review_evidence_gate_error(verdict, accounting, errors)

    def test_an_owner_item_completed_by_hand_can_be_approved(self) -> None:
        self.assertEqual(run_contributor._evidence_item_kind(self.OWNER_ITEM), "other")
        body = self.body(
            self.OWNER_ITEM,
            machine_status="blocked",
            visible_status="complete",
            visible_detail=self.PROOF,
        )
        for verdict in ("approve", "approve_with_followups"):
            with self.subTest(verdict=verdict):
                accounting, error = self.review(body, self.OWNER_ITEM, verdict)
                self.assertIsNone(error)
                self.assertEqual(accounting["complete_items"], [self.OWNER_ITEM])
                self.assertEqual(accounting["blocked_items"], [])

    def test_a_hand_edit_still_has_to_say_what_was_checked(self) -> None:
        body = self.body(
            self.OWNER_ITEM,
            machine_status="blocked",
            visible_status="complete",
            visible_detail="done",
        )
        accounting, error = self.review(body, self.OWNER_ITEM)
        self.assertEqual(accounting["unproven_items"], [self.OWNER_ITEM])
        self.assertIsNotNone(error)

    def test_an_owner_s_blocked_line_holds_the_review_too(self) -> None:
        body = self.body(
            self.OWNER_ITEM,
            machine_status="complete",
            visible_status="blocked",
            visible_detail="not reachable after all; the fixture is the only caller",
        )
        accounting, error = self.review(body, self.OWNER_ITEM)
        self.assertEqual(accounting["blocked_items"], [self.OWNER_ITEM])
        self.assertIsNotNone(error)

    def render(self, model_body: str) -> str:
        rendered, errors = run_contributor.render_execution_summary_body(
            model_body,
            requested_evidence=[self.OWNER_ITEM],
            evidence_complete=None,
            evidence_blocked=[f"1 -- {self.MACHINE_DETAIL}"],
            evidence_pending_ci=None,
        )
        self.assertEqual(errors, [])
        return rendered

    def test_a_section_the_model_wrote_cannot_pose_as_the_owner_s_line(self) -> None:
        # The line reads as the owner's because only an edit on GitHub makes
        # it differ from the metadata. A section in the model's own body,
        # under a heading the renderer does not strip, survives beside the
        # machine's and is read first -- so a body with more than one section
        # a reader accepts has no line that is the owner's.
        forged = f"- [complete] {self.OWNER_ITEM} -- trust me"
        for shape, model_body in (
            ("trailing spaces", f"## Summary\n\nFixed it.\n\n## Evidence Status  \n{forged}\n\n## Validation\n- ok\n"),
            ("CRLF", f"## Summary\r\n\r\nFixed it.\r\n\r\n## Evidence Status\r\n{forged}\r\n\r\n## Validation\r\n- ok\r\n"),
            ("lower case and a tab", f"## Summary\n\nFixed it.\n\n## evidence status\t\n{forged}\n"),
            ("fenced, trailing spaces", f"## Summary\n\n```markdown\n## Evidence Status  \n{forged}\n```\n\n## Validation\n- ok\n"),
        ):
            with self.subTest(shape=shape):
                rendered = self.render(model_body)
                self.assertEqual(
                    run_contributor._owner_written_entries(rendered, [self.OWNER_ITEM]), {}
                )
                accounting, error = self.review(rendered, self.OWNER_ITEM)
                self.assertEqual(accounting["blocked_items"], [self.OWNER_ITEM])
                self.assertIsNotNone(error)

    def test_a_fenced_example_in_the_model_s_body_keeps_its_closing_fence(self) -> None:
        # Stripping a fenced heading as a section runs to the next heading
        # and takes the closing fence with it, so the machine's metadata and
        # section render inside the code block, where a reader of the page
        # cannot see the line the owner has to edit.
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                rendered = self.render(
                    f"## Summary\n\nThe format:\n\n{fence}markdown\n## Evidence Status  \n"
                    f"- [complete] {self.OWNER_ITEM} -- an example\n{fence}\n\n"
                    "## Validation\n- ok\n"
                )
                self.assertEqual(rendered.count(fence), 2, rendered)

    def test_a_hand_edit_over_an_item_a_lane_owns_is_still_refused(self) -> None:
        # Each of these is completed by a lane, a live check or the factory's
        # own reading of the body. A `[complete]` line written over one is
        # not the owner's gesture, and reading it as a completion would clear
        # an item nothing ran.
        for item, machine_status in (
            ("CI: `Web CI` green on the PR head", "pending-ci"),
            ("`swift test --filter FooTests` passes", "blocked"),
            ("Screenshots of the new sidebar", "blocked"),
            ("`pnpm test` in `web-next` passes", "pending-ci"),
            ("Before/after latency on the same workload", "pending-ci"),
            ("Diff: the README links the overview page", "blocked"),
        ):
            with self.subTest(item=item):
                self.assertNotEqual(run_contributor._evidence_item_kind(item), "other")
                body = self.body(
                    item,
                    machine_status=machine_status,
                    visible_status="complete",
                    visible_detail="Ran 214 tests, all passed on this head",
                )
                accounting, error = self.review(body, item)
                self.assertEqual(accounting["complete_items"], [])
                self.assertIsNotNone(error)


class OwnerReadFailsClosedTests(unittest.TestCase):
    """Where an owner's line cannot be read, nothing it might say is assumed.

    Codex round 1 on #1681. Whenever the section could not be read as the
    owner's, an owner item fell back to the metadata, so a `[blocked]` the
    owner wrote was lost and the PR approved. The read also took lines a
    reader of the page never sees, took the kind from the item's wording,
    let the first of two lines win, and took a bare `PASS` as proof.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = "checked: the app and the `workspaces` CLI both call `WorkspaceService.shared`"

    def meta(
        self, item: str, status: str, detail: str = "earlier completion", kind: str | None = "other"
    ) -> str:
        entry: dict[str, object] = {"index": 1, "item": item, "status": status, "detail": detail}
        if kind is not None:
            entry["kind"] = kind
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n"

    def gate(self, body: str, item: str) -> tuple[dict[str, object], str | None]:
        accounting, errors = run_contributor.validate_evidence_accounting(body, [item], review_ci=[])
        return accounting, run_contributor.review_evidence_gate_error("approve", accounting, errors)

    def assert_refused(self, body: str, item: str | None = None) -> None:
        item = item or self.OWNER_ITEM
        accounting, error = self.gate(body, item)
        self.assertNotIn(item, accounting["complete_items"])
        self.assertIsNotNone(error)

    def test_an_owner_s_blocked_line_stands_when_the_section_cannot_be_read(self) -> None:
        blocked = f"- [blocked] {self.OWNER_ITEM} -- owner found it unsafe\n"
        complete = f"- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        for shape, section in (
            ("a second heading", f"## Evidence Status\n{blocked}\n## Evidence Status\n- [complete] decoy -- ignored\n"),
            ("a second heading, both lines complete", f"## Evidence Status\n{complete}\n## Evidence Status\n{complete}"),
            ("trailing space on the heading", f"## Evidence Status \n{blocked}"),
            ("a tab after the heading", f"## Evidence Status\t\n{blocked}"),
            ("a stray line", f"## Evidence Status\n{blocked}Run bare on this head.\n"),
            ("a rule cutting lines off", f"## Evidence Status\n{complete}\n---\n\n{blocked}"),
        ):
            with self.subTest(shape=shape):
                self.assert_refused(self.meta(self.OWNER_ITEM, "complete") + section)

    def test_a_line_a_reader_never_sees_is_not_the_owner_s(self) -> None:
        complete = f"- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        for shape, hidden in (
            ("backtick fence", f"```markdown\n## Evidence Status\n{complete}## Decoy\n```\n"),
            ("tilde fence", f"~~~\n## Evidence Status\n{complete}## Decoy\n~~~\n"),
            ("indented fence", f"   ```\n## Evidence Status\n{complete}## Decoy\n   ```\n"),
            ("unterminated fence", f"```\n## Evidence Status\n{complete}"),
            ("HTML comment", f"<!--\n## Evidence Status\n{complete}## Decoy\n-->\n"),
            ("unterminated HTML comment", f"<!--\n## Evidence Status\n{complete}"),
        ):
            with self.subTest(shape=shape):
                self.assert_refused(
                    self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required") + hidden
                )

    def test_a_fenced_example_does_not_hide_the_real_section(self) -> None:
        example = f"```markdown\n## Evidence Status\n- [blocked] {self.OWNER_ITEM} -- an example\n```\n\n"
        body = (
            example
            + self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")
            + f"\n## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        )
        accounting, error = self.gate(body, self.OWNER_ITEM)
        self.assertEqual(accounting["complete_items"], [self.OWNER_ITEM])
        self.assertIsNone(error)

    def test_the_kind_that_lets_a_line_count_comes_from_the_metadata(self) -> None:
        item = "CI must be green on the PR head: `Web CI`"
        self.assertEqual(run_contributor._evidence_item_kind(item), "other")
        section = f"## Evidence Status\n- [complete] {item} -- {self.PROOF}\n"
        for kind in ("ci", None):
            with self.subTest(metadata_kind=kind):
                self.assert_refused(self.meta(item, "pending-ci", "waiting for checks", kind=kind) + section, item)

    def test_two_lines_for_one_item_are_refused(self) -> None:
        complete = f"- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        blocked = f"- [blocked] {self.OWNER_ITEM} -- owner says it remains unsafe\n"
        for order, lines in (("complete first", complete + blocked), ("blocked first", blocked + complete)):
            with self.subTest(order=order):
                self.assert_refused(
                    self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")
                    + "## Evidence Status\n"
                    + lines
                )

    def test_a_bare_status_word_is_no_proof_of_an_owner_item(self) -> None:
        for detail in (
            "PASS",
            "pass",
            "ok",
            "done",
            "complete",
            "yes",
            "PASS.",
            f"PASS {run_contributor.CARRIED_FORWARD_NOTE}",
        ):
            with self.subTest(detail=detail):
                body = self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required") + (
                    f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {detail}\n"
                )
                accounting, error = self.gate(body, self.OWNER_ITEM)
                self.assertEqual(accounting["unproven_items"], [self.OWNER_ITEM])
                self.assertIsNotNone(error)

    def test_a_sentence_saying_what_was_checked_is_proof(self) -> None:
        body = self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required") + (
            f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        )
        accounting, error = self.gate(body, self.OWNER_ITEM)
        self.assertEqual(accounting["unproven_items"], [])
        self.assertIsNone(error)


class OwnerLineAsRenderedTests(unittest.TestCase):
    """The owner's line is read the way GitHub renders it (#1681, round 3).

    Checked against GitHub's own renderer (`gh api markdown`, gfm): a comment
    hides only what it covers, so the text beside it on the line still shows;
    a fenced line shows as code; and emphasis around the item shows the item.
    The read blanked every line a comment touched, did not notice a code
    block under the heading, and did not see the item through emphasis, so an
    owner's `[blocked]` a reader could plainly see was lost to the metadata.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = OwnerReadFailsClosedTests.PROOF
    BLOCKED = f"- [blocked] {OwnerKindHandEditTests.OWNER_ITEM} -- owner found it unsafe"
    meta = OwnerReadFailsClosedTests.meta
    gate = OwnerReadFailsClosedTests.gate
    assert_refused = OwnerReadFailsClosedTests.assert_refused

    def assert_approved(self, body: str) -> None:
        accounting, error = self.gate(body, self.OWNER_ITEM)
        self.assertEqual(accounting["complete_items"], [self.OWNER_ITEM])
        self.assertIsNone(error)

    def test_a_comment_hides_only_what_it_covers(self) -> None:
        for shape, line in (
            ("a comment after the owner's line", f"{self.BLOCKED} <!-- x -->"),
            ("a comment inside the owner's line", self.BLOCKED.replace("whether ", "whether <!-- x --> ", 1)),
            ("a comment before the owner's line", f"<!-- x --> {self.BLOCKED}"),
        ):
            with self.subTest(shape=shape):
                self.assert_refused(self.meta(self.OWNER_ITEM, "complete") + f"## Evidence Status\n{line}\n")

    def test_a_comment_beside_a_completion_leaves_the_section_unread(self) -> None:
        # Inline HTML inside an item leaves the section unread rather than
        # being rebuilt, since a tag beside the text can strike it out, and a
        # comment is inline HTML too.
        self.assert_refused(
            self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")
            + f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF} <!-- checked on the laptop -->\n"
        )

    def test_a_comment_opened_mid_line_that_runs_on_leaves_the_section_unread(self) -> None:
        # After a list item GitHub shows the `<!--` as text and the next
        # bullet as a bullet, so cutting the span out would hide a `[blocked]`
        # a reader sees. Where it ends depends on blocks the read does not
        # model, so the section is not read at all.
        self.assert_refused(
            self.meta(self.OWNER_ITEM, "complete")
            + f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF} <!--\n{self.BLOCKED}\n-->\n"
        )

    def test_a_code_block_under_the_heading_leaves_the_section_unread(self) -> None:
        for shape, body in (
            ("the owner's line fenced", self.meta(self.OWNER_ITEM, "complete") + f"## Evidence Status\n```\n{self.BLOCKED}\n```\n"),
            ("a tilde fence left open", self.meta(self.OWNER_ITEM, "complete") + f"## Evidence Status\n~~~\n{self.BLOCKED}\n"),
            (
                "a completion beside a fenced blocked line",
                self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")
                + f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n```\n{self.BLOCKED}\n```\n",
            ),
        ):
            with self.subTest(shape=shape):
                self.assert_refused(body)

    def test_emphasis_around_the_item_is_the_same_item(self) -> None:
        item = self.OWNER_ITEM
        for wrapped in (f"**{item}**", f"_{item}_", f"*{item}*", f"__{item}__", f"**`{item}`**"):
            with self.subTest(wrapped=wrapped):
                self.assert_refused(
                    self.meta(item, "complete") + f"## Evidence Status\n- [blocked] {wrapped} -- owner found it unsafe\n"
                )
                self.assert_approved(
                    self.meta(item, "blocked", "owner follow-up required")
                    + f"## Evidence Status\n- [complete] {wrapped} -- {self.PROOF}\n"
                )

    def test_a_status_line_naming_no_requested_item_leaves_the_section_unread(self) -> None:
        # A line the read cannot attribute is still a `[blocked]` a reader
        # sees; ignoring it lets the metadata decide an item the owner may
        # have answered.
        misspelt = self.BLOCKED.replace("reachable", "reachble", 1)
        self.assert_refused(self.meta(self.OWNER_ITEM, "complete") + f"## Evidence Status\n{misspelt}\n")


class SectionReadAsCommonMarkTests(unittest.TestCase):
    """The section is read by a CommonMark parser, the way GitHub renders it (#1701).

    Four rounds of reading lines by pattern each left a shape the read took
    as a status line while GitHub rendered something else. These are the
    three #1701 found on main after #1681 merged, the plain lines that must
    still read, and the machine's own lines that parsing must not mistake for
    a person's edit.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = OwnerReadFailsClosedTests.PROOF
    meta = OwnerReadFailsClosedTests.meta
    gate = OwnerReadFailsClosedTests.gate
    assert_refused = OwnerReadFailsClosedTests.assert_refused
    assert_approved = OwnerLineAsRenderedTests.assert_approved

    def blocked_meta(self) -> str:
        return self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")

    def test_an_indented_code_block_is_not_a_status_line(self) -> None:
        self.assert_refused(
            self.blocked_meta() + f"## Evidence Status\n\n    - [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        )
        self.assert_refused(
            self.meta(self.OWNER_ITEM, "complete")
            + f"## Evidence Status\n\n    - [blocked] {self.OWNER_ITEM} -- owner found it unsafe\n"
        )

    def test_comment_delimiters_inside_a_code_span_are_text(self) -> None:
        self.assert_refused(
            self.blocked_meta() + f"## Evidence Status\n- [complete] `<!-- -->{self.OWNER_ITEM}` -- {self.PROOF}\n"
        )

    def test_asterisks_the_parser_does_not_read_as_emphasis_stay_in_the_item(self) -> None:
        for line in (
            f"- [complete] ** {self.OWNER_ITEM} ** -- {self.PROOF}",
            f"- [complete] **{self.OWNER_ITEM} * -- {self.PROOF}",
        ):
            with self.subTest(line=line[:24]):
                self.assert_refused(self.blocked_meta() + f"## Evidence Status\n{line}\n")

    def test_plain_status_lines_still_read(self) -> None:
        self.assert_approved(self.blocked_meta() + f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n")
        accounting, error = self.gate(
            self.meta(self.OWNER_ITEM, "complete")
            + f"## Evidence Status\n- [blocked] {self.OWNER_ITEM} -- owner found it unsafe\n",
            self.OWNER_ITEM,
        )
        self.assertEqual(accounting["blocked_items"], [self.OWNER_ITEM])
        self.assertIsNotNone(error)

    ATTESTED = "`pnpm test` in `web-next` passes"
    MACHINE_DETAIL = (
        "attested by the PR author, **not** run by the factory: `pnpm test` printed 214 tests passed, "
        "[log](https://evidence.cloudcompute.com/workspaces/pr-1/log.txt)"
    )

    def attested_body(self, visible_status: str) -> str:
        payload = json.dumps(
            {"entries": [{"index": 1, "item": self.ATTESTED, "status": "complete", "detail": self.MACHINE_DETAIL, "kind": "test-attested"}]}
        )
        return (
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            f"## Evidence Status\n- [{visible_status}] {self.ATTESTED} -- {self.MACHINE_DETAIL}\n"
        )

    def test_a_line_the_machine_wrote_is_not_drift_once_parsed(self) -> None:
        # Parsing drops emphasis markers and rebuilds code spans and links,
        # so the visible detail is compared with the recorded one read the
        # same way; comparing it with the raw text would call every machine
        # line with a `**` in it a person's edit.
        self.assertEqual(run_contributor._owner_written_entries(self.attested_body("complete"), [self.ATTESTED]), {})

    def test_a_status_changed_by_hand_keeps_the_detail_the_machine_recorded(self) -> None:
        written = run_contributor._owner_written_entries(self.attested_body("blocked"), [self.ATTESTED])
        self.assertEqual(written[1]["status"], "blocked")
        self.assertEqual(written[1]["detail"], self.MACHINE_DETAIL)


class SectionFailsClosedOnHtmlAndBreaksTests(unittest.TestCase):
    """HTML and line breaks under the heading leave the section unread (#1703, round 5).

    The confirmation lane found five ways the parsed read still disagreed with
    GitHub, each approving against blocked metadata: a `<!-->` block passed
    over as a comment, a decoded `&#10;` that re-cut the section, a soft break
    flattened to a space, inline HTML dropped from beside a status, and
    `<details>` opened before the heading. Rebuilding each rendering is how the
    earlier rounds went wrong, so each fails closed with its reason named.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = OwnerReadFailsClosedTests.PROOF
    UNSAFE = "owner found it unsafe"
    meta = OwnerReadFailsClosedTests.meta
    gate = OwnerReadFailsClosedTests.gate
    assert_refused = OwnerReadFailsClosedTests.assert_refused
    assert_approved = OwnerLineAsRenderedTests.assert_approved

    def blocked_meta(self) -> str:
        return self.meta(self.OWNER_ITEM, "blocked", "owner follow-up required")

    def assert_unread_because(self, body: str, reason: str) -> None:
        self.assert_refused(body)
        unreadable = run_contributor.evaluate_evidence_accounting(body, [self.OWNER_ITEM]).get("owner_section_unreadable")
        self.assertIsNotNone(unreadable)
        self.assertIn(reason, unreadable)

    def test_an_html_block_under_the_heading_leaves_the_section_unread(self) -> None:
        item, proof, unsafe = self.OWNER_ITEM, self.PROOF, self.UNSAFE
        for shape, section in (
            ("<!--> block showing a [blocked]", f"<!--> - [blocked] {item} -- {unsafe} -->\n- [complete] {item} -- {proof}\n"),
            ("<!---> block showing a [blocked]", f"<!---> - [blocked] {item} -- {unsafe} -->\n- [complete] {item} -- {proof}\n"),
            ("--!> block showing a [blocked]", f"<!-- x --!> - [blocked] {item} -- {unsafe} -->\n- [complete] {item} -- {proof}\n"),
            ("a comment-only block after the list", f"- [complete] {item} -- {proof}\n<!--\n- [blocked] {item} -- {unsafe}\n-->\n"),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(self.blocked_meta() + f"## Evidence Status\n{section}", "HTML block")

    def test_a_character_reference_decoding_to_a_line_break_leaves_the_section_unread(self) -> None:
        item, proof, unsafe = self.OWNER_ITEM, self.PROOF, self.UNSAFE
        for shape, section in (
            ("&#10;## re-cutting the section", f"- [complete] {item} -- {proof}&#10;## cut\n- [blocked] {item} -- {unsafe}\n"),
            ("&#10;--- re-cutting the section", f"- [complete] {item} -- {proof}&#10;---&#10;x\n- [blocked] {item} -- {unsafe}\n"),
            ("&NewLine;## re-cutting the section", f"- [complete] {item} -- {proof}&NewLine;## cut\n- [blocked] {item} -- {unsafe}\n"),
            ("&#10; inside one bullet", f"- [complete] {item} -- {proof}&#10;[blocked] {item} -- {unsafe}\n"),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(self.blocked_meta() + f"## Evidence Status\n{section}", "decodes")

    def test_an_item_running_onto_a_second_line_leaves_the_section_unread(self) -> None:
        item, proof, unsafe = self.OWNER_ITEM, self.PROOF, self.UNSAFE
        for shape, section in (
            ("a [blocked] line continuing a [complete] bullet", f"- [complete] {item} -- {proof}\n[blocked] {item} -- {unsafe}\n"),
            ("a hard break before a [blocked] line", f"- [complete] {item} -- {proof}  \n[blocked] {item} -- {unsafe}\n"),
            ("the proof on the next line", f"- [complete] {item}\n-- {proof}\n"),
            ("table rows continuing a bullet", f"- [complete] {item} -- {proof}\n| [blocked] | {item} |\n|---|---|\n"),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(self.blocked_meta() + f"## Evidence Status\n{section}", "second line")

    def test_inline_html_inside_an_item_leaves_the_section_unread(self) -> None:
        item, proof = self.OWNER_ITEM, self.PROOF
        for shape, line in (
            ("<del> around the status", f"- <del>[complete]</del> {item} -- {proof}"),
            ("<del> around the item", f"- [complete] <del>{item}</del> -- {proof}"),
            ("<title> around the status", f"- <title>[complete]</title> {item} -- {proof}"),
        ):
            with self.subTest(shape=shape):
                # `<title>` opens an HTML block where `<del>` stays inline;
                # either way it is HTML the read does not interpret.
                self.assert_unread_because(self.blocked_meta() + f"## Evidence Status\n{line}\n", "HTML")

    def test_html_before_the_heading_leaves_the_section_unread(self) -> None:
        section = f"## Evidence Status\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"
        for shape, body in (
            ("<details> around the whole section", f"<details>\n\n{self.blocked_meta()}\n{section}\n</details>\n"),
            ("<details><summary> opened in one block", f"<details><summary>Evidence</summary>\n\n{self.blocked_meta()}\n{section}"),
            # What not interpreting HTML costs: HTML that closes before the
            # heading leaves the section unread too, until it moves below the
            # section or into a code block.
            ("a balanced paragraph with an image", '<p align="center"><img src="https://evidence.cloudcompute.com/workspaces/pr-1/a.png"></p>\n\n' + self.blocked_meta() + "\n" + section),
            ("<details> closed before the heading", "<details>\n<summary>Notes</summary>\n\nSome notes.\n\n</details>\n\n" + self.blocked_meta() + "\n" + section),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(body, "before the heading")


class HtmlBeforeAndInTheHeadingTests(unittest.TestCase):
    """HTML before or in the Evidence Status heading leaves the section unread (#1704).

    Tracking which elements were still open at the heading meant parsing HTML
    a second way, and it disagreed with GitHub on self-closing tags and on
    comments, and by Python version. Before the heading, only the factory's
    own metadata comment is passed over, recognised by its shape; any other
    HTML block, any inline HTML, and inline HTML in the heading itself leave
    the section unread, with the reason named.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = OwnerReadFailsClosedTests.PROOF
    meta = OwnerReadFailsClosedTests.meta
    gate = OwnerReadFailsClosedTests.gate
    assert_refused = OwnerReadFailsClosedTests.assert_refused
    assert_approved = OwnerLineAsRenderedTests.assert_approved
    blocked_meta = SectionFailsClosedOnHtmlAndBreaksTests.blocked_meta
    assert_unread_because = SectionFailsClosedOnHtmlAndBreaksTests.assert_unread_because

    def section(self, heading: str = "## Evidence Status") -> str:
        return f"{heading}\n- [complete] {self.OWNER_ITEM} -- {self.PROOF}\n"

    def test_any_html_before_the_heading_leaves_the_section_unread(self) -> None:
        for shape, before in (
            ("<details/>, which HTML leaves open", "<details/>\n\n"),
            ("Intro <s/>, striking what follows", "Intro <s/>\n\n"),
            ("Intro <strike/>", "Intro <strike/>\n\n"),
            ("<!--> <details> -->, a comment GitHub ends at <!-->", "<!--> <details> -->\n\n"),
            ("<!-- x --!> <details> -->, a comment a browser ends at --!>", "<!-- x --!> <details> -->\n\n"),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(before + self.blocked_meta() + "\n" + self.section(), "before the heading")

    def test_only_the_machine_s_own_metadata_comment_is_passed_over(self) -> None:
        meta = self.blocked_meta()
        for shape, prefix in (
            # After the real metadata, which the metadata reader takes as the
            # last complete block; placed before it, these two would run into
            # it and read as malformed metadata rather than as HTML.
            ("a metadata-looking comment with a tag after it", meta + '\n<!-- evidence-status:v1\n{"entries": []}\n--> <details>\n\n'),
            ("a metadata-looking comment carrying --!>", meta + "\n<!-- evidence-status:v1 --!> <details> -->\n\n"),
            # Opens and ends like the metadata, and a browser ends it at the
            # first `-->`, which leaves `<details>` open.
            ("a metadata-looking comment with text between two -->", meta + "\n<!-- evidence-status:v1 --> <details> -->\n\n"),
            # Before it, since a complete block after it would be read as the
            # metadata; the `-->` inside the JSON ends the HTML block on that
            # line, so the block does not end at a `-->` of its own.
            ("a metadata-looking comment with a second --> in its JSON", '<!-- evidence-status:v1\n{"note": "-->"}\n-->\n\n' + meta + "\n"),
        ):
            with self.subTest(shape=shape):
                self.assert_unread_because(prefix + self.section(), "before the heading")

    def test_the_machine_s_metadata_comment_and_a_plain_section_still_read(self) -> None:
        self.assert_approved("## Summary\n\nA change.\n\n" + self.blocked_meta() + "\n" + self.section())

    def test_inline_html_in_the_heading_leaves_the_section_unread(self) -> None:
        self.assert_unread_because(self.blocked_meta() + "\n" + self.section("## Evidence Status <s>"), "heading carries inline HTML")

    def test_a_literal_heading_hidden_above_does_not_let_heading_html_through(self) -> None:
        # GitHub carries the `<s>` past the heading and strikes the list,
        # while the literal `## Evidence Status` hidden in the comment is what
        # the section-presence check sees.
        body = "<!--\n## Evidence Status\n-->\n\n" + self.blocked_meta() + "\n" + self.section("## Evidence Status <s>")
        self.assert_unread_because(body, "HTML")

    def test_a_comment_only_block_after_the_section_still_leaves_it_unread(self) -> None:
        body = self.blocked_meta() + "\n" + self.section() + "\n<!-- a note below the list -->\n\n## Validation\n- ok\n"
        self.assert_unread_because(body, "HTML block")


class NoMetadataFallbackTests(unittest.TestCase):
    """A body with no evidence metadata is read as GitHub renders it, and by kind (#1693).

    Every refusal the owner read gained was skipped when the metadata comment
    was missing or indented: the fallback read the section line by line, never
    looked above the heading, and let a `[complete]` there finish any item, a
    `swift test` one included. It now reads through the same CommonMark reader,
    and a hand-written line completes only what the item's kind allows.
    """

    OWNER_ITEM = OwnerKindHandEditTests.OWNER_ITEM
    PROOF = OwnerReadFailsClosedTests.PROOF
    INDENTED_META = ' <!-- evidence-status:v1\n{"entries": []}\n-->\n\n'

    def section(self, item: str, detail: str | None = None) -> str:
        return f"## Evidence Status\n- [complete] {item} -- {detail or self.PROOF}\n"

    def gate(self, body: str, item: str) -> tuple[dict[str, object], list[str], str | None]:
        accounting, errors = run_contributor.validate_evidence_accounting(body, [item], review_ci=[])
        return accounting, errors, run_contributor.review_evidence_gate_error("approve", accounting, errors)

    def assert_unread(self, body: str, item: str, reason: str) -> None:
        accounting, errors, error = self.gate(body, item)
        self.assertEqual(accounting["source"], "markdown")
        self.assertNotIn(item, accounting["complete_items"])
        self.assertIsNotNone(error)
        self.assertIn(reason, accounting["owner_section_unreadable"] or "")
        self.assertTrue(any(e.startswith("the Evidence Status section cannot be read") for e in errors), errors)

    def test_the_confirmation_case_refuses_with_or_without_metadata(self) -> None:
        # GitHub renders this heading and list inside a closed `<details>`.
        item = "Owner check"
        section = self.section(item, "checked manually")
        for shape, body in (
            ("metadata comment indented one space", "<details/>\n\n" + self.INDENTED_META + section),
            ("no metadata comment", "<details/>\n\n" + section),
        ):
            with self.subTest(shape=shape):
                self.assert_unread(body, item, "HTML")

    def test_an_indented_metadata_comment_is_html_before_the_heading(self) -> None:
        self.assert_unread(self.INDENTED_META + self.section(self.OWNER_ITEM), self.OWNER_ITEM, "before the heading")

    def test_a_hand_written_complete_does_not_complete_an_item_something_else_completes(self) -> None:
        for item in (
            "`swift test --filter FooTests` passes",
            "CI: `Web CI` green on the PR head",
            "Diff: the README links the overview page",
            "Screenshots of the new sidebar",
        ):
            with self.subTest(kind=run_contributor._evidence_item_kind(item)):
                accounting, _, error = self.gate(self.section(item, "Ran 214 tests, all passed"), item)
                self.assertNotIn(item, accounting["complete_items"])
                self.assertIn(item, accounting["pending_ci_items"])
                self.assertIsNotNone(error)

    def test_an_attested_test_completes_from_the_statement_of_what_ran(self) -> None:
        item = "`pnpm test` in `web-next` passes"
        body = f"## Evidence Status\n- [complete] {item} -- `pnpm test` in `web-next`: 214 tests passed\n"
        accounting, _, _ = self.gate(body, item)
        self.assertEqual(accounting["complete_items"], [item])

    def test_an_owner_item_still_completes_from_its_line(self) -> None:
        accounting, errors, error = self.gate(self.section(self.OWNER_ITEM), self.OWNER_ITEM)
        self.assertEqual(accounting["source"], "markdown")
        self.assertEqual(accounting["complete_items"], [self.OWNER_ITEM])
        self.assertEqual(errors, [])
        self.assertIsNone(error)

    def test_an_item_written_with_emphasis_completes_from_a_line_naming_it(self) -> None:
        # The line is read as rendered text, so the item is matched as rendered too.
        for item in ("**The launch state is captured**", "The *launch* state is captured"):
            with self.subTest(item=item):
                accounting, errors, error = self.gate(self.section(item), item)
                self.assertEqual(accounting["complete_items"], [item])
                self.assertEqual(accounting["missing_items"], [])
                self.assertEqual(errors, [])
                self.assertIsNone(error)

    def test_an_item_written_with_emphasis_is_classified_as_it_renders(self) -> None:
        # Emphasis around a command does not make a lane item the owner's.
        item = "**`swift test --filter FooTests` passes**"
        body = "## Evidence Status\n- [complete] `swift test --filter FooTests` passes -- hand-written result text\n"
        accounting, _, error = self.gate(body, item)
        self.assertNotIn(item, accounting["complete_items"])
        self.assertEqual(accounting["pending_ci_items"], [item])
        self.assertIsNotNone(error)
        attested = "**`pnpm test` in `web-next` passes**"
        body = "## Evidence Status\n- [complete] `pnpm test` in `web-next` passes -- `pnpm test` in `web-next`: 214 tests passed\n"
        accounting, _, _ = self.gate(body, attested)
        self.assertEqual(accounting["complete_items"], [attested])

    SPLIT_ITEM = '<span title="screenshots"></span>The new sidebar renders'
    SPLIT_LINE = "## Evidence Status\n- [complete] The new sidebar renders -- looked at it\n"

    def recorded(self, item: str, kind: str, status: str = "pending-ci") -> str:
        entry = {"index": 1, "item": item, "status": status, "detail": "the lane runs it", "kind": kind}
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def test_an_item_that_classifies_two_ways_takes_the_stricter_kind(self) -> None:
        # The contributor records the kind from the item as the issue writes it,
        # and a line is matched against the item as it renders. Inline HTML is
        # in the first text and not the second, so the two readings disagree.
        accounting, _, error = self.gate(self.SPLIT_LINE, self.SPLIT_ITEM)
        self.assertNotIn(self.SPLIT_ITEM, accounting["complete_items"])
        self.assertEqual(accounting["pending_ci_items"], [self.SPLIT_ITEM])
        self.assertIn("classifies two ways", accounting["entries"]["The new sidebar renders"]["detail"])
        self.assertIsNotNone(error)

    def test_a_recorded_kind_does_not_let_a_split_item_complete_from_its_line(self) -> None:
        for kind in ("screenshot", "other"):
            with self.subTest(recorded=kind):
                body = self.recorded(self.SPLIT_ITEM, kind) + self.SPLIT_LINE
                accounting, _, error = self.gate(body, self.SPLIT_ITEM)
                self.assertEqual(accounting["source"], "structured")
                self.assertNotIn(self.SPLIT_ITEM, accounting["complete_items"])
                self.assertIsNotNone(error)

    def test_a_lane_item_recorded_other_does_not_complete_from_its_line(self) -> None:
        # The mirror: the recorded kind reads `other` from the raw item, while
        # the item renders as a lane item, so its visible line is not the
        # owner's to complete.
        item = "**`swift test --filter FooTests` passes**"
        body = self.recorded(item, "other") + "## Evidence Status\n- [complete] `swift test --filter FooTests` passes -- hand-written result text\n"
        accounting, _, error = self.gate(body, item)
        self.assertEqual(accounting["source"], "structured")
        self.assertEqual(accounting["complete_items"], [])
        self.assertEqual(accounting["pending_ci_items"], [item])
        self.assertIsNotNone(error)

    def test_metadata_is_read_whatever_the_line_endings(self) -> None:
        # A metadata comment with CRLF or CR endings went unmatched, so the body
        # fell to the hand-written read and a lane item recorded pending
        # completed from its visible line.
        item = "`pnpm test` in `web-next` passes"
        entry = {"index": 1, "item": item, "status": "pending-ci", "detail": "the evidence lane runs it", "kind": "test-attested"}
        body = (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n## Evidence Status\n"
            f"- [complete] {item} -- `pnpm test` in `web-next`: 214 tests passed\n"
        )
        for name, ending in (("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")):
            with self.subTest(ending=name):
                accounting, _, error = self.gate(body.replace("\n", ending), item)
                self.assertEqual(accounting["source"], "structured")
                self.assertEqual(accounting["complete_items"], [])
                self.assertEqual(accounting["pending_ci_items"], [item])
                self.assertIsNotNone(error)

    def test_two_items_that_render_alike_do_not_share_one_line(self) -> None:
        items = ["**The launch state is captured**", "The launch state is captured"]
        body = self.section(items[1])
        for contract in (items, items[::-1]):
            with self.subTest(contract=contract):
                accounting, _ = run_contributor.validate_evidence_accounting(body, contract, review_ci=[])
                self.assertEqual(accounting["complete_items"], [items[1]])
                self.assertEqual(accounting["missing_items"], [items[0]])

    def test_a_line_that_does_not_name_the_item_does_not_complete_it(self) -> None:
        accounting, _, error = self.gate(self.section(self.OWNER_ITEM + " on macOS"), self.OWNER_ITEM)
        self.assertNotIn(self.OWNER_ITEM, accounting["complete_items"])
        self.assertIn(self.OWNER_ITEM, accounting["blocked_items"])
        self.assertIsNotNone(error)

    def test_the_1701_shapes_refuse_without_metadata(self) -> None:
        item = self.OWNER_ITEM
        for shape, body in (
            ("an indented code block", f"## Evidence Status\n\n    - [complete] {item} -- {self.PROOF}\n"),
            ("comment delimiters in a code span", f"## Evidence Status\n- [complete] `<!-- -->{item}` -- {self.PROOF}\n"),
            ("** item ** that is not emphasis", f"## Evidence Status\n- [complete] ** {item} ** -- {self.PROOF}\n"),
            ("**item * that is not emphasis", f"## Evidence Status\n- [complete] **{item} * -- {self.PROOF}\n"),
        ):
            with self.subTest(shape=shape):
                accounting, _, error = self.gate(body, item)
                self.assertNotIn(item, accounting["complete_items"])
                self.assertIsNotNone(error)

    def test_the_1704_shapes_refuse_without_metadata(self) -> None:
        item = self.OWNER_ITEM
        self.assert_unread("Intro <s/>\n\n" + self.section(item), item, "before the heading")
        self.assert_unread("<!--\n## Evidence Status\n-->\n\n" + self.section(item).replace("## Evidence Status", "## Evidence Status <s>", 1), item, "HTML")


class SplitKindCompletionRouteTests(unittest.TestCase):
    """An item that classifies two ways completes the way its decided kind does, metadata or not (#1693).

    The contributor records the kind from the item as the issue writes it, so a
    split item is recorded `other` and seeded blocked. Its decided kind is not
    `other`, so its visible line is not read as the owner's, and no lane owns
    it either. What is left is the body's own proof form, the route the
    hand-written read already uses.
    """

    ATTESTED = "**`pnpm test` in `web-next` passes**"
    STATEMENT = "`pnpm test` in `web-next`: 214 tests passed"
    PERF_ITEM = "Sidebar render be<span></span>fore and after latency"
    PERF_SECTION = "## Performance\n\n- Before Summary: latency 120 ms\n- After Summary: latency 80 ms\n\n"
    LANE_ITEM = "**`swift test --filter FooTests` passes**"

    def recorded(self, item: str, status: str = "blocked", kind: str = "other", detail: str = "owner follow-up required") -> str:
        entry = {"index": 1, "item": item, "status": status, "detail": detail, "kind": kind}
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def gate(self, body: str, item: str) -> tuple[dict[str, object], str | None]:
        accounting, errors = run_contributor.validate_evidence_accounting(body, [item], review_ci=[])
        return accounting, run_contributor.review_evidence_gate_error("approve", accounting, errors)

    def section(self, item: str, detail: str) -> str:
        return f"## Evidence Status\n- [complete] {item} -- {detail}\n"

    def test_an_attested_item_recorded_other_completes_from_the_statement(self) -> None:
        line = self.section("`pnpm test` in `web-next` passes", self.STATEMENT)
        body = f"## Validation\n\n- {self.STATEMENT}\n\n" + line
        for shape, whole in (("metadata seeds it blocked", self.recorded(self.ATTESTED) + body), ("no metadata", body)):
            with self.subTest(shape=shape):
                accounting, error = self.gate(whole, self.ATTESTED)
                self.assertEqual(accounting["complete_items"], [self.ATTESTED])
                self.assertIsNone(error)

    def test_without_the_statement_it_stays_blocked_and_says_what_to_write(self) -> None:
        body = self.recorded(self.ATTESTED) + self.section("`pnpm test` in `web-next` passes", "checked by hand")
        accounting, error = self.gate(body, self.ATTESTED)
        self.assertEqual(accounting["blocked_items"], [self.ATTESTED])
        detail = accounting["entries"][self.ATTESTED]["detail"]
        self.assertIn("state the command and the line it printed", detail)
        self.assertIn("classifies two ways", detail)
        self.assertIsNotNone(error)

    def test_a_perf_item_recorded_other_completes_from_the_performance_section(self) -> None:
        line = self.section("Sidebar render before and after latency", "measured it")
        accounting, error = self.gate(self.recorded(self.PERF_ITEM) + self.PERF_SECTION + line, self.PERF_ITEM)
        self.assertEqual(accounting["complete_items"], [self.PERF_ITEM])
        self.assertIsNone(error)
        measured_something_else = "## Performance\n\n- Before Summary: memory 400 MB\n- After Summary: memory 380 MB\n\n"
        accounting, error = self.gate(self.recorded(self.PERF_ITEM) + measured_something_else + line, self.PERF_ITEM)
        self.assertEqual(accounting["blocked_items"], [self.PERF_ITEM])
        self.assertIn("before and after measurements", accounting["entries"][self.PERF_ITEM]["detail"])
        self.assertIsNotNone(error)

    def test_a_lane_item_recorded_other_is_not_completed_by_a_statement(self) -> None:
        # `swift test` is run by the evidence lane, so no form in the body
        # completes it; the statement route belongs to the attested kinds.
        body = (self.recorded(self.LANE_ITEM) + "## Validation\n\n- `swift test --filter FooTests`: 12 tests passed\n\n"
                + self.section("`swift test --filter FooTests` passes", "12 tests passed"))
        accounting, error = self.gate(body, self.LANE_ITEM)
        self.assertEqual(accounting["complete_items"], [])
        self.assertIsNotNone(error)


class ScreenshotRequestNeedsAPersonTests(unittest.TestCase):
    """An item that reads as a screenshot request only once rendered is one a person has to look at.

    `_needs_a_person_to_look` decides the screenshot kind the way #1707's three
    sites decide theirs, through `_hand_completion_kind`. A strictness tie
    keeps the written reading and `screenshot` outranks `other`, so this can
    gain a screenshot request and never lose one: inline HTML the render drops
    no longer hides one from the reader.

    The second test is the bar the decided kind must not be asked to carry.
    `_hand_completion_kind` ranks by which completion form is stricter, where
    `other` is the least strict; `_detail_proves_nothing(owner=...)` asks
    whether a runner stands behind the item, where `other` is the answer that
    turns the status-word rule on. The same word means opposite things to the
    two readers, so `unproven_items` keeps reading the written wording. An
    item whose two readings disagree, recorded complete with nothing but a
    status word for a detail, is what the inversion would let through.
    """

    SCREENSHOT_ITEM = "Screen<span></span>shots of the new sidebar"
    SPLIT_ITEM = "**swift test** owner confirms"

    def test_an_item_that_renders_as_a_screenshot_request_needs_a_person(self) -> None:
        self.assertTrue(run_contributor._needs_a_person_to_look(self.SCREENSHOT_ITEM))
        self.assertTrue(run_contributor._needs_a_person_to_look("Screenshots of the new sidebar"))
        self.assertFalse(run_contributor._needs_a_person_to_look("The launch state is captured"))

    def test_a_status_word_does_not_prove_a_split_item_recorded_complete(self) -> None:
        # Written `other`, rendered `test`. `green` is a status word, not a
        # report of a run, and no lane stands behind a hand-written line.
        self.assertEqual(run_contributor._evidence_item_kind(self.SPLIT_ITEM), "other")
        self.assertEqual(sys.modules["evidence"]._hand_completion_kind(self.SPLIT_ITEM), ("test", True))
        entry = {"index": 1, "item": self.SPLIT_ITEM, "status": "complete", "detail": "green", "kind": "other"}
        body = ("<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"
                "## Evidence Status\n- [complete] swift test owner confirms -- green\n")
        accounting, errors = run_contributor.validate_evidence_accounting(body, [self.SPLIT_ITEM], review_ci=[])
        self.assertEqual(accounting["unproven_items"], [self.SPLIT_ITEM])
        self.assertIsNotNone(run_contributor.review_evidence_gate_error("approve", accounting, errors))
class MetadataLineEndingsTests(unittest.TestCase):
    """Every function that reads or rewrites the metadata sees the same blocks, whatever the body's line endings (#1710).

    `_EVIDENCE_METADATA_RE` is anchored on `\n`, and GitHub stores a body with
    whatever endings the client sent. Normalising in one reader is worse than
    normalising in none: a reader that sees a CRLF block beside a writer that
    cannot strip it leaves two blocks behind, and which one is authoritative
    then decides whether a named check is re-verified. So each of these
    normalises, and these are the guards on that.

    What none of them changes is which block decides. A body carrying several
    is read at its last, as it is on main, and the writer below is why that
    stays safe: a rewrite now strips what it read, so no new two-block body is
    made. One already stored that way is a migration question, not a reason to
    widen a read.
    """

    ITEM = "CI: `Web CI` green on the PR head"

    def body(self, ending: str = "\n", *, status: str = "complete", detail: str = "claims green") -> str:
        entry = {"index": 1, "item": self.ITEM, "status": status, "detail": detail, "kind": "ci"}
        text = ("<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"
                f"## Evidence Status\n- [{status}] {self.ITEM} -- {detail}\n")
        return text.replace("\n", ending)

    def test_the_extractor_reads_every_ending(self) -> None:
        for name, ending in (("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")):
            with self.subTest(endings=name):
                metadata = run_contributor._extract_evidence_metadata(self.body(ending))
                self.assertIsNotNone(metadata)
                self.assertEqual([entry["item"] for entry in metadata["entries"]], [self.ITEM])

    def test_the_stripper_removes_a_block_in_every_ending(self) -> None:
        evidence = sys.modules["evidence"]
        for name, ending in (("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")):
            with self.subTest(endings=name):
                self.assertNotIn("evidence-status", evidence._strip_evidence_metadata(self.body(ending)))

    def test_the_writer_rewrites_a_crlf_body_once_and_only_once(self) -> None:
        evidence = sys.modules["evidence"]
        updates = {1: {"status": "blocked", "detail": "the lane refused it"}}
        once = evidence.update_evidence_entries(self.body("\r\n"), updates)
        self.assertEqual(once.count("<!-- evidence-status:"), 1)
        self.assertEqual(evidence.update_evidence_entries(once, updates), once)
        entries = run_contributor._extract_evidence_metadata(once)["entries"]
        self.assertEqual([(e["status"], e["detail"]) for e in entries], [("blocked", "the lane refused it")])

    def test_a_body_with_several_blocks_is_read_at_its_last(self) -> None:
        # Last-block-wins is unchanged; which blocks are visible is not. Main
        # could not see a trailing CRLF block and so read the LF block ahead
        # of it. Both are visible now, and the last decides -- the rule main
        # already applies when both blocks are LF. So this shape reads
        # differently than it did, and that is the migration question: the
        # writer below no longer makes such a body, and repairing one already
        # stored is not something a read should do quietly.
        second = ("<!-- evidence-status:v1\n" + json.dumps({"entries": []}) + "\n-->\n").replace("\n", "\r\n")
        metadata = run_contributor._extract_evidence_metadata(self.body("\n") + "\n" + second)
        self.assertEqual(metadata["entries"], [])


class DocumentedTestFormTests(unittest.TestCase):
    """The `test` form the docs teach has to survive the parser.

    `docs/development/evidence.md` and the admission decline comment both show
    a backticked command followed by "passes". Read as one command that whole
    string is unparseable, and the run aborted with `evidence_validation`
    before the author's first commit -- so following the documentation was the
    fastest way to fail. The command is the backticked span; what follows is
    the author saying what the command should do.
    """

    DOCUMENTED_TEST_ITEM = "`swift test --filter FooTests` passes"
    DOCUMENTED_BUILD_ITEM = "`swift build` succeeds"

    def test_the_documented_item_still_classifies_as_a_test(self) -> None:
        self.assertEqual(
            run_contributor._evidence_item_kind(self.DOCUMENTED_TEST_ITEM), "test"
        )

    def test_trailing_prose_is_not_part_of_the_command(self) -> None:
        self.assertEqual(
            run_contributor._extract_test_commands([self.DOCUMENTED_TEST_ITEM]),
            ["swift test --filter FooTests"],
        )

    def test_the_documented_item_is_admissible(self) -> None:
        # Patched on `evidence`, not on the wrapper: the preflight resolves
        # through `sys.modules.get("run_contributor", sys.modules[__name__])`,
        # and this file loads the wrapper under its own name.
        with mock.patch.object(
            sys.modules["evidence"],
            "_listed_swift_tests",
            return_value=["FooTests/theCase()"],
        ):
            errors = run_contributor.validate_requested_test_commands(
                [self.DOCUMENTED_TEST_ITEM], env={}
            )
        self.assertEqual(errors, [])

    def test_the_preflight_skips_where_there_is_no_swift_to_ask(self) -> None:
        # The agent lanes run `ubuntu-latest`. `swift test list` raises
        # FileNotFoundError there, and an unhandled one aborted the run
        # instead of skipping a preflight that cannot apply.
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}, clear=False):
            self.assertEqual(
                run_contributor.validate_requested_test_commands(
                    [self.DOCUMENTED_TEST_ITEM], env={"PATH": "/nonexistent"}
                ),
                [],
            )

    def test_a_missing_binary_is_not_swallowed_for_every_other_caller(self) -> None:
        # `run_optional` has 26 call sites and one of them reads `git status
        # --porcelain`, where an empty answer means "clean". Swallowing an
        # error there would let a revision finish without committing its
        # edits, so the tolerance lives in the preflight, not in the helper.
        with self.assertRaises(FileNotFoundError):
            run_contributor.run_optional(
                ["definitely-not-a-real-binary-xyzzy"], timeout=5, default="fallback"
            )

    def test_the_documented_build_item_is_admissible(self) -> None:
        errors = run_contributor.validate_requested_test_commands(
            [self.DOCUMENTED_BUILD_ITEM], env={}
        )
        self.assertEqual(errors, [])

    def test_the_bare_command_form_is_unchanged(self) -> None:
        self.assertEqual(
            run_contributor._extract_test_commands(
                ["swift test --filter FooTests", "`swift test`"]
            ),
            ["swift test --filter FooTests", "swift test"],
        )

    def test_an_unsafe_command_inside_the_span_is_still_refused(self) -> None:
        # Stripping prose reaches only what is outside the span. Everything
        # the allowlist refused before it still refuses.
        errors = run_contributor.validate_requested_test_commands(
            ["`swift test --parallel` passes"], env={}
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("must use `swift test`", errors[0])

    def test_prose_before_the_command_is_not_a_command(self) -> None:
        # The span has to open the item. An item that merely mentions a
        # command mid-sentence is not a request to run it, and reading one out
        # of the middle would run a command nobody asked for.
        item = "Run something, then `swift test --filter FooTests`"
        self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_the_pending_ci_seed_names_the_command_not_the_prose(self) -> None:
        _, _, pending = run_contributor.synthesize_initial_execution_evidence(
            [self.DOCUMENTED_TEST_ITEM]
        )
        self.assertEqual(len(pending), 1)
        self.assertIn("`swift test --filter FooTests`", pending[0])
        self.assertNotIn("passes", pending[0])

    def test_a_second_requirement_after_the_command_fails_closed(self) -> None:
        # Stripping prose must not strip a demand. Each of these asks for the
        # command AND something the command cannot produce; running it would
        # complete the item with half the contract met. The grammar is an
        # allowlist, so the last two -- a second command, and an owner
        # directive with the verb before the noun -- fail closed without
        # anyone having thought to name them.
        for item in (
            "`swift test` passes (owner-attested)",
            "`swift test` passes; a screenshot of the sidebar from the same commit",
            "`swift test` passes and the new column appears in the PR diff",
            "`swift test` passes with the `Lint, Test, Build` check green",
            "`swift build` succeeds, owner confirms the warning is gone",
            "`swift test --filter FooTests` passes and `swift test --filter BarTests` passes",
            "`swift test` passes, approved by the owner",
            "`swift test --filter FooTests` passes, including the screenshot metadata cases",
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), "other")

    def test_a_before_and_after_run_is_two_runs_not_a_verdict(self) -> None:
        # The lane runs the head only, so this completed with a baseline it
        # never took.
        self.assertEqual(
            run_contributor._evidence_item_kind("`swift test` passes before and after"),
            "other",
        )

    def metadata_body(self, payload: str) -> str:
        return "## Summary\n\n<!-- evidence-status:v1\n" + payload + "\n-->\n"

    def test_a_payload_json_cannot_build_does_not_take_the_lane_down(self) -> None:
        # The body this reads is PR-editable, and `json.loads` has two ways to
        # refuse that are not JSONDecodeError: past 4300 digits it will not
        # build the integer and raises the plain ValueError, and a deeply
        # nested payload exhausts the stack with RecursionError. Either one
        # escaped and aborted the run.
        for label, payload in (
            ("long integer", '{"entries": [{"index": ' + "1" * 4301 + "}]}"),
            # An object, and deep enough that 3.13 recurses too: a list at
            # 1200 parses there, so the case proved nothing on that runtime.
            ("deep nesting", '{"a":' * 20000 + "1" + "}" * 20000),
        ):
            with self.subTest(label=label):
                body = self.metadata_body(payload)
                self.assertIsNone(run_contributor._extract_evidence_metadata(body))
                accounting = run_contributor.evaluate_evidence_accounting(
                    body, ["an item"]
                )
                self.assertEqual(accounting["source"], "structured-invalid")

    def test_a_lone_surrogate_does_not_break_the_writers(self) -> None:
        # A JSON-escaped lone surrogate parses fine and then cannot be encoded
        # as UTF-8, so every writer of the body it lands in raises
        # UnicodeEncodeError -- `gh pr edit`, the evidence workflow.
        body = self.metadata_body(
            '{"entries": [{"index": 1, "item": "x", "status": "complete",'
            ' "detail": "\\ud800"}]}'
        )
        for label, rendered in (
            (
                "update",
                run_contributor.update_evidence_entries(
                    body, {1: {"status": "complete", "detail": "y"}}
                ),
            ),
            (
                "reconcile",
                run_contributor.reconcile_pending_ci_evidence(
                    body,
                    build_succeeded=True,
                    tests_succeeded=True,
                    smoke_succeeded=True,
                ),
            ),
        ):
            with self.subTest(label=label):
                rendered.encode("utf-8")

    def test_cleaning_a_body_does_not_grow_it_past_what_github_stores(self) -> None:
        # Escaping everything to ASCII kept a lone surrogate out, and turned
        # 6,000 emoji into 78,000 characters -- past GitHub's 65,536 limit, so
        # the body could not be written back at all.
        emoji = "\U0001F600" * 6000
        body = self.metadata_body(
            json.dumps(
                {"entries": [{"index": 1, "item": emoji, "status": "complete",
                              "detail": "d"}]}
            )
        )
        rendered = run_contributor.update_evidence_entries(
            body, {1: {"status": "complete", "detail": "kept"}}
        )
        self.assertLess(len(rendered), len(body))

    def test_a_deeply_nested_payload_does_not_take_a_writer_down(self) -> None:
        # A thousand nested arrays parse fine on this runtime, and then both
        # the cleaning pass and `json.dumps` with an indent recurse on the way
        # back out -- so a body could be built that no writer could serialise.
        body = self.metadata_body('{"entries": [' + "[" * 1000 + "]" * 1000 + "]}")
        self.assertEqual(
            run_contributor.evaluate_evidence_accounting(body, ["x"])["source"],
            "structured-invalid",
        )
        for label, rendered in (
            (
                "update",
                run_contributor.update_evidence_entries(
                    body, {1: {"status": "complete", "detail": "d"}}
                ),
            ),
            (
                "reconcile",
                run_contributor.reconcile_pending_ci_evidence(
                    body,
                    build_succeeded=True,
                    tests_succeeded=True,
                    smoke_succeeded=True,
                ),
            ),
        ):
            with self.subTest(label=label):
                self.assertIsInstance(rendered, str)

    def test_an_ordinary_payload_is_carried_through_unchanged(self) -> None:
        payload = {
            "entries": [
                {"index": 1, "item": "x", "status": "complete", "detail": "d",
                 "kind": "ci"}
            ]
        }
        self.assertEqual(run_contributor._encodable_payload(payload), payload)

    def test_an_infinite_index_does_not_take_any_metadata_path_down(self) -> None:
        # `1e9999` parses as infinity and `int()` of that raises OverflowError,
        # which the three index reads did not catch.
        body = self.metadata_body(
            '{"entries": [{"index": 1e9999, "item": "x", "status": "complete",'
            ' "detail": "d"}]}'
        )
        self.assertEqual(
            run_contributor.evaluate_evidence_accounting(body, ["x"])["source"],
            "structured-invalid",
        )
        self.assertIsInstance(
            run_contributor.update_evidence_entries(
                body, {1: {"status": "complete", "detail": "y"}}
            ),
            str,
        )
        self.assertIsInstance(
            run_contributor.reconcile_pending_ci_evidence(
                body, build_succeeded=True, tests_succeeded=True, smoke_succeeded=True
            ),
            str,
        )

    def test_the_verdicts_people_actually_write_are_accepted(self) -> None:
        for item, kind in (
            ("`swift test`", "test"),
            ("`swift test --filter FooTests` passes", "test"),
            ("`swift test` passes locally", "test"),
            ("`swift test --filter FooTests` must pass on the PR head", "test"),
            ("`swift test` is green", "test"),
            ("`swift build` succeeds", "build"),
            ("`swift build` succeeds cleanly.", "build"),
            ("swift test --filter FooTests", "test"),
        ):
            with self.subTest(item=item):
                self.assertEqual(run_contributor._evidence_item_kind(item), kind)

    def test_the_lane_command_key_is_spelled_the_way_the_lane_spells_it(self) -> None:
        # The lane logs `$ ` + shlex.join(argv). An author's own quoting of the
        # same command is a different string, and the lookup would miss it.
        self.assertEqual(
            run_contributor._lane_command_key(
                '`swift test --filter \'WorkspaceManagerTests.FooTests\'` passes'
            ),
            "swift test --filter WorkspaceManagerTests.FooTests",
        )

    def test_the_lane_result_matches_the_command_it_logged(self) -> None:
        # The lane writes `$ <shlex-joined command>` above each run's output,
        # and resolution looks that key up. Resolving on the item text instead
        # would miss the section and report "matched no tests" for a run that
        # passed.
        status, detail = run_contributor._pending_ci_resolution(
            self.DOCUMENTED_TEST_ITEM,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            test_output="$ swift test --filter FooTests\nTest run with 1 test passed.\n",
        )
        self.assertEqual(status, "complete")
        self.assertIn("`swift test --filter FooTests`", detail)


class LaneWrittenMetadataMatchesTheFactoryShapeTests(unittest.TestCase):
    """The metadata a reconcile writes on a hand-written body is the factory's own shape (#1708).

    The reader treats the metadata as the whole account once it exists, and
    which rule each item falls to is decided by the `kind` recorded beside it
    -- an `other` item is read from its visible line, every other kind from
    the metadata. So a body that gains its metadata from the lane has to gain
    the same entry for each item that a body written by a factory turn
    carries, owner items included: leaving them out would report them missing
    and take the owner's attested line with them.
    """

    maxDiff = None
    OWNER_ITEM = "Manual QA sign-off from the owner"
    PERF_ITEM = "Before and after sidebar rebuild timings for the 500-row fixture"
    ATTESTED_ITEM = "`uv run --script scripts/tests/test_run_contributor.py` passes"
    REQUESTED = [
        "swift build",
        "swift test --filter SidebarTests",
        "Screenshot of the sidebar from the exact commit under review",
        CI_ITEM,
        DIFF_ITEM,
        PERF_ITEM,
        ATTESTED_ITEM,
        OWNER_ITEM,
    ]

    def kinds_of(self, body: str) -> dict[str, str]:
        metadata = sys.modules["evidence"]._extract_evidence_metadata(body)
        self.assertIsInstance(metadata, dict)
        return {str(entry["item"]): str(entry["kind"]) for entry in metadata["entries"]}

    def factory_body(self) -> str:
        rendered, errors = run_contributor.render_execution_summary_body(
            "## Summary\n- Reordered the sidebar rows\n\n## Validation\n- blocked on evidence: waiting on CI\n",
            requested_evidence=self.REQUESTED,
            evidence_complete=[],
            evidence_blocked=[],
            evidence_pending_ci=[
                f"{index} -- self-hosted macOS CI will gather this"
                for index in range(1, len(self.REQUESTED) + 1)
            ],
        )
        self.assertEqual(errors, [])
        return rendered

    def hand_written_body(self) -> str:
        lines = "\n".join(
            f"- [pending-ci] {item} -- self-hosted macOS CI will gather this"
            for item in self.REQUESTED
        )
        return (
            "## Summary\n- Reordered the sidebar rows\n\n"
            f"## Evidence Status\n{lines}\n\n"
            "## Validation\n- blocked on evidence: waiting on CI\n"
        )

    def test_the_lane_records_the_kind_the_factory_records_for_every_item(self) -> None:
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            self.hand_written_body(),
            requested_evidence=self.REQUESTED,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[("sidebar", "https://evidence.example/pr-1/sidebar.png")],
        )

        self.assertEqual(self.kinds_of(reconciled), self.kinds_of(self.factory_body()))
        self.assertEqual(self.kinds_of(reconciled)[self.OWNER_ITEM], "other")

    def test_the_lane_answers_only_the_kinds_it_gathers(self) -> None:
        """What each kind reads as once the lane has written the metadata.

        The three kinds the macOS lane gathers carry its results. `ci`, `diff`,
        `perf` and `test-attested` are exempt from it and keep the line's own
        words, so each still waits for the lane that does complete it. An
        owner's item is the one the lane answers by refusing: it writes the
        blocked entry that asks the owner to rewrite the line, the same answer
        it gives on a factory body.
        """
        reconciled = run_contributor.reconcile_pending_ci_evidence(
            self.hand_written_body(),
            requested_evidence=self.REQUESTED,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[("sidebar", "https://evidence.example/pr-1/sidebar.png")],
        )
        accounting, _ = run_contributor.validate_evidence_accounting(reconciled, self.REQUESTED)

        self.assertEqual(accounting["source"], "structured")
        self.assertEqual(accounting["complete_items"], self.REQUESTED[:3])
        self.assertEqual(accounting["pending_ci_items"], self.REQUESTED[3:7])
        self.assertEqual(accounting["blocked_items"], [self.OWNER_ITEM])


class OneSectionBoundaryForBothViewsTests(unittest.TestCase):
    """A section stops in one place, and both views ask the same question (#1723).

    The written read matched a literal three-dash line; the page applies
    CommonMark, where three dashes directly under a line of text underline it
    into a heading instead of ruling a section off. A Performance section closed that
    way was whole to the written read and empty to the rendered one, and the
    item stopped completing with nothing saying why.

    Both reads now take their boundary from `is_section_boundary` over the same
    tokens, so neither can place one the other does not. What that leaves for a
    setext heading is a block of lines an author wrote plain and a rule under
    them: not a section of its own, and not a heading whose hashes the read may
    invent.
    """

    PERF_ITEM = "p50 launch latency before and after"
    READER_HEADINGS = (
        "Evidence Status",
        "Requested Evidence",
        "Validation",
        "Performance",
        "Blockers",
        "Blocked By",
        "Execution",
        "Mergeability",
        "Risks",
        "What",
        "Summary",
        "Evidence",
    )

    def evidence(self):
        """The reader module. Every name these tests use it for predates this
        change, so the properties below run on the merge base as written."""
        return sys.modules["evidence"]

    @staticmethod
    def closes_a_section(token) -> bool:
        """The boundary condition spelled out, rather than asked of the code under test."""
        if token.level != 0:
            return False
        if token.type == "hr":
            return token.markup.startswith("-")
        return token.type == "heading_open" and token.tag in {"h1", "h2"}

    def views(self, body: str, heading: str = "Performance") -> tuple[list[str], list[str]]:
        """The written lines and the rendered lines of one section."""
        evidence = self.evidence()
        written = evidence.MARKDOWN_LINE_ENDING_RE.split(evidence.markdown_section(body, heading))
        return [line for line in written if line.strip()], evidence._rendered_lines(body, heading)

    PARAGRAPH_FIELDS = (
        "Before Summary: p50 launch latency 900 ms\n"
        "After Summary: p50 launch latency 410 ms\n"
    )

    UNDERLINES = ("---", "-----", "  ---", "===")

    def test_a_dash_rule_written_against_the_measurements_still_refuses(self) -> None:
        # The #1723 shape and every underline that makes it: three dashes, more
        # than three, an indented run, and the equals sign that underlines an
        # h1. The page shows a heading where the author wrote measurements, so
        # no reading of the section finds a `Before:` line -- and both views
        # now stop in the same place, which is the part that was wrong.
        evidence = self.evidence()
        for underline in self.UNDERLINES:
            body = f"## Performance\n\n{self.PARAGRAPH_FIELDS}{underline}\n\n## Risks\n\nNone.\n"
            with self.subTest(underline=underline):
                self.assertIsNone(run_contributor._perf_numbers(body, self.PERF_ITEM))
                _, rendered = self.views(body)
                self.assertEqual([line for line in rendered if evidence.PERF_FIELD_RE.match(line)], [])
                self.assertEqual(
                    evidence.markdown_section(body, "Performance"),
                    self.rendered_boundary_section(body, "Performance"),
                )

    def test_the_refusal_names_the_underline_rather_than_asking_for_the_numbers(self) -> None:
        # What #1723 gets: not a section that reads, but a refusal that says
        # what the page is doing with the lines and what to change. Asking for
        # measurements the author already wrote is the misleading part.
        evidence = self.evidence()
        for underline in self.UNDERLINES:
            body = f"## Performance\n\n{self.PARAGRAPH_FIELDS}{underline}\n\n## Risks\n\nNone.\n"
            with self.subTest(underline=underline):
                self.assertTrue(evidence._perf_underlined_measurement(body))
                refusal = evidence._hand_completion_refusal(body, self.PERF_ITEM, self.PERF_ITEM)
                self.assertIn("read as a heading", refusal)
                self.assertIn("blank line", refusal)
                # The note must not name `---` for a body underlined with `===`.
                self.assertNotIn("`---`", refusal)

    def test_an_unfilled_section_is_refused_without_the_underline_note(self) -> None:
        # The note is about one shape, so a section that really carries no
        # measurements must not be told to move a rule it does not have --
        # including one whose underlined heading is a heading the author meant.
        evidence = self.evidence()
        for body in (
            "## Performance\n\nNot measured on this head yet.\n",
            "## Performance\n\nBefore Summary: p50 launch latency 900 ms\n\n---\n",
            "## Performance\n\nNotes on the method\n---\n\nNot measured yet.\n",
        ):
            with self.subTest(body=body[:48]):
                self.assertFalse(evidence._perf_underlined_measurement(body))
                refusal = evidence._hand_completion_refusal(body, self.PERF_ITEM, self.PERF_ITEM)
                self.assertNotIn("read as a heading", refusal)

    def test_a_rule_that_cannot_underline_anything_still_leaves_the_numbers_readable(self) -> None:
        # `- - -` is a thematic break and nothing else -- dashes with spaces
        # between them underline no line -- so it ends the section below the
        # measurements and both views still read them.
        body = f"## Performance\n\n{self.PARAGRAPH_FIELDS}- - -\n\n## Risks\n\nNone.\n"
        self.assertIsNotNone(run_contributor._perf_numbers(body, self.PERF_ITEM))
        written, rendered = self.views(body)
        self.assertEqual(written, rendered)

    def test_a_dash_rule_a_blank_line_below_the_measurements_still_ends_the_section(self) -> None:
        # The other half of the same rule: with a blank line above it the run of
        # dashes underlines nothing and is the rule the author meant. Dropping
        # an After that sits below it is what both views did before this and
        # what both views do now.
        for underline in ("---", "-----", "- - -"):
            body = (
                f"## Performance\n\nBefore Summary: p50 launch latency 900 ms\n\n{underline}\n\n"
                "After Summary: p50 launch latency 410 ms\n"
            )
            with self.subTest(underline=underline):
                self.assertIsNone(run_contributor._perf_numbers(body, self.PERF_ITEM))
                written, rendered = self.views(body)
                self.assertEqual(written, rendered)
                self.assertNotIn("After Summary: p50 launch latency 410 ms", "\n".join(written))

    def test_a_rule_or_heading_inside_a_block_does_not_end_the_section(self) -> None:
        # A rule under a bullet and a heading inside a quote belong to the
        # block that holds them. Reading either as the end of the section
        # drops the measurement below it, which is the direction that refuses
        # a body a reader can see whole.
        for name, nested in (
            ("a rule under a bullet", "- a note\n\n  ---\n\n- another note\n"),
            ("a rule inside a quote", "> quoting an older PR\n>\n> ---\n"),
            ("a heading inside a quote", "> quoting an older PR\n>\n> ## Performance\n"),
        ):
            body = (
                "## Performance\n\n- Before Summary: p50 launch latency 900 ms\n\n"
                f"{nested}\n- After Summary: p50 launch latency 410 ms\n"
            )
            with self.subTest(case=name):
                self.assertIsNotNone(run_contributor._perf_numbers(body, self.PERF_ITEM))
                written, _ = self.views(body)
                self.assertIn("- After Summary: p50 launch latency 410 ms", written)

    def test_a_setext_heading_keeps_hashes_it_was_never_written_with(self) -> None:
        # Emitting it as the author's own lines reads as more faithful and
        # loosens two gates (#1723, round 2): the split pushes a disclaimer out
        # of the window that binds a count to a run, and a `Before:` line under
        # an underline becomes a measurement. A heading is one line with
        # hashes, whatever made it one, so a statement still ends there.
        #
        # Both underlines end a section now -- `===` makes an h1 and `---` an
        # h2, and a section ends at either (#1734) -- so the hashes are read on
        # the whole body: no setext heading sits inside a section to be read
        # there.
        body = (
            "## Performance\n\nTwo lines\nunder one rule\n===\n\nplain text\n\n"
            "## Aside\n\n### Hashed\n"
        )
        self.assertIn("# Two lines under one rule", self.evidence()._rendered_lines(body))
        self.assertEqual(self.evidence()._rendered_lines(body, "Performance"), [])
        self.assertEqual(self.evidence()._rendered_lines(body, "Aside"), ["### Hashed"])
        underlined = "## Performance\n\nUnderlined heading\n---\n\nbelow\n"
        self.assertEqual(self.evidence()._rendered_lines(underlined, "Performance"), [])

    # The shapes above, written out, because the properties below read this
    # file's string literals and an f-string built at run time is not one.
    UNDERLINED = (
        "## Performance\n\nBefore: 900 ms\nAfter: 410 ms\n---\n\n## Risks\n\nNone.\n",
        "## Performance\n\nBefore: 900 ms\nAfter: 410 ms\n-----\n\n## Risks\n\nNone.\n",
        "## Performance\n\nBefore: 900 ms\n\n-----\n\nAfter: 410 ms\n",
        "## Validation\n\n`swift test` passed\n===\n\n## Risks\n\nNone.\n",
        "## Evidence Status\n\n- [complete] one -- proof\n- - -\n\n## Risks\n\nNone.\n",
    )

    def source_bodies(self) -> list[str]:
        """Every string literal in this file that carries a section heading."""
        return sorted(
            {
                node.value
                for node in ast.walk(ast.parse(Path(__file__).read_text(encoding="utf-8")))
                if isinstance(node, ast.Constant)
                and isinstance(node.value, str)
                and "## " in node.value
            }
        )

    def rendered_boundary_section(self, body: str, heading: str) -> str | None:
        """The section text the rendered span's boundary implies, sliced from the body.

        Built out of the rendered read and nothing else, so asserting the
        written read returns the same string is a check that one boundary
        serves both rather than a restatement of one of them.

        `None` where the question does not arise: no rendered section, no
        literal `## <heading>` line for the written read to find, or the two
        reads finding their heading on different lines -- which is a
        difference about where a section starts, not where it ends.
        """
        evidence = self.evidence()
        lines = evidence.MARKDOWN_LINE_ENDING_RE.split(body)
        tokens = evidence.MARKDOWN.parse(evidence.MARKDOWN_LINE_ENDING_RE.sub("\n", body))
        # A revision without the unclosed-fence line takes two arguments and
        # returns two values. Reading it either way keeps this property a
        # failure on such a revision rather than an error.
        try:
            span = evidence._rendered_section_span(tokens, heading, lines)
        except TypeError:
            span = evidence._rendered_section_span(tokens, heading)
        if span is not None and len(span) == 2:
            span = (*span, None)
        literal = re.search(rf"(?mi)^## {re.escape(heading)}\n", body)
        if span is None or literal is None:
            return None
        line_starts = [0] + [end.end() for end in evidence.MARKDOWN_LINE_ENDING_RE.finditer(body)]
        opened = tokens[span[0] - 3]
        if opened.map[0] != bisect.bisect_right(line_starts, literal.start()) - 1:
            return None
        stop = tokens[span[1]].map[0] if span[1] < len(tokens) else len(line_starts)
        if span[2] is not None:
            # An unclosed fence stops the section partway through one token, so
            # the line the rendered read reports beats the token it sits in.
            stop = min(stop, span[2])
        begin, end = (
            line_starts[line] if line < len(line_starts) else len(body)
            for line in (opened.map[1], stop)
        )
        return body[begin:end].strip()

    def test_the_written_read_ends_every_section_where_the_rendered_span_does(self) -> None:
        # The property, over this file's own fixtures: hundreds of bodies
        # people wrote to exercise these readers, each read at every heading a
        # reader reads. On main the literal and the parser part company on the
        # setext shapes above; here they cannot.
        bodies, checked = self.source_bodies(), 0
        self.assertGreater(len(bodies), 100)
        for body in bodies:
            for heading in self.READER_HEADINGS:
                expected = self.rendered_boundary_section(body, heading)
                if expected is None:
                    continue
                checked += 1
                with self.subTest(body=body[:50], heading=heading):
                    self.assertEqual(self.evidence().markdown_section(body, heading), expected)
        self.assertGreater(checked, 100)

    def test_no_section_a_reader_reads_carries_a_boundary_of_its_own(self) -> None:
        # The same property from the other side, and the one a caller depends
        # on: whatever comes back is one section. A run of dashes left inside
        # it is a rule the read was meant to stop at.
        evidence = self.evidence()
        for body in self.source_bodies():
            for heading in self.READER_HEADINGS:
                section = evidence.markdown_section(body, heading)
                if not section:
                    continue
                with self.subTest(body=body[:50], heading=heading):
                    self.assertEqual(
                        [
                            token.type
                            for token in evidence.MARKDOWN.parse(section)
                            if self.closes_a_section(token)
                        ],
                        [],
                    )

    def test_the_raster_delivery_script_keeps_its_helpers_import_inside_a_function(self) -> None:
        # `_helpers` imports the markdown parser now. The delivery script's own
        # entry point declares no pin for it and does not need one: its
        # `--fetch` path never reaches `evidence_section`, and that holds only
        # while the import stays where it is.
        source = (
            REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "review_evidence.py"
        ).read_text(encoding="utf-8")
        module_level = {
            name.name
            for node in ast.parse(source).body
            for name in (node.names if isinstance(node, (ast.Import, ast.ImportFrom)) else [])
        }
        self.assertNotIn("_helpers", module_level)
        self.assertEqual(
            [
                node.module
                for node in ast.walk(ast.parse(source))
                if isinstance(node, ast.ImportFrom) and node.module == "_helpers"
            ],
            ["_helpers"],
        )


class AnH1EndsASectionForTheContributorReadTests(unittest.TestCase):
    """A top-level h1 ends a section, so a rewrite of the one above it leaves it alone (#1734).

    `is_section_boundary` answered `False` for an h1, and every reader and
    writer of a section asks it, so they were consistent and wrong together:
    an author's `# Release blockers` under `## Evidence Status` read as a block
    inside that section. The rewrite then carried the heading into
    `## Evidence Notes` and dropped the `- [blocked]` bullet under it, which a
    status rewrite replaces with the entries in hand -- #1725's harm, back for
    any h1 section after Evidence Status, and silent.

    The predicate is two questions rather than one. `is_section_heading` is the
    level a section is addressed at, a top-level h2, because `markdown_section`
    finds its heading with a literal `^## ` anchor; `is_section_boundary` is
    where a section stops, a top-level h1 or h2 or a dash rule. Answering the
    first with the second would match `# Evidence Status` as the section for
    the rendered read while the written read found nothing under that name.
    """

    ITEM = "unit tests"
    BLOCKERS = (
        "# Release blockers\n"
        "- [blocked] the signing profile is missing\n\n"
        "The profile lives on the laptop and the hosted lane cannot see it."
    )

    def meta(self) -> str:
        entry = {
            "index": 1,
            "item": self.ITEM,
            "status": "pending-ci",
            "detail": "the lane has not run yet",
            "kind": "test",
        }
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def status(self) -> str:
        return f"## Evidence Status\n\n- [pending-ci] {self.ITEM} -- the lane has not run yet\n\n"

    def body(self) -> str:
        return (
            self.meta()
            + self.status()
            + self.BLOCKERS
            + "\n\n## Validation\n- local unit tests passed\n"
        )

    def evidence(self):
        return sys.modules["evidence"]

    def assert_h1_section_survives(self, written: str) -> None:
        """The author's section, byte for byte, and no notes section holding it."""
        self.assertIn(self.BLOCKERS, written)
        self.assertNotIn("## Evidence Notes", written)

    def test_the_lane_writer_leaves_the_h1_section_and_its_blocked_bullet_alone(self) -> None:
        # The reproduction from the issue, through the writer a lane run uses.
        # At the merge base the bullet is gone from the output entirely.
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            written = self.evidence().update_evidence_entries(
                self.body(), {1: {"status": "complete", "detail": "10 passed"}}
            )
        self.assertEqual(spoke.getvalue(), "")
        self.assert_h1_section_survives(written)
        self.assertIn(f"- [complete] {self.ITEM} -- 10 passed", written)
        # A second write over the first moves nothing.
        self.assertEqual(
            self.evidence().update_evidence_entries(
                written, {1: {"status": "complete", "detail": "10 passed"}}
            ),
            written,
        )

    def test_the_factory_writer_leaves_the_h1_section_and_its_blocked_bullet_alone(self) -> None:
        # The same body through the other writer of this section. Both come
        # through `write_evidence_status_section`, and a test on one of them is
        # a test that the pair was routed, not that the pair agrees.
        model_body = (
            "## Summary\n\n- did the thing\n\n"
            + self.status()
            + self.BLOCKERS
            + "\n\n## Validation\n- local unit tests passed\n"
        )
        written, errors = run_contributor.render_execution_summary_body(
            model_body,
            requested_evidence=[self.ITEM],
            evidence_complete=["1 -- 10 passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(errors, [])
        self.assert_h1_section_survives(written)
        self.assertIn(f"- [complete] {self.ITEM} -- 10 passed", written)

    def test_the_write_leaves_every_heading_in_the_order_the_author_wrote_it(self) -> None:
        # Nothing moves, the machine's own section included. A rewrite replaces
        # the section where it stands, so a shorter cut cannot lift
        # `## Evidence Status` out from under the author's h1 and land it at
        # the placement point -- which is what it did until the write learned
        # to re-insert at the offset it cut from (#1734, round 2).
        body = self.body()
        written = self.evidence().update_evidence_entries(
            body, {1: {"status": "complete", "detail": "10 passed"}}
        )
        headings = ("## Evidence Status", "# Release blockers", "## Validation")
        self.assertEqual(
            [heading for heading in headings if heading in written],
            sorted((h for h in headings if h in written), key=written.index),
        )
        self.assertEqual(
            [heading for heading in headings if heading in body],
            sorted((h for h in headings if h in body), key=body.index),
        )
        # And a second write over the first is a fixed point.
        self.assertEqual(
            self.evidence().update_evidence_entries(
                written, {1: {"status": "complete", "detail": "10 passed"}}
            ),
            written,
        )

    def test_the_written_read_stops_before_a_top_level_h1(self) -> None:
        self.assertEqual(
            sys.modules["_helpers"].markdown_section(self.body(), "Evidence Status"),
            f"- [pending-ci] {self.ITEM} -- the lane has not run yet",
        )

    def test_the_rendered_span_ends_at_the_h1(self) -> None:
        evidence = self.evidence()
        body = self.body()
        lines = evidence.MARKDOWN_LINE_ENDING_RE.split(body)
        tokens = evidence.MARKDOWN.parse(body)
        span = evidence._rendered_section_span(tokens, "Evidence Status", lines)
        self.assertIsNotNone(span)
        stop = tokens[span[1]]
        self.assertEqual((stop.type, stop.tag), ("heading_open", "h1"))
        self.assertEqual(lines[stop.map[0]], "# Release blockers")

    BOUNDARIES = {
        "an atx h1": ("# Release blockers\n", True),
        "an atx h2": ("## Release blockers\n", True),
        "a setext h1": ("Release blockers\n===\n", True),
        "a setext h2": ("Release blockers\n---\n", True),
        "a dash rule": ("---\n", True),
        "a long dash rule": ("-----\n", True),
        "an atx h3": ("### Release blockers\n", False),
        "a star rule": ("***\n", False),
        "an underscore rule": ("___\n", False),
        "an h1 in a closed fence": ("```markdown\n# Release blockers\n```\n", False),
        "an h1 inside a list item": ("- a bullet\n\n  # Release blockers\n", False),
    }

    def test_the_predicate_answers_for_every_shape_a_section_can_end_on(self) -> None:
        helpers = sys.modules["_helpers"]
        for name, (markup, ends_it) in self.BOUNDARIES.items():
            body = f"## Evidence Status\n\nunit tests passed.\n\n{markup}\nafter\n"
            with self.subTest(shape=name):
                tokens = helpers.MARKDOWN.parse(body)
                self.assertEqual(
                    any(
                        token.map
                        and token.map[0] >= 4
                        and helpers.is_section_boundary(token)
                        for token in tokens
                    ),
                    ends_it,
                )
                self.assertEqual(
                    helpers.markdown_section(body, "Evidence Status") == "unit tests passed.",
                    ends_it,
                )

    def test_the_h1_shapes_end_a_section_exactly_where_the_h2_shapes_do(self) -> None:
        # The pair rule, asserted as a symmetry rather than a list: for every
        # way of writing a heading, the read's answer for the h1 form is the
        # answer it gives for the h2 form. A predicate that grew a special case
        # for one level fails here even where no fixture below names the shape.
        helpers = sys.modules["_helpers"]
        for name, one, two in (
            ("atx at column 0", "# Release blockers", "## Release blockers"),
            ("atx indented three spaces", "   # Release blockers", "   ## Release blockers"),
            ("atx with no space after the hashes", "#Release blockers", "##Release blockers"),
            ("setext underline", "Release blockers\n===", "Release blockers\n---"),
            ("inside a closed fence", "```\n# Release blockers\n```", "```\n## Release blockers\n```"),
        ):
            with self.subTest(shape=name):
                sections = [
                    helpers.markdown_section(
                        f"## Evidence Status\n\nunit tests passed.\n\n{markup}\n\nafter\n",
                        "Evidence Status",
                    )
                    for markup in (one, two)
                ]
                self.assertEqual(
                    sections[0] == "unit tests passed.", sections[1] == "unit tests passed."
                )

    # Codex's reproducing body for the regression the boundary opened, kept as
    # it was written: an unclosed `<pre>` below the author's h1.
    HIDDEN_PLACEMENT_BODY = (
        "This change fixes the section rewrite so evidence stays accurate before review.\n\n"
        "## Mergeability\n\n"
        "- Surface: agent-runtime\n"
        "- User-facing behavior changed: no\n"
        "- Non-happy paths considered: malformed bodies\n"
        "- Release/ops preconditions: none\n"
        "- Residual risk or follow-up: none\n\n"
        "## Evidence Status\n\n- [pending-ci] `swift test` passes -- waiting\n\n"
        "# Release blockers\n\n<pre>\nnever closed\n"
    )

    # The same body with no `## Evidence Status` section at all. Where the
    # section exists it is replaced where it stands, so the placement question
    # never arises; this is the shape where it does -- a new section, and
    # nowhere visible to put it.
    NO_SECTION_PLACEMENT_BODY = HIDDEN_PLACEMENT_BODY.replace(
        "## Evidence Status\n\n- [pending-ci] `swift test` passes -- waiting\n\n", ""
    )

    def test_a_write_over_the_author_s_own_section_lands_where_the_page_shows_it(self) -> None:
        # Codex's reproducing body, and the answer it gets now. The regression
        # was the cut going short and the re-insert falling back to the end of
        # the body, inside a block that never closes. A section replaced where
        # it stands cannot travel there at all, so this body is written --
        # correctly, above the author's h1 -- rather than stood down.
        written, errors = run_contributor.render_execution_summary_body(
            self.HIDDEN_PLACEMENT_BODY,
            requested_evidence=["`swift test` passes"],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(errors, [])
        self.assertIn("- [complete] `swift test` passes -- 214 tests passed", written)
        self.assertLess(written.index("## Evidence Status"), written.index("# Release blockers"))
        self.assertIsNone(self.evidence()._placement_a_reader_cannot_see(written))

    def test_a_new_section_the_page_would_not_show_stands_the_body_down(self) -> None:
        # The postcondition's own case: no section to replace, and every
        # placement below the `<pre>` that never closes. Written there the
        # status would be in the source, absent from the page, and still
        # carried to every gate by the metadata comment.
        written, errors = run_contributor.render_execution_summary_body(
            self.NO_SECTION_PLACEMENT_BODY,
            requested_evidence=["`swift test` passes"],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(written, self.NO_SECTION_PLACEMENT_BODY)
        self.assertEqual(len(errors), 1)
        self.assertIn("is not a heading on the page", errors[0])
        self.assertIn("</pre>", errors[0])

    def test_the_lane_writer_stands_that_body_down_and_says_so(self) -> None:
        # The other writer, and the part that matters for a lane: the body
        # stands whole with its metadata, so the record and the page still say
        # the same thing, and the run says which block did it.
        evidence = self.evidence()
        body = self.meta() + self.NO_SECTION_PLACEMENT_BODY
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            written = evidence.update_evidence_entries(
                body, {1: {"status": "complete", "detail": "214 tests passed"}}
            )
        self.assertEqual(written, body)
        self.assertIn("is not a heading on the page", spoke.getvalue())

    def test_the_stood_down_body_still_fails_its_gates(self) -> None:
        # Why standing down is the right answer rather than a cost: the body
        # that goes forward is the author's, whose pending line both reads
        # still see, so the gates refuse it. The written body was the one that
        # passed them with nothing on the page to pass on.
        evidence = self.evidence()
        lines, unreadable = evidence._rendered_status_lines(self.HIDDEN_PLACEMENT_BODY)
        self.assertIsNone(unreadable)
        self.assertEqual(lines, ["[pending-ci] `swift test` passes -- waiting"])
        accounting, errors = run_contributor.validate_evidence_accounting(
            self.HIDDEN_PLACEMENT_BODY, ["`swift test` passes"], review_ci=[]
        )
        self.assertIsNotNone(
            run_contributor.review_evidence_gate_error("APPROVE", accounting, errors)
        )

    def test_a_write_the_page_does_show_is_not_stood_down(self) -> None:
        # The postcondition must not cost an ordinary write, so it is asked of
        # one: the same body with the block closed and a Validation heading
        # below it places the section where the page shows a heading. What is
        # asserted is the postcondition's own question -- whether the rendered
        # read finds the section this write placed -- and not the stricter
        # status read, which fails closed on the author's HTML block whatever
        # the placement does.
        evidence = self.evidence()
        written, errors = run_contributor.render_execution_summary_body(
            self.HIDDEN_PLACEMENT_BODY + "</pre>\n\n## Validation\n\n- ran it\n",
            requested_evidence=["`swift test` passes"],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(errors, [])
        self.assertIn("- [complete] `swift test` passes -- 214 tests passed", written)
        self.assertIsNone(evidence._placement_a_reader_cannot_see(written))
        # And the plain shape, with no HTML at all, still reads back whole.
        plain, plain_errors = run_contributor.render_execution_summary_body(
            "## Summary\n\n- did the thing\n\n"
            "## Evidence Status\n\n- [pending-ci] `swift test` passes -- waiting\n\n"
            "# Release blockers\n\n- [blocked] the signing profile is missing\n\n"
            "## Validation\n\n- ran it\n",
            requested_evidence=["`swift test` passes"],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(plain_errors, [])
        self.assertEqual(
            evidence._rendered_status_lines(plain)[0],
            ["[complete] `swift test` passes -- 214 tests passed"],
        )
        self.assertIn("- [blocked] the signing profile is missing", plain)

    OWNER_ITEM = "a note on whether the fixture state survives a relaunch"
    CUT_CONTRACT_BODY = (
        f"## Requested Evidence\n\n- {OWNER_ITEM}\n\n"
        "# Reviewer notes\n\n- a screenshot of the narrowed row\n\n"
        f"## Evidence Status\n\n- [complete] {OWNER_ITEM} -- checked: the fixture survived\n\n"
        "## Validation\n\n- ran the suite on this head\n"
    )

    def test_a_contract_an_h1_cuts_is_refused_rather_than_read_short(self) -> None:
        # The one direction where a shorter section buys an approval rather
        # than costing one, and the one place this change refuses instead of
        # narrowing. A shorter Evidence Status section holds fewer
        # completions, which can only cost one; a shorter `## Requested
        # Evidence` section is a shorter promise, so an item an author wrote
        # below their own h1 would stop being something the PR has to prove --
        # with the page still showing it in the list and nothing in the run
        # saying it had stopped counting.
        items, refusal = self.evidence().requested_evidence_contract(self.CUT_CONTRACT_BODY)
        self.assertEqual(items, [])
        self.assertIsNotNone(refusal)
        self.assertIn("## Requested Evidence", refusal)
        self.assertIn("line 5", refusal)
        self.assertIn("# Reviewer notes", refusal)

    def test_an_h2_ends_the_contract_silently_as_it_always_has(self) -> None:
        # The control, and the boundary of the refusal: a heading at the
        # section's own level reads as the next section to every reader, the
        # author included, so it ends the contract without a word -- which it
        # did before any of this.
        items, refusal = self.evidence().requested_evidence_contract(
            self.CUT_CONTRACT_BODY.replace("# Reviewer notes", "## Reviewer notes")
        )
        self.assertEqual(items, [self.OWNER_ITEM])
        self.assertIsNone(refusal)

    def test_a_setext_h1_cuts_the_contract_too(self) -> None:
        # An underline of equals signs is an h1 on the page; a rule that only
        # counted `#` would let the same item vanish under it.
        items, refusal = self.evidence().requested_evidence_contract(
            self.CUT_CONTRACT_BODY.replace("# Reviewer notes", "Reviewer notes\n==============")
        )
        self.assertEqual(items, [])
        self.assertIsNotNone(refusal)
        self.assertIn("Reviewer notes", refusal)

    def test_a_contract_cut_by_a_heading_a_runaway_fence_hides_is_refused_too(self) -> None:
        # In response to the confirmation pass. The section's end can come from
        # the repaired parse -- a fence with no closing line hides every
        # heading below it, and the reader blanks the opener and asks again --
        # so a rule that looked for an h1 token in the body as parsed found
        # none and let the cut through. The refusal asks what the two readings
        # of the section list instead, which reaches the repaired cut without
        # knowing it exists.
        helpers = sys.modules["_helpers"]
        body = "## Blocked By\n\n- #101\n\n```markdown\n# Reviewer notes\n\n- #202\n"
        numbers, refusal = helpers.blocked_by_contract(body)
        self.assertEqual(numbers, [])
        self.assertIsNotNone(refusal)
        self.assertIn("# Reviewer notes", refusal)

    def test_a_heading_that_drops_no_item_is_not_a_cut(self) -> None:
        # The other half, and the reason the question is about items rather
        # than about headings: an h1 an author writes below a complete
        # contract, with prose under it, takes nothing out of the contract.
        # Refusing there would strand an issue over a heading that costs
        # nothing.
        items, refusal = self.evidence().requested_evidence_contract(
            "## Requested Evidence\n\n- `swift test` passes\n\n"
            "# Design notes\n\nThis section asks for no evidence.\n\n"
            "## Blocked By\n\n- none\n"
        )
        self.assertEqual(items, ["`swift test` passes"])
        self.assertIsNone(refusal)

    def test_the_blocked_by_contract_refuses_on_the_same_shape(self) -> None:
        # The other contract, and the more dangerous one to read short: an
        # empty blocker list releases the issue.
        helpers = sys.modules["_helpers"]
        body = "## Blocked By\n\n- #101\n\n# Reviewer notes\n\n- #202\n"
        numbers, refusal = helpers.blocked_by_contract(body)
        self.assertEqual(numbers, [])
        self.assertIsNotNone(refusal)
        self.assertIn("## Blocked By", refusal)
        self.assertEqual(
            helpers.blocked_by_contract("## Blocked By\n\n- #101\n\n## Notes\n\n- #202\n"),
            ([101], None),
        )

    def test_an_h1_a_runaway_fence_hides_still_ends_the_section(self) -> None:
        # The third place the boundary is asked: a fence with no closing line
        # holds every heading below it, so the section's end is a line the
        # repaired parse finds rather than a token this one carries. Both reads
        # stop at the author's h1, which is what keeps the section the writer
        # rewrites the section the reader reported.
        evidence = self.evidence()
        body = (
            "## Evidence Status\n\n- [pending-ci] unit tests -- the lane has not run yet\n\n"
            "```\nan excerpt whose fence never closes\n\n"
            "# Release blockers\n- [blocked] the signing profile is missing\n"
        )
        lines = evidence.MARKDOWN_LINE_ENDING_RE.split(body)
        span = evidence._rendered_section_span(evidence.MARKDOWN.parse(body), "Evidence Status", lines)
        self.assertIsNotNone(span)
        # Asserted before it is used as an index, so a revision that finds no
        # swallowed boundary fails here saying so rather than erroring.
        self.assertIsNotNone(span[2])
        self.assertEqual(lines[span[2]], "# Release blockers")
        written = sys.modules["_helpers"].markdown_section(body, "Evidence Status")
        self.assertNotIn("# Release blockers", written)
        self.assertNotIn("[blocked]", written)

    def test_an_h1_named_like_the_section_is_not_the_section_for_either_read(self) -> None:
        # Why the predicate is two and not one. `markdown_section` finds its
        # heading with a literal `^## ` anchor, so a rendered read that took
        # `is_section_boundary` for the level would match `# Evidence Status`
        # as the section while the written read found nothing -- the split the
        # pair exists to prevent, arriving by way of the fix for it.
        evidence = self.evidence()
        body = "# Evidence Status\n\n- [complete] unit tests -- 10 passed\n\n## Validation\n- ran it\n"
        self.assertEqual(sys.modules["_helpers"].markdown_section(body, "Evidence Status"), "")
        self.assertIsNone(
            evidence._rendered_section_span(
                evidence.MARKDOWN.parse(body),
                "Evidence Status",
                evidence.MARKDOWN_LINE_ENDING_RE.split(body),
            )
        )

    def test_the_two_questions_are_asked_of_the_two_readers(self) -> None:
        # The call sites, named: the rendered read asks which heading is the
        # section once -- through `section_heading_index`, the same call the
        # written read makes, so the two cannot find it in different places
        # (#1730) -- and asks `is_section_boundary` where the section stops.
        # Swapping either reintroduces one of the two bugs, so the source is
        # checked rather than only the behaviour.
        scripts = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
        source = (scripts / "evidence.py").read_text(encoding="utf-8")
        span = source[source.index("def _rendered_section_span") :]
        span = span[: span.index("\ndef ", 1)]
        self.assertEqual(span.count("section_heading_index("), 1)
        self.assertEqual(span.count("is_section_heading("), 0)
        self.assertEqual(span.count("is_section_boundary("), 2)
        # And the level question is asked once, where the shared finder is.
        helpers = (scripts / "_helpers.py").read_text(encoding="utf-8")
        finder = helpers[helpers.index("def section_heading_index") :]
        finder = finder[: finder.index("\ndef ", 1)]
        self.assertEqual(finder.count("is_section_heading("), 1)


class NoReaderGainsAnAcceptanceFromABoundaryTests(unittest.TestCase):
    """What a wider section may and may not do to a reader (#1723, round 2).

    Asking one predicate where a section ends closes the disagreement that
    filed #1723, and it widens some sections: a setext underline is part of
    the heading it underlines, so the lines around it stay in the section they
    were written in. A wider section must not let a reader accept something it
    refused before -- the confirmation pass found two readers doing exactly
    that, both through the rendered read emitting an underlined heading as the
    author's own plain lines, which is why that emission is gone.

    These are those four findings, each as the body it was found on.
    """

    TEST_ITEM = "`swift test` passes"
    # `p50` is what makes the item a `perf` kind rather than an owner's note,
    # which is the classification the refusal path below turns on.
    PERF_ITEM = "p50 launch latency before and after"

    @staticmethod
    def write_refusal(helpers, body: str, heading: str) -> str | None:
        """The writer's reason for refusing, or None on a revision without one.

        A revision that has no such reason writes anyway, and the assertions
        below then fail on what the write did rather than erroring on a name
        it does not carry.
        """
        ask = getattr(helpers, "section_write_refusal", None)
        return ask(body, heading) if ask else None

    NOT_RUN_BODY = (
        "## Validation\n\n"
        "Ran `swift test` and it printed 214 tests passed.\n"
        "padding one\n"
        "padding two\n"
        "padding three\n"
        "These results were not run on this branch.\n"
        "---\n\n"
        "## Risks\n\nNone.\n"
    )

    def test_a_disclaimer_the_page_still_shows_still_refuses_the_statement(self) -> None:
        # Finding 1. The guard reads four lines past the run for a disclaimer.
        # Splitting an underlined heading into the lines it was written as put
        # the disclaimer on the fifth, and the statement completed against a
        # page that says the results are not from this branch.
        evidence = sys.modules["evidence"]
        self.assertIsNone(run_contributor._attested_test_statement(self.NOT_RUN_BODY, self.TEST_ITEM))
        # The underline made the whole paragraph a heading, so the section is
        # empty -- and empty to both views, which is the difference from the
        # revision that accepted here.
        self.assertEqual(evidence.markdown_section(self.NOT_RUN_BODY, "Validation"), "")
        self.assertEqual(evidence._rendered_lines(self.NOT_RUN_BODY, "Validation"), [])

    UNDERLINED_FIELD_BODY = (
        "## Performance\n\nMeasured on this head.\n\n"
        "Before: p50 launch 2.4s\n---\nAfter: p50 launch 1.2s\n"
    )

    def test_a_field_serving_as_its_own_boundary_does_not_complete(self) -> None:
        # Finding 2. The underline made `Before: launch 2.4s` a heading, so it
        # was the start of a new section to a reader; read as the line it was
        # written as it was also a `Before:` field to the gate, and being both
        # at once is what completed the item.
        evidence = sys.modules["evidence"]
        self.assertIsNone(run_contributor._perf_numbers(self.UNDERLINED_FIELD_BODY, self.PERF_ITEM))
        self.assertEqual(
            evidence._rendered_lines(self.UNDERLINED_FIELD_BODY, "Performance"),
            ["Measured on this head."],
        )
        self.assertEqual(
            evidence.markdown_section(self.UNDERLINED_FIELD_BODY, "Performance"),
            "Measured on this head.",
        )
        # And the refusal says which line the page took, rather than asking for
        # measurements that are sitting right there.
        self.assertIn(
            "read as a heading",
            evidence._hand_completion_refusal(self.UNDERLINED_FIELD_BODY, self.PERF_ITEM, self.PERF_ITEM),
        )

    BLOCKED_BY_BODY = "## Blocked By\n\n- #101\n\nsomething\n---\n\n- #202\n"
    # Bodies where a literal three-dash match and the page part company over a
    # number, so a second copy of the reader cannot agree with the first by
    # accident. Without these the pair test passed with the copy restored.
    BLOCKED_BY_DIVERGENT = (
        "## Blocked By\n\n- #101\n\n#202 blocks this too\n---\n\n- #303\n",
        "## Blocked By\n\n- #101\n\n-----\n\n- #202\n",
        "## Blocked By\n\n```\n---\n```\n\n- #202\n",
    )

    def test_both_readers_of_blocked_by_answer_alike_on_every_fixture(self) -> None:
        # Finding 3. The two carried character-identical copies, which agree
        # until one of them changes. They are one function now, and the
        # property is over every body this file holds rather than over the one
        # shape that caught them.
        bodies = [
            self.BLOCKED_BY_BODY,
            *self.BLOCKED_BY_DIVERGENT,
            *OneSectionBoundaryForBothViewsTests().source_bodies(),
        ]
        self.assertGreater(len(bodies), 100)
        for body in bodies:
            with self.subTest(body=body[:50]):
                self.assertEqual(
                    run_contributor.blocked_by_contract(body)[0],
                    sync_execution_state.blocked_by_contract(body)[0],
                )
        # The underline makes `something` a heading, so the section stops there
        # and #202 is in the section below it -- the answer the merge base gave
        # through its literal match, now the answer both readers give.
        self.assertEqual(run_contributor.blocked_by_contract(self.BLOCKED_BY_BODY)[0], [101])

    ORPHAN_BODY = "## Evidence Status\n\n- [x] one - done\n\nnote\n---\n- [x] two - done\n"

    def test_the_read_and_the_rewrite_stop_in_the_same_place(self) -> None:
        # Finding 4. The read counted `- [x] two - done` and the rewrite cut
        # above it, so a completion the gate had counted survived outside every
        # section. They stop in one place now: the read does not count that
        # line, and the rewrite leaves it where its author put it.
        helpers = sys.modules["_helpers"]
        section = helpers.markdown_section(self.ORPHAN_BODY, "Evidence Status")
        self.assertEqual(section, "- [x] one - done")
        rewritten = helpers.insert_markdown_section(
            self.ORPHAN_BODY, "Evidence Status", "- [x] three - done"
        )
        self.assertNotIn("- [x] one - done", rewritten)
        self.assertIn("- [x] two - done", rewritten)
        self.assertEqual(
            helpers.markdown_section(rewritten, "Evidence Status"), "- [x] three - done"
        )

    def test_a_rewrite_round_trips_and_orphans_nothing_over_every_fixture(self) -> None:
        # The property behind finding 4: whatever the read counts, the write
        # replaces. A line left behind is a line the next read cannot find.
        helpers = sys.modules["_helpers"]
        content = "- [x] the written line - done"
        checked = 0
        for raw in OneSectionBoundaryForBothViewsTests().source_bodies():
            # As the writer sees it: `insert_markdown_section` trims first, and
            # a leading blank line moves every line under it.
            body = raw.strip()
            for heading in OneSectionBoundaryForBothViewsTests.READER_HEADINGS:
                section = helpers.markdown_section(body, heading)
                if not section:
                    continue
                checked += 1
                remainder = helpers.strip_markdown_section(body, heading)
                rewritten = helpers.insert_markdown_section(body, heading, content)
                refusal = self.write_refusal(helpers, body, heading)
                with self.subTest(body=body[:50], heading=heading):
                    if refusal is not None:
                        # One of three: the heading the parser reads as code,
                        # whose closer a write would eat; a block that never
                        # closed and so hides where the section ends; or an
                        # end only the repaired parse can see, which a cut
                        # would reach by deleting a fence opener. The body
                        # stands and the reason names which.
                        self.assertEqual(rewritten, body)
                        self.assertEqual(remainder, body)
                        self.assertTrue(
                            "inside the code block" in refusal
                            or "runs to the end of the body" in refusal
                            or "only a repaired parse can see" in refusal,
                            refusal,
                        )
                        continue
                    self.assertEqual(helpers.markdown_section(rewritten, heading), content)
                    for line in section.splitlines():
                        # Only lines that occur once, so a line the body
                        # repeats elsewhere is not read as a leftover.
                        if line.strip() and body.count(line) == 1:
                            self.assertNotIn(line, remainder)
        self.assertGreater(checked, 100)

    FENCED_BOUNDARY_BODY = (
        "## Performance\n\n"
        "```\nquoted report\n## Risks\n```\n\n"
        "Before Summary: p50 launch latency 900 ms\n"
        "After Summary: p50 launch latency 410 ms\n"
    )

    def test_a_heading_inside_a_fence_stops_ending_the_section(self) -> None:
        # The one acceptance this change adds, on the record rather than by
        # accident. A `##` heading or a `---` rule inside a code fence is code
        # to the page and was the end of the section to a literal match, so
        # measurements written below a quoted report went unread. The reverse
        # of the same blindness is worse: a fenced rule truncated the section a
        # reader of record saw while a person saw the section whole.
        self.assertIsNotNone(run_contributor._perf_numbers(self.FENCED_BOUNDARY_BODY, self.PERF_ITEM))
        self.assertIn(
            "After Summary: p50 launch latency 410 ms",
            sys.modules["evidence"]._rendered_lines(self.FENCED_BOUNDARY_BODY, "Performance"),
        )

    RUNAWAY = "```\nthe run log, and the fence is never closed\n"

    def test_an_unclosed_fence_does_not_put_a_later_section_inside_this_one(self) -> None:
        # A fence with no closing line runs to the end of the body, so a
        # Performance section holding one holds every section below it and the
        # read took a later `## Validation`'s measurements for this section's.
        # Nobody reads a body with a runaway fence that way.
        helpers, evidence = sys.modules["_helpers"], sys.modules["evidence"]
        # Both lines a literal match stopped at, and a fence closed by a run
        # too short to close it -- which is why closedness comes from the
        # token rather than from matching the markup against a later line.
        for opener, divider in (
            ("```", "## Validation"),
            ("```", "---"),
            ("~~~", "## Validation"),
            ("````", "## Validation\n\n```"),
            # A run too short to close the fence it follows leaves a second
            # fence open above the heading, so blanking one opener is not
            # enough and the repair repeats.
            ("````", "```\n\n## Validation"),
        ):
            runaway = f"{opener}\nthe run log, and the fence is never closed\n"
            body = (
                f"## Performance\n\n{runaway}\n{divider}\n\n"
                "- Before Summary: p50 launch latency 900 ms\n"
                "- After Summary: p50 launch latency 410 ms\n"
            )
            with self.subTest(opener=opener, divider=divider.splitlines()[0]):
                self.assertIsNone(run_contributor._perf_numbers(body, self.PERF_ITEM))
                # The section stops above the hidden heading, so neither view
                # carries a measurement written under it. The fence's own lines
                # above that heading stay, which is why this is stated as the
                # measurements being absent rather than as an exact slice.
                section = helpers.markdown_section(body, "Performance")
                self.assertIn("the run log, and the fence is never closed", section)
                self.assertNotIn("Before Summary", section)
                self.assertNotIn("After Summary", section)
                rendered = evidence._rendered_lines(body, "Performance")
                self.assertIn("the run log, and the fence is never closed", rendered)
                self.assertEqual([line for line in rendered if evidence.PERF_FIELD_RE.match(line)], [])

    def test_an_unclosed_fence_does_not_widen_the_status_section(self) -> None:
        # The same shape in Evidence Status. The `[x]` line belongs to the
        # Blockers section a person reads below the runaway fence.
        body = f"## Evidence Status\n\n{self.RUNAWAY}\n## Blockers\n\n- [x] None\n"
        section = sys.modules["_helpers"].markdown_section(body, "Evidence Status")
        self.assertEqual(section, self.RUNAWAY.strip())
        self.assertNotIn("- [x] None", section)

    def test_a_statement_still_reads_from_the_whole_body_under_a_runaway_fence(self) -> None:
        # The attested reader reads the body rather than one section, so an
        # unclosed fence changes nothing for it. Pinned because narrowing the
        # section is not the same as narrowing every reader, and a change that
        # did both here would refuse a statement the merge base accepts.
        body = (
            f"## Validation\n\n{self.RUNAWAY}\n## Notes\n\n"
            "Ran `cd web-next && pnpm test` and it printed 214 tests passed.\n"
        )
        self.assertEqual(
            run_contributor._attested_test_statement(body, "`pnpm test` in `web-next` passes"),
            "Ran `cd web-next && pnpm test` and it printed 214 tests passed.",
        )

    def test_a_closed_fence_holding_a_boundary_still_does_not_end_the_section(self) -> None:
        # The acceptance is for closed fences and stays there: the page shows a
        # fenced `##` or `---` as code, so measurements written below a quoted
        # report are in the section a reader sees.
        for fenced in ("```\nquoted report\n## Risks\n```", "```\nquoted report\n---\n```"):
            body = (
                f"## Performance\n\n{fenced}\n\n"
                "Before Summary: p50 launch latency 900 ms\n"
                "After Summary: p50 launch latency 410 ms\n"
            )
            with self.subTest(fenced=fenced[:24]):
                self.assertIsNotNone(run_contributor._perf_numbers(body, self.PERF_ITEM))

    # The seam the write-path refusal sits on: a section with nothing after it
    # ends at the end of the body and is written, and only a heading the parser
    # reads as code is refused.
    WRITE_SEAM = {
        # The block's kind decides, not where the section sits. A fence shows
        # the rest of the body as code, so the section really does run to the
        # end and the cut is right; a comment or a `<pre>` hides what follows,
        # so the cut is over text nobody can see.
        "a last section with an unclosed fence": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n```\nthe log, never closed\n", False
        ),
        "a last section with an unclosed comment": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n<!-- a reviewer note\n", True
        ),
        "a last section with an unclosed <pre>": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n<pre>\nthe log\n", True
        ),
        "a last section with an unclosed <script>": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n<script>\nthe log\n", True
        ),
        "a last section with an unclosed CDATA": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n<![CDATA[\nthe log\n", True
        ),
        "a last section ending in a kind-7 tag that starts like <pre": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n- [x] one\n\n<prefix>\n", False
        ),
        "an unclosed comment hiding the sections below it": (
            "## Evidence Status\n\n- [x] one\n<!-- a reviewer note\n\n## Risks\n\nNone.\n", True
        ),
        "an unclosed <script> hiding the sections below it": (
            "## Evidence Status\n\n- [x] one\n\n<script>\nx\n\n## Risks\n\nNone.\n", True
        ),
        "an unclosed <![CDATA[ hiding the sections below it": (
            "## Evidence Status\n\n- [x] one\n\n<![CDATA[\nx\n\n## Risks\n\nNone.\n", True
        ),
        # A CRLF body's page is identical to the LF one, so nothing is hidden
        # and there is nothing to refuse -- the section just has to be found.
        "a CRLF body": (
            "## Summary\r\n\r\nnote\r\n\r\n## Evidence Status\r\n\r\n- [x] one\r\n\r\n## Risks\r\n\r\nNone.\r\n", False
        ),
        "a closed comment above the sections below it": (
            "## Evidence Status\n\n- [x] one\n\n<!-- a reviewer note -->\n\n## Risks\n\nNone.\n", False
        ),
        "a last section whose fenced example holds a fence": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n````md\n```\ninner\n```\n````\n", False
        ),
        "an open <details> at the end of the body": (
            "## Summary\n\nnote\n\n## Evidence Status\n\n<details>\n<summary>log</summary>\n", False
        ),
        "the factory's own metadata comment at the end": (
            "## Evidence Status\n\n- [x] one\n\n<!-- evidence-status:v1\n{}\n-->\n", False
        ),
        # Refusing since #1734 round 2: the end is a line only the repaired
        # parse can see, and a cut to it takes the fence's opening line along,
        # so the log below it comes back as live markdown.
        "a heading hidden inside a runaway fence": (
            "## Evidence Status\n\n```\nthe log, never closed\n\n## Risks\n\nNone.\n", True
        ),
        "a heading hidden and indented three spaces": (
            "## Evidence Status\n\n```\nthe log, never closed\n\n   ## Risks\n\nNone.\n", True
        ),
        "a heading hidden behind an underline": (
            "## Evidence Status\n\n```\nthe log, never closed\n\nRisks\n---\n\nNone.\n", True
        ),
        # Writing since #1730: a `##` line inside a fence is not a heading, so
        # the body has no section there, the write places a real one and the
        # example keeps its closing line.
        "a fenced heading the write no longer reads as one": (
            "## Summary\n\n```markdown\n## Evidence Status\n- [complete] the item -- proof\n```\n\n"
            "## Risks\n\nNone.\n", False
        ),
    }

    def test_a_write_refuses_only_where_the_end_is_a_guess(self) -> None:
        # Refusing too readily costs the lane its record of a run, so the seam
        # is pinned from both sides. A section with nothing after it ends at
        # the end of the body, whatever block the body ends inside; an end
        # only the repaired parse can see is not an end a writer may cut to,
        # though a reader may read to it; and a heading the parser reads as
        # code is an example rather than a section to refuse a write to, so a
        # body whose only copy is fenced gets a real section written beside it.
        helpers = sys.modules["_helpers"]
        for name, (body, refuses) in self.WRITE_SEAM.items():
            with self.subTest(case=name):
                refusal = self.write_refusal(helpers, body, "Evidence Status")
                self.assertEqual(refusal is not None, refuses, refusal)
                rewritten = helpers.insert_markdown_section(body, "Evidence Status", "- [x] written")
                if refuses:
                    self.assertEqual(rewritten, body)
                else:
                    self.assertEqual(
                        helpers.markdown_section(rewritten, "Evidence Status"), "- [x] written"
                    )
                # Whatever the answer, no section the body carried is lost.
                for heading in ("Summary", "Risks"):
                    if helpers.has_markdown_section(body, heading):
                        self.assertTrue(helpers.has_markdown_section(rewritten, heading), heading)

    # The five block openers CommonMark runs to the end of the document when
    # their closer never comes, with the reason each write refuses. The raw
    # HTML ones hide where the section ends; the fence's end is a heading only
    # the repair can see, which a reader may read to and a writer may not cut
    # to. Either way no section is lost, which is the property.
    RUNAWAY_OPENERS = {
        "<!-- a reviewer note": "runs to the end of the body",
        "<pre>": "runs to the end of the body",
        "<script>": "runs to the end of the body",
        "<![CDATA[": "runs to the end of the body",
        "```": "only a repaired parse can see",
    }

    def test_two_writes_under_a_block_that_never_closes_delete_no_section(self) -> None:
        # The class, not the instance. A fence was the shape round 3 fixed; a
        # raw HTML block of kinds 1 to 5 runs to the end of the body the same
        # way, and two ordinary writes through one deleted Blocked By and
        # Risks. Every kind either keeps all five or refuses before the first
        # cut, and a refusal names the missing closer and the opening line.
        helpers = sys.modules["_helpers"]
        headings = ("Summary", "Evidence Status", "Performance", "Blocked By", "Risks")
        for opener, reason in self.RUNAWAY_OPENERS.items():
            body = (
                "## Summary\n\ntext\n\n## Evidence Status\n\n- [complete] item -- proof\n"
                f"{opener}\n\n## Performance\n\nBefore: 1 ms\nAfter: 2 ms\n\n"
                "## Blocked By\n\n- none\n\n## Risks\n\nlow\n"
            )
            with self.subTest(opener=opener):
                refusal = self.write_refusal(helpers, body, "Evidence Status")
                self.assertIsNotNone(refusal, opener)
                self.assertIn(reason, refusal)
                self.assertRegex(refusal, r"line \d+")
                one = helpers.insert_markdown_section(body, "Evidence Status", "- [complete] item -- proof")
                two = helpers.insert_markdown_section(one, "Performance", "Before: 1 ms\nAfter: 2 ms")
                # Asked of the text, because under a block that never closes
                # the page shows none of these headings as headings -- before
                # the writes as much as after (#1730). The loss this is
                # against is a section leaving the body, not a section the
                # author hid; and no section may stop being shown.
                for heading in headings:
                    self.assertIn(f"## {heading}", two, heading)
                shown_before = {h for h in headings if helpers.has_markdown_section(body, h)}
                shown_after = {h for h in headings if helpers.has_markdown_section(two, h)}
                self.assertTrue(shown_before <= shown_after, (shown_before, shown_after))

    def test_an_unclosed_fence_at_the_end_writes_where_one_hiding_a_heading_refuses(self) -> None:
        # Two fence shapes with opposite answers, and they must not be one
        # case. A fence hiding a heading gives the section an end only the
        # repair can see: the reader reads to it, and the writer refuses,
        # because cutting there deletes the fence's opening line and shows the
        # log below as markdown. A fence with nothing after it hides no
        # heading, so the section runs to the end of the body and the write is
        # safe -- the page shows that text as code either way.
        helpers, evidence = sys.modules["_helpers"], sys.modules["evidence"]
        hiding = "## Evidence Status\n\n```\nthe log, never closed\n\n## Risks\n\nNone.\n"
        nothing_after = "## Summary\n\nnote\n\n## Evidence Status\n\n```\nthe log, never closed\n"
        for name, body, refuses in (("hiding a heading", hiding, True), ("nothing after", nothing_after, False)):
            with self.subTest(case=name):
                refusal = self.write_refusal(helpers, body, "Evidence Status")
                self.assertEqual(refusal is not None, refuses, refusal)
                written = helpers.insert_markdown_section(body, "Evidence Status", "- [x] written")
                if refuses:
                    # The body stands, the fence opener with it, and the read
                    # still stops at the heading the repair found.
                    self.assertEqual(written, body)
                    self.assertIn("```", written)
                    self.assertEqual(
                        helpers.markdown_section(body, "Evidence Status"), "```\nthe log, never closed"
                    )
                    continue
                self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "- [x] written")
                self.assertFalse(helpers.has_markdown_section(written, "Risks"))
        # And the repair is what tells them apart: for the first it reports a
        # boundary below the heading, for the second there is none to report.
        for body, boundary_below in ((hiding, True), (nothing_after, False)):
            lines = helpers.MARKDOWN_LINE_ENDING_RE.split(body)
            tokens = helpers.MARKDOWN.parse(helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", body))
            repaired = helpers.reparsed_without_runaway(tokens, lines)
            self.assertIsNotNone(repaired)
            heading_line = lines.index("## Evidence Status")
            found = any(
                token.map and token.map[0] > heading_line and helpers.is_section_boundary(token)
                for token in repaired
            )
            self.assertEqual(found, boundary_below, body[:40])
        # Which shows up as the section text: bounded for the first, to the end
        # of the body for the second.
        self.assertNotIn("## Risks", helpers.markdown_section(hiding, "Evidence Status"))
        self.assertIn("never closed", helpers.markdown_section(nothing_after, "Evidence Status"))

    def test_a_hidden_completion_does_not_complete_the_item(self) -> None:
        # Invisible text may refuse, never accept. A `[complete]` line below an
        # unclosed comment or `<pre>` is matched by the written reader and
        # rendered as nothing, and the item does not complete -- because since
        # #1721 a completion is the conjunction of the written and the rendered
        # readings, and the rendered reading of hidden text is empty. That
        # conjunction is what stops the written reader deciding on its own, so
        # it is pinned here rather than left to the readers that use it.
        evidence = sys.modules["evidence"]
        item = "a note on whether the fixture state survives a relaunch"
        line = f"- [complete] {item} -- checked: the fixture survived"
        for opener in ("<!-- hidden", "<pre>", "<script>"):
            body = f"## Evidence Status\n\n{opener}\n{line}\n"
            with self.subTest(opener=opener):
                # The written reader does see the line.
                self.assertIn(line, evidence.markdown_section(body, "Evidence Status"))
                # The rendered one does not, so nothing completes.
                self.assertEqual(evidence._rendered_lines(body, "Evidence Status"), [])
                accounting, errors = run_contributor.validate_evidence_accounting(body, [item], review_ci=[])
                self.assertNotIn(item, accounting.get("complete_items", []))
                self.assertIsNotNone(run_contributor.review_evidence_gate_error("APPROVE", accounting, errors))
        # A fenced line is not hidden -- the page shows a fence as code -- so
        # that shape is refused for its own reason, a code block under the
        # heading, and not by this one.
        fenced = f"## Evidence Status\n\n```\n{line}\n```\n"
        self.assertIn(line, evidence._rendered_lines(fenced, "Evidence Status"))
        accounting, errors = run_contributor.validate_evidence_accounting(fenced, [item], review_ci=[])
        self.assertNotIn(item, accounting.get("complete_items", []))
        # The control: the same line, visible, completes.
        visible = f"## Evidence Status\n\n{line}\n"
        accounting, errors = run_contributor.validate_evidence_accounting(visible, [item], review_ci=[])
        self.assertEqual(accounting.get("complete_items"), [item])
        self.assertIsNone(run_contributor.review_evidence_gate_error("APPROVE", accounting, errors))

    FENCED_EXAMPLE_BODY = (
        "## Summary\n\nwhat.\n\n```markdown\n## Mergeability\n- Surface: docs\n```\n\n"
        "## Validation\n\n- ok\n\n## Risks\n\nNone.\n"
    )

    UNTERMINATED_BLOCK_BODY = (
        "## Summary\n\nwhat.\n\n## Mergeability\n\n- Surface: docs\n<!-- a reviewer note\n\n"
        "## Risks\n\nNone.\n"
    )

    def test_a_refused_write_says_so_rather_than_returning_the_body(self) -> None:
        # A refusal that returns the body and logs nothing is a write the
        # caller believes happened, so the reason comes from the writer, once,
        # on the run's output. Asserting only that the body came back
        # unchanged would pass on the silent no-op this is named against.
        helpers = sys.modules["_helpers"]
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            out = helpers.insert_markdown_section(
                self.UNTERMINATED_BLOCK_BODY, "Mergeability", "- Surface: agent-runtime"
            )
        self.assertEqual(out, self.UNTERMINATED_BLOCK_BODY)
        self.assertIn("refusing to rewrite the `Mergeability` section", captured.getvalue())
        self.assertIn("runs to the end of the body", captured.getvalue())

    def test_a_write_to_a_body_whose_only_copy_is_fenced_places_a_real_section(self) -> None:
        # The refusal that is gone, and what replaced it. A `##` line inside a
        # fenced example is not a heading, so there is no section under it to
        # cut and nothing to refuse: the write places a real section and
        # leaves the example alone. That refusal was the cost of finding the
        # start by pattern, and the better answer was never to match there.
        helpers = sys.modules["_helpers"]
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            out = helpers.insert_markdown_section(
                self.FENCED_EXAMPLE_BODY, "Mergeability", "- Surface: agent-runtime"
            )
        self.assertEqual(captured.getvalue(), "")
        self.assertEqual(helpers.markdown_section(out, "Mergeability"), "- Surface: agent-runtime")
        self.assertIn("```markdown\n## Mergeability\n- Surface: docs\n```", out)
        for heading in ("Summary", "Validation", "Risks"):
            self.assertTrue(helpers.has_markdown_section(out, heading), heading)
        # A second write replaces what the first placed rather than adding a
        # third copy beside the example.
        again = helpers.insert_markdown_section(out, "Mergeability", "- Surface: docs")
        self.assertEqual(again.count("## Mergeability"), 2)
        self.assertEqual(helpers.markdown_section(again, "Mergeability"), "- Surface: docs")

    ITEM_FOR_WRITE = "a note on whether the fixture state survives a relaunch"

    def test_the_runtime_write_places_a_section_where_the_body_had_only_an_example(self) -> None:
        # The site that really reaches the writer:
        # `render_execution_summary_body` rewrites Evidence Status on the body
        # the model wrote. On a body whose only `## Evidence Status` is a
        # fenced example it used to return the body untouched with the reason
        # in its errors -- a good refusal, and one nobody should have needed:
        # the example is not a section, so the run now writes a real one
        # beside it and the PR carries its evidence (#1730).
        body = (
            "## Summary\n\nwhat.\n\n```markdown\n## Evidence Status\n- [complete] x -- proof\n```\n\n"
            "## Validation\n\n- ok\n"
        )
        rendered, errors = run_contributor.render_execution_summary_body(
            body,
            requested_evidence=[self.ITEM_FOR_WRITE],
            evidence_complete=["1 -- checked: the fixture survived"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(errors, [])
        helpers = sys.modules["_helpers"]
        self.assertIn(
            f"- [complete] {self.ITEM_FOR_WRITE} -- checked: the fixture survived",
            helpers.markdown_section(rendered, "Evidence Status"),
        )
        # The author's example keeps its fence, its line and its closer.
        self.assertIn("```markdown\n## Evidence Status\n- [complete] x -- proof\n```", rendered)
        # And the example's own completion is not the run's: the status the
        # gate reads is the one that was written.
        self.assertNotIn("x -- proof", helpers.markdown_section(rendered, "Evidence Status"))
        # The control: the same call on an ordinary body still writes.
        ordinary = "## Summary\n\nwhat.\n\n## Validation\n\n- ok\n"
        written, ok_errors = run_contributor.render_execution_summary_body(
            ordinary,
            requested_evidence=[self.ITEM_FOR_WRITE],
            evidence_complete=["1 -- checked: the fixture survived"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(ok_errors, [])
        self.assertIn(self.ITEM_FOR_WRITE, helpers.markdown_section(written, "Evidence Status"))

    def test_seeding_mergeability_seeds_a_body_whose_only_copy_is_a_fenced_example(self) -> None:
        # #1730, the issue this test was pinned for. `seed_mergeability_section`
        # asked `has_markdown_section`, which matched the `##` line inside the
        # fenced example, so it returned the body it was given, seeded nothing
        # and said nothing -- and the readiness gate then asked for the section
        # the runtime believed it had written. The presence check is a parse
        # now: a fenced heading is an example, so the body has no Mergeability
        # section and the seeder writes one.
        execution = sys.modules["execution"]
        helpers = sys.modules["_helpers"]
        self.assertFalse(helpers.has_markdown_section(self.FENCED_EXAMPLE_BODY, "Mergeability"))
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            result = execution.seed_mergeability_section(
                self.FENCED_EXAMPLE_BODY, changed_files=["docs/x.md"]
            )
        self.assertNotEqual(result, self.FENCED_EXAMPLE_BODY)
        self.assertEqual(spoke.getvalue(), "")
        self.assertTrue(helpers.has_markdown_section(result, "Mergeability"))
        seeded = helpers.markdown_section(result, "Mergeability")
        self.assertIn("- Surface: docs", seeded)
        for label in execution.mergeability_field_labels():
            self.assertIn(f"- {label}:", seeded)
        # The author's example is untouched: the body now carries two
        # `## Mergeability` lines and the page shows exactly one of them.
        self.assertIn("```markdown\n## Mergeability\n- Surface: docs\n```", result)
        self.assertEqual(result.count("## Mergeability"), 2)

    STRIP_FLIP_BODY = (
        "## Summary\n\nwhat.\n\n```\nlog opens here and never closes\n\n"
        "## Evidence Status\n\n- [complete] x -- checked\n"
    )

    def test_the_guard_and_the_write_answer_about_the_same_text(self) -> None:
        # The writer asked about `body.strip()` and cut `body.strip()`, while
        # a caller asking `section_write_refusal(body)` got the answer for the
        # untrimmed body -- and a trailing newline is enough to flip it. One
        # text, asked once: whatever the reason says, the write does.
        helpers = sys.modules["_helpers"]
        refusal = self.write_refusal(helpers, self.STRIP_FLIP_BODY, "Evidence Status")
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            written = helpers.insert_markdown_section(
                self.STRIP_FLIP_BODY, "Evidence Status", "- [complete] y -- checked"
            )
        # Two questions now, and a body that comes back unchanged answers to
        # one of them: the cut's guard, or the writer's own postcondition that
        # the page would show what it placed. Whichever it is, it is said.
        if written == self.STRIP_FLIP_BODY:
            self.assertTrue(
                refusal is not None or "not a heading on the page" in spoke.getvalue(),
                spoke.getvalue(),
            )
        else:
            self.assertIsNone(refusal)
        # And the answer does not depend on a trailing newline.
        self.assertEqual(
            self.write_refusal(helpers, self.STRIP_FLIP_BODY, "Evidence Status") is None,
            self.write_refusal(helpers, self.STRIP_FLIP_BODY.strip(), "Evidence Status") is None,
        )
        # Nor on which line ending the client sent. The heading match was
        # anchored on `\n`, so a CRLF body read as having no section while
        # `has_markdown_section` said it had one -- and the write then appended
        # a second copy instead of replacing the first.
        crlf = "## Summary\r\n\r\nnote\r\n\r\n## Evidence Status\r\n\r\n- [x] one\r\n"
        self.assertTrue(helpers.has_markdown_section(crlf, "Evidence Status"))
        self.assertEqual(helpers.markdown_section(crlf, "Evidence Status"), "- [x] one")
        rewritten = helpers.insert_markdown_section(crlf, "Evidence Status", "- [x] written")
        self.assertEqual(rewritten.count("## Evidence Status"), 1)
        self.assertEqual(helpers.markdown_section(rewritten, "Evidence Status"), "- [x] written")
        self.assertEqual(
            self.write_refusal(helpers, crlf, "Evidence Status"),
            self.write_refusal(helpers, crlf.replace("\r\n", "\n"), "Evidence Status"),
        )

    def test_a_completion_visible_only_to_the_written_read_never_completes_an_item(self) -> None:
        # The property, not the behaviour. The written read is a raw slice of
        # the body, so a `<!-- scratch` comment that runs to the end of the
        # body still CONTAINS the line that would complete an item; only the
        # rendered read drops it. Completion is the conjunction of the two
        # (#1721), and that conjunction is the whole reason hidden text cannot
        # launder a completion. Nothing else in this file enforces it.
        evidence = sys.modules["evidence"]
        owner = "a note on whether the fixture state survives a relaunch"
        attested = "`pnpm test` in `web-next` passes"
        perf = "p50 launch latency before and after"
        for item, hidden in (
            (owner, f"- [complete] {owner} -- checked: the fixture survived"),
            (attested, "Ran `cd web-next && pnpm test` and it printed 214 tests passed."),
            (perf, "Before Summary: p50 launch latency 900 ms\nAfter Summary: p50 launch latency 410 ms"),
        ):
            heading = "Performance" if item == perf else ("Validation" if item == attested else "Evidence Status")
            body = f"## {heading}\n\n<!-- scratch\n{hidden}\n"
            with self.subTest(item=item[:32]):
                # The written slice carries it.
                self.assertIn(hidden.splitlines()[0], evidence.markdown_section(body, heading))
                # The page shows nothing, so the item does not complete.
                self.assertEqual(evidence._rendered_lines(body, heading), [])
                accounting, errors = run_contributor.validate_evidence_accounting(body, [item], review_ci=[])
                self.assertEqual(accounting.get("complete_items"), [])
                self.assertIsNotNone(
                    run_contributor.review_evidence_gate_error("APPROVE", accounting, errors)
                )

    def test_two_ordinary_writes_keep_every_section_of_a_body_with_a_fenced_example(self) -> None:
        # The sequence, which needs nobody to have written an unclosed fence:
        # the first write ate the fence's closing line, and the second then
        # took the rest of the body for the section it was replacing. Three
        # sections went with it.
        helpers = sys.modules["_helpers"]
        seed = (
            "The change, in a paragraph.\n\n## Summary\n\nA body that carries the format:\n\n"
            "```markdown\n## Evidence Status\n- [complete] the item -- proof\n```\n\n"
            "## Performance\n\n- Before Summary: p50 launch latency 900 ms\n"
            "- After Summary: p50 launch latency 410 ms\n\n## Blocked By\n\n- #101\n\n"
            "## Risks\n\nNone.\n"
        )
        headings = ("Summary", "Evidence Status", "Performance", "Blocked By", "Risks")
        one = helpers.insert_markdown_section(seed, "Evidence Status", "- [complete] the item -- proof")
        two = helpers.insert_markdown_section(one, "Performance", "- Before: 1 ms\n- After: 2 ms")
        for heading in headings:
            with self.subTest(heading=heading):
                self.assertTrue(helpers.has_markdown_section(two, heading))
        # And the fence still closes, which is what kept the second write honest.
        self.assertEqual(two.count("```"), seed.count("```"))

    def test_the_section_a_second_heading_would_shadow_goes_too(self) -> None:
        # A rewrite removes every occurrence, not the first. `markdown_section`
        # reads the first, so a later copy left behind is the stale one the
        # next read finds.
        helpers = sys.modules["_helpers"]
        body = "## Evidence Status\n- [x] first\n\n## Risks\n\nNone.\n\n## Evidence Status\n- [x] second\n"
        rewritten = helpers.insert_markdown_section(body, "Evidence Status", "- [x] written")
        self.assertEqual(rewritten.count("## Evidence Status"), 1)
        self.assertNotIn("- [x] second", rewritten)


class ASectionStartsAtAHeadingThePageShowsTests(unittest.TestCase):
    """A section starts where a reader sees a heading, not where a pattern matches (#1730).

    `has_markdown_section` was a presence check with no parse behind it and
    the section cut was a literal `^## <heading>` match, so a `##` line inside
    a fenced example was a heading to both. The seeder read one and returned a
    body it had seeded nothing into, silently, and the readiness gate then
    asked for the section the runtime believed it had written. The same match
    made an example's text the section a reader of Evidence Status got, and an
    example's `[complete]` line the proof the gate recorded.

    The start is a parse now -- a top-level h2 whose text a reader sees as this
    heading -- which is the same call the rendered read makes, so the two views
    cannot find their section in different places.
    """

    ITEM = "a note on whether the fixture state survives a relaunch"
    EXAMPLE = f"- [complete] {ITEM} -- an example, not a claim"
    REAL = f"- [complete] {ITEM} -- checked: the fixture survived"
    FENCED_ONLY = (
        f"## Summary\n\nwhat.\n\n```markdown\n## Evidence Status\n{EXAMPLE}\n```\n\n"
        "## Validation\n\n- ok\n"
    )
    FENCED_ABOVE_REAL = (
        f"## Summary\n\n```markdown\n## Evidence Status\n{EXAMPLE}\n```\n\n"
        f"## Evidence Status\n\n{REAL}\n\n## Validation\n\n- ok\n"
    )

    def helpers(self):
        return sys.modules["_helpers"]

    def evidence(self):
        return sys.modules["evidence"]

    def test_a_body_whose_only_heading_is_fenced_has_no_section(self) -> None:
        helpers = self.helpers()
        self.assertFalse(helpers.has_markdown_section(self.FENCED_ONLY, "Evidence Status"))
        self.assertEqual(helpers.markdown_section(self.FENCED_ONLY, "Evidence Status"), "")
        # And the page agrees, which is the point: the rendered read finds no
        # section there either, and did not before this change.
        normalized = helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", self.FENCED_ONLY)
        self.assertIsNone(
            self.evidence()._rendered_section_span(
                helpers.MARKDOWN.parse(normalized), "Evidence Status", normalized.split("\n")
            )
        )

    def test_a_fenced_copy_above_a_real_section_is_not_the_section(self) -> None:
        # The forged-evidence shape, and the one that cost a reading rather
        # than a write: the example's `[complete]` line was what the gate
        # recorded as the proof for this item.
        helpers = self.helpers()
        self.assertTrue(helpers.has_markdown_section(self.FENCED_ABOVE_REAL, "Evidence Status"))
        self.assertEqual(
            helpers.markdown_section(self.FENCED_ABOVE_REAL, "Evidence Status"), self.REAL
        )
        entries = run_contributor.extract_evidence_status_entries(
            self.FENCED_ABOVE_REAL, [self.ITEM]
        )["entries"]
        self.assertEqual(entries[self.ITEM]["detail"], "checked: the fixture survived")

    def test_the_two_views_find_the_section_in_the_same_place(self) -> None:
        # The pair rule, on the START. The two agreed about where a section
        # ends since #1723 and could still disagree about where it began: on
        # the body above, the written read's section was the example's and the
        # rendered read's was the author's.
        helpers, evidence = self.helpers(), self.evidence()
        for name, body in {
            "a fenced copy above a real one": self.FENCED_ABOVE_REAL,
            "a fenced copy only": self.FENCED_ONLY,
            "an ordinary body": f"## Evidence Status\n\n{self.REAL}\n\n## Validation\n\n- ok\n",
            "a setext heading": f"Evidence Status\n---------------\n\n{self.REAL}\n\n## Validation\n\n- ok\n",
            "trailing spaces on the heading": f"## Evidence Status  \n\n{self.REAL}\n\n## Validation\n\n- ok\n",
            "emphasis in the heading": f"## **Evidence Status**\n\n{self.REAL}\n\n## Validation\n\n- ok\n",
            "a heading indented three spaces": f"## Summary\n\nwhat.\n\n   ## Evidence Status\n\n{self.REAL}\n",
            "a heading in a quote": f"## Summary\n\n> ## Evidence Status\n> {self.REAL}\n",
            "a heading in a list": f"## Summary\n\n- ## Evidence Status\n  {self.REAL}\n",
            "the heading written as an h1": f"# Evidence Status\n\n{self.REAL}\n\n## Validation\n\n- ok\n",
            "a heading on the last line": "## Summary\n\nwhat.\n\n## Evidence Status",
        }.items():
            with self.subTest(body=name):
                normalized = helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", body)
                tokens = helpers.MARKDOWN.parse(normalized)
                span = evidence._rendered_section_span(
                    tokens, "Evidence Status", normalized.split("\n")
                )
                self.assertEqual(
                    helpers.has_markdown_section(body, "Evidence Status"), span is not None
                )
                if span is None:
                    continue
                # The same heading token, so the same line of the body.
                index = helpers.section_heading_index(tokens, "Evidence Status")
                self.assertEqual(span[0], index + 3)

    def test_a_setext_heading_is_a_section_for_the_reader_and_the_writer_alike(self) -> None:
        # Decided rather than inherited: an underline is what makes the line
        # above it a heading, and the page then shows a heading there whatever
        # the author meant -- the answer #1723 already gave for a setext line
        # that ENDS a section, and the rendered read already gave for one that
        # starts it. So the written read takes it too, and the writer cuts the
        # underline with the line it underlines rather than leaving a stray
        # rule where the heading was.
        helpers = self.helpers()
        body = f"## Summary\n\nwhat.\n\nEvidence Status\n---------------\n\n{self.REAL}\n\n## Validation\n\n- ok\n"
        self.assertTrue(helpers.has_markdown_section(body, "Evidence Status"))
        self.assertEqual(helpers.markdown_section(body, "Evidence Status"), self.REAL)
        written = helpers.insert_markdown_section(body, "Evidence Status", "- [complete] y -- proof")
        self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "- [complete] y -- proof")
        self.assertNotIn("---------------", written)
        self.assertNotIn(self.REAL, written)
        # The sections around it are untouched and a second write is a fixed point.
        for heading in ("Summary", "Validation"):
            self.assertTrue(helpers.has_markdown_section(written, heading), heading)
        self.assertEqual(
            helpers.insert_markdown_section(written, "Evidence Status", "- [complete] y -- proof"),
            written,
        )

    def test_the_runtime_seeds_mergeability_and_the_gate_then_finds_it(self) -> None:
        # The issue's own reproduction, end to end: the runtime writes the
        # section, and the section it writes is the one a reader sees.
        execution, helpers = sys.modules["execution"], self.helpers()
        body = self.FENCED_ONLY.replace("Evidence Status", "Mergeability").replace(
            self.EXAMPLE, "- Surface: docs"
        )
        seeded = execution.seed_mergeability_section(body, changed_files=["docs/x.md"])
        self.assertNotEqual(seeded, body)
        self.assertTrue(helpers.has_markdown_section(seeded, "Mergeability"))
        section = helpers.markdown_section(seeded, "Mergeability")
        for label in execution.mergeability_field_labels():
            self.assertIn(f"- {label}:", section)

    def test_a_seeded_section_the_page_would_not_show_stands_the_body_down(self) -> None:
        # The postcondition is every writer's, not the status writer's. The
        # seeder appends at the end of the body, and the end of a body holding
        # a block that never closes is inside that block: the section would be
        # in the source, absent from the page, and the gate would then ask for
        # a section the runtime had written (#1734, for the other writer).
        execution, helpers = sys.modules["execution"], self.helpers()
        body = "## Summary\n\nwhat.\n\n<pre>\nthe log I never closed\n"
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            seeded = execution.seed_mergeability_section(body, changed_files=["docs/x.md"])
        self.assertEqual(seeded, body)
        self.assertIn("is not a heading on the page", spoke.getvalue())
        self.assertIn("</pre>", spoke.getvalue())
        # And the control: close the block and the same write goes ahead.
        closed = body + "</pre>\n"
        written = execution.seed_mergeability_section(closed, changed_files=["docs/x.md"])
        self.assertTrue(helpers.has_markdown_section(written, "Mergeability"))

    def test_a_heading_the_page_shows_as_code_anywhere_else_is_left_alone(self) -> None:
        # The guard on the change itself: an example is an example wherever it
        # sits, and a reader that started taking fenced lines again would show
        # up here as well as above.
        helpers = self.helpers()
        for name, body in {
            "fenced below the real section": (
                f"## Evidence Status\n\n{self.REAL}\n\n## Validation\n\n"
                f"```markdown\n## Evidence Status\n{self.EXAMPLE}\n```\n"
            ),
            "indented four spaces": (
                f"## Summary\n\nwhat.\n\n    ## Evidence Status\n    {self.EXAMPLE}\n\n"
                f"## Evidence Status\n\n{self.REAL}\n"
            ),
        }.items():
            with self.subTest(body=name):
                self.assertEqual(helpers.markdown_section(body, "Evidence Status"), self.REAL)
                written = helpers.insert_markdown_section(
                    body, "Evidence Status", "- [complete] z -- proof"
                )
                self.assertIn(self.EXAMPLE, written)
                self.assertEqual(
                    helpers.markdown_section(written, "Evidence Status"), "- [complete] z -- proof"
                )


class ALongSHeadingIsAnotherHeadingTests(unittest.TestCase):
    """Two headings a reader sees as different words are two sections (#1742).

    Heading identity was compared after `casefold()`, and full case folding
    maps characters that are not case variants of anything. U+017F, the long s
    a printer sets in `Statu\u017f`, folds to `s`, so `## Evidence Statu\u017f`
    written above the real `## Evidence Status` was the same heading to this
    reader: the first one won the identity, and the cut -- which takes every
    section under that name -- removed both, handing back a body with neither
    section's contents. The page showed two visibly different headings the
    whole time.

    The fold is `lower()` now, which accepts every single-character case pair
    Unicode records and declines a fold that changes the letters. The harm is
    fixtured here, beside the writer it protects, and the cross-file agreement
    with the readiness gate is pinned in `test_pr_readiness.py`.
    """

    ITEM = "the UI lane"
    AUTHORS_LINE = f"- [pending-ci] {ITEM} -- waiting"
    ENTRIES = {ITEM: {"status": "complete", "detail": "swift test passed"}}
    LONG_S = "## Evidence Statu\u017f"
    BODY = (
        "Why this exists.\n\n"
        f"{LONG_S}\n\n"
        "- [complete] the printer's item -- not this section\n\n"
        "## Evidence Status\n\n"
        f"{AUTHORS_LINE}\n\n"
        "## Validation\n\n- ran\n"
    )

    def helpers(self):
        return sys.modules["_helpers"]

    def evidence(self):
        return sys.modules["evidence"]

    def test_the_fold_accepts_case_and_declines_a_changed_letter(self) -> None:
        helpers = self.helpers()
        self.assertEqual(
            helpers.heading_identity("EVIDENCE STATUS"), helpers.heading_identity("Evidence Status")
        )
        self.assertNotEqual(
            helpers.heading_identity("Evidence Statu\u017f"),
            helpers.heading_identity("Evidence Status"),
        )

    def test_the_section_is_the_heading_that_reads_as_it(self) -> None:
        helpers = self.helpers()
        self.assertEqual(helpers.markdown_section(self.BODY, "Evidence Status"), self.AUTHORS_LINE)

    def test_a_rewrite_leaves_the_long_s_section_where_it_is(self) -> None:
        # The harm as the author sees it: their long-s section survives, and
        # the real one is the one rewritten.
        write = self.evidence().write_evidence_status_section(
            self.BODY, self.ENTRIES, notes_from=self.BODY, entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
        )
        self.assertIn(self.LONG_S, write.body, write.refusal)
        self.assertIn("- [complete] the printer's item -- not this section", write.body)
        self.assertNotIn(
            self.AUTHORS_LINE, self.helpers().markdown_section(write.body, "Evidence Status")
        )
        self.assertEqual(write.body.count("## Evidence Status"), 1)

    def test_the_owner_read_sees_one_section_and_does_not_refuse_for_two(self) -> None:
        lines, reason = self.evidence()._rendered_status_lines(self.BODY)
        self.assertIsNone(reason)
        self.assertEqual(lines, [f"[pending-ci] {self.ITEM} -- waiting"])


class AHeadingCarryingInlineHtmlIsNotThisSectionTests(unittest.TestCase):
    """A heading is this section only if the page shows it as this heading (#1730).

    `inline_text` drops every tag but `<br>` -- the right reading for a
    requested item or a recorded detail, and the wrong one for identity. Asked
    on a heading it made `## Evidence <del>Status</del>`, `## <details>Evidence
    Status</details>` and `## Evidence<br>Status` all read as `Evidence
    Status`, so each BECAME the section and the rewrite replaced its contents
    with the entries in hand -- taking the author's own status line with it. A
    reader sees struck-through text, a collapsed disclosure widget, and two
    lines. Both reads agreed against the page, so the disagreement refusal
    #1737 built had nothing to fire on.

    The rule is any inline HTML, not a list of the tags that show something.
    `_unreadable_inline` already answers it that way for a status line, and
    `_rendered_status_lines` refuses this very heading for carrying inline
    HTML; a second answer in `section_heading_index` is the disagreement one
    function away. The alternative needs the set of tags GitHub's sanitizer
    renders as nothing -- a second renderer, built from an allow-list this repo
    does not hold, whose only plausible members are `<span>` and a comment.

    Nothing is lost by refusing those two. None of these shapes was this
    section before #1730's change, `<span>` included, so the rule declines to
    widen rather than taking something away; the tests below hold at the merge
    base as well as here, and fail only in between.
    """

    ITEM = "the UI lane"
    AUTHORS_LINE = f"- [pending-ci] {ITEM} -- waiting"
    ENTRIES = {ITEM: {"status": "complete", "detail": "swift test passed"}}
    # Each renders as something other than a plain `Evidence Status` heading:
    # struck through, a disclosure widget, two lines, an empty span.
    SHAPES = {
        "del": "## Evidence <del>Status</del>",
        "s": "## Evidence <s>Status</s>",
        "details": "## <details>Evidence Status</details>",
        "br": "## Evidence<br>Status",
        "span": "## <span>Evidence Status</span>",
        "comment": "## Evidence Status<!-- a note -->",
    }

    def helpers(self):
        return sys.modules["_helpers"]

    def evidence(self):
        return sys.modules["evidence"]

    def body(self, heading: str) -> str:
        return f"Why this exists.\n\n{heading}\n\n{self.AUTHORS_LINE}\n\n## Validation\n\n- ran\n"

    def test_none_of_them_is_the_section(self) -> None:
        helpers = self.helpers()
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.body(heading)
                self.assertFalse(helpers.has_markdown_section(body, "Evidence Status"))
                self.assertEqual(helpers.markdown_section(body, "Evidence Status"), "")

    def test_the_rewrite_leaves_the_authors_line_where_it_is(self) -> None:
        # The harm, stated as the author sees it: their own `[pending-ci]` line
        # is replaced by the entries in hand when the rewrite believes it owns
        # the section. It does not own these.
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.body(heading)
                written, stood_down, _ = self.evidence().write_evidence_status_section(
                    body, self.ENTRIES, notes_from=body, entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
                )
                self.assertIn(self.AUTHORS_LINE, written, stood_down)

    def test_a_plain_heading_is_still_the_section_and_still_rewritten(self) -> None:
        # The control the other way: nothing above is a refusal of headings in
        # general.
        helpers = self.helpers()
        body = self.body("## Evidence Status")
        self.assertTrue(helpers.has_markdown_section(body, "Evidence Status"))
        written, _, _ = self.evidence().write_evidence_status_section(
            body, self.ENTRIES, notes_from=body, entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
        )
        # Out of the SECTION, which is what "still rewritten" means. Their
        # bytes are below it now rather than gone (#1751, round 17).
        self.assertNotIn(self.AUTHORS_LINE, self.helpers().markdown_section(written, "Evidence Status"))
        self.assertIn(self.AUTHORS_LINE, self.helpers().markdown_section(written, "Evidence Notes"))

    def test_emphasis_is_markdown_rather_than_a_tag_and_stays_this_section(self) -> None:
        # The line this rule does not cross. `**Evidence Status**` is bold on
        # the page and reads as the heading it looks like, which is the
        # widening #1730 makes on purpose; it is not a tag and nothing here
        # takes it back. Green here and red at the merge base, where the
        # presence check was a literal pattern.
        helpers = self.helpers()
        body = self.body("## **Evidence Status**")
        self.assertTrue(helpers.has_markdown_section(body, "Evidence Status"))
        written, _, _ = self.evidence().write_evidence_status_section(
            body, self.ENTRIES, notes_from=body, entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
        )
        # Out of the SECTION, which is what "still rewritten" means. Their
        # bytes are below it now rather than gone (#1751, round 17).
        self.assertNotIn(self.AUTHORS_LINE, self.helpers().markdown_section(written, "Evidence Status"))
        self.assertIn(self.AUTHORS_LINE, self.helpers().markdown_section(written, "Evidence Notes"))

    def test_the_internal_read_says_why_rather_than_saying_nothing_is_there(self) -> None:
        # Named for what it checks. This is `_rendered_markdown_entries`, an
        # internal read: a heading the page shows and this reader will not own
        # is not the same as no heading at all, and the reason has to survive
        # that distinction. Reporting it turns on whether a reader has a
        # heading to refuse, not on `section_present`, which the rule above
        # makes false for exactly these shapes.
        #
        # Whether the AUTHOR is told is a different question and a different
        # surface; `ARejectedHeadingIsToldWhyAtTheRunsOutputTests` is where
        # that is asserted. An earlier version of this name promised it.
        evidence = self.evidence()
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.body(heading)
                parsed, unreadable = evidence._rendered_markdown_entries(body, [self.ITEM])
                self.assertFalse(parsed["section_present"])
                self.assertIn("HTML", unreadable or "")
        # And a body with no heading at all stays silent, which is the one
        # refusal that means there is nothing here to read.
        plain = f"Why this exists.\n\n## Validation\n\n- ran\n"
        self.assertIsNone(evidence._rendered_markdown_entries(plain, [self.ITEM])[1])


class ARejectedHeadingIsToldWhyAtTheRunsOutputTests(unittest.TestCase):
    """A heading the readers decline is named, on the surfaces the author reads (#1730).

    The rejection is correct and it was silent. A body whose only
    `## Evidence Status` carries inline HTML comes back from the factory turn
    with a second, plain heading written below it and `errors == []`, and the
    read that collects evidence then refuses it: "a reader sees 2
    `Evidence Status` headings, not one". True, comprehensible, and it points
    at the wrong repair -- delete one, and deleting the written one leaves a
    body with no readable section and the same refusal. A round lost before
    anything is learned.

    Round 2 moved where the note is said and narrowed what it claims. It is
    composed from the body the write RETURNED rather than from the body it was
    handed, so it cannot announce a heading that was written on a turn where
    the write refused; it says what the readers this repo actually has do
    rather than "every check"; and every value it quotes from the body is
    escaped, because it goes to a workflow log and to a pull request and both
    of those read what they are given.
    """

    ITEM = "`swift test` passes"
    # Heading, and the tag the note has to name as the reason.
    SHAPES = {
        "span": ("## <span>Evidence Status</span>", "<span>"),
        "del": ("## Evidence <del>Status</del>", "<del>"),
        "details": ("## <details>Evidence Status</details>", "<details>"),
        "br": ("## Evidence<br>Status", "<br>"),
    }

    def helpers(self):
        return sys.modules["_helpers"]

    def evidence(self):
        return sys.modules["evidence"]

    @staticmethod
    def readiness_gate():
        """The repo's readiness gate, loaded by path, so a claim about it is measured.

        The note says what this gate does and does not do with a tagged
        heading, and a sentence about another file's behaviour is worth what
        the test that runs it is worth.
        """
        spec = importlib.util.spec_from_file_location(
            "pr_readiness_for_heading_claims", REPO_ROOT / "scripts" / "pr-readiness.py"
        )
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules["pr_readiness_for_heading_claims"] = module
        spec.loader.exec_module(module)
        return module

    def body(self, heading: str) -> str:
        return (
            "Why this exists, at length enough to satisfy the leading paragraph rule.\n\n"
            f"{heading}\n\n- [pending-ci] {self.ITEM} -- the lane has not run yet\n\n"
            "## Validation\n\n- ran\n"
        )

    def written(self, heading: str) -> str:
        """The body the write returns, which is what the note is asked about."""
        with contextlib.redirect_stderr(io.StringIO()):
            body, refusal, _ = self.evidence().write_evidence_status_section(
                self.body(heading),
                ["- [complete] the UI lane -- swift test passed"], notes_from=self.body(heading),
                entries=entries_for(["- [complete] the UI lane -- swift test passed"]), previous_entries=entries_for(["- [complete] the UI lane -- swift test passed"]), recorded_items=[self.ITEM],
            )
        self.assertIsNone(refusal)
        return body

    def test_the_note_names_the_line_the_tag_and_both_repairs(self) -> None:
        helpers = self.helpers()
        for name, (heading, tag) in self.SHAPES.items():
            with self.subTest(shape=name):
                note = helpers.rejected_heading_note(self.written(heading), "Evidence Status")
                assert note is not None
                self.assertIn(heading, note)
                # The tag in its own right, not merely because the heading line
                # it came from is quoted above it: an author who has two tags
                # in one heading needs to know which one this reader stopped
                # at.
                self.assertIn(f"carries inline HTML (`{tag}`)", note)
                self.assertIn("A readable `Evidence Status` h2 below it is the one read as that section", note)
                self.assertIn("Remove the tags from yours, or remove yours", note)
        # A body whose heading is plain has nothing to say.
        self.assertIsNone(
            helpers.rejected_heading_note(self.body("## Evidence Status"), "Evidence Status")
        )

    def test_the_note_reports_the_write_s_result_and_not_its_intent(self) -> None:
        """"A plain heading was written below it" is a claim about a body, checked against one.

        Asked of the body the model wrote -- which is where it was asked, and
        before the write -- the sentence is a prediction, and on a body the
        write then refuses it is a false one: the returned body is the
        author's, untouched, and the log carried "was written below it" one
        line above "refusing to write" (#1730, round 2).
        """
        helpers, evidence = self.helpers(), self.evidence()
        source = self.body(self.SHAPES["span"][0])
        # Before the write there is no plain heading, and the note says so.
        before = helpers.rejected_heading_note(source, "Evidence Status")
        assert before is not None
        self.assertIn("No readable `Evidence Status` h2 is in this body", before)
        self.assertNotIn("was written below it", before)
        # After a write that went ahead, there is one, and the note says that.
        after = helpers.rejected_heading_note(self.written(self.SHAPES["span"][0]), "Evidence Status")
        assert after is not None
        self.assertIn("A readable `Evidence Status` h2 below it is the one read as that section", after)
        # And on a body the write refuses, the returned body is the source, so
        # the note asked of the RESULT makes the true claim about it.
        refusing = source.replace("## Validation\n\n- ran\n", "<pre>\nnever closed\n")
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            result, refusal, _ = evidence.write_evidence_status_section(
                refusing,
                ["- [complete] the UI lane -- swift test passed"], notes_from=refusing,
                entries=entries_for(["- [complete] the UI lane -- swift test passed"]), previous_entries=entries_for(["- [complete] the UI lane -- swift test passed"]), recorded_items=[self.ITEM],
            )
        self.assertIsNotNone(refusal)
        self.assertEqual(result, refusing)
        stood_down = helpers.rejected_heading_note(result, "Evidence Status")
        assert stood_down is not None
        self.assertIn("No readable `Evidence Status` h2 is in this body", stood_down)
        # The writer says nothing about the heading at all now, so the log
        # cannot carry both sentences.
        self.assertNotIn("carries inline HTML", spoke.getvalue())
        self.assertIn("refusing to", spoke.getvalue())

    def test_the_writer_is_no_longer_where_the_note_is_said(self) -> None:
        # It was said here, and this is a writer: it runs more than once in a
        # turn, and it had to be asked before the write to see the author's
        # heading alone, which is what made the sentence above false. The write
        # still goes ahead -- the repair is the point, not a stand-down.
        for name, (heading, _) in self.SHAPES.items():
            with self.subTest(shape=name):
                spoke = io.StringIO()
                with contextlib.redirect_stderr(spoke):
                    written, refusal, _ = self.evidence().write_evidence_status_section(
                        self.body(heading),
                        # Naming the recorded item, because the write asks its
                        # own reader whether it can read back what it renders
                        # and says so when it cannot (#1751, round 4). A line
                        # for an item nobody recorded is exactly that shape.
                        [f"- [complete] {self.ITEM} -- swift test passed"], notes_from=self.body(heading),
                        entries=entries_for([f"- [complete] {self.ITEM} -- swift test passed"]), previous_entries=entries_for([f"- [complete] {self.ITEM} -- swift test passed"]), recorded_items=[self.ITEM],
                    )
                self.assertIsNone(refusal)
                self.assertEqual(spoke.getvalue(), "")
                self.assertIn("\n## Evidence Status\n", written)
                self.assertIn(heading, written)

    def test_the_factory_turn_keeps_its_errors_empty(self) -> None:
        # Not an error: adding it to the turn's errors would abort a turn that
        # succeeded, and the repair is what the turn is for.
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        for name, (heading, _) in self.SHAPES.items():
            with self.subTest(shape=name):
                rendered, errors = run_contributor.render_execution_summary_body(
                    self.body(heading),
                    requested_evidence=[self.ITEM],
                    evidence_complete=["1 -- 214 tests passed"],
                    evidence_blocked=None,
                    evidence_pending_ci=None,
                )
                self.assertEqual(errors, [])
                self.assertIn(heading, rendered)
                self.assertIsNotNone(
                    self.helpers().rejected_heading_note(rendered, "Evidence Status")
                )

    def test_the_two_headings_refusal_names_every_heading_carrying_a_tag(self) -> None:
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        for name, (heading, _) in self.SHAPES.items():
            with self.subTest(shape=name):
                rendered, _ = run_contributor.render_execution_summary_body(
                    self.body(heading),
                    requested_evidence=[self.ITEM],
                    evidence_complete=["1 -- 214 tests passed"],
                    evidence_blocked=None,
                    evidence_pending_ci=None,
                )
                _, unreadable = self.evidence()._rendered_status_lines(rendered)
                assert unreadable is not None
                self.assertIn("2 `Evidence Status` headings", unreadable)
                self.assertIn("carries inline HTML", unreadable)
                self.assertIn("Leave exactly one heading", unreadable)

    def test_when_every_heading_carries_a_tag_the_refusal_still_names_them_all(self) -> None:
        """Naming one of two tagged headings is true and useless (#1730, round 2).

        What remains is the other tagged heading, still not read as the
        section, still refused -- so the author repairs, re-runs, and meets
        this refusal again. Every tagged heading is named, and the repair the
        message asks for is the body to end up with rather than the result of
        taking one thing away.
        """
        opening = "Why this exists, at length enough to satisfy the leading paragraph rule.\n\n"
        both = (
            opening
            + "## <span>Evidence Status</span>\n\n- [complete] a -- b\n\n"
            + "## <del>Evidence Status</del>\n\n- [complete] c -- d\n"
        )
        _, unreadable = self.evidence()._rendered_status_lines(both)
        assert unreadable is not None
        self.assertIn("(`<span>`)", unreadable)
        self.assertIn("(`<del>`)", unreadable)
        self.assertIn("none of them is read as the section", unreadable)
        self.assertIn(
            "Leave exactly one heading whose text reads as `Evidence Status` "
            "-- top level, an h2, and carrying no tags",
            unreadable,
        )

    # Text an author wrote, reaching a log that obeys workflow commands and a
    # comment that renders markdown and delivers mentions. Each is a hazard on
    # one of those surfaces and inert on the other.
    HAZARDS = {
        "an attribute spanning a newline": (
            '<span title="x\n::error::owned\ny">Evidence Status</span>\n---',
            "::error::owned",
        ),
        "a backtick and a mention in an attribute": (
            '## <span title="a`b @someone">Evidence Status</span>',
            "@someone",
        ),
        "a terminal escape in an attribute": (
            '## <span title="\x1b[31mred">Evidence Status</span>',
            "\x1b",
        ),
        "a comment delimiter in an attribute": (
            '## <span title="<!-- x -->">Evidence Status</span>',
            "<!--",
        ),
    }

    def hazard_note(self, heading: str) -> str:
        note = self.helpers().rejected_heading_note(self.body(heading), "Evidence Status")
        assert note is not None, heading
        return note

    def test_the_note_is_one_line_whatever_the_author_wrote(self) -> None:
        # The log surface. A workflow command is only a command at column 0, so
        # one line is the whole of the defence -- and it is also what keeps a
        # structured record on one line.
        for name, (heading, _) in self.HAZARDS.items():
            with self.subTest(hazard=name):
                note = self.hazard_note(heading)
                self.assertNotIn("\n", note)
                self.assertNotIn("\r", note)
                self.assertNotIn("\x1b", note)

    def test_no_line_of_the_comment_is_a_workflow_command(self) -> None:
        execution = sys.modules["execution"]
        heading, _ = self.HAZARDS["an attribute spanning a newline"]
        note = self.hazard_note(heading)
        # The hazard is real: the author's text carries it.
        self.assertIn("::error::owned", heading)
        # It survives as text and never as a line of its own, on either surface.
        self.assertIn("::error::owned", note)
        comment = execution.compose_rejected_heading_comment("April", note, "0" * 40)
        self.assertEqual([line for line in comment.split("\n") if line.startswith("::")], [])
        self.assertEqual([line for line in note.split("\n") if line.startswith("::")], [])

    def test_a_backtick_in_a_tag_does_not_let_a_mention_out_of_the_code_span(self) -> None:
        """The comment surface, asked of the parser rather than of the string.

        A code span fenced with one backtick is closed by the first backtick
        inside the attribute, and what follows is live markdown -- an
        `@someone` there is a mention GitHub delivers to a person who has
        nothing to do with this PR. The fence is one backtick longer than the
        longest run inside, so there is nothing after the span to be live.
        """
        helpers, execution = self.helpers(), sys.modules["execution"]
        heading, mention = self.HAZARDS["a backtick and a mention in an attribute"]
        note = self.hazard_note(heading)
        comment = execution.compose_rejected_heading_comment("April", note, "0" * 40)
        tokens = helpers.MARKDOWN.parse(comment)
        spans = [
            child.content
            for token in tokens
            for child in (token.children or [])
            if child.type == "code_inline"
        ]
        plain = "".join(
            child.content
            for token in tokens
            for child in (token.children or [])
            if child.type == "text"
        )
        # The tag is inside a span, and the mention is nowhere outside one.
        self.assertTrue([span for span in spans if mention in span], spans)
        self.assertNotIn(mention, plain)
        self.assertNotIn("a`b", plain)

    def test_nothing_mutates_the_note_after_it_is_fenced(self) -> None:
        """The order of escaping is the escaping (#1730, round 2).

        The delimiter strip used to run over the composed comment, after
        `code_span` had chosen a fence. Removing `<!--` JOINS the backtick runs
        on either side of it, and two runs joined can be long enough to close
        the fence the note was given -- after which an `@mention` in the same
        attribute is live markdown in a comment the bot posts. Codex
        (gpt-5.6-sol, xhigh) found it with this heading; the delimiters come
        out before the runs are counted now, and nothing touches the result.
        """
        helpers, execution = self.helpers(), sys.modules["execution"]
        heading = '## <span>Evidence Status</span><i title="`<!--``@octocat"></i>'
        note = helpers.rejected_heading_note(self.body(heading), "Evidence Status")
        assert note is not None
        comment = execution.compose_rejected_heading_comment("April", note, "0" * 40)
        tokens = helpers.MARKDOWN.parse(comment)
        plain = "".join(
            child.content
            for token in tokens
            for child in (token.children or [])
            if child.type == "text"
        )
        self.assertNotIn("@octocat", plain)
        self.assertNotIn("<!--", comment)
        # And the whole heading is inside one span, which is what the fence
        # length has to be right for.
        spans = [
            child.content
            for token in tokens
            for child in (token.children or [])
            if child.type == "code_inline"
        ]
        self.assertTrue([span for span in spans if "@octocat" in span], spans)

    def test_an_invisible_character_cannot_splice_a_delimiter_back_together(self) -> None:
        """The order of the removals is the escaping, not just their presence (#1730, round 3).

        Round 2 put the delimiter strip before the fence, which was the fix it
        needed, and left the invisible-character removal AFTER it. So an author
        who writes `a<!` ZWSP `--b--` ZWSP `>c` gets past the strip -- the
        delimiters are not there yet -- and the removal then splices them
        together, handing the comment a `<!--` the strip had already run.

        The invisibles go first for that reason: a delimiter can be made by
        taking a character out, so nothing that removes characters may run
        after the strip.
        """
        helpers = self.helpers()
        spliced = helpers.code_span("a<!\u200b--b--\u200b>c")
        self.assertNotIn("<!--", spliced)
        self.assertNotIn("-->", spliced)
        # The spliced delimiters go with the strip, brackets and all, and the
        # author's own letters are what is left: `a<!` ZWSP `--b--` ZWSP `>c`
        # becomes `a<!--b-->c` once the invisibles are out, and the strip then
        # takes both delimiters.
        self.assertEqual(spliced, "`abc`")

    def test_a_whitespace_control_between_two_words_stays_a_space(self) -> None:
        """A control character that separates is a separator, not nothing (#1730, round 3b).

        Step 1 removes the control and format characters, and removing a tab or
        a newline from between two words glues them: `a` tab `b` quoted as `ab`
        is text the author never wrote, on the accepting side -- nothing
        refuses, the note simply misquotes. It is the failure `inline_text`
        records for `<br>`, where dropping the tag turned `1<br>2 tests passed`
        into a count nobody wrote.

        So a Cc or Cf character Python calls whitespace becomes a space, which
        step 3 then collapses with its neighbours. The ones that are not
        whitespace -- NUL, and the C1 controls with U+0085 excepted -- are
        removed, because there is no separator there to keep.
        """
        helpers = self.helpers()
        self.assertEqual(helpers.code_span("a\tb\nc\rd\x0ce"), "`a b c d e`")
        self.assertEqual(helpers.code_span("a\x0bb\x1fc"), "`a b c`")
        self.assertEqual(helpers.code_span("a\u0085b"), "`a b`")
        # Not whitespace, so nothing is kept in their place.
        self.assertEqual(helpers.code_span("d\x00e"), "`de`")
        self.assertEqual(helpers.code_span("d\u009be"), "`de`")
        self.assertEqual(helpers.code_span("d\u200be"), "`de`")

    def test_the_note_keeps_the_gap_a_tag_attribute_wrote(self) -> None:
        # The same thing where it reaches an author: a setext heading whose
        # attribute spans a newline quoted the two halves with a space between
        # them until round 3 removed it.
        helpers = self.helpers()
        heading = '<span title="x\n::error::owned">Evidence Status</span>\n---'
        note = helpers.rejected_heading_note(self.body(heading), "Evidence Status")
        assert note is not None
        self.assertIn('<span title="x ::error::owned">', note)
        self.assertNotIn('<span title="x::error::owned">', note)

    def test_a_c1_control_does_not_survive_into_the_note(self) -> None:
        # `[\x00-\x1f\x7f]` is C0 and DEL. The C1 range is U+0080-U+009F,
        # where the CSI introducer lives -- a single character that opens an
        # escape sequence on a terminal reading the workflow log, and one the
        # class above does not name (#1730, round 3).
        helpers = self.helpers()
        for name, char in (
            ("CSI introducer", "\u009b"),
            ("string terminator", "\u009c"),
            ("next line", "\u0085"),
        ):
            with self.subTest(character=name):
                span = helpers.code_span(f"<span title=\"x{char}y\">")
                self.assertNotIn(char, span)
                self.assertIn("<span", span)

    def test_an_invisible_format_character_does_not_survive_into_the_note(self) -> None:
        # A zero-width space and a right-to-left override are neither control
        # characters in the C0 sense nor whitespace: the first is invisible and
        # the second reorders what a reader sees for the rest of the line, in a
        # comment a person is being asked to act on.
        helpers = self.helpers()
        for name, char in (("zero width space", "\u200b"), ("right-to-left override", "\u202e")):
            with self.subTest(character=name):
                span = helpers.code_span(f"<span title=\"a{char}b\">")
                self.assertNotIn(char, span)
                self.assertIn("<span", span)

    def test_a_comment_delimiter_in_a_tag_cannot_spell_a_marker(self) -> None:
        # The same strip model prose gets, for the same reason: no line of text
        # this runtime did not write may parse as one of its markers.
        execution = sys.modules["execution"]
        heading, delimiter = self.HAZARDS["a comment delimiter in an attribute"]
        comment = execution.compose_rejected_heading_comment("April", self.hazard_note(heading), "0" * 40)
        self.assertNotIn(delimiter, comment)
        self.assertNotIn("-->", comment)

    def test_the_comment_claims_only_what_the_readers_here_do(self) -> None:
        """Every sentence about a consequence, measured on this tree (#1730, round 2).

        It used to say "every check that reads this section refuses it". The
        readiness gate's ambiguity check returns `None` on that body and its
        `evaluate` reports nothing about the heading -- so the note corrected a
        wrongly attributed refusal with a wrongly attributed refusal.
        """
        execution, evidence = sys.modules["execution"], self.evidence()
        written = self.written(self.SHAPES["span"][0])
        note = self.helpers().rejected_heading_note(written, "Evidence Status")
        assert note is not None
        _, unreadable = evidence._rendered_status_lines(written)
        assert unreadable is not None
        comment = execution.compose_rejected_heading_comment("April", note, "0" * 40, unreadable)

        # Claim 1: the read that collects evidence refuses, and the comment
        # QUOTES that refusal rather than restating it.
        self.assertIn("2 `Evidence Status` headings, not one", unreadable)
        self.assertIn("carries inline HTML", unreadable)
        self.assertIn(unreadable, comment)

        # Claim 2: the readiness gate does not refuse it for this. Asked of
        # the check that would, and of whether making the heading plain changes
        # any refusal -- rather than of whether the word "heading" appears in
        # one. It did appear: #1744's pending refusal names the run it matched
        # with "the page shows this line under the heading", and that branch
        # and this test were independently green until they met (#1738, round
        # 4 rebase).
        gate = self.readiness_gate()
        self.assertIsNone(gate.evidence_status_heading_failure(written))
        failures = gate.evaluate(
            {"title": "t", "body": written, "draft": False, "labels": []}, ["Sources/App.swift"]
        ).failures
        pending = "Requested evidence is blocked or still pending CI."
        self.assertEqual(
            [
                failure
                for failure in failures
                if "heading" in failure.casefold() and not failure.startswith(pending)
            ],
            [],
        )
        # The gate DOES refuse this body, and not for the heading: the author's
        # own `[pending-ci]` line is under a heading the page shows, so the
        # rendered view reads it and says so. That refusal names the run it
        # matched -- "the page shows this line under the heading" -- which is
        # where the word comes from, and why the filter above cannot be a bare
        # word match. #1744's branch and this test were independently green
        # until they met on one tree.
        self.assertEqual(
            [failure for failure in failures if failure.startswith(pending)],
            [
                f'{pending} The page shows this line under the heading: '
                f'"[pending-ci] {self.ITEM.strip("`").replace("`", "")} -- the lane has not run yet".'
            ],
        )
        self.assertIn("The readiness gate does not refuse it for this", comment)
        # And the sentence that was not true of this repo is gone.
        self.assertNotIn("every check that reads this section refuses it", comment)

    def test_a_break_outside_the_control_range_is_flattened_too(self) -> None:
        """The half of the flattening that is not obvious (#1730, round 2).

        The Cc and Cf removal covers the control and format characters. A line
        separator and a paragraph separator are neither -- Unicode files them
        under Zl and Zp -- and each is a line break to something downstream;
        what removes them is the bare `.split()`, which splits on every
        character Python calls whitespace. Narrowing that to `.split(" ")`
        reads like the same thing and puts them back, so it is pinned here
        rather than left to the docstring.
        """
        helpers = self.helpers()
        for name, char in (
            ("line separator", "\u2028"),
            ("paragraph separator", "\u2029"),
            ("next line", "\u0085"),
            ("form feed", "\x0c"),
            ("vertical tab", "\x0b"),
        ):
            with self.subTest(character=name):
                span = helpers.code_span(f"a{char}::error::owned")
                self.assertNotIn(char, span)
                self.assertIn("::error::owned", span)

    def test_the_note_says_where_the_plain_heading_is_and_not_where_it_usually_is(self) -> None:
        """"Written below it" is a claim about position, checked against the body (#1730, round 2).

        The write puts a plain heading below the author's, which is what makes
        the sentence useful -- it tells them which of the two headings is which.
        On a body that already carried a plain heading ABOVE the tagged one it
        was simply false, and the author looking below for a heading that is
        above them is the round this note exists to save.
        """
        helpers = self.helpers()
        opening = "Why this exists, at length enough to satisfy the leading paragraph rule.\n\n"
        tagged = "## <span>Evidence Status</span>\n\n- [complete] a -- b\n\n"
        plain = "## Evidence Status\n\n- [complete] c -- d\n"
        below = helpers.rejected_heading_note(opening + tagged + plain, "Evidence Status")
        above = helpers.rejected_heading_note(opening + plain + "\n" + tagged, "Evidence Status")
        assert below is not None and above is not None
        self.assertIn("h2 below it is the one read as that section", below)
        self.assertIn("h2 above it is the one read as that section", above)
        self.assertNotIn("below it", above)
        # And it names what the reader accepts rather than a syntax the body
        # need not carry: a setext h2 is this section to `section_heading_index`,
        # so "a plain `## Evidence Status`" was a claim about source text that
        # such a body does not support (codex, gpt-5.6-sol, xhigh).
        setext = helpers.rejected_heading_note(
            opening + tagged + "Evidence Status\n---------------\n\n- [complete] c -- d\n",
            "Evidence Status",
        )
        assert setext is not None
        self.assertIn("A readable `Evidence Status` h2 below it", setext)
        self.assertNotIn("`## Evidence Status`", setext.split("carries inline HTML")[1])

    def test_the_refusal_asks_for_the_body_to_aim_for_rather_than_predicting_a_removal(self) -> None:
        """Two goes at predicting what a removal leaves were wrong two ways (#1730, round 2).

        Subtracting rejections from headings counted an `# Evidence Status` as
        though taking a tag off would make it readable. Counting readable h2s
        instead ignored that this refusal counts every heading whose text reads
        as this one, at any level and any depth -- so a body with one good h2
        and one h1 clears the readability count and refuses again. A predicate
        that decides the repair and a predicate that judges it have to be the
        same one; the message describes the body to aim for instead, which is
        true of every arrangement.
        """
        opening = "Why this exists, at length enough to satisfy the leading paragraph rule.\n\n"
        tagged = "## <span>Evidence Status</span>\n\n- [complete] a -- b\n\n"
        target = (
            "Leave exactly one heading whose text reads as `Evidence Status` "
            "-- top level, an h2, and carrying no tags"
        )
        for name, other in (
            ("a plain h2 of the same text", "## Evidence Status\n\n- [complete] c -- d\n"),
            ("an h1 of the same text", "# Evidence Status\n\n- [complete] c -- d\n"),
            ("an h3 of the same text", "### Evidence Status\n\n- [complete] c -- d\n"),
            ("one inside a block quote", "> ## Evidence Status\n"),
            ("a second tagged heading", "## <del>Evidence Status</del>\n\n- [complete] c -- d\n"),
        ):
            with self.subTest(other=name):
                _, unreadable = self.evidence()._rendered_status_lines(opening + tagged + other)
                assert unreadable is not None
                self.assertIn("2 `Evidence Status` headings, not one", unreadable)
                self.assertIn(target, unreadable)
                # No promise about what a removal leaves, in any arrangement.
                self.assertNotIn("leaves a body with", unreadable)
                self.assertNotIn("would leave a body", unreadable)
        # Every tagged heading is still named, with its line.
        _, both = self.evidence()._rendered_status_lines(
            opening + tagged + "## <del>Evidence Status</del>\n\n- [complete] c -- d\n"
        )
        assert both is not None
        self.assertIn("(`<span>`)", both)
        self.assertIn("(`<del>`)", both)
        self.assertIn("none of them is read as the section", both)

    def test_the_comment_quotes_the_refusal_rather_than_counting_for_itself(self) -> None:
        """A sentence that says "2" and "both" on a body with three (#1730, round 3).

        The comment used to restate the refusal: "a reader sees 2
        `Evidence Status` headings", "while both headings stand", "names yours
        as the one carrying the tag". An author with TWO tagged headings gets a
        written body with three and a refusal that names all of them, under a
        paragraph saying two and pointing at one.

        The readers already compute the count and the names, so the comment
        quotes what they say. There is no second copy of that sentence to
        count wrong.
        """
        execution, evidence, helpers = sys.modules["execution"], self.evidence(), self.helpers()
        opening = "Why this exists, at length enough to satisfy the leading paragraph rule.\n\n"
        two_tagged = (
            opening
            + "## <span>Evidence Status</span>\n\n- [pending-ci] a -- b\n\n"
            + "## <del>Evidence Status</del>\n\n- [pending-ci] c -- d\n\n"
            + "## Validation\n\n- ran\n"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            written, refusal, _ = evidence.write_evidence_status_section(
                two_tagged,
                ["- [complete] the UI lane -- swift test passed"], notes_from=two_tagged,
                entries=entries_for(["- [complete] the UI lane -- swift test passed"]), previous_entries=entries_for(["- [complete] the UI lane -- swift test passed"]), recorded_items=["the UI lane"],
            )
        self.assertIsNone(refusal)
        note = helpers.rejected_heading_note(written, "Evidence Status")
        assert note is not None
        _, unreadable = evidence._rendered_status_lines(written)
        assert unreadable is not None
        comment = execution.compose_rejected_heading_comment("April", note, "0" * 40, unreadable)

        # Three headings a reader sees, and the comment says three because the
        # refusal does.
        self.assertIn("a reader sees 3 `Evidence Status` headings, not one", unreadable)
        self.assertIn("a reader sees 3 `Evidence Status` headings, not one", comment)
        self.assertNotIn("a reader sees 2 `Evidence Status` headings", comment)
        # Both tags named, in the comment, because the refusal names both.
        self.assertIn("(`<span>`)", comment)
        self.assertIn("(`<del>`)", comment)
        # And no sentence that can only count to two.
        self.assertNotIn("both headings", comment)
        self.assertNotIn("names yours as the one carrying the tag", comment)

    def test_the_comment_says_which_head_it_was_read_from(self) -> None:
        # What makes it once per head rather than once per run: the line is
        # visible, and the next turn at the same commit finds it.
        execution = sys.modules["execution"]
        note = self.helpers().rejected_heading_note(
            self.written(self.SHAPES["span"][0]), "Evidence Status"
        )
        assert note is not None
        head = "0123456789abcdef0123456789abcdef01234567"
        comment = execution.compose_rejected_heading_comment("April", note, head)
        self.assertIn(execution.rejected_heading_checked_line(head), comment)
        self.assertIn(head, comment)
        self.assertNotIn(execution.rejected_heading_checked_line("f" * 40), comment)


class TextUnderTheHeadingKeepsAHomeTests(unittest.TestCase):
    """A re-render of `## Evidence Status` moves what is not a status line rather than dropping it (#1725).

    The section is rebuilt from the recorded entries on every lane run and
    every factory turn, so a note an author left for a reviewer, a link to a
    run, or a pasted log excerpt was gone by the next write. Keeping it where
    it was is not available: the readers refuse any block under the heading
    that is not a list (#1701, #1709), so text preserved in place produces a
    body the reader then refuses. So the grammar is explicit -- under the
    heading a status line is the machine's and everything else is a note --
    and a note gets a section of its own directly below.
    """

    ITEM = "`swift test` passes"
    NOTE = "A note for the reviewer: the fixture state survived the relaunch."
    LINK = "Run: https://example.invalid/actions/runs/1"
    EXCERPT = "```\n214 tests passed\n```"

    def meta(self, status: str = "pending-ci", detail: str = "the lane has not run yet") -> str:
        entry = {"index": 1, "item": self.ITEM, "status": status, "detail": detail, "kind": "test"}
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def body(self, under_heading: str, *, status: str = "pending-ci",
             detail: str = "the lane has not run yet") -> str:
        return (
            self.meta(status, detail)
            + f"## Evidence Status\n\n- [{status}] {self.ITEM} -- {detail}\n"
            + under_heading
            + "\n## Validation\n\n- ran the suite on this head\n"
        )

    NOTES_BODY_TAIL = f"\n{NOTE}\n\n{LINK}\n\n{EXCERPT}\n"

    def resolved(self, body: str) -> str:
        return sys.modules["evidence"].update_evidence_entries(
            body, {1: {"status": "complete", "detail": "214 tests passed"}}
        )

    @staticmethod
    def notes_section(body: str) -> str:
        return sys.modules["_helpers"].markdown_section(body, "Evidence Notes")

    # The test's own reading of what is not an entry, deliberately not the
    # writer's: a bullet whose text carries a status token and a `--` split.
    # The fixtures below keep no such line inside a fence, so a source line is
    # an entry here exactly when a reader would read it as one.
    ENTRY_LINE_RE = re.compile(r"^- \[(?:complete|blocked|pending-ci)\] .+ -- .+$")

    def non_entry_lines(self, body: str) -> list[str]:
        section = sys.modules["_helpers"].markdown_section(body, "Evidence Status")
        return [
            line for line in section.splitlines()
            if line.strip() and not self.ENTRY_LINE_RE.match(line)
        ]

    @staticmethod
    def section_boundaries(body: str) -> tuple[list[str], list[int]]:
        """The body's lines, and the line each section boundary a reader has begins on.

        The oracle for "a heading a reader has" is the parse. A scan for
        `^## ` is not one: it calls a `## ` line inside a fence a heading and
        does not see a setext heading at all. Neither is `_rendered_lines`,
        which emits a fence's content verbatim by design (`evidence.py`), so
        it says yes to that same fenced line. `is_section_boundary` is the
        predicate production uses for where a section ends -- an h1 or h2
        however the author made it, or a dash rule -- and a successor is
        exactly that.

        A setext heading's token maps to the line its TEXT is on, not its
        underline, which is where a reader sees the new section begin and so
        the line a carried block has to stay above.
        """
        helpers = sys.modules["_helpers"]
        normalized = helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", body)
        return normalized.split("\n"), [
            token.map[0]
            for token in helpers.MARKDOWN.parse(normalized)
            if token.map and helpers.is_section_boundary(token)
        ]

    @staticmethod
    def line_offsets(lines: list[str]) -> list[int]:
        """Where each line starts, in characters, so an offset comparison can be made against it."""
        offsets, running = [], 0
        for line in lines:
            offsets.append(running)
            running += len(line) + 1
        return offsets

    def notes_lines(self, body: str) -> list[str]:
        """The Evidence Notes section's lines, sliced rather than read, and ended by the parser.

        `markdown_section` trims the section it returns, which takes the
        indentation off a leading indented block -- and that indentation is
        the difference between a code block and whatever its first line would
        otherwise be read as. So the text comes back as the author's bytes.

        Where it ENDS is the parser's answer, not the next `^## ` line. That
        scan reports both ways on the shapes this class now carries: it runs
        past a setext heading, sweeping the author's own next section in as if
        the write had carried it, and it stops at a `## ` line inside a fence,
        losing the rest of a note that was carried whole (#1733).
        """
        marker = "## Evidence Notes"
        lines, boundaries = self.section_boundaries(body)
        if marker not in lines:
            return []
        start = lines.index(marker)
        end = next((line_no for line_no in boundaries if line_no > start), len(lines))
        return [line for line in lines[start + 1 : end] if line.strip()]

    def test_a_note_a_link_and_an_excerpt_move_to_evidence_notes(self) -> None:
        body = self.body(self.NOTES_BODY_TAIL)
        resolved = self.resolved(body)

        # The entries are rewritten, which is what the re-render is for.
        self.assertIn(f"- [complete] {self.ITEM} -- 214 tests passed", resolved)
        self.assertNotIn("the lane has not run yet", resolved)
        # And the three blocks are carried, verbatim and in the order written.
        notes = self.notes_section(resolved)
        self.assertEqual(notes, f"{self.NOTE}\n\n{self.LINK}\n\n{self.EXCERPT}")
        # The section the reader reads is now only the machine's.
        lines, unreadable = sys.modules["evidence"]._rendered_status_lines(resolved)
        self.assertIsNone(unreadable)
        self.assertEqual(lines, [f"[complete] {self.ITEM} -- 214 tests passed"])
        # A second run moves nothing: the notes are already where they belong.
        self.assertEqual(self.resolved(resolved), resolved)

    def test_the_factory_turn_writes_the_same_notes_to_the_same_place(self) -> None:
        # Two writers of one section disagreeing about what a body carries is
        # the failure #1729 named; they share the function that decides. Each
        # is handed the body it carries FROM, which is the same body here:
        # the lane rewrites the published body, and the turn is told that the
        # published body is where a person's text can be (#1751, round 18).
        body = self.body(self.NOTES_BODY_TAIL)
        rendered, errors = run_contributor.render_execution_summary_body(
            body,
            requested_evidence=[self.ITEM],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
            published_body=body,
        )
        self.assertEqual(errors, [])
        notes = self.notes_section(rendered)
        # Non-empty, or the two writers agree by both dropping the text.
        self.assertIn(self.NOTE, notes)
        self.assertEqual(notes, self.notes_section(self.resolved(body)))
        self.assertIn(f"- [complete] {self.ITEM} -- 214 tests passed", rendered)

    def test_a_note_moves_whatever_line_endings_the_client_sent(self) -> None:
        # GitHub stores a body with the endings the client sent, and the notes
        # are sliced out of the stored text rather than a re-render of it, so
        # a CRLF body is where a slice taken by one reading and cut by another
        # would show up (#1710).
        body = self.body(f"\n{self.NOTE}\n").replace("\n", "\r\n")
        resolved = self.resolved(body)
        self.assertEqual(self.notes_section(resolved), self.NOTE)
        self.assertEqual(self.resolved(resolved), resolved)

    def test_a_body_with_nothing_but_entries_gains_no_section(self) -> None:
        resolved = self.resolved(self.body(""))
        self.assertNotIn("Evidence Notes", resolved)

    def test_a_checked_box_is_a_note_and_not_an_entry(self) -> None:
        # `- [x] done` is a list item and carries no status token, so the owner
        # read refuses the section it sits in. It is a note, and moving it is
        # what makes the section readable again.
        resolved = self.resolved(self.body("- [x] pasted the log into the thread\n"))
        self.assertEqual(self.notes_section(resolved), "- [x] pasted the log into the thread")
        self.assertIsNone(sys.modules["evidence"]._rendered_status_lines(resolved)[1])

    def test_a_block_with_no_end_stands_the_write_down_rather_than_being_deleted(self) -> None:
        # A fence with no closing line has no end the body states, and the
        # section's end is then a heading only the repaired parse can see. The
        # rewrite used to cut to it, which deleted the opener and the author's
        # log with it and showed the lines below as markdown; it stands the
        # body down instead (#1734, round 2). The cost is real and accepted:
        # the lane cannot write this body again until someone closes the
        # fence, and the run says which line that is.
        body = self.body("\n```\n214 tests passed\n")
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            resolved = self.resolved(body)
        self.assertEqual(resolved, body)
        self.assertIn("```", resolved)
        self.assertIn("only a repaired parse can see", spoke.getvalue())

    def test_a_section_whose_end_is_hidden_still_refuses_in_both_writers(self) -> None:
        # The refusal that is not new: an HTML block with no closer runs to
        # the end of the body, so where this section ends is not something the
        # body says (#1729). Both writers leave the body byte for byte as it
        # stands, where the lane re-render used to record the entries anyway.
        evidence = sys.modules["evidence"]
        body = self.body("\n<!-- a note I never closed\n")
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            resolved = evidence.update_evidence_entries(
                body, {1: {"status": "complete", "detail": "214 tests passed"}}
            )
        self.assertEqual(resolved, body)
        self.assertIn("refusing to rewrite the `Evidence Status` section", spoke.getvalue())
        rendered, errors = run_contributor.render_execution_summary_body(
            body,
            requested_evidence=[self.ITEM],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
        )
        self.assertEqual(rendered, body)
        self.assertTrue(
            any("Evidence Status section was not rewritten" in error for error in errors), errors
        )

    def test_a_block_the_parser_cannot_end_is_not_carried_at_any_depth(self) -> None:
        # A container carries its contents. An unclosed comment inside a quote
        # is the same hazard as one at the top of the body: moved, it runs to
        # the end of wherever it lands and takes the sections after it with
        # it. A check that looked only at top-level blocks carried the quote.
        evidence = sys.modules["evidence"]
        for label, tail in (
            ("a quoted unclosed comment", "\n> <!-- an author note I never closed\n> keep this\n"),
            ("an unclosed comment in a bullet", "- see below\n  <!-- never closed\n"),
        ):
            with self.subTest(block=label):
                spoke = io.StringIO()
                with contextlib.redirect_stderr(spoke):
                    resolved = self.resolved(self.body(f"{tail}\nplain note beside it\n"))
                self.assertNotIn("<!--", self.notes_section(resolved))
                self.assertIn("a raw HTML block with no `-->`", spoke.getvalue())
                # The note that the parser can end still moves.
                self.assertIn("plain note beside it", self.notes_section(resolved))
                # And the section below the block is still a heading a reader
                # sees, which is what an unclosed comment would swallow.
                self.assertIn("## Validation", evidence._rendered_lines(resolved))

    def test_a_closed_html_block_is_carried_because_the_parser_ends_it(self) -> None:
        # The rule is about blocks the parser cannot end, and it does not reach
        # a block that closes. Kinds 6 and 7 end at a blank line and kinds 1 to
        # 5 at the closer they wrote, so deleting a `<details>` note a reader
        # can see -- on the grounds that something inside it might still be
        # open -- would be this issue again in a narrower form.
        for label, tail in (
            ("a closed details block", "\n<details>\n<summary>More</summary>\n\nplain note\n\n</details>\n"),
            ("a void tag on its own line", "\n<img src=x>\n"),
            ("a quoted closed comment", "\n> <!-- a closed one -->\n> beside it\n"),
            ("a closed comment with text beside it", "\n<!-- a closed one -->\nbeside it\n"),
        ):
            with self.subTest(block=label):
                spoke = io.StringIO()
                with contextlib.redirect_stderr(spoke):
                    resolved = self.resolved(self.body(tail))
                self.assertEqual(self.notes_lines(resolved), [l for l in tail.splitlines() if l.strip()])
                self.assertNotIn("not carried", spoke.getvalue())

    def test_an_item_that_opens_with_a_block_is_the_author_s_and_moves_whole(self) -> None:
        # The item's own first line decides, not the first line of whatever it
        # wraps: reading a table's header row as the item's text called the
        # item the machine's and deleted the table with it.
        resolved = self.resolved(
            self.body("\n- | [complete] a reviewer table |\n  | --- |\n  | keep me |\n")
        )
        self.assertIn("| keep me |", self.notes_section(resolved))
        self.assertIn("| [complete] a reviewer table |", self.notes_section(resolved))

    def test_a_reference_definition_under_a_status_bullet_is_carried(self) -> None:
        # The parser folds it into the item above, so a status item claiming
        # its whole span took the definition with it -- and the link in the
        # body below then rendered as literal text.
        resolved = self.resolved(self.body("\n  [run]: https://example.invalid/1\n"))
        self.assertEqual(self.notes_lines(resolved), ["  [run]: https://example.invalid/1"])

    def test_a_fenced_heading_in_a_moved_note_does_not_swallow_the_next_write(self) -> None:
        # The move puts a note somewhere a later write looks. A `## Validation`
        # inside a fenced example is code, not a heading, and a writer placing
        # its section "before Validation" by matching the line wrote the whole
        # status list and the metadata INSIDE the fence -- so the second pass
        # left a body showing no Evidence Status heading at all.
        evidence = sys.modules["evidence"]
        body = self.body("\n```markdown\n## Validation\nexample only\n```\n")
        once = self.resolved(body)
        twice = self.resolved(once)
        self.assertEqual(twice, once)
        self.assertIn("```markdown", self.notes_section(once))
        lines, unreadable = evidence._rendered_status_lines(once)
        self.assertIsNone(unreadable)
        self.assertEqual(lines, [f"[complete] {self.ITEM} -- 214 tests passed"])

    def test_a_fenced_notes_example_is_left_where_it_is_and_the_write_goes_ahead(self) -> None:
        # The cut used to take every `## Evidence Notes` LINE, so one inside a
        # fenced example was a section it would cut from -- taking the fence's
        # closing line with it -- and the writer stood the whole body down to
        # avoid that. The cut takes headings now, and a fenced line is not
        # one: the example stays exactly as its author wrote it, the notes
        # section the write needs is placed beside it, and nothing is refused
        # (#1730).
        evidence = sys.modules["evidence"]
        helpers = sys.modules["_helpers"]
        body = (
            self.meta() + f"## Evidence Status\n\n- [pending-ci] {self.ITEM} -- the lane has not"
            " run yet\n\nA note.\n\n## Validation\n\n```markdown\n## Evidence Notes\nexample\n```\n"
        )
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            resolved = evidence.update_evidence_entries(
                body, {1: {"status": "complete", "detail": "214 tests passed"}}
            )
        self.assertNotEqual(resolved, body)
        self.assertEqual(spoke.getvalue(), "")
        self.assertIn("```markdown\n## Evidence Notes\nexample\n```", resolved)
        self.assertEqual(self.notes_section(resolved), "A note.")
        self.assertIn(f"- [complete] {self.ITEM} -- 214 tests passed", resolved)
        # The page shows one notes heading, not the example's, and a second
        # write is a fixed point.
        self.assertTrue(helpers.has_markdown_section(resolved, "Evidence Notes"))
        self.assertEqual(self.resolved(resolved), resolved)
        # And a heading line carrying trailing spaces writes the same way it
        # always did -- that shape was never the refusal's.
        spaced = body.replace("## Evidence Notes\nexample", "## Evidence Notes  \nexample")
        self.assertNotEqual(
            evidence.update_evidence_entries(
                spaced, {1: {"status": "complete", "detail": "214 tests passed"}}
            ),
            spaced,
        )

    def test_a_fenced_example_of_the_placement_heading_is_not_placed_in_front_of(self) -> None:
        # A body quoting the format shows `## Validation` as code somewhere
        # above its real one. A writer that places its section before the
        # first matching line writes it inside that fence, taking the status
        # list and the metadata out of the rendered body -- so the placement
        # walks to the first match the page shows as a heading.
        evidence = sys.modules["evidence"]
        body = (
            self.meta()
            + "## Summary\n\nThe format:\n\n```markdown\n## Validation\n- ran it\n```\n\n"
            + f"## Evidence Status\n\n- [pending-ci] {self.ITEM} -- the lane has not run yet\n"
            + "\nA note.\n\n## Validation\n\n- ran the suite on this head\n"
        )
        resolved = self.resolved(body)
        self.assertEqual(resolved.count("```"), 2)
        self.assertLess(resolved.index("```markdown"), resolved.index("## Evidence Status"))
        lines, unreadable = evidence._rendered_status_lines(resolved)
        self.assertIsNone(unreadable)
        self.assertEqual(lines, [f"[complete] {self.ITEM} -- 214 tests passed"])
        self.assertEqual(self.notes_section(resolved), "A note.")
        self.assertEqual(self.resolved(resolved), resolved)
        # And in this order, which an implementation that only ever appended
        # would also satisfy for the fence but not for all three.
        self.assertLess(
            resolved.index("## Evidence Status"), resolved.index("## Evidence Notes")
        )
        self.assertLess(
            resolved.index("## Evidence Notes"),
            resolved.index("## Validation\n\n- ran the suite on this head"),
        )

    def test_a_heading_on_the_last_line_is_replaced_rather_than_duplicated(self) -> None:
        # In response to the confirmation pass. The cut matched a heading only
        # where a newline followed it, so a body ending on its heading had a
        # section every reader could see and none the cut could take: the write
        # placed a second copy above and left the first standing. Reached in
        # production through the blocked note, which writes `## Validation` on
        # a body whose last line is that heading.
        helpers = sys.modules["_helpers"]
        body = "intro\n\n## Evidence Status"
        written = helpers.insert_markdown_section(body, "Evidence Status", "- new")
        self.assertEqual(written.count("## Evidence Status"), 1)
        self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "- new")
        pending = (
            "## Summary\n\nwhat\n\n## Evidence Status\n\n"
            "- [pending-ci] proof -- waiting\n\n## Validation"
        )
        rendered, errors = run_contributor.render_execution_summary_body(
            pending,
            requested_evidence=["proof"],
            evidence_complete=None,
            evidence_blocked=None,
            evidence_pending_ci=["1 -- waiting"],
        )
        self.assertEqual(errors, [])
        self.assertEqual(rendered.count("## Validation"), 1)

    def test_a_body_whose_client_sent_bare_carriage_returns_has_its_sections(self) -> None:
        # The gate normalises every line ending GitHub stores before it reads;
        # the cut's pattern took `\r\n` and `\n` but not a bare `\r`, so one
        # file read a section of this body and the other read none of it.
        helpers = sys.modules["_helpers"]
        body = "## Evidence Status\r\r- [complete] x -- y\r\r## Validation\r- ran it\r"
        self.assertEqual(helpers.markdown_section(body, "Evidence Status"), "- [complete] x -- y")
        self.assertTrue(helpers.has_markdown_section(body, "Validation"))

    def test_a_rewrite_keeps_the_hard_break_on_the_line_above_the_section(self) -> None:
        # Two spaces at the end of the line above a section are a hard break on
        # the page, and a splice that trimmed them changed how a body renders
        # around a section it was only asked to replace. The line BELOW is the
        # asymmetry, and it is deliberate: its leading whitespace comes off,
        # because an indent kept there stops it being a boundary once the
        # section's own content is a list, and the section then runs past the
        # heading that used to end it -- which the rewrite sweep catches.
        helpers = sys.modules["_helpers"]
        body = "intro with hard break  \n## Evidence Status\nold\n\n## Validation\nkeep\n"
        written = helpers.insert_markdown_section(body, "Evidence Status", "new")
        self.assertIn("intro with hard break  \n", written)
        self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "new")
        self.assertIn("## Validation\nkeep", written)
        indented = helpers.insert_markdown_section(
            "intro\n\n## Evidence Status\nold\n   ## Validation\nkeep\n",
            "Evidence Status",
            "- [complete] x -- proof",
        )
        self.assertEqual(
            helpers.markdown_section(indented, "Evidence Status"), "- [complete] x -- proof"
        )

    def test_the_notes_land_under_the_status_and_not_merely_above_the_next_heading(self) -> None:
        # The two placements this writer could use are the same placement on
        # every fixture where `## Evidence Status` is the heading directly
        # above `## Validation`, which is every fixture the file had. Here an
        # author's own h1 section sits between them, so "directly below the
        # status" and "above the next Validation heading" are different lines,
        # and only one of them is the promise the writer's docstring makes
        # (#1733's first gap, live in this PR's writer).
        body = (
            self.meta()
            + f"## Evidence Status\n\n- [pending-ci] {self.ITEM} -- the lane has not run yet\n"
            + f"\n{self.NOTE}\n"
            + "\n# Release blockers\n\n- the signing profile is missing\n"
            + "\n## Validation\n\n- ran the suite on this head\n"
        )
        resolved = self.resolved(body)
        self.assertEqual(self.notes_section(resolved), self.NOTE)
        self.assertLess(
            resolved.index("## Evidence Notes"), resolved.index("# Release blockers")
        )
        self.assertLess(
            resolved.index("## Evidence Status"), resolved.index("## Evidence Notes")
        )
        # The author's section is untouched and a second write moves nothing.
        self.assertIn("- the signing profile is missing", resolved)
        self.assertEqual(self.resolved(resolved), resolved)

    def test_an_empty_notes_section_goes_rather_than_outliving_the_status(self) -> None:
        # A heading with nothing under it is a section this writer would place
        # next run and a reader finds above the status now: leaving it is what
        # let a second write put Evidence Notes before Evidence Status.
        body = self.body("") + "\n## Evidence Notes\n"
        resolved = self.resolved(body)
        self.assertNotIn("Evidence Notes", resolved)
        self.assertEqual(self.resolved(resolved), resolved)

    def test_a_notes_heading_carrying_trailing_spaces_is_the_section_it_looks_like(self) -> None:
        # The recorded limit, gone. A heading line with trailing spaces is one
        # a reader sees, and the cut used to pass over it: the old notes
        # section stood where it was and the status was placed below it, so a
        # body ended up showing two notes-shaped headings. The heading is a
        # token now, whitespace normalised, so the cut takes it and the notes
        # come back as one section under the status -- what the writer's own
        # docstring promises (#1730).
        evidence = sys.modules["evidence"]
        body = self.body("\nA note.\n\n## Evidence Notes   \n\nolder note\n")
        once = self.resolved(body)
        self.assertEqual(self.resolved(once), once)
        self.assertNotIn("## Evidence Notes   ", once)
        self.assertEqual(once.count("## Evidence Notes"), 1)
        self.assertLess(once.index("## Evidence Status"), once.index("## Evidence Notes"))
        self.assertIsNone(evidence._rendered_status_lines(once)[1])
        # Both notes are in the one section, the older first.
        self.assertEqual(self.notes_section(once), "older note\n\nA note.")

    def test_a_body_at_the_limit_keeps_the_status_it_cannot_keep_the_notes_with(self) -> None:
        # A body GitHub will not store is not a body. Carrying the notes past
        # the limit would fail the edit outright, so the status the lane just
        # resolved would go unwritten too -- the write keeps the status and
        # says on the run's output which notes it could not carry.
        evidence = sys.modules["evidence"]
        status = f"- [complete] {self.ITEM} -- 214 tests passed"
        shell = f"## Evidence Status\n\n{status}\n\n\n\n## Validation\n\n- ran it\n"
        note = "n" * (evidence.PR_BODY_LIMIT - len(shell))
        body = f"## Evidence Status\n\n{status}\n\n{note}\n\n## Validation\n\n- ran it\n"
        self.assertLessEqual(len(body), evidence.PR_BODY_LIMIT)
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            written, refusal, _ = evidence.write_evidence_status_section(
                body, [status], notes_from=body, entries=entries_for([status]), previous_entries=entries_for([status]), recorded_items=[self.ITEM]
            )
        self.assertIsNone(refusal)
        self.assertLessEqual(len(written), evidence.PR_BODY_LIMIT)
        self.assertIn(status, written)
        self.assertNotIn("Evidence Notes", written)
        self.assertIn("not written", spoke.getvalue())
        # The control: the same body one block shorter does carry it.
        shorter = body.replace(note, note[:-32], 1)
        carried, _, _ = evidence.write_evidence_status_section(
            shorter, [status], notes_from=shorter, entries=entries_for([status]), previous_entries=entries_for([status]), recorded_items=[self.ITEM]
        )
        self.assertIn("## Evidence Notes", carried)
        # And where the status alone is already past the limit, dropping the
        # notes buys nothing: the edit fails either way, so the text is kept
        # rather than traded for a body that still cannot be stored.
        huge = f"- [complete] {self.ITEM} -- " + "x" * evidence.PR_BODY_LIMIT
        kept, _, _ = evidence.write_evidence_status_section(
            body, [huge], notes_from=body, entries=entries_for([huge]), previous_entries=entries_for([huge]), recorded_items=[self.ITEM]
        )
        self.assertIn("## Evidence Notes", kept)

    def test_a_body_at_the_limit_announces_the_notes_it_dropped(self) -> None:
        # Said on the run's output AND handed back, like every other loss: the
        # author whose text was dropped for length reads the pull request, and
        # the size is the one reason for a drop they can act on (#1740).
        evidence = sys.modules["evidence"]
        status = f"- [complete] {self.ITEM} -- 214 tests passed"
        shell = f"## Evidence Status\n\n{status}\n\n\n\n## Validation\n\n- ran it\n"
        note = "n" * (evidence.PR_BODY_LIMIT - len(shell))
        body = f"## Evidence Status\n\n{status}\n\n{note}\n\n## Validation\n\n- ran it\n"
        with contextlib.redirect_stderr(io.StringIO()):
            written = evidence.write_evidence_status_section(
                body, [status], notes_from=body, entries=entries_for([status]), previous_entries=entries_for([status]), recorded_items=[self.ITEM]
            )
        self.assertIsNone(written.refusal)
        self.assertNotIn("Evidence Notes", written.body)
        self.assertEqual(len(written.announcements), 1, written.announcements)
        announcement = written.announcements[0]
        self.assertIn("not written", announcement)
        self.assertIn(str(evidence.PR_BODY_LIMIT), announcement)
        self.assertIn("1 block(s)", announcement)
        # The control: one block shorter carries the note and announces nothing.
        shorter = body.replace(note, note[:-32], 1)
        with contextlib.redirect_stderr(io.StringIO()):
            carried = evidence.write_evidence_status_section(
                shorter, [status], notes_from=shorter, entries=entries_for([status]), previous_entries=entries_for([status]), recorded_items=[self.ITEM]
            )
        self.assertIn("## Evidence Notes", carried.body)
        self.assertEqual(carried.announcements, [])

    def test_a_block_indented_under_a_status_bullet_moves_whole(self) -> None:
        # The bullet's own line is the machine's; a log pasted beneath it
        # belongs to the bullet only because the parser folds it there. Left to
        # the per-line sweep the fence markers came off and the two log lines
        # came out as separate paragraphs -- text altered rather than carried,
        # which is worse than text deleted, because it looks like the author's
        # words with the meaning changed.
        for label, nested in (
            ("a fenced excerpt", "  ```\n  log line one\n  log line two\n  ```\n"),
            ("a nested list", "  - one thing I checked\n  - and another\n"),
            ("an indented paragraph after a blank line", "\n  a second paragraph of the bullet\n"),
        ):
            with self.subTest(block=label):
                body = self.body(nested)
                resolved = self.resolved(body)
                self.assertEqual(
                    self.notes_lines(resolved), [l for l in nested.splitlines() if l.strip()]
                )
                self.assertIn(f"- [complete] {self.ITEM} -- 214 tests passed", resolved)
                self.assertIsNone(sys.modules["evidence"]._rendered_status_lines(resolved)[1])
                self.assertEqual(self.resolved(resolved), resolved)

    def test_a_status_line_wrapped_over_several_lines_goes_whole_and_says_so(self) -> None:
        # A soft-wrapped status line is one line on the page and one sentence
        # of the author's. The rewrite replaces it from the entries in hand, so
        # the continuation goes with it -- carrying half a sentence into a
        # section of its own would be the alteration the case above is against.
        # What is owed is the saying, not the keeping.
        body = self.body("  more about it\n  and more\n")
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            resolved = self.resolved(body)
        self.assertNotIn("more about it", resolved)
        self.assertNotIn("Evidence Notes", resolved)
        self.assertIn("2 line(s) continuing the status line", spoke.getvalue())

    def test_every_block_not_carried_is_named_on_the_run_s_output(self) -> None:
        # A loss nobody can see is the failure this file keeps paying for.
        for label, tail, expected in (
            # Nested, because an unclosed comment at the top of the section
            # hides where the section ends and the whole write refuses first.
            ("an unclosed comment in a quote", "\n> <!-- a note I never closed\n> keep this\n", "a raw HTML block with no `-->`"),
            ("a wrapped status line", "  more about it\n", "continuing the status line"),
        ):
            with self.subTest(block=label):
                spoke = io.StringIO()
                with contextlib.redirect_stderr(spoke):
                    self.resolved(self.body(tail))
                said = spoke.getvalue()
                self.assertIn("not carried to `## Evidence Notes`", said)
                self.assertIn(expected, said)
                self.assertIn("of the `Evidence Status` section", said)

    BYTE_FIXTURES = (
        ("a fence indented under the status bullet", "  ```\n  log line one\n  log line two\n  ```\n"),
        ("an indented code block", "\n    214 tests passed\n\nand a note under it.\n"),
        ("a table", "\n| run | result |\n| --- | --- |\n| 1 | green |\n"),
        ("a closed details note", "\n<details>\n<summary>More</summary>\n\nplain note\n\n</details>\n"),
        ("a quoted block", "\n> a reviewer asked about the fixture\n> and about the log\n"),
        ("a line with trailing spaces", "\nthe run printed this:   \n"),
    )

    def status_section_lines(self, body: str) -> list[str]:
        """The Evidence Status section's lines, sliced rather than read.

        The same raw slice `notes_lines` takes, for the same reason: a section
        read through `markdown_section` comes back trimmed, and the trimming is
        exactly what this property is about.
        """
        marker = "## Evidence Status\n"
        body = body.replace("\r\n", "\n")
        rest = body[body.index(marker) + len(marker) :]
        end = re.search(r"(?m)^## ", rest)
        return [line for line in (rest[: end.start()] if end else rest).splitlines() if line.strip()]

    def test_every_line_carried_is_the_source_line_byte_for_byte(self) -> None:
        # A mover that reformats is not a mover. Indentation, fence markers and
        # trailing spaces all survive, in the order they were written -- line
        # endings excepted, which every writer of this body has always emitted
        # as `\n` (a CRLF body is mixed after any write, as #1710 records).
        for label, tail in self.BYTE_FIXTURES + (("the same body in CRLF", None),):
            with self.subTest(body=label):
                raw = self.body(self.BYTE_FIXTURES[0][1] if tail is None else tail)
                body = raw.replace("\n", "\r\n") if tail is None else raw
                source = [line.rstrip("\r") for line in self.status_section_lines(body)]
                carried = [line.rstrip("\r") for line in self.notes_lines(self.resolved(body))]
                # Per fixture rather than as a total below the loop. The loop
                # body asserts nothing at all on a fixture that carried
                # nothing, so something has to say so -- and a sum over the set
                # is the wrong thing to say it with: it passes on one large
                # fixture beside five empty ones, and it names none of them
                # (#1733).
                self.assertTrue(carried, f"{label} carried nothing")
                pointer = 0
                for line in carried:
                    while pointer < len(source) and source[pointer] != line:
                        pointer += 1
                    self.assertLess(
                        pointer, len(source), f"{line!r} is not a line of the source section"
                    )
                    pointer += 1

    # Two blocks whose adjacency is a heading: a line of `=` directly under a
    # line of text is that text's setext underline, so the blank line between
    # them is the difference between two paragraphs and an h1 the author never
    # wrote. Written in both orders because the seam is between the blocks and
    # not a property of either one.
    TEXT_THEN_EQUALS_TAIL = "\nA note for the reviewer.\n\n===\n"
    EQUALS_THEN_TEXT_TAIL = "\n===\n\nA note for the reviewer.\n"
    # The same hazard at the other seam: the author's own `---` thematic break
    # is what follows the notes, and a carried line landing directly above it
    # turns the rule into that line's underline.
    AUTHOR_RULE_BELOW = "---\n\nA closing remark.\n"

    PLACEMENT_FIXTURES = BYTE_FIXTURES + (
        # The case the order is really for: an element left open folds what
        # follows it on GitHub's page, so where the write puts it is the whole
        # question, and no parser-based oracle can see that.
        ("an element left open", "\n<details>\n<summary>More</summary>\n\nplain note\n"),
        ("a fenced excerpt", "\n```\n214 tests passed\n```\n"),
        ("a quoted note", "\n> a reviewer asked about the fixture\n"),
        ("a text note above a line of equals", TEXT_THEN_EQUALS_TAIL),
        ("a line of equals above a text note", EQUALS_THEN_TEXT_TAIL),
    )

    ITEMS = (ITEM, "`pnpm test` in `web-next` passes", "the fixture state survives a relaunch")
    NOTE_TAIL = "\nA note for the reviewer.\n"
    OPEN_ELEMENT_TAIL = "\n<details>\n<summary>More</summary>\n\nplain note\n"
    ONE_HEADING_BELOW = "## Validation\n\n- ran the suite on this head\n"
    TWO_HEADINGS_BELOW = ONE_HEADING_BELOW + "\n## Risks\n\nNone.\n"
    RISKS_ALONE_BELOW = "## Risks\n\nNone.\n"
    # A setext h2 under the status list, with a plain line above it so the
    # heading is the underlined line alone. The page shows a heading there and
    # a `^## ` scan sees none, so the scan skipped to `## Validation` and a
    # block placed between the two passed every assertion while sitting in the
    # author's own section (#1733).
    SETEXT_AFTER_PLAIN_TAIL = "\nordinary carried note\n\nBoundary note\n-------------\n"
    # The same disagreement the other way: a `## ` line inside a fence is code
    # on the page, and the scan returned it as the successor and truncated the
    # carried lines at it.
    FENCED_HEADING_TAIL = "\nA note for the reviewer.\n\n```markdown\n## Not a heading\n```\n"
    # The setext heading with nothing above it: it ends the status section at
    # the line below the status list, so there is no block under the heading
    # to carry at all. Its own test, not a placement fixture, because a
    # placement fixture has to carry something.
    SETEXT_ALONE_TAIL = "\nBoundary note\n-------------\n"

    def interleaved_body(
        self,
        tail: str,
        *,
        entries: int = 1,
        note_after: int = 1,
        below: str = ONE_HEADING_BELOW,
    ) -> str:
        """A body carrying `entries` status lines, with `tail` written after the `note_after`-th.

        `self.body` writes one status line and one heading below the section,
        which is the shape where both bounds of the placement collapse into
        weaker ones that hold wherever the block lands. This says how many of
        each the body carries.
        """
        items = self.ITEMS[:entries]
        status = [f"- [pending-ci] {item} -- the lane has not run yet" for item in items]
        meta = {
            "entries": [
                {
                    "index": index + 1,
                    "item": item,
                    "status": "pending-ci",
                    "detail": "the lane has not run yet",
                    "kind": "test",
                }
                for index, item in enumerate(items)
            ]
        }
        section = "\n".join(status[:note_after]) + "\n" + tail + "\n".join(status[note_after:])
        return (
            "<!-- evidence-status:v1\n" + json.dumps(meta) + "\n-->\n\n"
            + "## Evidence Status\n\n" + section.rstrip("\n") + "\n\n" + below
        )

    def resolve_entries(self, body: str, entries: int) -> str:
        return sys.modules["evidence"].update_evidence_entries(
            body,
            {
                index + 1: {"status": "complete", "detail": f"{214 + index} tests passed"}
                for index in range(entries)
            },
        )

    def placement_bodies(self) -> list[tuple[str, str, int]]:
        """Every body the placement is asserted over, each with the status lines it carries."""
        return [(label, self.body(tail), 1) for label, tail in self.PLACEMENT_FIXTURES] + [
            # A second heading below the section is where "directly below the
            # status" and "somewhere above the next heading" come apart: a
            # block written under `## Validation` satisfies the second.
            (
                "a note with a second heading below the section",
                self.interleaved_body(self.NOTE_TAIL, below=self.TWO_HEADINGS_BELOW),
                1,
            ),
            (
                "an element left open with a second heading below the section",
                self.interleaved_body(self.OPEN_ELEMENT_TAIL, below=self.TWO_HEADINGS_BELOW),
                1,
            ),
            # The successor is whatever the author wrote under the status list,
            # which is not always the `## Validation` the status itself is
            # placed in front of.
            (
                "a section whose successor is Risks, with no Validation at all",
                self.interleaved_body(self.NOTE_TAIL, below=self.RISKS_ALONE_BELOW),
                1,
            ),
            # Below the LAST status line is the property. With one status line
            # per body it is also below the first, and a block left sitting
            # between two of them reads the same as one below them all.
            (
                "a note between two status lines",
                self.interleaved_body(
                    self.NOTE_TAIL, entries=2, note_after=1, below=self.TWO_HEADINGS_BELOW
                ),
                2,
            ),
            (
                "a note between the second and third status lines",
                self.interleaved_body(
                    self.NOTE_TAIL, entries=3, note_after=2, below=self.TWO_HEADINGS_BELOW
                ),
                3,
            ),
            (
                "an element left open between two status lines",
                self.interleaved_body(
                    self.OPEN_ELEMENT_TAIL, entries=2, note_after=1, below=self.TWO_HEADINGS_BELOW
                ),
                2,
            ),
            # The successor is a heading the page shows, however the author
            # made it one. A setext h2 is one and a `^## ` scan is blind to it.
            (
                "a note whose setext heading follows a plain line",
                self.interleaved_body(
                    self.SETEXT_AFTER_PLAIN_TAIL, below=self.TWO_HEADINGS_BELOW
                ),
                1,
            ),
            # And it is not a `## ` line the page shows as code. This note is
            # carried whole, fence and all, and the line inside it ends
            # nothing.
            (
                "a note carrying a fenced `## ` line",
                self.interleaved_body(self.FENCED_HEADING_TAIL, below=self.TWO_HEADINGS_BELOW),
                1,
            ),
            # The successor is a rule rather than a heading, which is the
            # shape where the carried region's tail seam decides whether the
            # author still has a rule.
            (
                "a note whose successor is the author's own dash rule",
                self.interleaved_body(self.NOTE_TAIL, below=self.AUTHOR_RULE_BELOW),
                1,
            ),
        ]

    # Which fixture exists for which varied shape, asserted by name. A `>=`
    # count over the set is not a guard: deleting the one fixture whose
    # successor is not `## Validation` left the old floors green, because it
    # scored false on both of them, and replacing the three-entry fixture with
    # a copy of the two-entry one did too. Every dimension here is read from
    # the fixture AS WRITTEN (`fixture_dimensions`), never from the write's
    # result -- a property read from the result can be satisfied by the defect
    # it guards, which is what the old count of fixtures with a heading below
    # the successor did when a wrong placement raised it from 5 to 15.
    FIXTURE_DIMENSIONS = {
        "a note with a second heading below the section": "a heading below the successor",
        "a section whose successor is Risks, with no Validation at all": (
            "a successor that is not `## Validation`"
        ),
        "a note between two status lines": "more than one status line",
        "a note between the second and third status lines": (
            "more than one status line above the note"
        ),
        "a note whose setext heading follows a plain line": "a setext successor",
        "a note carrying a fenced `## ` line": "a fenced `## ` line inside a note",
    }

    def fixture_dimensions(self, body: str) -> set[str]:
        """Which of the varied shapes this fixture carries, read from the fixture as written.

        The status section of the body the author wrote: how many status lines
        it holds, how many sit above the first line that is not one, what the
        first boundary below the heading is, and whether it holds a `## ` line
        the parser does not call a boundary.
        """
        lines, boundaries = self.section_boundaries(body)
        heading = lines.index("## Evidence Status")
        successor = next((line_no for line_no in boundaries if line_no > heading), len(lines))
        status_at = [
            line_no
            for line_no in range(heading + 1, successor)
            if self.ENTRY_LINE_RE.match(lines[line_no])
        ]
        note_at = next(
            (
                line_no
                for line_no in range(heading + 1, successor)
                if lines[line_no].strip() and line_no not in status_at
            ),
            successor,
        )
        found = set()
        if len(status_at) > 1:
            found.add("more than one status line")
        if len([line_no for line_no in status_at if line_no < note_at]) > 1:
            found.add("more than one status line above the note")
        if successor < len(lines):
            if lines[successor].strip() != "## Validation":
                found.add("a successor that is not `## Validation`")
            if not lines[successor].startswith("#"):
                found.add("a setext successor")
        if any(line_no > successor for line_no in boundaries):
            found.add("a heading below the successor")
        if any(
            lines[line_no].startswith("## ") and line_no not in boundaries
            for line_no in range(heading + 1, successor)
        ):
            found.add("a fenced `## ` line inside a note")
        return found

    def successor_heading(self, body: str) -> tuple[int, str] | None:
        """Where the status section's own successor begins, and the line it is.

        Read from the status section rather than from wherever the notes
        ended up. A boundary taken as the first `## ` below the notes heading
        moves with the notes: a block written under `## Validation` and above
        `## Risks` is then below its own boundary, every assertion holds, and
        a reader sees the notes in somebody else's section (#1733).

        The FIRST boundary a reader has below the status heading, the notes'
        own excepted, asked of the parser (`section_boundaries`). Both halves
        of that are load-bearing, and a `^## ` scan got each wrong in a
        different direction: on a body whose note ends in a setext heading the
        scan skipped past it to `## Validation`, so a block placed between the
        two -- in the author's own section, on the page -- was above the
        scan's pick and every assertion held; and on a note carrying a fenced
        `## ` line the scan returned that line, which is not a heading at all.
        Checking the pick against `_rendered_lines` catches neither: a fence's
        content is emitted there verbatim, and `## Validation` really is a
        heading -- just not the first one.
        """
        lines, boundaries = self.section_boundaries(body)
        offsets = self.line_offsets(lines)
        status = lines.index("## Evidence Status")
        for line_no in boundaries:
            if line_no <= status or lines[line_no].strip() == "## Evidence Notes":
                continue
            return offsets[line_no], lines[line_no].strip()
        return None

    def test_a_carried_block_lands_below_the_last_status_line_and_above_the_section_s_successor(
        self,
    ) -> None:
        """The order the page-level safety of a move rests on, in the form a test can check.

        A block that may fold what follows it -- a `<details>` with no
        `</details>` is the shape -- is safe to move only if it lands below
        every line the machine writes and above the heading the author wrote
        under the section. Then the status list is visible where the block used
        to hide it, and the block folds no more than it folded where the author
        put it.

        Both bounds are read from the status section, and both say something
        only because the corpus carries the shapes that tell them from weaker
        ones: with one status line per body "below the last" is "below the
        first", and with one heading under the section "above the section's
        successor" is "above whatever follows the notes", which a block in
        somebody else's section satisfies (#1733). The guard below the loop
        holds the corpus to those shapes by name.

        The successor is the first boundary a reader has, asked of the parser.
        A `^## ` scan is not that oracle in either direction: it skips a setext
        heading, so a block placed between one and the next `## ` line was
        above the scan's pick and in the author's section on the page; and it
        returns a `## ` line inside a fence, which is code. Neither does
        `_rendered_lines`, which emits a fence's content verbatim by design.

        Asserted by offset, over every carried line of every fixture, because
        the rendering oracle below cannot see it: put the notes above the
        status and `_rendered_lines` reports exactly what it reported before.

        A literal `## ` line written under the status list has no fixture here
        and cannot have one: it ends the section, so nothing below it is the
        section's to carry and there is no placement to assert. That is the
        third of the three shapes a `## ` line can take here, and the only one
        structurally out of reach -- the other two, a fenced copy and a setext
        heading, are fixtures above.
        """
        varied: dict[str, set[str]] = {}
        for label, body, entries in self.placement_bodies():
            with self.subTest(block=label):
                # Read from the fixture as written, before anything is
                # resolved, and kept for the guard below the loop.
                varied[label] = self.fixture_dimensions(body)
                resolved = self.resolve_entries(body, entries)
                carried = set(self.notes_lines(resolved))
                # Anti-vacuity first, so a fixture that carries nothing fails
                # here saying so rather than on the missing boundary.
                self.assertTrue(carried, f"{label} carried nothing")
                successor = self.successor_heading(resolved)
                self.assertIsNotNone(successor, "the section's successor did not survive the write")
                boundary, heading = successor
                # Located by searching the whole body for the carried text, not
                # by slicing the section: a slice would put every line inside
                # the section by construction and assert nothing.
                status_at, carried_at, offset = [], [], 0
                for line in resolved.split("\n"):
                    if self.ENTRY_LINE_RE.match(line):
                        status_at.append(offset)
                    elif line in carried:
                        carried_at.append(offset)
                    offset += len(line) + 1
                self.assertEqual(len(status_at), entries, "the write did not leave every status line")
                self.assertLess(max(status_at), min(carried_at), "a carried block sits above a status line")
                self.assertLess(max(carried_at), boundary, f"a carried block sits below `{heading}`")
                # Last, so a block in the wrong place fails on where it is
                # rather than on a count. It fails here when a line of the
                # notes section was not found in the body at all, which is the
                # scan going wrong rather than the write.
                self.assertEqual(
                    len(carried_at),
                    len(self.notes_lines(resolved)),
                    "a line of the notes section was not located in the body",
                )
        # Both bounds are only as strong as the shapes under them, so the
        # corpus is held by name rather than by a count. Each fixture named in
        # the table has to still carry the shape it exists for, and at least
        # one other fixture has to lack it -- a dimension every fixture carries
        # varies nothing, and one no fixture carries is a promise in a name.
        for label, dimension in self.FIXTURE_DIMENSIONS.items():
            with self.subTest(fixture=label):
                self.assertIn(label, varied, f"the fixture for {dimension} is gone")
                self.assertIn(dimension, varied[label], f"{label} no longer carries {dimension}")
                self.assertTrue(
                    [other for other, shapes in varied.items() if dimension not in shapes],
                    f"every fixture carries {dimension}, so it varies nothing",
                )

    def test_the_boundary_rejects_a_placement_the_scan_it_replaced_accepted(self) -> None:
        """The oracle asked about a body the writer did not produce.

        Every placement assertion above runs on the shipped writer's output,
        and the shipped writer is correct -- so an oracle that cannot tell a
        wrong placement from a right one passes either way and the test is a
        formality. That is what the `^## ` scan was: on a body whose status
        section ends in a setext heading it skipped past that heading to
        `## Validation`, so a block moved down into the author's own section
        was still above the scan's pick and every assertion held (#1733).

        Loosening the oracle cannot be caught by mutating the oracle, because
        a correct writer keeps its lines above the looser bound too. It is
        caught here, by handing the oracle a body with the block in the wrong
        place and asserting it says so -- and by asserting, in the same test,
        that the scan this replaced did not.
        """
        body = self.interleaved_body(self.SETEXT_AFTER_PLAIN_TAIL, below=self.TWO_HEADINGS_BELOW)
        right = self.resolve_entries(body, 1)
        # The same blocks, with the notes moved below the setext heading: what
        # a reader sees is a note inside the author's `Boundary note` section.
        moved = "## Evidence Notes\nordinary carried note\n\n"
        self.assertIn(moved + "Boundary note\n-------------\n", right)
        wrong = right.replace(moved + "Boundary note\n-------------\n", "Boundary note\n-------------\n\n" + moved)
        self.assertNotEqual(wrong, right)

        def scan(text: str) -> tuple[int, str]:
            """The boundary this replaced: the first `## ` line below the status heading."""
            start = text.index("## Evidence Status\n")
            for match in re.finditer(r"(?m)^## .*$", text[start:]):
                if match.start() == 0 or match.group().strip() == "## Evidence Notes":
                    continue
                return start + match.start(), match.group().strip()
            raise AssertionError("no `## ` line below the status heading")

        for placement, text in (("right", right), ("wrong", wrong)):
            with self.subTest(placement=placement):
                carried = set(self.notes_lines(text))
                self.assertEqual(carried, {"ordinary carried note"})
                at = min(
                    offset
                    for offset, line in zip(self.line_offsets(text.split("\n")), text.split("\n"))
                    if line in carried
                )
                boundary, heading = self.successor_heading(text)
                self.assertEqual(heading, "Boundary note")
                # The property, and the answer it gives on each body.
                self.assertEqual(at < boundary, placement == "right")
                # The scan says the same thing about both, which is the whole
                # of the defect: its pick is a heading a reader has, just not
                # the first one.
                scan_at, scan_heading = scan(text)
                self.assertEqual(scan_heading, "## Validation")
                self.assertLess(at, scan_at)

    def test_a_setext_heading_alone_under_the_status_list_leaves_nothing_to_carry(self) -> None:
        """The setext shape with nothing above it, kept distinct from the fixture that reproduces the defect.

        A setext h2 directly below the status list ends the status section
        there, so the section holds the status line and nothing else and the
        write has no block to move: no `## Evidence Notes` is written, the
        author's own section is untouched, and nothing is announced as lost
        because nothing was in the section to lose.

        The brief for this round expected a refusal here. There is none, and
        the difference matters to anyone reading this file: a refusal means the
        write saw a block it would not move, and what happens is that the
        block was never the section's. Asserted as what it is rather than as
        what it was predicted to be.
        """
        helpers = sys.modules["_helpers"]
        body = self.interleaved_body(self.SETEXT_ALONE_TAIL, below=self.TWO_HEADINGS_BELOW)
        # Why there is nothing to carry: the section ends at the setext
        # heading, above it rather than below.
        self.assertEqual(
            helpers.markdown_section(body, "Evidence Status"),
            f"- [pending-ci] {self.ITEMS[0]} -- the lane has not run yet",
        )
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            resolved = self.resolve_entries(body, 1)
        self.assertNotIn("## Evidence Notes", resolved)
        self.assertNotIn("not carried", spoke.getvalue())
        # The author's section survives whole, heading, underline and all, and
        # the status line was still rewritten.
        self.assertIn("\nBoundary note\n-------------\n", resolved)
        self.assertIn("- [complete] ", resolved)
        for heading in ("## Validation", "## Risks"):
            self.assertIn(heading, resolved)

    def test_the_parser_s_rendering_shows_no_less_below_the_notes_after_the_move(self) -> None:
        """What the parser's rendering can check about a move, and no more.

        The oracle is `_rendered_lines`, and it never interprets HTML -- that
        is the file's standing rule, since telling which elements are still
        open is a second renderer and the one we had disagreed with GitHub. So
        an element left open folds the blocks after it on the page and folds
        nothing here, and this test cannot fail on that case. It does not claim
        to: what makes the move safe there is the order, which the test above
        asserts.

        What this does check is the rest of the body: no block the parser DOES
        model stops rendering because the write moved something above it.
        """
        checked = 0
        for label, tail in self.PLACEMENT_FIXTURES:
            with self.subTest(block=label):
                body = self.body(tail)
                before, after = self.rendered_below(body), self.rendered_below(self.resolved(body))
                # Anti-vacuity: a comparison over nothing proves nothing, and
                # nothing else here pins that the fixture renders anything.
                self.assertTrue(before, f"{label} renders nothing below the notes to compare")
                self.assertTrue(
                    set(before) <= set(after), f"the move hid {sorted(set(before) - set(after))}"
                )
                checked += len(before)
        self.assertGreaterEqual(checked, 20, "the fixtures rendered almost nothing below")

    @staticmethod
    def rendered_below(body: str) -> list[str]:
        """The lines the parser renders from `## Validation` on, or none if it renders no such heading."""
        lines = sys.modules["evidence"]._rendered_lines(body)
        return lines[lines.index("## Validation") :] if "## Validation" in lines else []

    ROUND_TRIP_BODIES = (
        ("a note, a link and an excerpt", NOTES_BODY_TAIL),
        ("a quote and a sub-heading", "\n> a reviewer asked about the fixture\n\n### How I ran it\n\nBy hand.\n"),
        ("a checked box beside the entry", "- [x] pasted the log into the thread\n"),
        ("a table", "\n| run | result |\n| --- | --- |\n| 1 | green |\n"),
        ("a bullet naming no status", "- ran it twice to be sure\n"),
        # The parser emits no token at all for a link reference definition, so
        # a reading that collects blocks from the tokens loses it silently.
        ("a link reference definition", "\n[run]: https://example.invalid/1\n"),
        # Indented output first, because the section's content is trimmed on
        # the way in: taking four spaces off the first line turns a pasted
        # `## Validation` example into a heading of its own.
        ("indented output above a note", "\n    214 tests passed\n\nand a note under it.\n"),
        ("nothing that is not an entry", ""),
        # Two paragraphs whose adjacency would be a heading: see
        # `TEXT_THEN_EQUALS_TAIL`. Round-tripped in both orders as well as
        # placed, because "every line comes back" and "the blank line between
        # them comes back" are different properties and only the second one
        # decides whether the page gains a heading.
        ("a text note above a line of equals", TEXT_THEN_EQUALS_TAIL),
        ("a line of equals above a text note", EQUALS_THEN_TEXT_TAIL),
    )

    @staticmethod
    def page_blocks(body: str) -> list[tuple[str, str]]:
        """Every top-level heading and rule the page shows, as (tag, text), in order.

        The oracle for "a heading the author did not write". Read from the
        parse for the reason `section_boundaries` gives: a `^## ` scan calls a
        fenced line a heading and is blind to a setext one, and a setext one is
        exactly what a seam can manufacture.
        """
        helpers = sys.modules["_helpers"]
        normalized = helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", body)
        tokens = helpers.MARKDOWN.parse(normalized)
        blocks = []
        for index, token in enumerate(tokens):
            if token.level != 0:
                continue
            if token.type == "heading_open":
                blocks.append((token.tag, helpers.inline_text(tokens[index + 1].children).strip()))
            elif token.type == "hr":
                blocks.append(("hr", ""))
        return blocks

    @staticmethod
    def top_level_blocks(text: str) -> list[str]:
        """The type of each top-level block the parser reads, so a seam that merges two shows up as one."""
        helpers = sys.modules["_helpers"]
        return [
            token.type
            for token in helpers.MARKDOWN.parse(helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", text))
            if token.level == 0 and token.nesting >= 0 and token.type != "inline"
        ]

    def test_the_seam_between_two_carried_blocks_stays_a_blank_line(self) -> None:
        """Two blocks a reader sees as two are carried as two (#1738).

        The carried blocks are joined when they are written back, and on this
        fixture the join is the whole of what a reader gets: a line of `=`
        directly under a line of text is that text's setext underline, so a
        seam of one newline turns two paragraphs into an `<h1>` nobody wrote
        and swallows the note's text into its title. Written in both orders,
        because the seam belongs to neither block.

        Every placement branch in `insert_markdown_section` joins with a blank
        line today, which is why this passes; the fixture is what keeps it true
        through the next edit of that function. The last assertion is the
        oracle's own check -- the wrong seam really does make the heading, so
        passing here is a property of the writer rather than of the parser.
        """
        for label, tail, blocks in (
            ("a text note above a line of equals", self.TEXT_THEN_EQUALS_TAIL, ("A note for the reviewer.", "===")),
            ("a line of equals above a text note", self.EQUALS_THEN_TEXT_TAIL, ("===", "A note for the reviewer.")),
        ):
            with self.subTest(order=label):
                body = self.body(tail)
                self.assertEqual(self.page_blocks(body), [("h2", "Evidence Status"), ("h2", "Validation")])
                resolved = self.resolved(body)
                # Two blocks, in the order written, with the blank line back.
                self.assertEqual(self.notes_section(resolved), "\n\n".join(blocks))
                # And nothing new on the page: the author's two headings, plus
                # the one the write is allowed to add.
                self.assertEqual(
                    self.page_blocks(resolved),
                    [("h2", "Evidence Status"), ("h2", "Evidence Notes"), ("h2", "Validation")],
                )
                # A second write moves nothing: the blocks are no longer under
                # the status heading, so the seam is not rebuilt.
                self.assertEqual(self.resolved(resolved), resolved)
                # The oracle is not vacuous: the blank line is the only thing
                # between these two blocks and one block. Which one differs by
                # order -- `text` then `===` is a setext h1 that eats the note
                # into its title, and `===` then `text` is a single paragraph
                # by lazy continuation -- and neither is what the author wrote.
                self.assertEqual(len(self.top_level_blocks("\n\n".join(blocks))), 2)
                self.assertEqual(
                    len(self.top_level_blocks("\n".join(blocks))),
                    1,
                    "the wrong seam leaves two blocks, so this fixture pins nothing",
                )

    def test_the_seam_at_the_tail_of_the_carried_region_keeps_the_author_s_rule(self) -> None:
        """A `---` the author wrote as a thematic break is still one after the move (#1738).

        The other seam. The carried region lands directly above whatever
        followed the status section, and here that is the author's own rule --
        so a tail seam of one newline makes the last carried line the rule's
        setext text, which costs the author a rule and hands the page an
        `<h2>` in its place. The rule is also the section's boundary, so this
        is the one fixture where the block the write stops at is the block the
        seam could destroy.
        """
        body = self.interleaved_body(self.NOTE_TAIL, below=self.AUTHOR_RULE_BELOW)
        self.assertEqual(self.page_blocks(body), [("h2", "Evidence Status"), ("hr", "")])
        resolved = self.resolve_entries(body, 1)
        self.assertEqual(self.notes_section(resolved), "A note for the reviewer.")
        # The rule is still a rule, and the page gained only the notes heading.
        self.assertEqual(
            self.page_blocks(resolved),
            [("h2", "Evidence Status"), ("h2", "Evidence Notes"), ("hr", "")],
        )
        self.assertIn("\n\nA closing remark.\n", resolved)
        self.assertEqual(self.resolve_entries(resolved, 1), resolved)
        # Same oracle check: without the blank line the author has no rule and
        # the note is its heading text.
        self.assertEqual(
            self.page_blocks("A note for the reviewer.\n\n---"), [("hr", "")]
        )
        self.assertEqual(
            self.page_blocks("A note for the reviewer.\n---"),
            [("h2", "A note for the reviewer.")],
        )

    def test_no_line_that_is_not_an_entry_is_ever_dropped(self) -> None:
        # The property the fix is: whatever a body carried under the heading
        # that a reader would not read as a status line comes back out of
        # Evidence Notes, line for line. The counter is the anti-vacuity
        # guard -- a reading that finds nothing to carry proves nothing.
        carried = 0
        for label, tail in self.ROUND_TRIP_BODIES:
            with self.subTest(body=label):
                body = self.body(tail)
                before = self.non_entry_lines(body)
                resolved = self.resolved(body)
                # In the order written, not sorted: regrouping or reversing the
                # blocks is something a reader sees, and a sorted comparison
                # passes through it.
                self.assertEqual(self.notes_lines(resolved), before)
                carried += len(before)
        self.assertGreaterEqual(carried, 10, "the bodies carried no non-entry text to move")


class AnUncarriedNoteIsAnnouncedWhereItsAuthorLooksTests(unittest.TestCase):
    """What the write could not carry reaches the pull request (#1740).

    Two kinds of the author's text leave the `## Evidence Status` section
    without their consent: the continuation of a status line the write is
    about to replace, and a block whose end the body never states -- dropped
    where it stands, or the whole write stood down. Both were said through
    `log()` alone, which is the Actions step log, and the person who wrote
    the text is the pull request's author, who reads the pull request.

    So the write returns what it announced, the lane writers carry it to
    their callers, and the surface posts it once per loss per head. What is
    and is not carried does not change here (#1732, #1737 decided that);
    this is the reporting.
    """

    ENTRIES = ["- [complete] a test -- ran it"]
    ITEM = "a test"
    HEAD = "b6fdd45ab02090d9ccfbbec50329849bdd9ba817"
    OTHER_HEAD = "0" * 40
    STATUS = "- [pending-ci] a test -- waiting"

    # Every shape below leaves the section last in the body, which is what
    # separates an announced loss from a stand-down: with a heading under it a
    # block that never closes hides the section's end and the write refuses
    # outright (#1734). At the end of the body there is no end to guess, so
    # the block is deleted where it stands -- and that deletion is the one
    # nobody was told about.
    LOSSES = {
        "a continuation line": (
            f"{STATUS}\n  the rest of the sentence the author wrote",
            "continuing the status line",
        ),
        "an unclosed fence": (
            f"{STATUS}\n\n```text\nan excerpt nobody closed",
            "code fence with no closing line",
        ),
    }
    # A raw HTML block of kinds 1 to 5 never reaches the loss channel: it runs
    # to the end of the document, so the write stands the whole body down
    # instead -- and on the lane path that was said on stderr and nowhere else.
    UNCLOSED_HTML = f"{STATUS}\n\n<!--\nan aside nobody closed"

    def evidence(self):
        return sys.modules["evidence"]

    def execution(self):
        return sys.modules["execution"]

    def body(self, tail: str) -> str:
        return f"## Summary\n\nA change.\n\n## Evidence Status\n\n{tail}\n"

    def write(self, tail: str):
        """The write, and everything it printed while making it."""
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            result = self.evidence().write_evidence_status_section(
                self.body(tail), self.ENTRIES, notes_from=self.body(tail), entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
            )
        return result, err.getvalue()

    def metadata_body(self, tail: str) -> str:
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1,
                        "item": self.ITEM,
                        "status": "pending-ci",
                        "detail": "waiting",
                        "kind": "test-attested",
                    }
                ]
            },
            indent=2,
        )
        return (
            "## Summary\n\nA change.\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            f"## Evidence Status\n\n{tail}\n"
        )

    def test_every_loss_the_write_announces_comes_back_in_its_result(self) -> None:
        for shape, (tail, phrase) in self.LOSSES.items():
            with self.subTest(shape=shape):
                result, _ = self.write(tail)
                self.assertIsNone(result.refusal)
                # The loss this shape is about comes back in the result. A
                # write may say more than one thing about one body -- it also
                # says when it replaced somebody's status line -- so this
                # asks WHICH sentence came back rather than how many
                # (#1751, round 17).
                carried = [note for note in result.announcements if "not carried" in note]
                self.assertEqual(len(carried), 1, result.announcements)
                announcement = carried[0]
                self.assertIn(phrase, announcement)
                # The line the author has to look at, which is the only part of
                # this a person can act on.
                self.assertRegex(announcement, r"at line \d+")

    def test_the_step_log_still_says_every_announcement(self) -> None:
        # A channel added, not moved: the Actions log is where a run is
        # debugged, and nothing here takes that away.
        for shape, (tail, _) in self.LOSSES.items():
            with self.subTest(shape=shape):
                result, printed = self.write(tail)
                for announcement in result.announcements:
                    self.assertIn(announcement, printed)

    def test_a_stand_down_is_announced_through_the_same_channel(self) -> None:
        # The kind-1-to-5 block: nothing is written, and the reason has to
        # reach the author through the one channel the callers forward.
        result, _ = self.write(self.UNCLOSED_HTML)
        self.assertIsNotNone(result.refusal)
        self.assertEqual(result.body, self.body(self.UNCLOSED_HTML))
        self.assertEqual(len(result.announcements), 1, result.announcements)
        self.assertIn(result.refusal, result.announcements[0])

    def test_both_writers_announce_the_same_text(self) -> None:
        # The pair that has to agree about what a body carries has to agree
        # about what it dropped, or the author is told two different things
        # depending on which run got there first (#1729).
        for shape, (tail, _) in {**self.LOSSES, "the HTML block": (self.UNCLOSED_HTML, "")}.items():
            with self.subTest(shape=shape):
                body = self.metadata_body(tail)
                lane: list[str] = []
                factory: list[str] = []
                with contextlib.redirect_stderr(io.StringIO()):
                    self.evidence().update_evidence_entries(
                        body,
                        {1: {"status": "complete", "detail": "ran it"}},
                        announcements=lane,
                    )
                    self.evidence().render_execution_summary_body(
                        body,
                        requested_evidence=[self.ITEM],
                        evidence_complete=["1 -- ran it"],
                        evidence_blocked=[],
                        evidence_pending_ci=[],
                        announcements=factory,
                        # The same body in both roles: the sentence is about
                        # text a person may have written, so the turn has to
                        # be told where that text is (#1751, round 18).
                        published_body=body,
                    )
                self.assertNotEqual(lane, [])
                self.assertEqual(lane, factory)

    def test_a_second_write_over_the_first_announces_nothing_new(self) -> None:
        # Once per loss, not once per run: the section is rewritten on every
        # lane run and every factory turn, and a sentence repeated on each is
        # its own noise. The first write is what makes the second silent --
        # the text it could not carry is gone from the section by then.
        for shape, (tail, _) in self.LOSSES.items():
            with self.subTest(shape=shape):
                first, _ = self.write(tail)
                self.assertNotEqual(first.announcements, [])
                with contextlib.redirect_stderr(io.StringIO()):
                    second = self.evidence().write_evidence_status_section(
                        first.body, self.ENTRIES, notes_from=first.body, entries=entries_for(self.ENTRIES), previous_entries=entries_for(self.ENTRIES), recorded_items=[self.ITEM]
                    )
                self.assertEqual(second.announcements, [])

    def test_the_lane_writer_hands_its_announcements_to_its_caller(self) -> None:
        # `update_evidence_entries` returns a body, not errors, so the lane had
        # nowhere to put this. The sink is that somewhere.
        for shape, (tail, _) in self.LOSSES.items():
            with self.subTest(shape=shape):
                sink: list[str] = []
                with contextlib.redirect_stderr(io.StringIO()):
                    self.evidence().update_evidence_entries(
                        self.metadata_body(tail),
                        {1: {"status": "complete", "detail": "ran it"}},
                        announcements=sink,
                    )
                self.assertNotEqual(sink, [])

    def test_the_macos_lane_reconciler_hands_its_announcements_to_its_caller(self) -> None:
        for shape, (tail, _) in self.LOSSES.items():
            with self.subTest(shape=shape):
                sink: list[str] = []
                with contextlib.redirect_stderr(io.StringIO()):
                    sys.modules["run_contributor_evidence_kinds"].reconcile_pending_ci_evidence(
                        self.metadata_body(tail),
                        requested_evidence=[self.ITEM],
                        build_succeeded=True,
                        tests_succeeded=True,
                        smoke_succeeded=True,
                        test_output="Ran 1 test\nOK",
                        announcements=sink,
                    )
                self.assertNotEqual(sink, [])

    def notes(self) -> list[str]:
        result, _ = self.write(self.LOSSES["an unclosed fence"][0])
        return list(result.announcements)

    def posted(self, prior: list[str], notes: list[str], head: str | None = None):
        """What the poster would say on a PR whose comments are `prior`."""
        execution = self.execution()
        sent: list[str] = []
        with mock.patch.object(execution, "_pr_comment_bodies", return_value=prior), \
             mock.patch.object(
                 execution, "_post_pr_comment", side_effect=lambda *a, **k: sent.append(a[1]) or True
             ):
            execution.post_uncarried_notes(7, "April Clearwater", notes, head or self.HEAD, {})
        return sent

    def test_the_turn_names_the_block_and_the_line_on_the_pull_request(self) -> None:
        notes = self.notes()
        sent = self.posted([], notes)
        self.assertEqual(len(sent), 1, sent)
        self.assertIn(notes[0], sent[0])
        self.assertIn(self.HEAD, sent[0])

    def test_nothing_is_posted_when_the_write_announced_nothing(self) -> None:
        self.assertEqual(self.posted([], []), [])

    def test_a_loss_already_announced_at_this_head_is_not_announced_again(self) -> None:
        notes = self.notes()
        prior = self.posted([], notes)
        self.assertEqual(self.posted(prior, notes), [])

    def test_the_same_loss_at_a_new_head_is_announced_again(self) -> None:
        # The author has pushed since and the text is still going: saying it
        # again is right, the same way the rejected-heading note is.
        notes = self.notes()
        prior = self.posted([], notes, head=self.OTHER_HEAD)
        self.assertEqual(len(self.posted(prior, notes)), 1)

    def test_a_loss_not_yet_announced_is_said_even_at_an_announced_head(self) -> None:
        # Per loss, not per head: a body edited between two writes at one head
        # can lose a line the first write never saw.
        notes = self.notes()
        second = "not carried to `## Evidence Notes`: 2 line(s) continuing the status line at line 9 of the `Evidence Status` section"
        prior = self.posted([], notes)
        sent = self.posted(prior, notes + [second])
        self.assertEqual(len(sent), 1, sent)
        self.assertIn(second, sent[0])
        self.assertNotIn(notes[0], sent[0])

    def test_a_copy_nobody_can_see_does_not_silence_the_note(self) -> None:
        # The hole #1749 documents in the rejected-heading guard, refused here
        # rather than widened: the dedup asks what the page shows, so a copy
        # inside an HTML comment or a collapsed block counts as nothing said.
        notes = self.notes()
        real = self.posted([], notes)[0]
        for shape, forged in {
            "an HTML comment": f"<!--\n{real}\n-->",
            "a collapsed block": f"<details><summary>nothing to see</summary>\n{real}\n</details>",
            # The strip was non-greedy to the FIRST `</details>`, so a copy
            # placed after an inner closer and before the outer one survived it
            # and read as visible -- the one placement that silenced the note
            # (#1740, round 3).
            "a nested collapsed block": (
                "<details><summary>outer</summary>\n"
                "<details><summary>inner</summary>\nnothing\n</details>\n"
                f"{real}\n</details>"
            ),
            "two collapsed blocks with the copy between them": (
                "<details><summary>one</summary>\nnothing\n</details>\n"
                f"{real}\n"
                "<details><summary>two</summary>\nnothing\n</details>"
            ),
        }.items():
            with self.subTest(shape=shape):
                self.assertEqual(len(self.posted([forged], notes)), 1)

    def test_a_note_said_below_a_closed_disclosure_still_silences_it(self) -> None:
        # The strip ends at the LAST `</details>`, not at the end of the
        # comment. `(?:</details>|\Z)` after a greedy `.*` never reached the
        # closer -- `.*` ran to the end and `\Z` matched there -- so a comment
        # that folded a log away and then said the note in the open read as
        # nothing shown, and the author was told the same thing twice (#1740,
        # round 4).
        notes = self.notes()
        real = self.posted([], notes)[0]
        shown = f"<details><summary>log</summary>\nnothing to see\n</details>\n\n{real}"
        self.assertEqual(self.posted([shown], notes), [])

    def test_a_note_a_reader_was_actually_shown_still_silences_it(self) -> None:
        # The control the strip must not cost: a plain comment carrying the
        # note is a comment the author read, and the run stays quiet.
        notes = self.notes()
        real = self.posted([], notes)[0]
        self.assertEqual(self.posted([real], notes), [])

    def test_two_losses_at_one_line_are_two_notes(self) -> None:
        # The dedup key was the sentence, and a sentence that names only the
        # line and the kind is the same sentence for two different pieces of
        # the author's text: a continuation at line 7, the author edits the
        # body, another continuation at line 7, and the second loss is
        # suppressed by the first. The note carries the text that went, so two
        # losses read as two (#1740, round 3).
        first, _ = self.write(f"{self.STATUS}\n  the first sentence I wrote under it")
        second, _ = self.write(f"{self.STATUS}\n  a different sentence, same line")
        uncarried = [
            [note for note in result.announcements if "not carried" in note]
            for result in (first, second)
        ]
        self.assertEqual([len(notes) for notes in uncarried], [1, 1], uncarried)
        self.assertNotEqual(uncarried[0][0], uncarried[1][0])
        prior = self.posted([], uncarried[0])
        self.assertEqual(len(self.posted(prior, uncarried[1])), 1)

    def test_the_note_quotes_the_line_that_went(self) -> None:
        # What makes the two distinguishable is also what makes the note
        # actionable: the author's own words, in a code span so nothing in
        # them reaches the page as markup.
        result, _ = self.write(f"{self.STATUS}\n  the first sentence I wrote under it")
        self.assertIn("the first sentence I wrote under it", result.announcements[0])
        self.assertIn("`", result.announcements[0])

    def test_the_fence_marker_is_one_code_span_on_the_page(self) -> None:
        # `unmovable_block` wrote the marker between backticks of its own, so
        # ``` inside ` ` was five backticks in a row and the page showed the
        # marker as text rather than as code (#1740, round 3).
        result, _ = self.write(self.LOSSES["an unclosed fence"][0])
        # The note about the text that could not be CARRIED, which is what
        # this quoting rule is about. A write may also say it replaced a
        # status line of somebody's, and that sentence quotes a different
        # thing (#1751, round 17).
        note = next(note for note in result.announcements if "not carried" in note)
        # Five backticks in a row is the bug's signature: a three-backtick
        # marker wrapped in one backtick each side.
        self.assertNotIn("`````", note)
        # And the marker is a code span to the parser, with the marker itself
        # as its content -- asked of the parser rather than of the characters,
        # because "it has backticks around it" is what the bug had too.
        spans = [
            child.content
            for token in self.evidence().MARKDOWN.parse(note)
            for child in (token.children or [])
            if child.type == "code_inline"
        ]
        self.assertIn("```", spans, spans)

    def test_a_note_list_too_long_for_one_comment_is_still_said(self) -> None:
        # Every fresh note went in one comment, and GitHub stores 65,536
        # characters: a body with enough multi-line entries composed a comment
        # past the limit, `gh` refused it, the False was ignored, and every
        # loss went unsaid -- the direction this is not allowed to fail in.
        execution = self.execution()
        notes = [
            f"not carried to `## Evidence Notes`: 1 line(s) continuing the status line "
            f"at line {index} of the `Evidence Status` section, starting "
            f"`{'x' * 400}`"
            for index in range(300)
        ]
        sent = self.posted([], notes)
        self.assertGreater(len(sent), 1, [len(comment) for comment in sent])
        for comment in sent:
            self.assertLessEqual(len(comment), execution.PR_COMMENT_LIMIT)
            # Each chunk stands on its own to the guard: the headline it reads
            # and the head line it keys on.
            self.assertIn(execution.uncarried_notes_checked_line(self.HEAD), comment)
        # And every note is in exactly one of them.
        for note in notes:
            self.assertEqual(sum(note in comment for comment in sent), 1, note[:60])

    def test_a_chunked_list_is_read_back_by_the_guard(self) -> None:
        # The chunks are only worth posting if the next run can see them: each
        # one has to satisfy the same read that decides what was already said.
        notes = [
            f"not carried to `## Evidence Notes`: 1 line(s) continuing the status line "
            f"at line {index} of the `Evidence Status` section, starting `{'y' * 400}`"
            for index in range(300)
        ]
        prior = self.posted([], notes)
        self.assertGreater(len(prior), 1)
        self.assertEqual(self.posted(prior, notes), [])

    def test_a_comment_that_did_not_land_is_logged(self) -> None:
        # The `False` was ignored, so a failed post looked like a quiet run.
        execution = self.execution()
        err = io.StringIO()
        with mock.patch.object(execution, "_pr_comment_bodies", return_value=[]), \
             mock.patch.object(execution, "_post_pr_comment", return_value=False), \
             contextlib.redirect_stderr(err):
            posted = execution.post_uncarried_notes(7, None, self.notes(), self.HEAD, {})
        self.assertFalse(posted)
        self.assertIn("could not", err.getvalue().casefold())

    def test_a_stand_down_comment_does_not_claim_text_was_not_carried(self) -> None:
        # A stand-down is the section left exactly as its author wrote it, so
        # a headline saying text "was not carried" and a sentence saying the
        # list "is rewritten on every run" are both false of it (#1740,
        # round 3).
        execution = self.execution()
        result, _ = self.write(self.UNCLOSED_HTML)
        sent = self.posted([], list(result.announcements))
        self.assertEqual(len(sent), 1, sent)
        self.assertNotIn(execution.UNCARRIED_NOTES_HEADLINE, sent[0])
        self.assertNotIn("could not be moved", sent[0])
        self.assertIn(result.refusal, sent[0])
        self.assertIn(self.HEAD, sent[0])

    def test_an_uncarried_comment_still_says_what_it_always_said(self) -> None:
        # The control: nothing above changes the comment a deletion gets.
        execution = self.execution()
        sent = self.posted([], self.notes())
        self.assertIn(execution.UNCARRIED_NOTES_HEADLINE, sent[0])


class AnUnrecordedStatusBulletUnderTheHeadingIsTheAuthorsTests(unittest.TestCase):
    """Whose line a status-shaped bullet inside the section is, settled at both readers (#1751).

    Two rules stood, and on one body they cost the author a line with nothing
    printed. The writer rebuilt the section from the entries in hand and took
    every status-shaped line under the heading; the sweep that measures what
    the writer costs a body called a line the machine's only when it names an
    item the body records. So an author's own
    `- [blocked] release approval -- the signing profile is missing` was the
    machine's to one and the author's to the other, and an ordinary write
    deleted it, announced nothing, and refused nothing.

    One rule now, stated in the same words at `write_evidence_status_section`,
    `_section_notes`, `_is_status_list_item` and the sweep's
    `_entry_line_numbers`, and read by one function: a status-shaped line
    inside the section that names no recorded item is the author's, wherever
    it sits, and it moves to `## Evidence Notes` like any other block. It
    fails toward keeping the author's words, and there is no new sentence to
    say, because nothing is taken.
    """

    ITEM = "`swift test` passes"
    DETAIL = "the lane has not run yet"
    RESOLVED = "214 tests passed"
    NOTE = "A note for the reviewer."
    UNDER = "And what I checked after it."
    THEIRS = "- [blocked] release approval -- the signing profile is missing"
    ENDINGS = {"lf": "\n", "crlf": "\r\n"}

    def evidence(self):
        return sys.modules["evidence"]

    def body(self, ending: str = "\n", *, tail: str | None = None) -> str:
        """The issue's own body: the recorded entry, a note, the author's bullet, a note under it."""
        payload = json.dumps(
            {
                "entries": [
                    {
                        "index": 1,
                        "item": self.ITEM,
                        "status": "pending-ci",
                        "detail": self.DETAIL,
                        "kind": "test",
                    }
                ]
            },
            indent=2,
        )
        section = f"{self.NOTE}\n{self.THEIRS}\n\n{self.UNDER}\n" if tail is None else tail
        text = (
            "## Summary\n\n- did the thing\n\n"
            f"<!-- evidence-status:v1\n{payload}\n-->\n\n"
            "## Evidence Status\n\n"
            f"- [pending-ci] {self.ITEM} -- {self.DETAIL}\n\n"
            f"{section}\n"
            "## Validation\n\n- ran the suite on this head\n"
        )
        return text.replace("\n", ending)

    def written(self, source: str) -> tuple[str, list[str]]:
        """The lane writer's body and every sentence it owed the author."""
        said: list[str] = []
        with contextlib.redirect_stderr(io.StringIO()):
            body = self.evidence().update_evidence_entries(
                source, {1: {"status": "complete", "detail": self.RESOLVED}}, announcements=said
            )
        return body, said

    @staticmethod
    def flat(body: str) -> str:
        return body.replace("\r\n", "\n")

    def section_of(self, body: str) -> str:
        """What stands under the `## Evidence Status` heading, and nothing else."""
        after = self.flat(body).split("## Evidence Status\n", 1)[1]
        return after.split("\n## ", 1)[0].strip()

    # intent: fix
    # marker: behaviourally red at `016d94ba`, its own base
    # (`AssertionError`).
    def test_the_authors_own_blocked_bullet_lands_in_the_notes(self) -> None:
        for name, ending in self.ENDINGS.items():
            with self.subTest(ending=name):
                written, said = self.written(self.body(ending))
                self.assertIn(self.THEIRS, self.flat(written))
                # In the notes, in the order the author wrote the three blocks:
                # a carried status line is a block like any other, and a mover
                # that reorders is not a mover.
                self.assertIn(
                    f"## Evidence Notes\n{self.NOTE}\n\n{self.THEIRS}\n\n{self.UNDER}",
                    self.flat(written),
                )
                # The section itself holds the machine's line and nothing else.
                self.assertEqual(
                    self.section_of(written), f"- [complete] {self.ITEM} -- {self.RESOLVED}"
                )
                # Nothing is taken, so there is nothing to say about it. The
                # other decision available here kept the deletion and added a
                # sentence; this one needs no channel at all.
                self.assertEqual(said, [])

    # intent: fix
    # marker: behaviourally red at `016d94ba`, its own base
    # (`AssertionError`).
    def test_a_second_write_leaves_the_bullet_where_the_first_put_it(self) -> None:
        # A fixed point, or the line travels one write at a time and an author
        # reading the body between two lane runs sees a different page each.
        for name, ending in self.ENDINGS.items():
            with self.subTest(ending=name):
                once, _ = self.written(self.body(ending))
                twice, said = self.written(once)
                self.assertEqual(self.flat(twice), self.flat(once))
                self.assertIn(self.THEIRS, self.flat(twice))
                self.assertEqual(said, [])

    # intent: fix
    # marker: behaviourally red at `61c1e37a`, its own base -- the bullet
    # leaves the body there with no error, nothing on stderr and no notes
    # entry (`AssertionError`).
    def test_a_bullet_of_theirs_for_a_recorded_item_is_replaced_out_loud(self) -> None:
        """Their own words for a requirement this body records, and where they go.

        The rule does not move: a status line naming a recorded item is the
        machine's, and the rewrite renders the entry's line in its place --
        two answers for one requirement under the heading would leave a
        reader choosing between them. What moves is what happens to the bytes
        it replaces. They are not this write's output: somebody typed them,
        and at `61c1e37a` they left the body with no error, nothing on
        stderr and no `## Evidence Notes` entry, while the same bullet for an
        item the body does NOT record survived into the notes. The
        instrument built to catch silent losses could not see it either,
        because it asked the writer's own ownership predicate.

        So the replacement is announced and the text is carried, the way any
        other line of theirs is. The cost is named rather than hidden: the
        page does then show their older sentence below the section.
        """
        theirs = f"- [complete] {self.ITEM} -- I ran it myself and it passed"
        written, said = self.written(self.body(tail=f"{self.NOTE}\n{theirs}\n"))
        helpers = sys.modules["_helpers"]
        # The section says what was recorded.
        self.assertEqual(
            self.section_of(written), f"- [complete] {self.ITEM} -- {self.RESOLVED}"
        )
        # Their bytes are on the page, below it.
        self.assertIn(theirs, helpers.markdown_section(written, "Evidence Notes"))
        # And one sentence says what happened, naming the line, its position
        # and the item the entry records.
        replaced = [note for note in said if "replaced in" in note]
        self.assertEqual(len(replaced), 1, said)
        self.assertIn(helpers.code_span(theirs), replaced[0])
        self.assertRegex(replaced[0], r"at line \d+")
        self.assertIn(helpers.code_span(self.ITEM), replaced[0])

    # intent: control
    # marker: green at `61c1e37a`, its own base: a copy of the machine's own
    # bytes says nothing there and says nothing here (#1751, round 17).
    def test_a_byte_identical_copy_of_the_machines_line_is_still_silent(self) -> None:
        # Round 16's control, which this round must not move: there is
        # nothing of anybody else's in those bytes, so the page keeps the
        # line and no sentence is spent on it.
        copy = f"- [pending-ci] {self.ITEM} -- {self.DETAIL}"
        written, said = self.written(self.body(tail=f"{self.NOTE}\n{copy}\n"))
        self.assertEqual([note for note in said if "replaced in" in note], [], said)
        self.assertEqual(
            self.section_of(written), f"- [complete] {self.ITEM} -- {self.RESOLVED}"
        )

    # intent: control
    # marker: green at `61c1e37a`, its own base -- the branch made it so --
    # and behaviourally red on `016d94ba`, where a bullet for an item nothing
    # records was replaced in silence, which is this branch's first defect
    # (#1751, round 17).
    def test_a_bullet_for_an_item_this_body_does_not_record_still_survives(self) -> None:
        # The other side of the rule, unchanged: the write owns no line for
        # an item it does not record, so the bullet moves to the notes as
        # any block of theirs does -- and nothing is announced, because
        # nothing was replaced.
        written, said = self.written(self.body(tail=f"{self.NOTE}\n{self.THEIRS}\n"))
        helpers = sys.modules["_helpers"]
        self.assertIn(self.THEIRS, helpers.markdown_section(written, "Evidence Notes"))
        self.assertEqual([note for note in said if "replaced in" in note], [], said)

    # Guards: a stale reading of a recorded item stays the machine's -- the SECTION
    # half is green on main; what the write says about replacing it is round 17's.
    # intent: fix
    # marker: `control` until round 17, when the behaviour it pins moved.
    # Behaviourally red at `61c1e37a`, its own base now -- the head this
    # round started from -- `FAILED (failures=1)`, because the
    # two assertions this round adds (the text carried, the replacement
    # announced) are this round's. Red on `016d94ba` the same way. The
    # section half it kept is green at both (#1751, round 17).
    def test_a_status_line_naming_a_recorded_item_is_still_the_machines(self) -> None:
        # The other direction of the same rule, and the half that keeps the
        # section readable: a stale reading of an item the write records is
        # replaced by the entry in hand. What changed in round 17 is what
        # happens to the bytes: they are not the write's own, so they are
        # carried below the section and the replacement is said out loud.
        # The cost is named rather than hidden -- a reader does see the older
        # reading under `## Evidence Notes` -- and it is the price of "nothing
        # leaves without a word" over a line the machine owns.
        stale = f"- [blocked] {self.ITEM} -- an older reading of the same item"
        written, said = self.written(self.body(tail=f"{self.NOTE}\n{stale}\n"))
        self.assertEqual(
            self.section_of(written), f"- [complete] {self.ITEM} -- {self.RESOLVED}"
        )
        self.assertNotIn("an older reading of the same item", self.section_of(written))
        self.assertIn("an older reading of the same item", self.flat(written))
        self.assertEqual(len([note for note in said if "replaced in" in note]), 1, said)
        self.assertIn(f"## Evidence Notes\n{self.NOTE}", self.flat(written))

    # intent: fix
    # marker: behaviourally red at `016d94ba`, its own base
    # (`AssertionError`).
    def test_both_writers_carry_it(self) -> None:
        # The pair that has to agree about what a body carries (#1729): the
        # lane's re-render and the factory turn's own render, on one body.
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        source = self.body()
        with contextlib.redirect_stderr(io.StringIO()):
            rendered, errors = run_contributor.render_execution_summary_body(
                source,
                requested_evidence=[self.ITEM],
                evidence_complete=[f"1 -- {self.RESOLVED}"],
                evidence_blocked=None,
                evidence_pending_ci=None,
                # One body, both writers: the turn carries from the published
                # body, so that is the body this hands it (#1751, round 18).
                published_body=source,
            )
        lane, _ = self.written(source)
        self.assertEqual(errors, [])
        self.assertIn(self.THEIRS, rendered)
        self.assertEqual(self.section_of(rendered), self.section_of(lane))
        self.assertEqual(
            self.flat(rendered).split("## Evidence Notes\n", 1)[1].rstrip("\n"),
            self.flat(lane).split("## Evidence Notes\n", 1)[1].rstrip("\n"),
        )

    # intent: fix
    # marker: red at `fa8a2010`, its own base, behaviourally -- the replaced
    # text is carried there as the `- [complete] …` bullet it was, so after
    # the machine's verdict flips the page shows `- [blocked] <item>` under
    # `## Evidence Status` and `- [complete] <item>` directly below it under
    # `## Evidence Notes`, one such bullet per author edit and nothing marking
    # either superseded. Red on `016d94ba` for a different reason: nothing is
    # carried there at all (#1751, round 18).
    def test_the_page_shows_one_status_however_often_the_author_edits_the_line(self) -> None:
        """The cost of carrying a replaced line, measured per author edit rather than per write.

        Two edits and a verdict flip, driven through the lane writer: the
        author's own reading of the item is replaced each time, so what the
        notes hold grows by one block per EDIT -- not per write, which is why
        the third write adds nothing, and not per flip.

        What the page must not show is two answers for one requirement. The
        older readings are carried as fenced excerpts under a sentence saying
        what they were, so nothing under `## Evidence Notes` renders as a
        status bullet: the status list has one line, and the excerpts are
        code.
        """
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        theirs = [
            f"- [complete] {self.ITEM} -- I ran it by hand",
            f"- [complete] {self.ITEM} -- I ran it again on the rebuild",
        ]

        def edited(body: str, line: str) -> str:
            """The author replacing the machine's status line with their own words."""
            section = helpers.markdown_section(body, "Evidence Status")
            return body.replace(section, line, 1)

        said: list[str] = []
        written = self.body()
        with contextlib.redirect_stderr(io.StringIO()):
            for their_line in theirs:
                written = evidence.update_evidence_entries(
                    edited(written, their_line),
                    {1: {"status": "pending-ci", "detail": self.DETAIL}},
                    announcements=said,
                )
            # A third write with nothing edited: one per edit, not one per run.
            written = evidence.update_evidence_entries(
                written, {1: {"status": "pending-ci", "detail": self.DETAIL}}, announcements=said
            )
            # And the flip, which is where two statuses used to be on the page
            # at once.
            written = evidence.update_evidence_entries(
                written, {1: {"status": "blocked", "detail": "the device is not on the bench"}},
                announcements=said,
            )
        replaced = [note for note in said if evidence.says_text_was_replaced(note)]
        self.assertEqual(len(replaced), len(theirs), said)
        status = helpers.markdown_section(written, "Evidence Status")
        self.assertEqual(
            status.splitlines(),
            [f"- [blocked] {self.ITEM} -- the device is not on the bench"],
            written,
        )
        notes = helpers.markdown_section(written, "Evidence Notes")
        for their_line in theirs:
            self.assertIn(their_line, notes, "an older reading of theirs is not in the notes")
        # The page's own reading: nothing under the notes heading is a list,
        # so no reader meets a second status bullet for one requirement.
        kinds = {token.type for token in helpers.MARKDOWN.parse(notes)}
        self.assertNotIn("bullet_list_open", kinds, notes)
        self.assertIn("fence", kinds, notes)

    # intent: guard
    # marker: red at `016d94ba`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_one_function_decides_whose_line_it_is(self) -> None:
        # The rule itself, where both readers call it. Two spellings of one
        # question were what the disagreement was made of.
        evidence = self.evidence()
        self.assertTrue(
            evidence.is_recorded_status_line(
                f"- [complete] {self.ITEM} -- {self.RESOLVED}", [self.ITEM]
            )
        )
        self.assertFalse(evidence.is_recorded_status_line(self.THEIRS, [self.ITEM]))
        # A write that records nothing owns no line in the section, which is
        # the conservative answer and the one the sweep gives a body whose
        # metadata records no entries.
        self.assertFalse(
            evidence.is_recorded_status_line(f"- [complete] {self.ITEM} -- {self.RESOLVED}", [])
        )
        # The item is matched whole against the items in hand rather than read
        # out of the line up to its first ` -- ` (#1738, round 3).
        self.assertTrue(
            evidence.is_recorded_status_line("- [pending-ci] build -- release -- d", ["build -- release"])
        )
        self.assertFalse(
            evidence.is_recorded_status_line(
                "- [blocked] build -- staging -- someone else's line", ["build -- release"]
            )
        )
        # Not status-shaped at all: a note is a note however it opens.
        self.assertFalse(evidence.is_recorded_status_line("- a plain bullet", [self.ITEM]))

    # Every way a reader can write one status line, and the reading the page
    # gives it. The rule takes the page's reading, so these are one line to it
    # -- and where the two readers handed it different text instead, a wrapped
    # line naming a recorded item was the machine's to one and the author's to
    # the other, which is #1751 again on the wrapped form (round 2).
    WRAPPED = {
        "plain": "- [pending-ci] {item} -- {detail}",
        "a bold status token": "- **[pending-ci]** {item} -- {detail}",
        "an italic status token": "- _[pending-ci]_ {item} -- {detail}",
        "a bold item": "- [pending-ci] **{item}** -- {detail}",
        "an ordered marker": "1. [pending-ci] {item} -- {detail}",
        "a star marker": "* [pending-ci] {item} -- {detail}",
    }

    # intent: guard
    # marker: red at `e6934e95`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_rule_reads_a_line_the_way_the_page_reads_it(self) -> None:
        evidence = self.evidence()
        plain = f"- [pending-ci] {self.ITEM} -- {self.DETAIL}"
        for name, template in self.WRAPPED.items():
            with self.subTest(form=name):
                line = template.format(item=self.ITEM, detail=self.DETAIL)
                self.assertEqual(evidence.status_line_as_page_reads_it(line), plain)
                self.assertTrue(
                    evidence.is_recorded_status_line(
                        evidence.status_line_as_page_reads_it(line), [self.ITEM]
                    )
                )
        # A code span is not emphasis: the reading keeps its backticks -- not
        # because the page shows them, which it does not, but because
        # `inline_text` re-emits them so an item naming its command in a span
        # stays that item. The line is the author's at both readers, as it was
        # before this rule existed.
        in_code = f"- `[pending-ci]` {self.ITEM} -- {self.DETAIL}"
        self.assertEqual(evidence.status_line_as_page_reads_it(in_code), in_code)
        self.assertFalse(
            evidence.is_recorded_status_line(
                evidence.status_line_as_page_reads_it(in_code), [self.ITEM]
            )
        )
        # A line that is not a list item at all comes back as it was: it names
        # no item the rule can read either way.
        for line in (f"[pending-ci] {self.ITEM} -- {self.DETAIL}", "", "    an indented block"):
            with self.subTest(line=line):
                self.assertEqual(evidence.status_line_as_page_reads_it(line), line)
        # And a task box stays the author's, however the status is wrapped.
        boxed = f"- [x] **[pending-ci]** {self.ITEM} -- {self.DETAIL}"
        self.assertFalse(
            evidence.is_recorded_status_line(
                evidence.status_line_as_page_reads_it(boxed), [self.ITEM]
            )
        )

    # Guards: the writer reads the wrapped spellings as the page does -- true on main,
    # said out loud here so the reader this arc unified cannot quietly narrow.
    # intent: fix
    # marker: `control` until round 17. Behaviourally red at `61c1e37a`, its
    # own base now, in all six spellings -- `FAILED (failures=6)` --
    # because the carried text and the sentence about it are this round's.
    # Red the same way on `016d94ba`. The half it kept -- every wrapped
    # spelling read as the machine's -- is green at both (#1751, round 17).
    def test_a_wrapped_line_naming_a_recorded_item_is_the_machines(self) -> None:
        # The writer's half of the pair, pinned: it read the page all along,
        # and this says so rather than leaving it to the docstring. Round 17
        # adds what it does with the bytes it replaces.
        for name, template in self.WRAPPED.items():
            with self.subTest(form=name):
                line = template.format(item=self.ITEM, detail=self.DETAIL)
                written, said = self.written(self.body(tail=f"{self.NOTE}\n{line}\n"))
                self.assertEqual(
                    self.section_of(written), f"- [complete] {self.ITEM} -- {self.RESOLVED}"
                )
                self.assertNotIn(line, self.section_of(written))
                self.assertIn(line, self.flat(written))
                self.assertIn(f"## Evidence Notes\n{self.NOTE}", self.flat(written))
                # The plain form is byte-identical to the line the last run
                # rendered, so its claim is spent on the body's own copy and
                # this one moves in silence: nothing of anybody else's is in
                # those bytes. Every other spelling is somebody's own, and
                # the replacement is said (#1751, rounds 9, 16 and 17).
                self.assertEqual(
                    len([note for note in said if "replaced in" in note]),
                    0 if name == "plain" else 1,
                    f"{name}: {said}",
                )

    # intent: guard
    # marker: green at `e6934e95`, its own base.
    def test_a_wrapped_line_naming_no_recorded_item_is_the_authors(self) -> None:
        # The other half on the same shapes: wrapping a status token does not
        # hand the write a line it does not record.
        theirs = "- **[blocked]** release approval -- the signing profile is missing"
        written, said = self.written(self.body(tail=f"{self.NOTE}\n{theirs}\n"))
        self.assertIn(theirs, self.flat(written))
        self.assertIn(f"## Evidence Notes\n{self.NOTE}\n\n{theirs}", self.flat(written))
        self.assertEqual(said, [])

    # intent: guard
    # marker: red at `016d94ba`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_items_are_read_once_however_the_caller_holds_them(self) -> None:
        # They are walked for every line of every section, so a generator
        # handed in is spent on the first of them -- after which every status
        # line below reads as the author's, and the section the write just
        # rebuilt fills again with the entries it was replacing.
        evidence = self.evidence()
        second = "the smoke lane"
        body = (
            "## Summary\n\n- did the thing\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.ITEM} -- {self.DETAIL}\n"
            f"- [pending-ci] {second} -- waiting\n\n"
            "## Validation\n\n- ran it\n"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            write = evidence.write_evidence_status_section(
                body,
                [f"- [complete] {self.ITEM} -- {self.RESOLVED}", f"- [complete] {second} -- ran"], notes_from=body,
                entries=entries_for([f"- [complete] {self.ITEM} -- {self.RESOLVED}", f"- [complete] {second} -- ran"]), previous_entries=entries_for([f"- [complete] {self.ITEM} -- {self.RESOLVED}", f"- [complete] {second} -- ran"]), recorded_items=(item for item in (self.ITEM, second)),
            )
        self.assertIsNone(write.refusal)
        self.assertEqual(
            self.section_of(write.body),
            f"- [complete] {self.ITEM} -- {self.RESOLVED}\n- [complete] {second} -- ran",
        )
        # This body records no metadata, so the write holds no claim on the
        # two lines already under the heading: they are somebody's bytes, and
        # round 17 keeps them below the section rather than dropping them.
        notes = sys.modules["_helpers"].markdown_section(write.body, "Evidence Notes")
        self.assertIn(f"- [pending-ci] {self.ITEM} -- {self.DETAIL}", notes)
        self.assertIn(f"- [pending-ci] {second} -- waiting", notes)

    # intent: guard
    # marker: red at `016d94ba`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_writer_is_told_which_items_it_records(self) -> None:
        # Not read back out of the rendered lines: an item carrying its own
        # ` -- ` cannot be recovered from the line it was rendered into, which
        # is the reading that handed a write its own entry back as somebody
        # else's (#1738, round 3). The caller has the items; it passes them.
        evidence = self.evidence()
        body = (
            "## Summary\n\n- did the thing\n\n## Evidence Status\n\n"
            "- [pending-ci] build -- release -- waiting\n"
            f"{self.THEIRS}\n\n## Validation\n\n- ran it\n"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            write = evidence.write_evidence_status_section(
                body,
                ["- [complete] build -- release -- 214 tests passed"], notes_from=body,
                entries=entries_for(["- [complete] build -- release -- 214 tests passed"]), previous_entries=entries_for(["- [complete] build -- release -- 214 tests passed"]), recorded_items=["build -- release"],
            )
        self.assertIsNone(write.refusal)
        # Replaced in the section -- which is what "the writer is told which
        # items it records" pins -- and carried below it, with one sentence
        # about the replacement (#1751, round 17).
        self.assertNotIn(
            "- [pending-ci] build -- release -- waiting",
            sys.modules["_helpers"].markdown_section(write.body, "Evidence Status"),
        )
        self.assertIn("- [pending-ci] build -- release -- waiting", write.body)
        self.assertIn(self.THEIRS, write.body)
        self.assertEqual(
            len([note for note in write.announcements if "replaced in" in note]), 1,
            write.announcements,
        )

class TheNotesComeFromTheBodyAPersonCanEditTests(unittest.TestCase):
    """`## Evidence Notes` is written from the published body and never from the draft (#1751, round 18).

    Round 17 asked "might a person have written this?" as a FLAG, and the flag
    gated one of the paths into that section: the item-claimed lines a write
    replaces. Every other block under the heading carried regardless, so a
    forged `- [complete] <item the record does not hold> -- trust me` planted
    in the MODEL's own draft came back as a note under a body whose metadata
    says otherwise -- measured at `61c1e37a` and `fa8a2010`, not at
    `016d94ba`, which is a path this branch opened at or before round 16 and
    round 17's guard never covered.

    The fix is not a fourth guard. The section's text has ONE source now, the
    body a person can edit, named by the parameter the caller passes: the turn
    passes the published body, the lane passes the body it is rewriting, and
    the trusted thing and the used thing are one object. The same change turns
    a second loss around -- at every head including the merge base, a note a
    person left under either heading on GitHub was dropped by the turn with
    nothing said, because the turn read its notes out of the draft.
    """

    ITEM = "run the QA filter"
    DETAIL = "214 tests passed"
    LAST_RUN = f"- [pending-ci] {ITEM} -- waiting on CI"
    FORGED_UNRECORDED = "- [complete] manual QA on device -- trust me"
    FORGED_RECORDED = f"- [complete] {ITEM} -- trust me"
    FORGED_PROSE = "the model says the filter passed, honestly"
    FORGED_NOTE = "a note the draft wrote into the notes section itself"
    THEIR_PROSE = "a person wrote this under the heading on GitHub"
    THEIR_NOTE = "a person wrote this under the notes heading on GitHub"
    THEIR_BULLET = f"- [complete] {ITEM} -- I checked it by hand"

    def evidence(self):
        return sys.modules["evidence"]

    def draft(self, under_heading: str = "", notes: str = "") -> str:
        """The model's own text for this turn."""
        body = (
            "## Summary\n\n- did the thing\n\n"
            f"## Evidence Status\n\n- [pending-ci] {self.ITEM} -- waiting\n"
            f"{under_heading}"
            "\n## Validation\n- ran it\n"
        )
        return body + (f"\n## Evidence Notes\n\n{notes}\n" if notes else "")

    def published(self, under_heading: str = "", notes: str = "", status_line: str = "") -> str:
        """The body GitHub holds, with the record the last run left in it.

        The record matters: without it the last run's own status line is
        nobody's claim and reads as a person's sentence, so a fixture without
        metadata would make the machine's line carry and prove nothing about
        whose text this reads.
        """
        body = (
            "## Summary\n\n- published\n\n"
            f"## Evidence Status\n\n{status_line or self.LAST_RUN}\n"
            f"{under_heading}"
            "\n## Validation\n- ran it\n"
        ) + (f"\n## Evidence Notes\n\n{notes}\n" if notes else "")
        return self.evidence()._insert_evidence_metadata(
            body,
            {"entries": [{"index": 1, "item": self.ITEM, "status": "pending-ci",
                          "detail": "waiting on CI", "kind": "ci"}]},
        )

    def turn(self, draft: str, published: str) -> tuple[str, list[str], list[str]]:
        """The turn's entry point, driven the way production drives it."""
        said: list[str] = []
        with contextlib.redirect_stderr(io.StringIO()):
            written, errors = run_contributor.render_execution_summary_body(
                draft,
                requested_evidence=[self.ITEM],
                evidence_complete=None,
                evidence_blocked=None,
                evidence_pending_ci=[f"1 -- {self.DETAIL}"],
                published_body=published,
                announcements=said,
            )
        self.assertEqual(errors, [], "the turn refused the fixture")
        return written, said, errors

    # intent: fix
    # marker: red at `fa8a2010`, its own base, behaviourally -- the three
    # draft shapes below are carried there (the unrecorded bullet, the prose
    # and the draft's own notes section) and the three published ones are
    # dropped. Red on `016d94ba` too, where the bullet does not survive but
    # the prose and the notes section do, and where nothing of the published
    # body is read (#1751, round 18).
    def test_the_notes_carry_the_published_bodys_text_and_no_other(self) -> None:
        """Every kind of text that can reach the section, one case each, both directions.

        The population is not these seven shapes; it is the two sources the
        section has, which the walk below reads out of the code. These are
        the regression pins over it: one per shape that has been found in the
        wild or constructed here, so a later change that reopens one is named
        by the shape rather than by a diff.
        """
        shapes = [
            ("a status bullet for an item the record does not hold",
             self.draft(self.FORGED_UNRECORDED + "\n"), self.published(),
             self.FORGED_UNRECORDED, False),
            ("a status bullet for a recorded item",
             self.draft(self.FORGED_RECORDED + "\n"), self.published(), "trust me", False),
            ("prose under the status heading",
             self.draft("\n" + self.FORGED_PROSE + "\n"), self.published(),
             self.FORGED_PROSE, False),
            ("a notes section of the draft's own",
             self.draft(notes=self.FORGED_NOTE), self.published(), self.FORGED_NOTE, False),
            ("their prose under the status heading",
             self.draft(), self.published("\n" + self.THEIR_PROSE + "\n"),
             self.THEIR_PROSE, True),
            ("their notes section",
             self.draft(), self.published(notes=self.THEIR_NOTE), self.THEIR_NOTE, True),
            ("their own words on a recorded item's line",
             self.draft(), self.published(status_line=self.THEIR_BULLET),
             "I checked it by hand", True),
            ("the last run's own status line",
             self.draft(), self.published(), "waiting on CI", False),
        ]
        for name, draft, published, text, carried in shapes:
            with self.subTest(shape=name):
                written, _, _ = self.turn(draft, published)
                notes = self.evidence().markdown_section(written, "Evidence Notes")
                self.assertEqual(
                    text in notes,
                    carried,
                    f"{name}: {'dropped' if carried else 'carried'} -- notes were {notes!r}",
                )

    # intent: fix
    # marker: red at `fa8a2010`, its own base, behaviourally: the draft's own
    # blocks are CARRIED there, so there is nothing for the run to be told and
    # nothing is said. Red on `016d94ba` the same way. The sentence it pins was
    # the one thing this round wrote that no test read -- found by a mutant
    # that dropped it and left every suite green (#1751, round 18).
    def test_the_run_is_told_which_of_the_drafts_blocks_it_did_not_carry(self) -> None:
        """Text the write leaves behind is said somewhere, and for generated text that is the log.

        The author's own losses go to the author, in the comment the turn
        posts. The draft's do not: a sentence about the model's own text in
        that comment is noise in the channel this branch keeps clearing. So
        they are said to the run, one per block, NAMING the line each block
        opens on -- a count nobody can check is what let this go unpinned.
        """
        spoken = "not carried from the body being written"
        shapes = [
            ("a status bullet for an item the record does not hold",
             self.draft(self.FORGED_UNRECORDED + "\n"), self.FORGED_UNRECORDED),
            ("prose under the status heading",
             self.draft("\n" + self.FORGED_PROSE + "\n"), self.FORGED_PROSE),
            ("a notes section of the draft's own",
             self.draft(notes=self.FORGED_NOTE), self.FORGED_NOTE),
        ]
        for name, draft, text in shapes:
            with self.subTest(shape=name):
                said = io.StringIO()
                with contextlib.redirect_stderr(said):
                    run_contributor.render_execution_summary_body(
                        draft,
                        requested_evidence=[self.ITEM],
                        evidence_complete=None,
                        evidence_blocked=None,
                        evidence_pending_ci=[f"1 -- {self.DETAIL}"],
                        published_body=self.published(),
                    )
                sentences = [line for line in said.getvalue().splitlines() if spoken in line]
                self.assertEqual(len(sentences), 1, said.getvalue())
                self.assertIn(text, sentences[0], "the sentence does not name what it left")
        # The control: a draft with nothing of its own under either heading
        # says nothing, so the sentence is about what happened rather than
        # about the path having run.
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            run_contributor.render_execution_summary_body(
                self.draft(),
                requested_evidence=[self.ITEM],
                evidence_complete=None,
                evidence_blocked=None,
                evidence_pending_ci=[f"1 -- {self.DETAIL}"],
                published_body=self.published(),
            )
        self.assertNotIn(spoken, said.getvalue())

    # intent: fix
    # marker: red at `fa8a2010` and at `016d94ba`, its own base and the merge
    # base, behaviourally: both sources of the notes content read the body
    # being rewritten there, so the walk finds `body` where it requires the
    # carried body (#1751, round 18).
    def test_every_source_of_the_notes_section_reads_the_carried_body(self) -> None:
        """The enumeration, walked rather than listed, so a path added later is named.

        One write puts text under `## Evidence Notes`. This reads the module,
        finds that call, follows every name its content is built from back to
        the reads that produce it, and requires each of those reads to take
        the CARRIED body. A future source that reads the body being rewritten
        -- the shape every one of the four forged paths had -- fails here with
        its own line number, which is what the per-shape pins above cannot do.
        """
        source = SCRIPT_PATH.with_name("evidence.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        readers = {"removed_section_texts", "markdown_section", "strip_markdown_section"}
        inserters = {"insert_markdown_section", "inserted_markdown_section"}

        def named(node) -> set[str]:
            return {found.id for found in ast.walk(node) if isinstance(found, ast.Name)}

        writes = [
            (function, call)
            for function in ast.walk(tree)
            if isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef))
            for call in ast.walk(function)
            if isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name)
            and call.func.id in inserters
            and len(call.args) > 2
            and "EVIDENCE_NOTES_HEADING" in named(call.args[1])
        ]
        self.assertEqual(
            [function.name for function, _ in writes],
            ["write_evidence_status_section"],
            "another function writes that section now, and nothing here asks whose text it uses",
        )
        found: list[tuple[str, int]] = []
        for function, call in writes:
            parameters = {
                argument.arg for argument in function.args.args + function.args.kwonlyargs
            }
            reached, frontier = set(), named(call.args[2])
            while frontier:
                name = frontier.pop()
                if name in reached or name in parameters:
                    reached.add(name)
                    continue
                reached.add(name)
                for node in ast.walk(function):
                    sources = []
                    if isinstance(node, ast.Assign):
                        for target in node.targets:
                            if isinstance(target, ast.Name) and target.id == name:
                                sources.append(node.value)
                            if isinstance(target, ast.Tuple) and any(
                                isinstance(element, ast.Name) and element.id == name
                                for element in target.elts
                            ):
                                sources.append(node.value)
                    if isinstance(node, ast.AnnAssign) and node.value is not None and (
                        isinstance(node.target, ast.Name) and node.target.id == name
                    ):
                        sources.append(node.value)
                    if (
                        isinstance(node, ast.Call)
                        and isinstance(node.func, ast.Attribute)
                        and isinstance(node.func.value, ast.Name)
                        and node.func.value.id == name
                        and node.func.attr in {"append", "extend"}
                    ):
                        sources.extend(node.args)
                    if isinstance(node, ast.For) and isinstance(node.target, ast.Name) and (
                        node.target.id == name
                    ):
                        sources.append(node.iter)
                    for reads in sources:
                        frontier |= named(reads) - reached
                        for inner in ast.walk(reads):
                            if (
                                isinstance(inner, ast.Call)
                                and isinstance(inner.func, ast.Name)
                                and inner.func.id in readers
                                and inner.args
                            ):
                                found.append((ast.unparse(inner.args[0]), inner.lineno))
        self.assertTrue(found, "no read feeds the notes section; the walk found nothing to check")
        self.assertEqual(
            sorted({argument for argument, _ in found}),
            ["notes_from"],
            f"a source of `## Evidence Notes` reads a body other than the carried one: {found}",
        )

    # intent: fix
    # marker: red at `fa8a2010`, its own base, behaviourally -- `TypeError
    # not raised`: the flag there defaults to the CARRYING answer, so a
    # caller that says nothing about whose body it is rewriting gets the
    # answer that republishes generated text, which is safe by the caller
    # remembering. Red on `016d94ba` too, on a name (`recorded_items`), which
    # is counted apart (#1751, round 18).
    def test_the_write_cannot_be_called_without_saying_whose_body_it_carries(self) -> None:
        evidence = self.evidence()
        entries = [{"index": 1, "item": self.ITEM, "status": "complete",
                    "detail": self.DETAIL, "kind": "ci"}]
        with self.assertRaises(TypeError) as refused:
            evidence.write_evidence_status_section(
                self.draft(),
                [f"- [complete] {self.ITEM} -- {self.DETAIL}"],
                recorded_items=[self.ITEM],
                entries=entries,
                previous_entries=[],
            )
        self.assertIn("notes_from", str(refused.exception))
        # And every production call site answers it, rather than the two this
        # round happens to have been looking at.
        source = SCRIPT_PATH.with_name("evidence.py").read_text(encoding="utf-8")
        calls = [
            node for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "write_evidence_status_section"
        ]
        self.assertEqual(len(calls), 2, "a call site appeared or went; check what it carries")
        for call in calls:
            self.assertIn(
                "notes_from",
                [keyword.arg for keyword in call.keywords],
                f"the call at line {call.lineno} does not say whose body it carries",
            )


class TheRecordedItemIsReadWhereTheLineIsReadTests(unittest.TestCase):
    """One function asked in two parse contexts (#1751, round 4).

    `item_as_page_reads_it` parsed the recorded item ALONE with `parseInline`
    while the line's item is parsed IN CONTEXT -- inside a list item, inside a
    section, where the body's link reference definitions are in scope. An
    inline construct does not have to mean the same thing in the two places:
    `[Manual QA][qa] on device` is literal text parsed alone and a link where
    `[qa]:` is defined, so the write did not recognise the line it had just
    rendered and carried a copy of it per run.

    The same defect one level up from round 3's, which was the same defect one
    level up from round 2's. Each time: a reading compared against something
    that went through a different reading.

    The context is the text the LINE is parsed from -- the section -- rather
    than the whole body, because handing the item more than the line sees is
    the asymmetry with its sign flipped.
    """

    ITEM = "[Manual QA][qa] on device"
    DEFINITION = "[qa]: https://example.invalid/qa"

    def evidence(self):
        return sys.modules["evidence"]

    def section(self, status: str, detail: str) -> str:
        return f"- [{status}] {self.ITEM} -- {detail}\n\n{self.DEFINITION}\n"

    def body(self, status: str = "pending-ci", detail: str = "waiting") -> str:
        return (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"{self.section(status, detail)}\n## Validation\n\n- ran it\n"
        )

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_two_readings_of_one_item_agree_in_the_lines_own_context(self) -> None:
        # The write's own pairing: the line read out of the SECTION tokens,
        # the item read with that same section as context. Both sides resolve
        # the definition or neither does.
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        section = self.section("complete", "214 passed")
        tokens = helpers.MARKDOWN.parse(section)
        reading = next(
            evidence._status_item_reading(tokens, index)
            for index, token in enumerate(tokens)
            if token.type == "list_item_open"
        )
        self.assertIn("https://example.invalid/qa", reading)
        self.assertTrue(evidence.is_recorded_status_line(reading, [self.ITEM], section))
        # And the sweep's pairing, which reads a physical line and so resolves
        # no definition on either side -- internally consistent too.
        line = f"- [complete] {self.ITEM} -- 214 passed"
        self.assertTrue(
            evidence.is_recorded_status_line(
                evidence.status_line_as_page_reads_it(line), [self.ITEM]
            )
        )

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_write_recognises_the_line_it_just_rendered(self) -> None:
        # The end of it: three writes, and the section holds one line with
        # nothing carried. At `3ac9675e` the first write left a copy behind.
        evidence = self.evidence()
        body = self.body()
        line = f"- [complete] {self.ITEM} -- 214 passed"
        for _ in range(3):
            write = evidence.write_evidence_status_section(
                body, [line], notes_from=body, entries=entries_for([line]), previous_entries=entries_for([line]), recorded_items=[self.ITEM]
            )
            self.assertIsNone(write.refusal)
            body = write.body
        self.assertEqual(body.count("- [complete]"), 1)
        # The definition is a note and moves like any other block; what must
        # not be there is a copy of the line THIS WRITE RENDERED. The body's
        # own earlier `[pending-ci]` line has no claim here -- this fixture
        # records no metadata -- so round 17 carries it once, and three
        # writes leave it at once: the fixed point is what this pins.
        notes = sys.modules["_helpers"].markdown_section(body, "Evidence Notes")
        self.assertNotIn("[complete]", notes)
        self.assertEqual(notes.count("[pending-ci]"), 1, notes)

    # intent: guard
    # marker: green at `3ac9675e`, its own base.
    def test_an_item_carrying_its_own_separator_is_still_read_whole(self) -> None:
        # The probe reads the item back by REMOVING what it added, not by
        # searching for a boundary: a search with no contract takes the first
        # ` -- ` and cut a recorded `build -- release` down to `build`, which
        # handed the write somebody else's line as its own (#1738, round 3).
        evidence = self.evidence()
        self.assertEqual(evidence.item_as_page_reads_it("build -- release"), "build -- release")
        self.assertFalse(
            evidence.is_recorded_status_line(
                "- [blocked] build -- staging -- someone else's line", ["build -- release"]
            )
        )

    # intent: guard
    # marker: green at `3ac9675e`, its own base.
    def test_the_reading_is_the_same_one_the_line_goes_through(self) -> None:
        # Round 3's cases, unchanged by round 4: the mechanism got deeper, not
        # different.
        evidence = self.evidence()
        for item in ("**Manual QA** on device", "*QA*", "_QA_", "Manual <span>QA</span>"):
            with self.subTest(item=item):
                line = f"- [complete] {item} -- 214 passed"
                self.assertTrue(
                    evidence.is_recorded_status_line(
                        evidence.status_line_as_page_reads_it(line), [item]
                    )
                )


class ALineTheWriteCannotReadBackIsSaidRatherThanOrphanedTests(unittest.TestCase):
    """Two shapes where the LINE, not the item, is what cannot be read (#1751, round 4).

    An inline construct that opens in the item and closes in the detail takes
    the ` -- ` separator inside itself, so the rendered line has no boundary
    any reader can find -- the write's reader, the sweep and a person fail
    alike. And a line past `EVIDENCE_STATUS_LINE_LIMIT` is refused by
    `split_evidence_status_line` outright, so a four-thousand-character item
    renders a line no later run recognises, well under the 65,536 characters
    GitHub stores.

    Neither is an asymmetry to normalise away, and that is why they are not
    fixed by the mechanism above: there is no item in the line to compare
    against. The decision on the 4,000-character case, and on the crossing
    construct with it: the line is still written, because the requirement
    belongs on the page and dropping it would take a reader's only sight of
    it -- and the author is told, by name, that their item's text makes a line
    nothing can parse. Silence was the cost of not asking.
    """

    CROSSING = ("run `swift test", "--filter QA` passed")
    TOO_LONG = ("Manual QA " + "x" * 4000, "214 passed")
    PLAIN = ("Manual QA on device", "214 passed")

    def evidence(self):
        return sys.modules["evidence"]

    def write(self, item: str, detail: str):
        body = (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {item} -- waiting\n\n## Validation\n\n- ran it\n"
        )
        return self.evidence().write_evidence_status_section(
            body, [f"- [complete] {item} -- {detail}"], notes_from=body, entries=entries_for([f"- [complete] {item} -- {detail}"]), previous_entries=entries_for([f"- [complete] {item} -- {detail}"]), recorded_items=[item]
        )

    def said(self, write) -> list[str]:
        return [note for note in write.announcements if "not readable back" in note]

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_a_construct_crossing_the_boundary_is_named(self) -> None:
        said = self.said(self.write(*self.CROSSING))
        self.assertEqual(len(said), 1, said)
        self.assertIn("no reader can say where the item ends", said[0])
        self.assertIn("balance the construct", said[0])

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_a_line_past_the_limit_is_named_with_its_length(self) -> None:
        said = self.said(self.write(*self.TOO_LONG))
        self.assertEqual(len(said), 1, said)
        self.assertIn("4037 characters", said[0])
        self.assertIn(str(self.evidence().EVIDENCE_STATUS_LINE_LIMIT), said[0])
        self.assertIn("shorten the item", said[0])

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_an_ordinary_line_is_not_named(self) -> None:
        self.assertEqual(self.said(self.write(*self.PLAIN)), [])

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_line_is_still_written(self) -> None:
        # Reported, not refused: the requirement stays on the page.
        for item, detail in (self.CROSSING, self.TOO_LONG):
            with self.subTest(item=item[:30]):
                write = self.write(item, detail)
                self.assertIsNone(write.refusal)
                self.assertIn(f"- [complete] {item} -- {detail}", write.body)

    def counts(self, body: str) -> tuple[int, int]:
        helpers = sys.modules["_helpers"]
        status = helpers.markdown_section(body, "Evidence Status")
        notes = helpers.markdown_section(body, "Evidence Notes")
        pattern = re.compile(r"\[(complete|blocked|pending-ci)\]")
        return (
            len([line for line in status.splitlines() if pattern.search(line)]),
            len([line for line in notes.splitlines() if pattern.search(line)]),
        )

    # intent: guard
    # marker: red at `3ac9675e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_predicate_answers_about_lines_rather_than_items(self) -> None:
        evidence = self.evidence()
        item, detail = self.CROSSING
        self.assertEqual(
            [why for _, why in evidence.unreadable_status_lines(
                [f"- [complete] {item} -- {detail}"], [item])],
            [
                "the item and the detail share an inline construct, so the ` -- ` that "
                "separates them is inside it and no reader can say where the item ends; "
                "balance the construct inside the item"
            ],
        )
        plain_item, plain_detail = self.PLAIN
        self.assertEqual(
            evidence.unreadable_status_lines(
                [f"- [complete] {plain_item} -- {plain_detail}"], [plain_item]
            ),
            [],
        )


class TwoItemsThatReadAsOneCostAnAuthorALineTests(unittest.TestCase):
    """The round-3 regression that deleted an owner's line in silence (#1751, round 4).

    Round 3 put the ownership rule on the page's reading of the item, and left
    `_indistinguishable` -- the check that refuses a contract whose items
    cannot be told apart -- comparing RAW text. `Manual QA on device` and
    `**Manual QA** on device` are two requirements to that check and one
    requirement to the rule, so a contract carrying both passed and then cost
    an author a line: their own
    `- [blocked] Manual QA on device -- owner says device is unavailable`
    matched the recorded `**Manual QA** on device` under the reading, was
    taken for the machine's, and was replaced by the rendered entry. No error,
    no announcement, nothing in `## Evidence Notes`.

    One key in both places closes it, and the turn stops before writing rather
    than acting on a contract it cannot tell apart.
    """

    PLAIN = "Manual QA on device"
    BOLD = "**Manual QA** on device"
    OWNER = "- [blocked] Manual QA on device -- owner says device is unavailable"

    def body(self) -> str:
        return (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.BOLD} -- waiting\n{self.OWNER}\n\n"
            "## Validation\n\n- ran it\n"
        )

    def evidence(self):
        return sys.modules["evidence"]

    # intent: fix
    # marker: behaviourally red at `3ac9675e`, its own base
    # (`AssertionError`).
    def test_the_collision_check_uses_the_ownership_rules_key(self) -> None:
        evidence = self.evidence()
        self.assertEqual(evidence._indistinguishable([self.BOLD, self.PLAIN]), [self.PLAIN])
        # And still tells apart two items that are genuinely different.
        self.assertEqual(evidence._indistinguishable([self.BOLD, "the smoke lane"]), [])

    # intent: fix
    # marker: behaviourally red at `3ac9675e`, its own base
    # (`AssertionError`).
    def test_the_turn_refuses_the_contract_and_keeps_the_authors_line(self) -> None:
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        with contextlib.redirect_stderr(io.StringIO()):
            written, errors = run_contributor.render_execution_summary_body(
                self.body(),
                requested_evidence=[self.BOLD, self.PLAIN],
                evidence_complete=["1 -- 214 passed"],
                evidence_blocked=None,
                evidence_pending_ci=None,
            )
        # The line the round-3 head deleted.
        self.assertIn(self.OWNER, written)
        self.assertEqual(written, self.body())
        self.assertEqual(len(errors), 1)
        self.assertIn("read as one requirement on the page", errors[0])
        self.assertIn("make each item distinct", errors[0])

    # intent: guard
    # marker: green at `690713b0`, its own base.
    def test_the_update_path_stands_down_and_keeps_the_authors_line(self) -> None:
        """The same harm on the path a LATER run takes (#1751, round 5).

        The turn's own renderer refuses a colliding contract before it writes,
        and that guard is tested above. `update_evidence_entries` is the other
        door: the lane re-renders the section from the entries on every run,
        and a body whose metadata already records both spellings reaches the
        write without the turn's check in front of it. Without the stand-down
        inside `write_evidence_status_section` the owner's line is deleted
        there instead, with nothing said -- the guard survived a mutant
        because only the turn's path had a test.
        """
        evidence = self.evidence()
        entries = [
            {"index": 1, "item": self.BOLD, "status": "pending-ci",
             "detail": "waiting", "kind": "test"},
            {"index": 2, "item": self.PLAIN, "status": "pending-ci",
             "detail": "waiting", "kind": "test"},
        ]
        body = (
            "<!-- evidence-status:v1\n"
            + json.dumps({"entries": entries})
            + "\n-->\n\n## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.BOLD} -- waiting\n{self.OWNER}\n\n"
            "## Validation\n\n- ran it\n"
        )
        announcements: list[str] = []
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            written = evidence.update_evidence_entries(
                body,
                {1: {"status": "complete", "detail": "214 passed"}},
                announcements=announcements,
            )
        # The line the mutant deletes.
        self.assertIn(self.OWNER, written)
        self.assertEqual(written, body)
        stood_down = [
            note for note in announcements if evidence.is_stood_down_announcement(note)
        ]
        self.assertEqual(len(stood_down), 1, announcements)
        # The sentence names the colliding spelling -- the second occurrence,
        # which is what `_indistinguishable` reports and the one an author
        # removes. Naming both would be a change to the message rather than to
        # the guard, and this round adds no production change.
        self.assertIn(self.PLAIN, stood_down[0])
        self.assertIn("read as one requirement on the page", stood_down[0])
        self.assertIn("cannot be told apart", stood_down[0])
        self.assertIn("make each requested item distinct", stood_down[0])

    # intent: fix
    # marker: behaviourally red at `3ac9675e`, its own base
    # (`AssertionError`).
    def test_the_accounting_names_the_collision_where_the_author_can_fix_it(self) -> None:
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        accounting, errors = run_contributor.validate_evidence_accounting(
            self.body(), [self.BOLD, self.PLAIN], review_ci=[]
        )
        self.assertEqual(accounting["duplicate_requested_items"], [self.PLAIN])
        self.assertTrue(
            any("asks for the same item more than once" in error for error in errors), errors
        )

    # intent: guard
    # marker: green at `3ac9675e`, its own base.
    def test_a_distinguishable_contract_is_written_as_before(self) -> None:
        # The control: the guard costs an ordinary contract nothing, and an
        # author's status bullet for something the contract does not ask for
        # is carried to the notes exactly as round 2 made it.
        run_contributor = sys.modules["run_contributor_evidence_kinds"]
        theirs = "- [blocked] release approval -- the signing profile is missing"
        body = (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.BOLD} -- waiting\n{theirs}\n\n"
            "## Validation\n\n- ran it\n"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            written, errors = run_contributor.render_execution_summary_body(
                body,
                requested_evidence=[self.BOLD],
                evidence_complete=["1 -- 214 passed"],
                evidence_blocked=None,
                evidence_pending_ci=None,
                # Their bullet is in the body GitHub holds, which is the only
                # copy a person could have written it into (#1751, round 18).
                published_body=body,
            )
        self.assertEqual(errors, [])
        self.assertIn("- [complete] ", written)
        self.assertIn(theirs, written)


class OneReadingInOneContextForEverythingComparedTests(unittest.TestCase):
    """The guard added to stop a deletion had the deletion (#1751, round 6).

    Fifth iteration of one class. `_indistinguishable` keyed on the item read
    ALONE while the ownership rule reads it IN THE SECTION, so two spellings
    of one link-reference item were two requirements to the guard and one to
    the rule: the contract passed, and the owner's line was replaced by the
    entry with nothing said anywhere.
    """

    REF = "[Manual QA][qa] on device"
    INLINE = "[Manual QA](https://example.invalid/qa) on device"
    OWNER = "- [blocked] [Manual QA][qa] on device -- owner says device is unavailable"
    DEFINITION = "[qa]: https://example.invalid/qa"

    def evidence(self):
        return sys.modules["evidence"]

    def body(self) -> str:
        return (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.INLINE} -- waiting\n{self.OWNER}\n\n{self.DEFINITION}\n\n"
            "## Validation\n\n- ran it\n"
        )

    # intent: guard
    # marker: red at `1955ed15`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_two_spellings_are_one_requirement_in_the_section(self) -> None:
        evidence = self.evidence()
        section = sys.modules["_helpers"].markdown_section(self.body(), "Evidence Status")
        self.assertEqual(
            evidence.item_as_page_reads_it(self.INLINE, section),
            evidence.item_as_page_reads_it(self.REF, section),
        )
        # And the guard now sees what the rule sees.
        self.assertEqual(evidence._indistinguishable([self.INLINE, self.REF], section), [self.REF])
        # Read alone they are two items, which is what the guard used to see.
        self.assertEqual(evidence._indistinguishable([self.INLINE, self.REF]), [])

    # intent: guard
    # marker: red at `1955ed15`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_write_stands_down_and_the_owners_line_survives(self) -> None:
        evidence = self.evidence()
        body = self.body()
        spoke = io.StringIO()
        with contextlib.redirect_stderr(spoke):
            write = evidence.write_evidence_status_section(
                body,
                [f"- [complete] {self.INLINE} -- 214 passed"], notes_from=body,
                entries=entries_for([f"- [complete] {self.INLINE} -- 214 passed"]), previous_entries=entries_for([f"- [complete] {self.INLINE} -- 214 passed"]), recorded_items=[self.INLINE, self.REF],
            )
        self.assertIn(self.OWNER, write.body)
        self.assertEqual(write.body, body)
        self.assertIsNotNone(write.refusal)
        self.assertIn("cannot be told apart", write.refusal)
        self.assertEqual(
            len([n for n in write.announcements if evidence.is_stood_down_announcement(n)]), 1
        )


def helpers_section(body: str) -> str:
    return sys.modules["_helpers"].markdown_section(body, "Evidence Status")


class OneFunctionAnswersWhoseLineItIsTests(unittest.TestCase):
    """The cap reopened the disagreement this branch exists to close (#1751, round 6).

    It compared the PAGE'S reading of the body line against the RAW bytes of
    the rendered lines -- two spellings of one comparison -- and the sweep had
    no cap at all. So an author who wrote the machine's text with a `*` marker
    had their line taken and deleted by the write while the instrument that
    measures the write called the same line lost.

    Byte identity on both sides, and ONE function for both readers: they start
    from the same shape, a line.
    """

    ITEM = "run `swift test"
    DETAIL = "--filter QA` passed"

    def evidence(self):
        return sys.modules["evidence"]

    @property
    def rendered(self) -> str:
        return f"- [complete] {self.ITEM} -- {self.DETAIL}"

    SPELLINGS = {
        "byte-identical": None,
        "a star marker": ("- ", "* "),
        "an ordered marker": ("- ", "1. "),
        "a bold status token": ("[complete]", "**[complete]**"),
        "a span in the item": ("run ", "<span>run</span> "),
    }

    # intent: guard
    # marker: red at `d02bb8cc`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_write_s_path_and_the_sweep_s_path_agree_on_every_spelling(self) -> None:
        """The two PATHS, each with the arguments it forms itself (#1751, round 8).

        This called `whose_status_line` twice with identical arguments
        and reported "0 of 8 disagree" -- a tautology wearing a measurement's
        name, over five spellings and not eight. One function is necessary and
        not sufficient: the disagreement lives in what each path HANDS it, and
        the sweep formed the cap from the body with the metadata already
        stripped, so its cap was empty on every body and the machine's own
        unreadable line read as the author's, lost.
        """
        helpers = sys.modules["_helpers"]
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_agreement", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        disagreements: list[str] = []
        for label, swap in self.SPELLINGS.items():
            line = self.rendered if swap is None else self.rendered.replace(*swap, 1)
            source = self.body_with_line(line)
            # The write's path: the section it parses, the lines it last rendered.
            write_says = evidence.whose_status_line(
                line,
                {self.ITEM},
                helpers.markdown_section(source, "Evidence Status"),
                evidence.owned_lines(evidence.evidence_entries_of(source), evidence.evidence_entries_of(source)),
            ).machine
            # The sweep's path: its own scan over the body's physical lines.
            normalized = evidence._strip_evidence_metadata(
                sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", source)
            )
            lines = normalized.split("\n")
            owned = sweep._entry_line_numbers(lines, normalized, source)
            sweep_says = lines.index(line) in owned
            if write_says != sweep_says:
                disagreements.append(f"{label} (write {write_says}, sweep {sweep_says})")
        self.assertEqual(
            disagreements,
            [],
            f"{len(disagreements)} of {len(self.SPELLINGS)} spellings read two ways",
        )

    def body_with_line(self, line: str) -> str:
        return (
            "<!-- evidence-status:v1\n"
            + json.dumps(
                {
                    "entries": [
                        {
                            "index": 1,
                            "item": self.ITEM,
                            "status": "complete",
                            "detail": self.DETAIL,
                            "kind": "test",
                        }
                    ]
                }
            )
            + "\n-->\n\n## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + f"{line}\n\n## Validation\n\n- ran it\n"
        )
    # intent: guard
    # marker: red at `d02bb8cc`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_an_authors_edit_of_the_machines_own_line_is_never_the_machines(self) -> None:
        """Byte identity means bytes, measured (#1751, round 8).

        The comparison was `line.strip() == one.strip()`, which is STRIPPED
        identity wearing byte identity's name. Measured, a stripped match
        takes four shapes an exact one does not, and each is an author's edit
        of a line no reader can parse -- the hard break costs them the
        continuation line that follows it.
        """
        evidence = self.evidence()
        edits = {
            "a trailing hard break": self.rendered + "  ",
            "a trailing tab": self.rendered + "\t",
            "a one-space indent": " " + self.rendered,
            "a four-space indent": "    " + self.rendered,
        }
        taken = []
        for label, line in edits.items():
            source = self.body_with_line(line)
            if evidence.whose_status_line(
                line,
                {self.ITEM},
                helpers_section(source),
                evidence.owned_lines(evidence.evidence_entries_of(source), evidence.evidence_entries_of(source)),
            ).machine:
                taken.append(label)
        self.assertEqual(taken, [], "an author's edit was taken as the machine's")
        source = self.body_with_line(self.rendered)
        self.assertTrue(
            evidence.whose_status_line(
                self.rendered,
                {self.ITEM},
                helpers_section(source),
                evidence.owned_lines(evidence.evidence_entries_of(source), evidence.evidence_entries_of(source)),
            ).machine
        )

    # intent: guard
    # marker: red at `1955ed15`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_a_differently_spelled_author_line_is_never_the_machines(self) -> None:
        evidence = self.evidence()
        section = f"{self.rendered}\n"
        for label, swap in self.SPELLINGS.items():
            if swap is None:
                continue
            with self.subTest(spelling=label):
                line = self.rendered.replace(*swap, 1)
                self.assertFalse(
                    evidence.whose_status_line(
                        line, [self.ITEM], section, evidence.owned_lines(entries_for([self.rendered]), ())
                    ).machine,
                    f"{label} was taken for the machine's",
                )
        # The write's own bytes still are.
        self.assertTrue(
            evidence.whose_status_line(
                self.rendered, [self.ITEM], section, evidence.owned_lines(entries_for([self.rendered]), ())
            ).machine
        )

    # intent: guard
    # marker: red at `1955ed15`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_a_star_marker_line_is_carried_rather_than_deleted(self) -> None:
        # The harm, end to end: the author's line survives the write.
        evidence = self.evidence()
        star = self.rendered.replace("- ", "* ", 1)
        body = (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.ITEM} -- waiting\n{star}\n\n## Validation\n\n- ran it\n"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            write = evidence.write_evidence_status_section(
                body, [self.rendered], notes_from=body, entries=entries_for([self.rendered]), previous_entries=entries_for([self.rendered]), recorded_items=[self.ITEM]
            )
        self.assertIn(star, write.body)

    # intent: guard
    # marker: red at `f28b61f0`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_sweep_and_the_write_answer_the_same_on_the_same_lines(self) -> None:
        """The two readers CALLED, not grepped (#1751, round 9).

        This asserted that `evidence-write-sweep.py` contains the text
        `evidence.whose_status_line(` -- a claim about a spelling wearing
        a structural property's name, which a rename or an alias satisfies and
        a wrong answer does not disturb. The property is that the two readers
        answer the same about the same lines, so it is asked of both.
        """
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        sweep = load_module(
            "evidence_write_sweep_answers", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        for label, swap in self.SPELLINGS.items():
            line = self.rendered if swap is None else self.rendered.replace(*swap, 1)
            source = self.body_with_line(line)
            with self.subTest(spelling=label):
                write_says = evidence.whose_status_line(
                    line,
                    {self.ITEM},
                    helpers.markdown_section(source, "Evidence Status"),
                    evidence.owned_lines(evidence.evidence_entries_of(source), evidence.evidence_entries_of(source)),
                ).machine
                normalized = evidence._strip_evidence_metadata(
                    sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", source)
                )
                lines = normalized.split("\n")
                sweep_says = lines.index(line) in sweep._entry_line_numbers(
                    lines, normalized, source
                )
                self.assertEqual(write_says, sweep_says, label)


class TheCapKeysOnTheEntryNotTheRenderedLineTests(unittest.TestCase):
    """A volatile detail brought the uncapped rate back with no status change (#1751, round 6).

    The cap keyed on the whole rendered line, and a detail is volatile: the
    verifier's own `pending-ci` detail carries a head and a run URL and
    changes on every push. So an unreadable line accrued a copy per push with
    ZERO status changes -- the rate the cap was added to hold, back through a
    field nobody counted as changing.

    The metadata comment carries every entry as the last run wrote it, so the
    line that run rendered is reconstructible byte for byte. A body line
    identical to THAT, or to the line about to be rendered, is the machine's.
    """

    ITEM = "run `swift test"
    DETAIL = "--filter QA` passed"

    def evidence(self):
        return sys.modules["evidence"]

    def counts(self, body: str) -> tuple[int, int]:
        helpers = sys.modules["_helpers"]
        pattern = re.compile(r"\[(complete|blocked|pending-ci)\]")
        return tuple(
            len([line for line in helpers.markdown_section(body, heading).splitlines()
                 if pattern.search(line)])
            for heading in ("Evidence Status", "Evidence Notes")
        )

    def body_with(self, detail: str) -> str:
        entry = {"index": 1, "item": self.ITEM, "status": "pending-ci",
                 "detail": detail, "kind": "test"}
        return (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.ITEM} -- {detail}\n\n## Validation\n\n- ran it\n"
        )

    # Guards: seven pushes with a changing detail accrue nothing.
    # intent: fix
    # marker: behaviourally red at `1955ed15`, its own base
    # (`AssertionError`).
    def test_seven_pushes_with_a_changing_detail_and_no_status_change(self) -> None:
        evidence = self.evidence()
        body = self.body_with(f"{self.DETAIL} on head aaaaaaaaaaaX")
        seen = []
        for push in range(7):
            with contextlib.redirect_stderr(io.StringIO()):
                body = evidence.update_evidence_entries(
                    body,
                    {1: {"status": "pending-ci",
                         "detail": f"{self.DETAIL} on head aaaaaaaaaaa{push}"}},
                )
            seen.append(self.counts(body))
        self.assertEqual(seen, [(1, 0)] * 7)

    # Guards: a status change costs no copy. Main passes it under a different key;
    # it pins the property the entry key has to keep.
    # intent: fix
    # marker: behaviourally red at `1955ed15`, its own base
    # (`AssertionError`).
    def test_a_status_change_carries_nothing_either(self) -> None:
        """Keyed on the ENTRY, a status change costs no copy at all.

        Round 5's cap keyed on the rendered line, so any change to it -- a
        status, a detail -- left the old line behind as the author's. Keyed on
        the entry, the line the last run rendered is reconstructible whatever
        changed, so it is the machine's and is replaced.

        Named for what it tests, unlike the round-5 test it replaces: that one
        changed only the DETAIL and called it a status change, so it could not
        fail on the thing it named.
        """
        evidence = self.evidence()
        body = self.body_with(f"{self.DETAIL} on head aaaaaaaaaaaX")
        for _ in range(2):
            with contextlib.redirect_stderr(io.StringIO()):
                body = evidence.update_evidence_entries(
                    body,
                    {1: {"status": "complete", "detail": f"{self.DETAIL} on head aaaaaaaaaaaY"}},
                )
            self.assertEqual(self.counts(body), (1, 0))
        self.assertIn("- [complete] ", body)

    # Guards: the cap runs on the path production takes, not only on a hand-made body.
    # intent: fix
    # marker: behaviourally red at `d02bb8cc`, its own base
    # (`AssertionError`).
    def test_the_turn_caps_it_too_through_the_entry_point_production_uses(self) -> None:
        """The turn path, driven where production drives it (#1751, round 8).

        Round 7's version called `render_execution_summary_body` with a body
        carrying metadata, and the turn path cannot produce one: on that path
        `summary_body` is `data["body"]`, the MODEL's text for this turn, and
        the metadata comment is inserted by the write itself. So the
        reconstruction read a body that never holds the previous run's
        entries, `previously_rendered` was `[]` on every push, and the cap
        never ran in production at all -- while a test on a hand-made body
        killed its mutant.

        The body that holds the last run's entries is `published_body`, which
        is what GitHub currently has. This drives `build_execution_summary_body`
        with the two bodies split the way the turn splits them.
        """
        execution = sys.modules["execution"]
        detail = f"{self.DETAIL} on head aaaaaaaaaaaX"
        published = self.body_with(detail)
        # The model's text for this turn: the same section, no metadata --
        # which is what the turn hands in.
        model = published.split("-->\n\n", 1)[1]
        self.assertNotIn("evidence-status:v1", model)
        seen = []
        for push in range(3):
            with contextlib.redirect_stderr(io.StringIO()):
                written, errors = execution.build_execution_summary_body(
                    {"body": model},
                    requested_evidence=[self.ITEM],
                    visual_evidence_available=False,
                    published_body=published,
                )
            self.assertEqual(errors, [])
            seen.append(self.counts(written))
            published, model = written, written.split("-->\n\n", 1)[1]
        self.assertEqual(seen, [(1, 0)] * 3)

    # intent: guard
    # marker: green at `d02bb8cc`, its own base.
    def test_the_turn_reconstructs_from_the_published_body_and_not_the_model_s(self) -> None:
        # The mechanism directly: the same expression over the two bodies
        # gives different answers, and only one of them is the last run's.
        evidence = self.evidence()
        published = self.body_with(f"{self.DETAIL} on head aaaaaaaaaaaX")
        model = published.split("-->\n\n", 1)[1]
        self.assertEqual(evidence.rendered_entry_lines(evidence.evidence_entries_of(model)), [])
        self.assertEqual(
            evidence.rendered_entry_lines(evidence.evidence_entries_of(published)),
            [f"- [pending-ci] {self.ITEM} -- {self.DETAIL} on head aaaaaaaaaaaX"],
        )

    # intent: guard
    # marker: red at `1955ed15`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_line_the_last_run_rendered_is_reconstructible(self) -> None:
        evidence = self.evidence()
        entries = evidence.evidence_entries_of(self.body_with("a detail"))
        self.assertEqual(
            evidence.rendered_entry_lines(entries),
            [f"- [pending-ci] {self.ITEM} -- a detail"],
        )
        self.assertEqual(evidence.rendered_entry_lines(None), [])


class OneDefinitionOfWhichEntriesTheWriteRendersTests(unittest.TestCase):
    """A metadata entry the write never renders deleted an owner's line (#1751, round 8).

    `_render_structured_entries` renders an entry only at index >= 1 with an
    in-vocabulary status and a non-empty item and detail; the cap's
    reconstruction built a line for any entry with a non-empty item, status
    and detail. So a `{"index": 0, ...}` entry was reconstructed by one reader
    and skipped by the other, the cap claimed a line the write had never
    rendered, and the author's own line matching it was replaced -- nothing in
    `## Evidence Notes`, nothing on stderr, no refusal. Two readers of "which
    entries exist", which is this family's shape for the tenth time, closed the
    way #1782 round 3 closed it: one function, asked by both.
    """

    ITEM = "run `swift test"
    DETAIL = "--filter QA` passed"
    OWNERS = "- [blocked] release approval -- the signing profile is missing"

    def evidence(self):
        return sys.modules["evidence"]

    def body(self, *, with_the_unrenderable_entry: bool) -> str:
        entries = [
            {"index": 1, "item": self.ITEM, "status": "pending-ci",
             "detail": self.DETAIL, "kind": "test"},
        ]
        if with_the_unrenderable_entry:
            entries.insert(0, {"index": 0, "item": "release approval", "status": "blocked",
                               "detail": "the signing profile is missing", "kind": "manual"})
        return (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": entries}) + "\n-->\n\n"
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"- [pending-ci] {self.ITEM} -- {self.DETAIL}\n{self.OWNERS}\n"
            "\n## Validation\n\n- ran it\n"
        )

    def written(self, body: str) -> tuple[str, str]:
        evidence = self.evidence()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            written = evidence.update_evidence_entries(
                body, {1: {"status": "complete", "detail": "passed on head aaaaaaaaaaa1"}}
            )
        return written, stderr.getvalue()

    # intent: fix
    # marker: behaviourally red at `d02bb8cc`, its own base
    # (`AssertionError`).
    def test_an_entry_the_write_would_not_render_does_not_take_the_owners_line(self) -> None:
        written, stderr = self.written(self.body(with_the_unrenderable_entry=True))
        self.assertIn(self.OWNERS, written, f"the owner's line went; stderr said {stderr!r}")

    # intent: guard
    # marker: green at `d02bb8cc`, its own base.
    def test_the_control_without_it_keeps_the_line_too(self) -> None:
        written, _ = self.written(self.body(with_the_unrenderable_entry=False))
        self.assertIn(self.OWNERS, written)

    # intent: fix
    # marker: behaviourally red at `d02bb8cc`, its own base
    # (`AssertionError`).
    def test_the_reconstruction_names_exactly_the_lines_the_write_renders(self) -> None:
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        body = self.body(with_the_unrenderable_entry=True)
        self.assertEqual(len(evidence.evidence_entries_of(body)), 2)
        written, _ = self.written(body)
        # Both read off the body the write PRODUCED: the lines it rendered,
        # and the lines its own metadata says it rendered. A write renders
        # exactly the lines its reconstruction rebuilds, or the cap is
        # claiming lines nothing wrote.
        reconstructed = evidence.rendered_entry_lines(evidence.evidence_entries_of(written))
        rendered = [
            line
            for line in helpers.markdown_section(written, "Evidence Status").splitlines()
            if line.startswith("- [")
        ]
        # EQUALITY, which is what the name claims. Two counts and a
        # hand-written prefix let the predicate be copied back inline and the
        # mutant survive: the structure was right and the composer was not
        # (#1751, round 9).
        self.assertEqual(reconstructed, rendered)
        self.assertEqual(
            reconstructed, [f"- [complete] {self.ITEM} -- passed on head aaaaaaaaaaa1"]
        )

    # intent: fix
    # marker: behaviourally red at `f28b61f0`, its own base
    # (`AssertionError`).
    def test_the_turn_renderer_renders_what_the_reconstruction_rebuilds(self) -> None:
        """The same equality on the OTHER renderer (#1751, round 9).

        The lane renderer called the one composer and the turn renderer
        carried a copy of its f-string, taking the item raw where the composer
        strips it. An item with a trailing space rendered `...y  -- ...` and
        reconstructed `...y -- ...`, so the write could not recognise its own
        line on the next push.
        """
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        item = "run `swift test "
        with contextlib.redirect_stderr(io.StringIO()):
            written, errors = evidence.render_execution_summary_body(
                "## Summary\n\n- one change\n\n## Validation\n\n- ran it\n",
                requested_evidence=[item],
                evidence_complete=["1 -- --filter QA` passed"],
                evidence_blocked=[],
                evidence_pending_ci=[],
                published_body="",
            )
        self.assertEqual(errors, [])
        rendered = [
            line
            for line in helpers.markdown_section(written, "Evidence Status").splitlines()
            if line.startswith("- [")
        ]
        self.assertEqual(
            evidence.rendered_entry_lines(evidence.evidence_entries_of(written)), rendered
        )
        # And what that one composer produces, stated as bytes. Agreement
        # alone cannot see a change that moves BOTH sides: with one function
        # answering, a predicate that stopped stripping the item would render
        # `...test  -- ...` and reconstruct it identically, and the equality
        # above would hold while every author's copy of the line diverged.
        self.assertEqual(rendered, [f"- [complete] {item.strip()} -- --filter QA` passed"])

    # intent: guard
    # marker: green at `d02bb8cc`, its own base.
    def test_the_turn_path_carries_the_same_two_bodies_and_the_same_metadata(self) -> None:
        """The axis neither the product nor the corpus can produce (#1751, round 8).

        Every generated body holds exactly one valid entry and is written into
        and read back out of ONE body. Both round-8 defects live where those
        two things come apart: metadata whose entries are not all renderable,
        and a reconstruction source that is a different body from the one
        being written. This drives both paths over exactly that fixture.
        """
        execution = sys.modules["execution"]
        published = self.body(with_the_unrenderable_entry=True)
        model = published.split("-->\n\n", 1)[1]
        with contextlib.redirect_stderr(io.StringIO()):
            written, errors = execution.build_execution_summary_body(
                {"body": model},
                requested_evidence=[self.ITEM],
                visual_evidence_available=False,
                published_body=published,
            )
        self.assertEqual(errors, [])
        self.assertIn(self.OWNERS, written)
        # And the previous run's line is still capped on the turn path: the
        # section holds one status entry, not one per push.
        helpers = sys.modules["_helpers"]
        section = helpers.markdown_section(written, "Evidence Status")
        self.assertEqual(len([one for one in section.splitlines() if one.startswith("- [")]), 1)


class OneEntryOwnsOneLineTests(unittest.TestCase):
    """The cap was a set, so one entry owned every copy of its line (#1751, round 9).

    A write renders one line per entry, so it owns one line per entry -- the
    invariant the section's writer states. The cap held its lines in a set, so
    a body carrying the machine's unreadable line TWICE had both taken: one
    written back, nothing carried to `## Evidence Notes`, nothing on stderr
    about the second, and no refusal. A silent deletion reached through the
    guard added to stop silent deletions.

    And it was invisible: round 8's fix gave the sweep a non-empty cap, whose
    set semantics then met the sweep's own multiset accounting and made
    `lines_lost` return `[]` where it had returned both lines. A correctness
    fix that stops a defect being detectable is worse than the defect, so the
    instrument's sight is restored in the same change -- by construction, not
    by copy: both readers take the same `RenderedLines` owner.
    """

    ITEM = "run `swift test"
    DETAIL = "--filter QA` passed"

    def evidence(self):
        return sys.modules["evidence"]

    @property
    def line(self) -> str:
        return f"- [pending-ci] {self.ITEM} -- {self.DETAIL}"

    def body(self, copies: int, recorded: str = "pending-ci") -> str:
        entry = {"index": 1, "item": self.ITEM, "status": recorded,
                 "detail": self.DETAIL, "kind": "test"}
        return (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + "\n".join([f"- [{recorded}] {self.ITEM} -- {self.DETAIL}"] * copies)
            + "\n\n## Validation\n\n- ran it\n"
        )

    def counts(self, text: str) -> tuple[int, int]:
        helpers = sys.modules["_helpers"]
        pattern = re.compile(r"\[(complete|blocked|pending-ci)\]")
        return tuple(
            len([line for line in helpers.markdown_section(text, heading).splitlines()
                 if pattern.search(line)])
            for heading in ("Evidence Status", "Evidence Notes")
        )

    def written(self, copies: int, recorded: str = "pending-ci") -> tuple[str, str]:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            body = self.evidence().update_evidence_entries(
                self.body(copies, recorded), {1: {"status": "complete", "detail": self.DETAIL}}
            )
        return body, stderr.getvalue()

    # intent: fix
    # marker: behaviourally red at `f28b61f0`, its own base
    # (`AssertionError`).
    def test_the_second_identical_line_is_the_authors_and_is_carried(self) -> None:
        written, said = self.written(2)
        self.assertEqual(self.counts(written), (1, 1), f"stderr said {said!r}")
        self.assertIn("not readable back", said)

    # intent: fix
    # marker: behaviourally red at `95f74424`, its own base
    # (`AssertionError`).
    def test_the_same_holds_when_the_verdict_has_not_changed(self) -> None:
        """The shape round 9's fixture could not reach (#1751, round 10).

        That fixture always changed the verdict, so this run's rendered line
        and the last run's reconstructed line were two distinct lines and the
        owner never had to decide what to do with the same bytes offered
        twice. On a re-run they ARE the same bytes -- and #1782 re-verifies
        every recorded CI completion, so every run is a rewrite and most
        rewrites conclude what the last one did. The entry owned its line
        twice and the second identical copy was deleted after all, with
        nothing said about the deletion.
        """
        written, said = self.written(2, recorded="complete")
        self.assertEqual(self.counts(written), (1, 1), f"stderr said {said!r}")

    # intent: fix
    # marker: behaviourally red at `95f74424`, its own base
    # (`AssertionError`).
    def test_a_third_copy_is_the_authors_too(self) -> None:
        written, _ = self.written(3, recorded="complete")
        self.assertEqual(self.counts(written), (1, 2))

    # Guards: the ordinary one-copy body -- the case the cap must leave alone.
    # intent: control
    # marker: green at `f28b61f0`, its own base.
    def test_one_copy_is_still_the_machines_and_is_replaced(self) -> None:
        written, _ = self.written(1)
        self.assertEqual(self.counts(written), (1, 0))
        self.assertIn("- [complete] ", written)

    def entry(self, index: int = 1, status: str = "pending-ci", item: str | None = None,
              detail: str | None = None) -> dict[str, object]:
        return {
            "index": index,
            "item": self.ITEM if item is None else item,
            "status": status,
            "detail": self.DETAIL if detail is None else detail,
            "kind": "test",
        }

    # intent: guard
    # marker: red at `15e80e9e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_one_entry_offering_its_line_from_both_sources_owns_one_line(self) -> None:
        # One claim per (entry, line). An unchanged verdict makes this run's
        # rendered line and the last run's the same bytes for the same entry,
        # and counting that twice let the entry own two body lines (#1751,
        # round 10).
        evidence = self.evidence()
        owner = evidence.owned_lines([self.entry()], [self.entry()])
        self.assertTrue(owner.claim(self.line))
        self.assertFalse(owner.claim(self.line))

    # intent: guard
    # marker: red at `95f74424`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_a_previous_line_that_differs_is_a_second_line_that_entry_owns(self) -> None:
        # The other half: a changed verdict means last run's line and this
        # run's are two distinct lines for one entry, and the write owns both
        # -- which is what lets it replace the line it wrote last time.
        evidence = self.evidence()
        current = f"- [complete] {self.ITEM} -- {self.DETAIL}"
        owner = evidence.owned_lines([self.entry(status="complete")], [self.entry()])
        self.assertTrue(owner.claim(self.line))
        self.assertTrue(owner.claim(current))
        self.assertFalse(owner.claim(self.line))
        self.assertFalse(owner.claim(current))

    # intent: guard
    # marker: red at `15e80e9e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_two_entries_rendering_one_line_keep_two_claims(self) -> None:
        """The mirror pair round 10's key could not tell apart (#1751, round 11).

        The ` -- ` boundary can fall in two places in one text, so two entries
        whose items genuinely differ render the same line and no guard sees a
        collision. Keyed on the bytes alone their two claims collapsed to one,
        and the write then owned one of the two lines it had just rendered --
        so it carried its own second line to `## Evidence Notes` on every
        write, unbounded.
        """
        evidence = self.evidence()
        mirrored = [
            self.entry(index=1, status="complete", item="run `a", detail="b -- c` ok"),
            self.entry(index=2, status="complete", item="run `a -- b", detail="c` ok"),
        ]
        line = "- [complete] run `a -- b -- c` ok"
        self.assertEqual(evidence.rendered_entry_lines(mirrored), [line, line])
        self.assertEqual(evidence._indistinguishable([str(one["item"]) for one in mirrored], ""), [])
        owner = evidence.owned_lines(mirrored, mirrored)
        self.assertTrue(owner.claim(line))
        self.assertTrue(owner.claim(line), "the second entry's claim was collapsed away")
        self.assertFalse(owner.claim(line))

    # Guards: no accrual for the mirror pair. Green on main, red at `15e80e9e`: it
    # guards a regression this PR introduced and then fixed.
    # intent: fix
    # marker: behaviourally red at `15e80e9e`, its own base
    # (`AssertionError`).
    def test_the_mirror_pair_is_a_fixed_point_rather_than_an_accrual(self) -> None:
        # Driven through the write, three times: (2,0) each time. At
        # `15e80e9e` this read (2,1), (2,2), (2,3) -- one machine copy into
        # `## Evidence Notes` per write, with nothing said about it.
        evidence = self.evidence()
        mirrored = [
            self.entry(index=1, status="complete", item="run `a", detail="b -- c` ok"),
            self.entry(index=2, status="complete", item="run `a -- b", detail="c` ok"),
        ]
        line = "- [complete] run `a -- b -- c` ok"
        body = (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": mirrored}) + "\n-->\n\n"
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"{line}\n{line}\n\n## Validation\n\n- ran it\n"
        )
        seen = []
        for _ in range(3):
            with contextlib.redirect_stderr(io.StringIO()):
                body = evidence.update_evidence_entries(
                    body, {1: {"status": "complete", "detail": "b -- c` ok"}}
                )
            seen.append(self.counts(body))
        self.assertEqual(seen, [(2, 0)] * 3)

    # intent: guard
    # marker: red at `15e80e9e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_both_readers_build_one_owner_from_the_same_inputs(self) -> None:
        """The same VALUE, not merely the same class (#1751, round 11).

        The write built its owner from two lists of lines and the instrument
        built a second one from a body's entries. Same implementation, two
        constructions -- so "the same owner" was a claim about a type, and the
        two would have parted on the first shape where an (entry, line) pair
        and a line disagree, which the mirror pair above is.
        """
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_owner", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        source = self.body(2, recorded="complete")
        entries = evidence.evidence_entries_of(source)
        written = sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", source)
        normalized = evidence._strip_evidence_metadata(written)
        lines = normalized.split("\n")
        # The instrument's owner, built where it builds it.
        instrument = sweep._entry_line_numbers(lines, normalized, written)
        # The write's, over the same body: the same entries at both ends.
        owner = evidence.owned_lines(entries, entries)
        claimed = [index for index, line in enumerate(lines) if owner.claim(line)]
        self.assertEqual(sorted(instrument), claimed)
        self.assertEqual(len(claimed), 1, "one entry, one line")

    # Guards: the instrument's owner holds the line the write is about to
    # render, over an update detail carrying a construct and one past the
    # length limit. Green at `76c65118`; it is the test that kills the
    # `(source, source)` mutant, which is a guard's job rather than a fix's.
    # intent: guard
    # marker: green at `76c65118`, its own base.
    def test_the_instrument_owns_the_line_the_write_is_about_to_render(self) -> None:
        """The axis round 12's attempt held fixed (#1751, round 13).

        Round 12 reported the "(source, source)" mutant as unkillable, on the
        reasoning that the update replaces the detail and so closes any
        construct the item opened. That reasoning is wrong -- replacing a
        detail closes nothing. What made the mutant survive is that the
        instrument's own update carries the detail `214 tests passed`, which
        holds no construct and is well inside the line limit, so the line it
        renders is one the RULE can read back and the cap never decides it.

        Vary the update's detail and the two constructions part. The detail is
        rebound on the sweep module (`mock.patch.object(sweep, "UPDATES", …)`)
        rather than parametrised into `_entry_line_numbers`, because the
        instrument's update is a property of the corpus it writes, not an
        argument its readers take.
        """
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_detail", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        item, waiting = "run `a", "waiting"
        for label, detail in (
            ("a detail that closes a construct the item opened", "b` ok"),
            ("a detail past the status-line limit", "x" * 4100),
        ):
            with self.subTest(detail=label):
                next_line = f"- [complete] {item} -- {detail}"
                entry = {
                    "index": 1, "item": item, "status": "pending-ci",
                    "detail": waiting, "kind": "test",
                }
                source = (
                    "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"
                    "## Summary\n\n- one change\n\n## Evidence Status\n\n"
                    f"- [pending-ci] {item} -- {waiting}\n{next_line}\n\n"
                    "## Validation\n\n- ran it\n"
                )
                normalized = evidence._strip_evidence_metadata(
                    sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", source)
                )
                lines = normalized.split("\n")
                with mock.patch.object(
                    sweep, "UPDATES", {1: {"status": "complete", "detail": detail}}
                ):
                    owned = sweep._entry_line_numbers(lines, normalized, source)
                self.assertIn(
                    lines.index(next_line),
                    owned,
                    f"{label}: the line the write is about to render is not the machine's here",
                )

    # intent: guard
    # marker: red at `d84ea5c9`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_owner_the_write_builds_holds_the_line_it_is_about_to_render(self) -> None:
        """The property the instrument's second input exists for (#1751, round 12).

        The write's owner is built from (the entries this run renders, the
        entries the body records), so an author's line byte-equal to the line
        the write is ABOUT to render is claimed and replaced. The instrument
        built its owner from the body's entries twice over, which holds only
        the line the LAST run rendered — a different first input on every
        changed verdict.

        What this asserts is the difference itself, at the owner. The
        end-to-end consequence is not constructible with the instrument's own
        update map, and the report says what was tried: a line the write is
        about to render is read back by the RULE unless its item and detail
        share a construct, and the instrument's update replaces the detail,
        which closes any construct the item opened. So the cap never decides
        that line and the two constructions answer the same.
        """
        evidence = self.evidence()
        recorded = evidence.evidence_entries_of(self.body(1))
        updates = {1: {"status": "complete", "detail": "214 tests passed"}}
        updated, changed = evidence.entries_with_updates(recorded, updates)
        self.assertTrue(changed, "the fixture has to change a verdict to say anything")
        next_line = evidence.rendered_entry_lines(updated)[0]
        self.assertTrue(evidence.owned_lines(updated, recorded).claim(next_line))
        self.assertFalse(
            evidence.owned_lines(recorded, recorded).claim(next_line),
            "the body's entries twice over cannot hold the line the write will render",
        )

    # intent: guard
    # marker: red at `d84ea5c9`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_the_instrument_applies_the_writes_updates_to_the_bodys_entries(self) -> None:
        # The structural half: `entries_with_updates` is the one helper both
        # sides use for "the entries this write renders", and the instrument
        # names the update map it writes with rather than assuming none.
        sweep = load_module(
            "evidence_write_sweep_updates", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        evidence = self.evidence()
        self.assertEqual(sorted(sweep.UPDATES), [1])
        updated, changed = evidence.entries_with_updates(
            evidence.evidence_entries_of(self.body(1)), sweep.UPDATES
        )
        self.assertTrue(changed)
        self.assertEqual([one["status"] for one in updated], ["complete"])

    MOVED_ITEM = "run `a"
    MOVED_DETAIL = "b` ok"
    OTHER_ITEM = "manual QA"

    def moved(self, requested: list[str], index: int) -> tuple[int, int]:
        """The turn, over a body the author wrote a second copy of the line into.

        The published body records the item at index 1 -- where the last turn
        wrote it. `requested` is the contract as it stands NOW, and `index` is
        this run's position for the same item.
        """
        line = f"- [complete] {self.MOVED_ITEM} -- {self.MOVED_DETAIL}"
        recorded = {"index": 1, "item": self.MOVED_ITEM, "status": "complete",
                    "detail": self.MOVED_DETAIL, "kind": "test"}
        visible = (
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"{line}\n{line}\n\n## Validation\n\n- ran it\n"
        )
        published = (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": [recorded]}) + "\n-->\n\n" + visible
        )
        with contextlib.redirect_stderr(io.StringIO()):
            rendered, errors = run_contributor.render_execution_summary_body(
                visible,
                requested_evidence=requested,
                evidence_complete=[f"{index} -- {self.MOVED_DETAIL}"],
                evidence_blocked=None,
                evidence_pending_ci=None,
                published_body=published,
            )
        self.assertEqual(errors, [])
        return self.counts(rendered)

    # intent: fix
    # marker: behaviourally red at `76c65118`, its own base
    # (`AssertionError`).
    def test_an_item_that_keeps_its_text_and_moves_position_owns_one_line(self) -> None:
        """A claim's key has to name the same entry in BOTH bodies (#1751, round 13).

        Through the turn, which is where the two index spaces met: this run's
        entries are built from positions in the CURRENT `requested_evidence`
        and the published body's entries were read at the positions the LAST
        turn wrote them at. So an issue owner reordering the requested list
        gave one line two claims, and the write owned both of the author's
        copies: one rewritten, the other deleted -- nothing in
        `## Evidence Notes`, nothing on stderr about it, no refusal.

        Both sides are indexed against one list now. At `76c65118` this read
        (1, 0) while the controls below read (1, 1) -- the position is the
        only thing that differs between them, which is why nothing caught it.
        """
        self.assertEqual(
            self.moved([self.OTHER_ITEM, self.MOVED_ITEM], 2),
            (1, 1),
            "the author's second copy was deleted",
        )

    # intent: guard
    # marker: green at `76c65118`, its own base.
    def test_the_same_item_at_one_position_is_unchanged(self) -> None:
        # The same turn with the item where the published body left it: one
        # contract item, and two, so the second control differs from the fix
        # case in the position alone.
        self.assertEqual(self.moved([self.MOVED_ITEM], 1), (1, 1))
        self.assertEqual(self.moved([self.MOVED_ITEM, self.OTHER_ITEM], 1), (1, 1))

    # intent: guard
    # marker: red at `76c65118`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_an_entry_this_contract_no_longer_asks_for_is_dropped(self) -> None:
        # Not guessed at: an item the issue no longer requests is not a
        # requirement of this contract, so it owns no line in it.
        evidence = self.evidence()
        recorded = {"index": 1, "item": "a requirement since removed", "status": "complete",
                    "detail": "d", "kind": "test"}
        self.assertEqual(evidence.entries_keyed_for([recorded], ["something else"]), [])

    # intent: guard
    # marker: green at `7808a051`, its own base.
    def test_two_entries_at_one_index_with_two_lines_are_a_fixed_point(self) -> None:
        """What `rendered_entry_claims` claims about a colliding index, run.

        The docstring used to justify the index key by saying a second entry
        at one index is refused as a collision. It is not -- that refusal is
        #1782's -- so the justification was false for the head it sat on. What
        IS true here is measured: three writes, no accrual either way.

        ONE AXIS, named in the test's own name since round 14: the two entries
        share an index and render DIFFERENT lines. Hold the other half equal
        as well -- one index and one line -- and this head carried a line the
        write had rendered itself, every run, which this test could not see
        and the sibling above is for.
        """
        evidence = self.evidence()
        entries = [
            self.entry(index=1),
            self.entry(index=1, item="manual QA on device", detail="queued"),
        ]
        self.assertEqual(
            evidence._indistinguishable([str(one["item"]) for one in entries], ""),
            [],
            "the items genuinely differ, so nothing here refuses the shape",
        )
        lines = evidence.rendered_entry_lines(entries)
        update = {1: {"status": "complete", "detail": str(entries[0]["detail"])}}
        for label, extra, expected in (
            ("no spare copy", [], (2, 0)),
            ("a spare copy of the first line", [lines[0]], (2, 1)),
        ):
            with self.subTest(body=label):
                body = (
                    "<!-- evidence-status:v1\n" + json.dumps({"entries": entries}) + "\n-->\n\n"
                    "## Summary\n\n- one change\n\n## Evidence Status\n\n"
                    + "\n".join(lines + extra)
                    + "\n\n## Validation\n\n- ran it\n"
                )
                seen = []
                for _ in range(3):
                    with contextlib.redirect_stderr(io.StringIO()):
                        body = evidence.update_evidence_entries(body, update)
                    seen.append(self.counts(body))
                self.assertEqual(seen, [expected] * 3)

    # intent: guard
    # marker: red at `7808a051`, its own base (`AssertionError: () is not
    # <class 'inspect._empty'>`), which puts it in the behavioural bucket --
    # but what it asserts is a SIGNATURE, not behaviour, so it is a guard by
    # nature: it pins the shape of the call rather than what the call does.
    # Named here rather than smoothed, because the bucket and the kind
    # disagree (#1751, round 15). The sha is here because a marker that names
    # its base in prose alone is one a reader cannot check (round 17).
    def test_the_writer_takes_both_ends_of_the_body_with_no_default(self) -> None:
        """Required where callers actually reach, not only where the owner is built.

        A default for `previous_entries` is a caller dropping the last run's
        claims without saying so: a changed verdict's old line is then
        carried to `## Evidence Notes` rather than replaced. It was required
        at `owned_lines` and defaulted to `()` one layer out at
        `write_evidence_status_section`, which is the function callers reach
        -- 21 of 21 test call sites took the default and both production
        sites passed it, so the guard asserted about a function nobody in the
        suite called that way. A guard on the function you wish they called
        is not a guard (#1751, round 14).
        """
        evidence = self.evidence()
        for name in ("owned_lines", "write_evidence_status_section"):
            with self.subTest(seam=name):
                parameters = inspect.signature(getattr(evidence, name)).parameters
                self.assertIs(
                    parameters["previous_entries"].default,
                    inspect.Parameter.empty,
                    f"{name}: a default here drops the last run's claims silently",
                )
        with self.assertRaises(TypeError):
            evidence.owned_lines([self.entry()])
        with self.assertRaises(TypeError):
            evidence.write_evidence_status_section(
                "body", [], notes_from="body", recorded_items=[], entries=[self.entry()]
            )

    # intent: fix
    # marker: behaviourally red at `7808a051`, its own base
    # (`AssertionError`).
    def test_two_entries_at_one_index_rendering_one_line_own_both(self) -> None:
        """The conjunction, held at once, through the lane every run calls.

        Round 11 keyed a claim on the (index, line) PAIR so that two entries
        offering the same bytes keep two claims -- true only while their
        indexes differ. Two entries AT ONE INDEX that also render one line
        collapsed to a single claim, so the write owned one of the two lines
        it had just rendered and carried the other to `## Evidence Notes`,
        once per run, with nothing said beyond a generic warning that fires
        without any accrual (#1751, round 14).

        Both halves are held equal here at the same time, which is the only
        shape that can see it: the sibling tests vary the index with the
        bytes fixed and the bytes with the index fixed, and BOTH pass on the
        broken code. The two items differ genuinely -- the ` -- ` boundary
        falls in two places in one text -- so nothing refuses them as
        indistinguishable, and they render one line.
        """
        evidence = self.evidence()
        first = {"item": "run `a", "detail": "b -- c` ok", "status": "pending-ci",
                 "kind": "ci", "check_name": "Web CI"}
        second = {"item": "run `a -- b", "detail": "c` ok", "status": "pending-ci",
                  "kind": "ci", "check_name": "Web CI"}
        line = "- [pending-ci] run `a -- b -- c` ok"
        self.assertEqual(evidence.rendered_entry_lines([first | {"index": 2}]), [line])
        self.assertEqual(evidence.rendered_entry_lines([second | {"index": 2}]), [line])
        for label, indexes in (("one index", (2, 2)), ("two indexes", (1, 2))):
            with self.subTest(held=label):
                entries = [first | {"index": indexes[0]}, second | {"index": indexes[1]}]
                body = (
                    "<!-- evidence-status:v1\n"
                    + json.dumps({"entries": entries})
                    + "\n-->\n\nWhy this exists, plainly, in a paragraph long enough to read"
                    " as one.\n\n"
                    f"## Evidence Status\n\n{line}\n{line}\n\n## Validation\n\n- ran it\n"
                )
                for run in range(1, 7):
                    with contextlib.redirect_stderr(io.StringIO()):
                        body = run_contributor.reconcile_pending_ci_evidence(
                            body, build_succeeded=True, tests_succeeded=True,
                            smoke_succeeded=True,
                        )
                    notes = evidence.markdown_section(body, "Evidence Notes")
                    self.assertEqual(
                        notes.count("- ["),
                        0,
                        f"{label}, run {run}: the write carried a line it rendered itself",
                    )
                    self.assertEqual(
                        evidence.markdown_section(body, "Evidence Status").count("- ["),
                        2,
                        f"{label}, run {run}: a rendered line went missing",
                    )

    # intent: fix
    # marker: behaviourally red at `7808a051`, its own base
    # (`AssertionError`).
    def test_two_items_that_both_read_as_nothing_are_one_requirement(self) -> None:
        # The page reads `**.**` and `.` as the same nothing, so a line naming
        # either cannot be told from a line naming the other -- which is what
        # this refusal is for. The guard skipped an empty key, so the one pair
        # the ownership rule is certain about was the one pair this answered
        # nothing for (#1751, round 14).
        evidence = self.evidence()
        self.assertEqual(evidence._indistinguishable(["**.**", "."]), ["."])
        self.assertEqual(evidence._indistinguishable(["a", "b"]), [], "a control")

    # intent: fix
    # marker: behaviourally red at `76c65118`, its own base
    # (`AssertionError`).
    def test_two_entries_with_one_item_text_stay_two_claims(self) -> None:
        """What the index buys, in the shape that would cost the item text.

        Two entries in ONE body can carry the same item text at two indexes.
        The index tells them apart, so they own their two lines; keyed on the
        item text alone they would be one key and one of the two lines would
        go unowned -- which is the alternative this round rejected.

        Re-keyed into a contract that names the item once they share an index,
        and they still own two lines: a claim is an (entry, line) pair, so two
        entries rendering two different lines are two claims either way.
        """
        evidence = self.evidence()
        item = "run `a"
        entries = [
            {"index": 1, "item": item, "status": "complete", "detail": "first` ok", "kind": "test"},
            {"index": 2, "item": item, "status": "complete", "detail": "second` ok", "kind": "test"},
        ]
        lines = evidence.rendered_entry_lines(entries)
        # The key carries the index AND that index's occurrence in this list,
        # so no two entries of one list can share it (#1751, round 14).
        self.assertEqual(
            evidence.rendered_entry_claims(entries), [((1, 0), lines[0]), ((2, 0), lines[1])]
        )
        keyed = evidence.entries_keyed_for(entries, [item])
        self.assertEqual([one["index"] for one in keyed], [1, 1], "one requirement, one position")
        owner = evidence.owned_lines(entries, keyed)
        self.assertTrue(owner.claim(lines[0]))
        self.assertTrue(owner.claim(lines[1]), "the second entry's line went unowned")

    COLLIDING_ITEM = "run `swift test"
    COLLIDING_DETAIL = "--filter QA` passed"
    PLAIN_BODY = "## Summary\n\n- did the thing\n\n## Validation\n- local unit tests passed\n"

    @property
    def colliding_line(self) -> str:
        return f"- [pending-ci] {self.COLLIDING_ITEM} -- {self.COLLIDING_DETAIL}"

    def turn(self, body: str, published: str = "", item: str = "", detail: str = ""):
        """The turn's entry point, driven the way production drives it."""
        item = item or self.COLLIDING_ITEM
        detail = detail or self.COLLIDING_DETAIL
        with contextlib.redirect_stderr(io.StringIO()):
            return run_contributor.render_execution_summary_body(
                body,
                requested_evidence=[item],
                evidence_complete=None,
                evidence_blocked=None,
                evidence_pending_ci=[f"1 -- {detail}"],
                published_body=published,
            )

    def published_recording(self, times: int, item: str = "", detail: str = "") -> str:
        """A published body the WRITER wrote, with its recorded entry repeated.

        Built from the writer's own output rather than hand-written JSON:
        metadata this code did not write is metadata the parser may decline,
        and a fixture the parser declines makes every assertion after it
        vacuous. The read-back below is asserted for that reason.
        """
        published, _ = self.turn(self.PLAIN_BODY, "", item, detail)
        if times == 1:
            return published
        found = re.search(r"<!-- evidence-status:v1\n(.*?)\n-->", published, re.S)
        record = json.loads(found.group(1))
        record["entries"] = record["entries"] * times
        return published[: found.start(1)] + json.dumps(record, indent=2) + published[found.end(1) :]

    # intent: fix
    # marker: red at `35a13793`, its own base, behaviourally --
    # `FAILED (failures=4)`, both items at both multiplicities: the write
    # there returns a body with the author's copy gone, no error and nothing
    # carried. Red on `016d94ba` on a name this branch adds (#1751, round 16).
    def test_one_requirement_recorded_twice_stands_the_write_down(self) -> None:
        """Two entries recording ONE item are two ownership claims on identical bytes.

        The duplicate is in the RECORDED METADATA of the published body,
        which no guard inspects: `entries_keyed_for` re-keys it into two
        entries at index 1, `rendered_entry_claims` keys on
        `(index, occurrence)` and gives each its own claim, and the second
        claim has no line of the write's to own -- so it takes the author's
        byte-identical copy. The contract's own guard never sees it because
        `requested_evidence` holds ONE item throughout.

        Measured through the turn's entry point with the author's copy in the
        body BEING REWRITTEN and the published metadata built from the
        writer's own output: at `35a13793` one recorded entry gives
        `(status, notes) = (1, 1)` and owner claims `[True, False, False]`;
        the same entry recorded twice gives `(1, 0)` and `[True, True,
        False]`; three times `(1, 0)` and `[True, True, True]` -- no refusal,
        nothing on stderr about the deletion, no `## Evidence Notes` entry.
        `76c65118` and `7808a051` carry it at every multiplicity, and
        `016d94ba` takes it at every multiplicity, so this is round 14's key
        rather than a defect of main's.

        The question it answers is "is this record VALID?". Ownership of a
        valid record is round 14's and is unchanged -- two entries ARE two
        claims. A record naming one requirement twice is not valid, and what
        a write does with one is stand down whole and name both positions.
        """
        # The fixture read-back first: a published body whose metadata the
        # parser declines makes everything below it vacuous.
        evidence = self.evidence()
        for item, detail in (("run the QA filter", "214 tests passed"),
                             (self.COLLIDING_ITEM, self.COLLIDING_DETAIL)):
            self.assertEqual(
                len(evidence.evidence_entries_of(self.published_recording(1, item, detail)) or []),
                1,
                "the published body's metadata did not parse; the fixture is not built",
            )
        # The ordinary fixture first -- a plain item, which is what a contract
        # carries -- and the pass's own item second, because it is the one
        # where the end-to-end symptom is VISIBLE: with a plain item the
        # duplicate line is deduplicated by the item-keyed rule anyway (the
        # control below), so only an item that rule cannot own shows the
        # author's copy leaving.
        for label, item, detail in (
            ("a plain item", "run the QA filter", "214 tests passed"),
            ("an item the reader cannot own", self.COLLIDING_ITEM, self.COLLIDING_DETAIL),
        ):
            line = f"- [pending-ci] {item} -- {detail}"
            model = (
                "## Summary\n\n- did the thing\n\n## Evidence Status\n\n"
                f"{line}\n{line}\n\n## Validation\n- local unit tests passed\n"
            )
            for times in (2, 3):
                with self.subTest(item=label, recorded=times):
                    published = self.published_recording(times, item, detail)
                    keyed = evidence.entries_keyed_for(
                        evidence.evidence_entries_of(published), [item]
                    )
                    self.assertEqual(len(keyed), times, "the duplicate did not survive the re-keying")
                    # The owner-level tell, on identical bytes: the second
                    # entry's claim is the one with no line of the write's
                    # to own.
                    owner = evidence.owned_lines(
                        [{"index": 1, "item": item, "status": "pending-ci",
                          "detail": detail, "kind": "test"}],
                        keyed,
                    )
                    self.assertEqual(
                        [owner.claim(line) for _ in range(3)],
                        # One claim per recorded entry, on identical bytes.
                        [True] * min(times, 3) + [False] * max(0, 3 - times),
                    )
                    written, errors = self.turn(model, published, item, detail)
                    self.assertEqual(written, model, "the body did not stand whole")
                    self.assertEqual(len(errors), 1, errors)
                    self.assertIn("record one requirement more than once", errors[0])
                    places = ", ".join(str(place) for place in range(1, times + 1))
                    self.assertIn(f"at position {places}", errors[0], "both positions are not named")
                    self.assertIn(sys.modules["_helpers"].code_span(item), errors[0])

    # intent: control
    # marker: green at `35a13793`, its own base -- `Ran 1 test ... OK` -- which
    # is what makes it a control; behaviourally red on `016d94ba`, where the
    # author's copy is taken at every multiplicity (#1751, round 16).
    def test_one_recorded_entry_still_carries_the_author_s_copy(self) -> None:
        # The multiplicity the refusal does not reach, and the reason the
        # refusal is keyed on the RECORD rather than on the copy: one entry,
        # two byte-identical lines, the entry owns one and the author's copy
        # is carried. This is the behaviour the fix must not move.
        evidence = self.evidence()
        # Driven through the LANE writer, where the body being rewritten and
        # the body notes may come from are one object. The turn path is the
        # same claim about a copy in the PUBLISHED body, and it moved there in
        # round 18: a copy in the model's own draft is the writer's text and
        # carries nothing, which the provenance suite drives shape by shape.
        # Keeping this one on the lane path keeps it measuring what round 16
        # built it for -- ownership multiplicity -- rather than provenance
        # (#1751, round 18).
        doubled = self.published_recording(1).replace(
            self.colliding_line, f"{self.colliding_line}\n{self.colliding_line}", 1
        )
        with contextlib.redirect_stderr(io.StringIO()):
            written = evidence.update_evidence_entries(
                doubled, {1: {"status": "pending-ci", "detail": self.COLLIDING_DETAIL}}
            )
        self.assertNotEqual(written, doubled, "the write did not happen")
        self.assertIn(self.colliding_line, evidence.markdown_section(written, "Evidence Notes"))

    # intent: control
    # marker: green at `35a13793`, its own base, and constant at every head of
    # this branch and on `016d94ba`: a readable item's duplicate line is
    # deduplicated by the item-keyed rule wherever it sits, which is why the
    # shape above needs an item the reader cannot own (#1751, round 16).
    def test_a_readable_item_s_duplicate_is_the_machine_s_wherever_it_sits(self) -> None:
        """The record that decided this round's scope, kept as a test.

        With a READABLE item the second byte-identical copy of the machine's
        line is replaced at every multiplicity -- one recorded entry
        included, and whether the copy sits in the model's draft, in the
        published body, or in both. Measured constant at `76c65118`,
        `7808a051`, `5ee6769e`, `35a13793` and this head, so it is neither
        this round's nor a regression: a line naming a recorded item is the
        machine's by the item-keyed rule, and a byte-identical copy of the
        machine's own line carries nothing of the author's -- the page keeps
        the line they wrote, once.

        It is recorded rather than folded into the finding above, because the
        end-to-end symptom there belongs to the path where that rule cannot
        answer -- an item the reader cannot own, where the byte-identical
        claim is the only claim available.
        """
        item, detail = "run the QA filter", "214 tests passed"
        line = f"- [pending-ci] {item} -- {detail}"

        def turn(body: str, published: str = ""):
            with contextlib.redirect_stderr(io.StringIO()):
                return run_contributor.render_execution_summary_body(
                    body, requested_evidence=[item], evidence_complete=None,
                    evidence_blocked=None, evidence_pending_ci=[f"1 -- {detail}"],
                    published_body=published,
                )

        published, _ = turn(self.PLAIN_BODY)
        twice = published.replace(
            f"## Evidence Status\n\n{line}", f"## Evidence Status\n\n{line}\n{line}", 1
        )
        model = (
            "## Summary\n\n- did the thing\n\n## Evidence Status\n\n"
            f"{line}\n{line}\n\n## Validation\n- local unit tests passed\n"
        )
        evidence = self.evidence()
        for shape, body, source in (
            ("the model's draft", model, published),
            ("the published body", self.PLAIN_BODY, twice),
            ("both", model, twice),
        ):
            with self.subTest(copy_in=shape):
                written, errors = turn(body, source)
                self.assertEqual(errors, [])
                self.assertEqual(
                    evidence.markdown_section(written, "Evidence Status").count(line), 1
                )
                self.assertEqual(
                    evidence.markdown_section(written, "Evidence Notes").count(line), 0
                )

    # intent: guard
    # marker: green at `35a13793`, its own base: the owner does what this says
    # there, and the refusal above is what keeps an invalid record from ever
    # reaching it. Red on `016d94ba` on a name (#1751, round 16).
    def test_the_owner_grants_a_second_claim_on_identical_bytes(self) -> None:
        """Where the refusal is, and where it is NOT: ownership is unchanged.

        The tell one level below the write: offer the same bytes three times
        to the owner of a record that names one requirement once, and to the
        owner of one that names it twice. Measured at five heads --
        `76c65118` and `7808a051` grant `[True, False, False]` at both
        multiplicities; `5ee6769e` and `35a13793` grant `[True, False,
        False]` for one entry and `[True, True, False]` for two, which is the
        second claim that takes the author's copy.

        This head grants the same as `35a13793`, deliberately: a claim is an
        (entry, line) pair and two entries ARE two claims -- round 14's key,
        which a valid record depends on. What this round changes is that a
        record naming one requirement twice never reaches the owner, because
        the write stands down first. Moving the fix into the owner would
        undo round 14 and re-break the case above it.
        """
        evidence = self.evidence()
        entry = {"index": 1, "item": self.COLLIDING_ITEM, "status": "complete",
                 "detail": self.COLLIDING_DETAIL, "kind": "test-attested"}
        for times, expected in ((1, [True, False, False]), (2, [True, True, False])):
            with self.subTest(recorded=times):
                entries = [dict(entry) for _ in range(times)]
                line = evidence.rendered_entry_lines(entries)[0]
                owner = evidence.owned_lines(entries, [])
                self.assertEqual([owner.claim(line) for _ in range(3)], expected)

    # intent: fix
    # marker: red at `35a13793`, its own base, behaviourally --
    # `AssertionError: unexpectedly None`, the write going ahead on a record
    # naming one requirement in two spellings. Red on `016d94ba` on a name
    # this branch adds (#1751, round 16).
    def test_two_spellings_of_one_requirement_in_the_record_are_refused(self) -> None:
        """The key is the page's reading, and this is the shape that says so.

        `Manual QA on device` and `**Manual QA** on device` are two strings
        and one requirement: the page reads them the same, so every status
        line naming either is the entry's under the ownership rule, and two
        entries recording them are two claims on one line's bytes. Keying
        this check on the raw item text instead leaves the suite green --
        measured, a surviving mutant of this round -- because no fixture in
        it records one requirement under two spellings.

        Asked at the WRITER rather than through the turn, which is where the
        check lives and the only seam where both spellings survive: the
        turn's re-keying drops an entry whose item is not the requested
        string, so the pair cannot reach the write through it.

        `recorded_items` holds the requirement ONCE here, which is what the
        writer is handed in the shape this is about -- the turn builds it
        from a map keyed by index, so two entries at one index collapse to
        one recorded item while the entries themselves keep both. Handing
        both spellings as recorded items instead makes the CONTRACT's own
        guard fire first, and then this test would be about that guard.
        """
        evidence = self.evidence()
        entries = [
            {"index": 1, "item": "Manual QA on device", "status": "complete",
             "detail": "done on the test device"},
            {"index": 2, "item": "**Manual QA** on device", "status": "complete",
             "detail": "done on the test device"},
        ]
        lines = evidence.rendered_entry_lines(entries)
        write = evidence.write_evidence_status_section(
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + "\n".join(lines) + "\n\n## Validation\n\n- ok\n",
            lines, notes_from="## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + "\n".join(lines) + "\n\n## Validation\n\n- ok\n",
            recorded_items=["Manual QA on device"],
            entries=entries,
            previous_entries=[],
        )
        self.assertIsNotNone(write.refusal, "the write went ahead on two spellings of one item")
        self.assertIn("record one requirement more than once", write.refusal)
        self.assertIn("at position 1, 2", write.refusal)

    # intent: control
    # marker: green at `35a13793`, its own base -- `Ran 1 test ... OK` -- which
    # is what makes it a control; red on `016d94ba` on a NAME this branch adds,
    # since the writer takes no `entries` there. The shape it holds is the one
    # the refusal must not take, which is why the refusal keys on the ITEM and
    # not on the rendered line (#1751, round 16).
    def test_two_entries_whose_items_differ_still_write(self) -> None:
        """Round 14's shape, and the one this refusal must leave alone.

        `{item: "run `a", detail: "b -- c` ok"}` and
        `{item: "run `a -- b", detail: "c` ok"}` render the SAME line because
        the ` -- ` boundary falls in two places in one text, and their items
        genuinely differ -- two requirements, two claims, and a write. A
        refusal keyed on the rendered line rather than on the item would
        stand this down and cost the author a verdict.
        """
        evidence = self.evidence()
        entries = [
            {"index": 1, "item": "run `a", "status": "complete", "detail": "b -- c` ok"},
            {"index": 1, "item": "run `a -- b", "status": "complete", "detail": "c` ok"},
        ]
        lines = evidence.rendered_entry_lines(entries)
        self.assertEqual(lines[0], lines[1], "the shape is not built: the lines differ")
        write = evidence.write_evidence_status_section(
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + "\n".join(lines) + "\n\n## Validation\n\n- ok\n",
            lines, notes_from="## Summary\n\n- one change\n\n## Evidence Status\n\n"
            + "\n".join(lines) + "\n\n## Validation\n\n- ok\n",
            recorded_items=[str(entry["item"]) for entry in entries],
            entries=entries,
            previous_entries=[],
        )
        self.assertIsNone(write.refusal, write.refusal)

    # intent: guard
    # marker: red at `15e80e9e`, its own round's base, by API alone and it cannot be otherwise --
    # the seam it pins is one that round ADDS, so there is no property to hold at the base and
    # no drive that makes it behaviourally red there (#1751, round 15).
    def test_both_readers_agree_on_the_shape_the_two_keys_disagree_about(self) -> None:
        # The mirror pair: two entries, one line, twice in the body. A
        # line-keyed owner and a pair-keyed one answer the same here only
        # because a single body offers each entry's line once -- which is why
        # the instrument's second construction was equivalent rather than
        # wrong, and why replacing it is a structural fix and not a behaviour
        # change. Asserted so a future change to the rule cannot move one
        # reader without the other.
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_mirror", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        mirrored = [
            self.entry(index=1, status="complete", item="run `a", detail="b -- c` ok"),
            self.entry(index=2, status="complete", item="run `a -- b", detail="c` ok"),
        ]
        line = "- [complete] run `a -- b -- c` ok"
        source = (
            "<!-- evidence-status:v1\n" + json.dumps({"entries": mirrored}) + "\n-->\n\n"
            "## Summary\n\n- one change\n\n## Evidence Status\n\n"
            f"{line}\n{line}\n\n## Validation\n\n- ran it\n"
        )
        normalized = evidence._strip_evidence_metadata(
            sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", source)
        )
        lines = normalized.split("\n")
        instrument = sweep._entry_line_numbers(lines, normalized, source)
        entries = evidence.evidence_entries_of(source)
        owner = evidence.owned_lines(entries, entries)
        claimed = [index for index, one in enumerate(lines) if owner.claim(one)]
        self.assertEqual(sorted(instrument), claimed)
        self.assertEqual(len(claimed), 2, "two entries, two lines")

    # intent: fix
    # marker: behaviourally red at `f28b61f0`, its own base
    # (`AssertionError`).
    def test_the_instrument_calls_the_second_copy_the_authors_too(self) -> None:
        # The sweep's sight, restored by construction: it builds the same
        # owner, so exactly one of the two identical lines is the machine's to
        # it. With the cap a set again this returns both, and the write
        # deletes both -- which is the pair of facts round 8 made invisible.
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_multiset", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        source = sweep.MARKDOWN_LINE_ENDING_RE.sub("\n", self.body(2, recorded="complete"))
        normalized = evidence._strip_evidence_metadata(source)
        lines = normalized.split("\n")
        owned = sweep._entry_line_numbers(lines, normalized, source)
        self.assertEqual(len(owned), 1, "the instrument gave one entry both copies")

    # intent: fix
    # marker: behaviourally red at `f28b61f0`, its own base
    # (`AssertionError`).
    def test_the_instrument_reports_the_loss_when_the_write_takes_both(self) -> None:
        # What `lines_lost` says about a write that deleted the second copy:
        # the line, rather than nothing. Asked of the instrument directly with
        # a written body that kept one line, which is what the set-semantics
        # write produced.
        evidence = self.evidence()
        sweep = load_module(
            "evidence_write_sweep_loss", REPO_ROOT / "scripts" / "evidence-write-sweep.py"
        )
        source = self.body(2)
        took_both = self.body(1).replace("- [pending-ci] ", "- [complete] ", 1)
        self.assertIn(self.line, sweep.lines_lost(source, took_both))


if __name__ == "__main__":
    unittest.main()
