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
import datetime
import hashlib
import importlib.util
import io
import itertools
import os
import json
import random
import email
import re
import subprocess
import sys
import urllib.error
import urllib.request
import time
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


run_contributor = load_module("run_contributor_evidence_kinds", SCRIPT_PATH)
sync_execution_state = load_module(
    "sync_execution_state_evidence_kinds", SCRIPT_PATH.with_name("sync-execution-state.py")
)

# The skill's own module, by the name `run-contributor.py` put it under when it
# imported it. Named here because the renderer seam lives on it and both the
# refusal below and the recordings beside it address it directly.
helpers = sys.modules["_helpers"]

# One recording directory for both copies of the seam. The readiness gate
# records what GitHub answered for a body under the sha256 of that body
# (`test_pr_readiness.py`), and a body this suite asks about is the same body
# with the same answer, so a recording made by either suite serves the other.
RENDERED_FIXTURES = REPO_ROOT / "scripts" / "tests" / "fixtures" / "rendered"
RENDERED_INDEX = RENDERED_FIXTURES / "index.json"
RECORD_ENV = "WORKSPACES_RECORD_RENDERED"
RECORD_COMMAND = (
    f"{RECORD_ENV}=1 GH_TOKEN=$(gh auth token) "
    "uv run --script scripts/tests/test_factory_evidence_kinds.py"
)

# Captured before `setUpModule` refuses the renderer for the whole file: the
# recorder is the one place that DOES ask GitHub, and it asks the real
# function rather than the suite's refusal of it. Absent on a tree whose skill
# has no renderer, which is the red-at-base measurement -- the suite runs with
# an older `_helpers.py` swapped in to say which shapes are new, and refusing
# a function that is not there would error the file instead of failing the
# tests being measured.
_LIVE_RENDER = getattr(helpers, "render_markdown", None)


def insert_markdown_section(*args, **kwargs) -> str:
    """The body an insert produced, for tests that only assert on the body.

    `_helpers` had this as a production wrapper and it discarded the refusal
    and the unverified note, which cost an author their notes once and nearly
    a Mergeability section twice. Every production caller takes the answer
    now, so the convenience lives here, where dropping the rest of it is the
    point (#1773, round 8).
    """
    return helpers.inserted_markdown_section(*args, **kwargs).body


def rendered_fixture_path(text: str) -> Path:
    """Where the recorded answer for one body lives: its sha256, as HTML."""
    return RENDERED_FIXTURES / f"{hashlib.sha256(text.encode('utf-8')).hexdigest()}.html"


def rendered_index() -> dict[str, str]:
    """Which body each recording answers, so a stale one can be re-asked."""
    if not RENDERED_INDEX.is_file():
        return {}
    return json.loads(RENDERED_INDEX.read_text(encoding="utf-8"))


def indexed_body(entry: object) -> str:
    """The body one index entry answers for, in either shape it has had.

    Entries were the body text alone; they carry a recording stamp beside it
    now, so a reader can tell how old an answer is. Both shapes are read
    because the committed index holds both until every entry is re-asked
    (#1773, round 8).
    """
    if isinstance(entry, dict):
        return str(entry.get("body", ""))
    return str(entry)


def record_rendered(text: str) -> str:
    """Ask the live renderer for this body and store what it said, overwriting any earlier answer.

    RE-asks under the record flag rather than returning what is on disk. It
    returned an existing recording untouched, so the command the drift test
    names -- the one it hands an author when a recording no longer matches the
    live renderer -- could not refresh the recording it was named for (#1790).
    """
    rendered = _LIVE_RENDER(text)
    RENDERED_FIXTURES.mkdir(parents=True, exist_ok=True)
    rendered_fixture_path(text).write_text(rendered, encoding="utf-8")
    index = rendered_index()
    index[hashlib.sha256(text.encode("utf-8")).hexdigest()] = {
        "body": text,
        # From the clock at the moment of the ask, which is the only stamp
        # that says anything about the answer stored beside it.
        "recorded_at": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    RENDERED_INDEX.write_text(
        json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return rendered


def recorded_html(text: str) -> str:
    """One body's recorded answer, recorded now if the recorder is on."""
    path = rendered_fixture_path(text)
    # The flag first: a recording that has drifted is refreshed by the command
    # the drift test names, which it could not be while an existing file was
    # returned untouched (#1790).
    if os.environ.get(RECORD_ENV):
        return record_rendered(text)
    if path.is_file():
        return path.read_text(encoding="utf-8")
    raise AssertionError(
        f"No recorded renderer response for this body ({path.name}). Record it with:\n"
        f"  {RECORD_COMMAND}"
    )


@contextlib.contextmanager
def recorded_page():
    """Answer the placement check from checked-in renderer responses instead of the network.

    Every other test in this file runs with the renderer refused outright
    (`setUpModule`), so the suite reaches no network whether or not a token is
    in the environment and the check takes the fallback a laptop takes. A test
    that needs the page's own answer wraps itself in this.

    A body with no recording fails naming the command that records it: a
    recording is a file someone committed after reading it, not something a
    test run invents.
    """

    if _LIVE_RENDER is None:
        yield
        return

    with (
        mock.patch.object(helpers, "render_markdown", side_effect=recorded_html),
        mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
    ):
        yield


_RENDERER_REFUSED = None
SUITE_UNVERIFIED = "the suite does not reach the renderer"


def setUpModule() -> None:
    """No test in this file reaches the network.

    The placement check asks GitHub to render the body a write produced, and a
    suite that let that call out would be slow, would spend a rate limit, and
    would answer differently on a laptop with a token and in a sandbox without
    one. So the renderer is refused for the whole file and the tests that need
    its answer opt back in through `recorded_page`.
    """
    global _RENDERER_REFUSED
    if _LIVE_RENDER is None:
        return

    def refuse(text: str) -> str:
        raise helpers.RendererUnavailable(SUITE_UNVERIFIED, cause="unreachable")

    _RENDERER_REFUSED = mock.patch.object(helpers, "render_markdown", side_effect=refuse)
    _RENDERER_REFUSED.start()


def tearDownModule() -> None:
    if _RENDERER_REFUSED is not None:
        _RENDERER_REFUSED.stop()


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
        rendered = insert_markdown_section(
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
        rendered = insert_markdown_section(
            body, "Validation", "- ran it", before_heading="Risks"
        )
        self.assertIn("## Validation\n- ran it", rendered)
        self.assertLess(rendered.index("## Validation"), rendered.index("## risks"))

    def test_the_inserted_section_is_written_as_text(self) -> None:
        # Placement is a substitution. Handed a replacement string, `re.sub`
        # reads a backslash in the section as one of its own escapes, and a
        # `\d` in a validation note raised instead of being inserted.
        note = r"- ran `rg '\d+ tests'` over the log"
        rendered = insert_markdown_section(
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
        self.assertIsNone(self.evidence()._placement_a_reader_cannot_see(written).refusal)

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
        self.assertIsNone(evidence._placement_a_reader_cannot_see(written).refusal)
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
        rewritten = insert_markdown_section(
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
                rewritten = insert_markdown_section(body, heading, content)
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
                rewritten = insert_markdown_section(body, "Evidence Status", "- [x] written")
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
                one = insert_markdown_section(body, "Evidence Status", "- [complete] item -- proof")
                two = insert_markdown_section(one, "Performance", "Before: 1 ms\nAfter: 2 ms")
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
                written = insert_markdown_section(body, "Evidence Status", "- [x] written")
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
            out = insert_markdown_section(
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
            out = insert_markdown_section(
                self.FENCED_EXAMPLE_BODY, "Mergeability", "- Surface: agent-runtime"
            )
        self.assertEqual(captured.getvalue(), "")
        self.assertEqual(helpers.markdown_section(out, "Mergeability"), "- Surface: agent-runtime")
        self.assertIn("```markdown\n## Mergeability\n- Surface: docs\n```", out)
        for heading in ("Summary", "Validation", "Risks"):
            self.assertTrue(helpers.has_markdown_section(out, heading), heading)
        # A second write replaces what the first placed rather than adding a
        # third copy beside the example.
        again = insert_markdown_section(out, "Mergeability", "- Surface: docs")
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
            ).body
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
            written = insert_markdown_section(
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
        rewritten = insert_markdown_section(crlf, "Evidence Status", "- [x] written")
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
        one = insert_markdown_section(seed, "Evidence Status", "- [complete] the item -- proof")
        two = insert_markdown_section(one, "Performance", "- Before: 1 ms\n- After: 2 ms")
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
        rewritten = insert_markdown_section(body, "Evidence Status", "- [x] written")
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
        written = insert_markdown_section(body, "Evidence Status", "- [complete] y -- proof")
        self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "- [complete] y -- proof")
        self.assertNotIn("---------------", written)
        self.assertNotIn(self.REAL, written)
        # The sections around it are untouched and a second write is a fixed point.
        for heading in ("Summary", "Validation"):
            self.assertTrue(helpers.has_markdown_section(written, heading), heading)
        self.assertEqual(
            insert_markdown_section(written, "Evidence Status", "- [complete] y -- proof"),
            written,
        )

    def test_the_runtime_seeds_mergeability_and_the_gate_then_finds_it(self) -> None:
        # The issue's own reproduction, end to end: the runtime writes the
        # section, and the section it writes is the one a reader sees.
        execution, helpers = sys.modules["execution"], self.helpers()
        body = self.FENCED_ONLY.replace("Evidence Status", "Mergeability").replace(
            self.EXAMPLE, "- Surface: docs"
        )
        seeded = execution.seed_mergeability_section(body, changed_files=["docs/x.md"]).body
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
            seeded = execution.seed_mergeability_section(body, changed_files=["docs/x.md"]).body
        self.assertEqual(seeded, body)
        self.assertIn("is not a heading on the page", spoke.getvalue())
        self.assertIn("</pre>", spoke.getvalue())
        # And the control: close the block and the same write goes ahead.
        closed = body + "</pre>\n"
        written = execution.seed_mergeability_section(closed, changed_files=["docs/x.md"]).body
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
                written = insert_markdown_section(
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
        write = self.evidence().write_evidence_status_section(self.BODY, self.ENTRIES)
        self.assertIn(self.LONG_S, write.body, write.refusal)
        self.assertIn("- [complete] the printer's item -- not this section", write.body)
        self.assertNotIn(self.AUTHORS_LINE, write.body)
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
                written, stood_down, _ = self.evidence().write_evidence_status_section(body, self.ENTRIES)
                self.assertIn(self.AUTHORS_LINE, written, stood_down)

    def test_a_plain_heading_is_still_the_section_and_still_rewritten(self) -> None:
        # The control the other way: nothing above is a refusal of headings in
        # general.
        helpers = self.helpers()
        body = self.body("## Evidence Status")
        self.assertTrue(helpers.has_markdown_section(body, "Evidence Status"))
        written, _, _ = self.evidence().write_evidence_status_section(body, self.ENTRIES)
        self.assertNotIn(self.AUTHORS_LINE, written)

    def test_emphasis_is_markdown_rather_than_a_tag_and_stays_this_section(self) -> None:
        # The line this rule does not cross. `**Evidence Status**` is bold on
        # the page and reads as the heading it looks like, which is the
        # widening #1730 makes on purpose; it is not a tag and nothing here
        # takes it back. Green here and red at the merge base, where the
        # presence check was a literal pattern.
        helpers = self.helpers()
        body = self.body("## **Evidence Status**")
        self.assertTrue(helpers.has_markdown_section(body, "Evidence Status"))
        written, _, _ = self.evidence().write_evidence_status_section(body, self.ENTRIES)
        self.assertNotIn(self.AUTHORS_LINE, written)

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
                self.body(heading), ["- [complete] the UI lane -- swift test passed"]
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
                refusing, ["- [complete] the UI lane -- swift test passed"]
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
        # Under the page's own answer, because one of these headings carries a
        # `<details>` tag: the placement check asks the renderer whenever
        # anything above the section could fold it, and a run that could not
        # ask says so on this same stream (#1773). What is asserted here is
        # that the WRITER says nothing, so the page is given.
        for name, (heading, _) in self.SHAPES.items():
            with self.subTest(shape=name), recorded_page():
                spoke = io.StringIO()
                with contextlib.redirect_stderr(spoke):
                    written, refusal, _ = self.evidence().write_evidence_status_section(
                        self.body(heading), ["- [complete] the UI lane -- swift test passed"]
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
                two_tagged, ["- [complete] the UI lane -- swift test passed"]
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
        # the failure #1729 named; they share the function that decides.
        body = self.body(self.NOTES_BODY_TAIL)
        rendered, errors = run_contributor.render_execution_summary_body(
            body,
            requested_evidence=[self.ITEM],
            evidence_complete=["1 -- 214 tests passed"],
            evidence_blocked=None,
            evidence_pending_ci=None,
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
        written = insert_markdown_section(body, "Evidence Status", "- new")
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
        written = insert_markdown_section(body, "Evidence Status", "new")
        self.assertIn("intro with hard break  \n", written)
        self.assertEqual(helpers.markdown_section(written, "Evidence Status"), "new")
        self.assertIn("## Validation\nkeep", written)
        indented = insert_markdown_section(
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
            written, refusal, _ = evidence.write_evidence_status_section(body, [status])
        self.assertIsNone(refusal)
        self.assertLessEqual(len(written), evidence.PR_BODY_LIMIT)
        self.assertIn(status, written)
        self.assertNotIn("Evidence Notes", written)
        self.assertIn("not written", spoke.getvalue())
        # The control: the same body one block shorter does carry it.
        shorter = body.replace(note, note[:-32], 1)
        carried, _, _ = evidence.write_evidence_status_section(shorter, [status])
        self.assertIn("## Evidence Notes", carried)
        # And where the status alone is already past the limit, dropping the
        # notes buys nothing: the edit fails either way, so the text is kept
        # rather than traded for a body that still cannot be stored.
        huge = f"- [complete] {self.ITEM} -- " + "x" * evidence.PR_BODY_LIMIT
        kept, _, _ = evidence.write_evidence_status_section(body, [huge])
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
            written = evidence.write_evidence_status_section(body, [status])
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
            carried = evidence.write_evidence_status_section(shorter, [status])
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
            result = self.evidence().write_evidence_status_section(self.body(tail), self.ENTRIES)
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
                self.assertEqual(len(result.announcements), 1, result.announcements)
                announcement = result.announcements[0]
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
                        first.body, self.ENTRIES
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
        self.assertEqual(len(first.announcements), 1, first.announcements)
        self.assertEqual(len(second.announcements), 1, second.announcements)
        self.assertNotEqual(first.announcements[0], second.announcements[0])
        prior = self.posted([], list(first.announcements))
        self.assertEqual(len(self.posted(prior, list(second.announcements))), 1)

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
        note = result.announcements[0]
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


class ThePlacementAsksThePageWhetherASectionIsFoldedTests(unittest.TestCase):
    """The writer's placement check asks the page whether a fold hides the section (#1773).

    `placement_refusal` is the postcondition on every write: the section this
    write places has to be one a reader can see. It answered that from the
    parse alone, and the parse cannot see a fold -- a `<details>` ends at a
    blank line to CommonMark while the element stays open on the page, so a
    section written below an unclosed one is a heading here and a heading
    behind a disclosure to everyone else (#1742, item 3). The gate's side of
    that was #1769: it reads a folded status and refuses it. This is the
    writer's side, and it refuses to put the section there at all.

    Deciding it means knowing element nesting across a whole body, which is
    the model this seam exists not to build. So the page is asked, the way the
    gate asks it for the line starts it reads (#1745), with the same fallback:
    no renderer means the source model's answer and a sentence saying the page
    went unread.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"
    SUMMARY = "## Summary\n\n- one change\n"
    DISCLOSURE = "<details>\n<summary>notes</summary>\n\nfolded prose\n"

    # Every placement shape this check answers about, with what it must say.
    # `None` is placed; a string is the substring the refusal has to carry.
    # The last three are what the source model already refused and still
    # refuses, so the page's answer is a widening and not a replacement.
    SHAPES: dict[str, tuple[str, str | None]] = {
        "an unclosed disclosure above the section": (
            f"{SUMMARY}\n{DISCLOSURE}",
            "renders inside the `<details>` opened at line 5",
        ),
        "a disclosure closed above the section": (
            f"{SUMMARY}\n{DISCLOSURE}\n</details>\n",
            None,
        ),
        "a disclosure inside another, the outer left open": (
            f"<details>\n<summary>outer</summary>\n\n<details>\n<summary>inner</summary>\n\nprose\n\n</details>\n",
            "renders inside the `<details>` opened at line 1",
        ),
        "a fenced example of a disclosure above the section": (
            f"{SUMMARY}\n```html\n<details>\n<summary>notes</summary>\n```\n",
            None,
        ),
        "no raw HTML at all": (SUMMARY, None),
        "a `<pre>` that never closes above the section": (
            f"{SUMMARY}\n<pre>\na log nobody closed\n",
            "is not a heading on the page",
        ),
        "a comment that never closes above the section": (
            f"{SUMMARY}\n<!-- a note the author left\n",
            "is not a heading on the page",
        ),
        "a fence that never closes above the section": (
            f"{SUMMARY}\n```text\na log, never closed\n",
            "is not a heading on the page",
        ),
    }

    # The shape the check is NOT about: a disclosure the author opened inside
    # the section folds that section's own text, and the heading stays where a
    # reader arrives at it. Whether folded contents are readable is the
    # reader's question and the gate answers it on its own account (#1769), so
    # the writer places this and the page is not even asked.
    SECTION_FOLDS_ITSELF = (
        "## Summary\n\n- one change\n"
        "\n## Evidence Status\n\n<details>\n<summary>runs</summary>\n\n"
        "- [complete] `swift test` -- 1992 tests passed\n"
    )

    def answer(self, body: str):
        """The whole answer: why the write stood down, and what went unasked."""
        return helpers.placement_refusal(body, body + self.SECTION, self.HEADING)

    def placement(self, body: str) -> str | None:
        return self.answer(body).refusal

    def test_every_placement_shape_gets_the_answer_the_page_supports(self) -> None:
        for label, (body, expected) in self.SHAPES.items():
            with self.subTest(shape=label), recorded_page():
                refusal = self.placement(body)
                if expected is None:
                    self.assertIsNone(refusal, label)
                else:
                    self.assertIsNotNone(refusal, label)
                    self.assertIn(expected, refusal, label)

    def test_the_refusal_names_the_disclosure_and_the_repair(self) -> None:
        # The headline shape, and what an author is owed about it: which
        # element folded the section, where it was opened, and the one edit
        # that puts the section back on the page.
        body, _ = self.SHAPES["an unclosed disclosure above the section"]
        with recorded_page():
            refusal = self.placement(body)
        self.assertIn("`## Evidence Status`", refusal)
        self.assertIn("(`<details>`)", refusal)
        self.assertIn("the page folds it away", refusal)
        self.assertIn("closing that element above the section", refusal)

    def test_a_section_the_page_shows_unfolded_is_placed(self) -> None:
        # The control, stated on its own rather than only in the table: the
        # same body with the disclosure closed is a placement, so the check
        # costs an ordinary write nothing.
        body, _ = self.SHAPES["a disclosure closed above the section"]
        with recorded_page():
            self.assertIsNone(self.placement(body))

    def test_a_disclosure_inside_the_section_is_not_a_placement_question(self) -> None:
        # The page decides it now rather than a gate that looked only above
        # the heading: `could_be_folded` reads the whole body, so this one IS
        # asked, and the answer is that the heading this write places is not
        # folded -- whatever its own contents do (#1773, round 3). The gate
        # and the question are about the same text, so the verdict no longer
        # depends on where an unrelated disclosure happens to sit.
        with recorded_page():
            answer = helpers.placement_refusal(
                self.SUMMARY, self.SECTION_FOLDS_ITSELF, self.HEADING
            )
        self.assertIsNone(answer.refusal)
        self.assertIsNone(answer.unverified)

    def test_the_page_is_asked_only_where_something_above_could_fold_the_heading(self) -> None:
        # A request per write on every body would spend a rate limit on
        # bodies where no fold is possible. The precondition is textual and
        # over-inclusive -- a fenced `<details>` above costs one call -- and
        # it can never skip a body a fold could reach.
        asked: dict[str, list[str]] = {}
        for label, (body, _) in self.SHAPES.items():
            with self.subTest(shape=label), recorded_page():
                seen: list[str] = []
                recorded = helpers.render_markdown
                with mock.patch.object(
                    helpers,
                    "render_markdown",
                    side_effect=lambda text: seen.append(text) or recorded(text),
                ):
                    self.placement(body)
                asked[label] = seen
        self.assertEqual(
            {label for label, seen in asked.items() if seen},
            {
                "an unclosed disclosure above the section",
                "a disclosure closed above the section",
                "a disclosure inside another, the outer left open",
                "a fenced example of a disclosure above the section",
            },
        )

    def test_the_page_is_asked_once_per_body(self) -> None:
        body, _ = self.SHAPES["an unclosed disclosure above the section"]
        seen: list[str] = []
        with recorded_page():
            recorded = helpers.render_markdown
            with mock.patch.object(
                helpers,
                "render_markdown",
                side_effect=lambda text: seen.append(text) or recorded(text),
            ):
                for _ in range(3):
                    self.placement(body)
        self.assertEqual(len(seen), 1, seen)

    def test_with_no_renderer_every_shape_falls_back_to_the_source_model(self) -> None:
        # The fallback, stated as the cost it is: with no page the check is
        # exactly the check that shipped before this change, so the fold
        # shapes are placed and the shapes the model sees are still refused.
        for label, (body, expected) in self.SHAPES.items():
            with self.subTest(shape=label):
                refusal = self.placement(body)
                if expected is not None and "is not a heading on the page" in expected:
                    self.assertIn(expected, refusal or "", label)
                else:
                    self.assertIsNone(refusal, label)

    def test_with_no_renderer_the_note_comes_back_to_the_caller(self) -> None:
        # Never a silent accept, and never only a log line: the body the page
        # would have refused is placed, and the sentence saying which question
        # went unanswered is RETURNED, so a caller with a surface the author
        # reads can put it there (#1773, round 2).
        body, _ = self.SHAPES["an unclosed disclosure above the section"]
        answer = self.answer(body)
        self.assertIsNone(answer.refusal)
        self.assertIn(SUITE_UNVERIFIED, answer.unverified)
        self.assertIn("decided by the source model alone", answer.unverified)

    def test_a_body_with_nothing_to_fold_says_nothing_about_the_renderer(self) -> None:
        # The note is about a question that was asked and went unanswered. A
        # body no fold can reach asks nothing, so a tokenless run on ordinary
        # bodies carries no note rather than one per write.
        answer = self.answer(self.SUMMARY)
        self.assertIsNone(answer.refusal)
        self.assertIsNone(answer.unverified)


class TheWriterStandsDownOnAFoldedPlacementTests(unittest.TestCase):
    """What the fold refusal does to a real write, and where its author reads it (#1773).

    A refusal that only a postcondition sees is a refusal nobody acts on. The
    write stands the body down whole -- the author's text untouched, the
    status this run resolved not written either -- and the reason travels in
    the announcements list, which is the surface that reaches the author
    (#1740, #1756). So a folded placement is a refusal with a reason given
    rather than a section quietly written where nobody arrives at it.
    """

    ITEM = "`swift test` passes"
    FOLDED_BODY = (
        "## Summary\n\n- one change\n\n"
        "<details>\n<summary>notes</summary>\n\nfolded prose\n\n"
        "## Validation\n\n- ran it\n"
    )

    def evidence(self):
        return sys.modules["evidence"]

    def meta(self) -> str:
        entry = {
            "index": 1,
            "item": self.ITEM,
            "status": "pending-ci",
            "detail": "the lane has not run yet",
            "kind": "test",
        }
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def test_the_turn_s_write_stands_the_body_down_and_names_the_disclosure(self) -> None:
        with recorded_page():
            written, errors = run_contributor.render_execution_summary_body(
                self.FOLDED_BODY,
                requested_evidence=[self.ITEM],
                evidence_complete=["1 -- 214 tests passed"],
                evidence_blocked=None,
                evidence_pending_ci=None,
            )
        self.assertEqual(written, self.FOLDED_BODY)
        self.assertEqual(len(errors), 1)
        self.assertIn("the page folds it away", errors[0])

    def test_the_lane_write_announces_the_stand_down_where_its_author_reads(self) -> None:
        evidence = self.evidence()
        with recorded_page():
            write = evidence.write_evidence_status_section(
                self.meta() + self.FOLDED_BODY, ["- [complete] `swift test` passes -- 214 passed"]
            )
        self.assertEqual(write.body, self.meta() + self.FOLDED_BODY)
        self.assertEqual(len(write.announcements), 1)
        self.assertTrue(evidence.is_stood_down_announcement(write.announcements[0]))
        self.assertIn("the page folds it away", write.announcements[0])

    # intent: control
    # Green on main: the unchanged case beside the stand-down.
    def test_the_same_write_goes_ahead_once_the_disclosure_is_closed(self) -> None:
        # The control on the write itself: closing the element is the repair
        # the refusal names, and the status lands under the page's own heading.
        closed = self.FOLDED_BODY.replace(
            "folded prose\n\n## Validation", "folded prose\n\n</details>\n\n## Validation"
        )
        with recorded_page():
            write = self.evidence().write_evidence_status_section(
                self.meta() + closed, ["- [complete] `swift test` passes -- 214 passed"]
            )
        self.assertIsNone(write.refusal)
        self.assertIn("## Evidence Status", write.body)
        self.assertIn("- [complete] `swift test` passes -- 214 passed", write.body)


class ThePageIsAskedAboutTheSectionAndNotAHeadingBesideItTests(unittest.TestCase):
    """The check asked a true question about the wrong element (#1773, round 2).

    `placement_refusal` answered from the FIRST rendered heading whose text
    reads as this section, while `section_heading_index` skips a heading
    carrying inline HTML. A body with both -- a struck-out
    `## Evidence <del>Status</del>` at the top level and the plain heading
    below an unclosed `<details>` -- got a true answer about the struck-out
    one ("not folded") for a write that landed in the fold; the rewrite then
    took the `</details>` with it and `## Validation` folded too.

    The defect has the same shape as #1751's regression one lane over: a
    reading compared against something adjacent to the thing being acted on.
    Here the fix is not to pick the right heading but to stop picking. Which
    rendered heading corresponds to which source heading cannot be decided
    without modelling what the renderer does to a heading carrying a tag, and
    the measurement says that model would have to have two branches:

    - `## Evidence <del>Status</del>` renders as `<h2>Evidence <del>Status</del></h2>`,
      whose text still reads as this heading, so the page shows two matches
      where the body has two;
    - `## <details>Evidence Status</details>` renders as
      `<h2><details><summary>Details</summary>Evidence Status</details></h2>`
      -- the renderer ADDS a summary -- so its text no longer reads as this
      heading and the page shows one match where the body has two.

    An index into one list read against the other names some other heading in
    the second case, counted from either end. So no index is taken: a page
    that folds a heading of this name away refuses the write, whichever
    heading it is. That direction can only add refusals, and the one it adds
    needs two headings a reader sees under one name.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"
    SUMMARY = "## Summary\n\n- one change\n\n"
    FOLD = "<details>\n<summary>notes</summary>\n\nfolded prose\n"

    # The reproduction, byte for byte: a tagged heading the source model skips
    # sits at the top level, and the heading it chooses is below an unclosed
    # disclosure. Red at `c717e7ef`, where the refusal was None.
    TAGGED_ABOVE_A_FOLDED_SECTION = f"{SUMMARY}## Evidence <del>Status</del>\n\nstruck\n\n{FOLD}"
    # And the body the renderer treats the other way: the source model skips
    # this heading too, but the page does not read it as this heading at all.
    # It placed before this round and it places now.
    DECORATED_ABOVE_A_PLAIN_SECTION = (
        f"{SUMMARY}## <details>Evidence Status</details>\n\ntagged\n"
    )

    def answer(self, body: str):
        return helpers.placement_refusal(body, body + self.SECTION, self.HEADING)

    def test_a_tagged_heading_above_a_folded_section_no_longer_answers_for_it(self) -> None:
        with recorded_page():
            answer = self.answer(self.TAGGED_ABOVE_A_FOLDED_SECTION)
        self.assertIsNotNone(answer.refusal)
        self.assertIn("the page folds it away", answer.refusal)
        self.assertIn("`## Evidence Status`", answer.refusal)

    def test_the_page_shows_both_headings_and_only_one_of_them_is_folded(self) -> None:
        # The measurement the rule rests on, asserted rather than described:
        # the struck-out heading reads as this heading on the page and is not
        # folded, and the one the write lands on is.
        written = self.TAGGED_ABOVE_A_FOLDED_SECTION + self.SECTION
        with recorded_page():
            page = helpers.rendered_page(written)
        self.assertIsNone(page.unverified)
        self.assertEqual(helpers.folded_headings_on_the_page(page.html, self.HEADING), [False, True])

    def test_a_heading_the_renderer_decorates_is_not_this_heading_and_still_places(self) -> None:
        # The other branch, and the body this round must not start refusing:
        # the renderer gives `<details>` in a heading a `<summary>Details</summary>`,
        # so that heading's text is no longer this heading, the page shows one
        # match, and it is not folded.
        written = self.DECORATED_ABOVE_A_PLAIN_SECTION + self.SECTION
        with recorded_page():
            page = helpers.rendered_page(written)
            answer = self.answer(self.DECORATED_ABOVE_A_PLAIN_SECTION)
        self.assertEqual(helpers.folded_headings_on_the_page(page.html, self.HEADING), [False])
        self.assertIsNone(answer.refusal)

    def test_the_notes_section_is_asked_the_same_question(self) -> None:
        # The other heading a placement asks about (`## Evidence Notes`), and
        # the same defect: one rule, so one fix, and this is what says so.
        body = f"{self.SUMMARY}## Evidence <del>Notes</del>\n\nstruck\n\n{self.FOLD}"
        written = body + "\n## Evidence Notes\n\na carried note\n"
        with recorded_page():
            answer = helpers.placement_refusal(body, written, "Evidence Notes")
        self.assertIsNotNone(answer.refusal)
        self.assertIn("the page folds it away", answer.refusal)
        self.assertIn("`## Evidence Notes`", answer.refusal)


class TheAuthorsOwnTagCannotBreakOutOfTheSentenceTests(unittest.TestCase):
    """The refusal quotes the author's opening line, so it goes through `code_span` (#1773, round 2).

    The sentence reaches a comment the app posts. A backtick inside the tag
    closes a hand-written span early and what follows it is live markdown --
    an `@name` after one is a mention GitHub delivers to a person with nothing
    to do with this (#1730, round 2). `code_span` is the helper that exists
    for exactly this and its docstring names this failure.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"

    def test_a_backtick_in_the_tag_does_not_close_the_span(self) -> None:
        body = (
            "## Summary\n\n- one change\n\n"
            '<details data-note="a `tick` and @nobody">\n<summary>notes</summary>\n\nfolded\n'
        )
        with recorded_page():
            refusal = helpers.placement_refusal(body, body + self.SECTION, self.HEADING).refusal
        self.assertIsNotNone(refusal)
        quoted = helpers.code_span('<details data-note="a `tick` and @nobody">')
        self.assertIn(quoted, refusal)
        # The whole quotation is one code span to the parser, so the `@nobody`
        # inside it is text rather than a mention.
        rendered = helpers.MARKDOWN.parseInline(refusal)[0].children or []
        self.assertTrue(
            any(child.type == "code_inline" and "@nobody" in child.content for child in rendered),
            [(child.type, child.content) for child in rendered],
        )


class AFailedRenderIsNotAnAnswerAboutThisBodyTests(unittest.TestCase):
    """A `RendererUnavailable` is not cached (#1773, round 2).

    Caching it disabled the check for that body for the rest of the process:
    a turn writes the status section and then the notes section beside it, and
    a 503 on the first write meant the second took the fallback even after the
    renderer came back. A failure says nothing about the text.
    """

    BODY = "## Summary\n\n- one change\n\n<details>\n<summary>notes</summary>\n\nfolded\n"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"

    def test_a_failure_is_not_remembered_and_a_later_answer_is(self) -> None:
        written = self.BODY + self.SECTION
        attempts: list[str] = []

        def flaky(text: str) -> str:
            attempts.append(text)
            if len(attempts) == 1:
                raise helpers.RendererUnavailable("the renderer answered HTTP 503", cause="server error")
            return recorded_html(text)

        with (
            mock.patch.object(helpers, "render_markdown", side_effect=flaky),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
        ):
            first = helpers.placement_refusal(self.BODY, written, "Evidence Status")
            second = helpers.placement_refusal(self.BODY, written, "Evidence Status")
        self.assertIn("503", first.unverified)
        self.assertIsNone(first.refusal)
        # The second call asks again and gets the answer the first could not.
        self.assertEqual(len(attempts), 2)
        self.assertIsNone(second.unverified)
        self.assertIn("the page folds it away", second.refusal)

    def test_an_answer_is_still_asked_once(self) -> None:
        written = self.BODY + self.SECTION
        asked: list[str] = []
        with recorded_page():
            recorded = helpers.render_markdown
            with mock.patch.object(
                helpers, "render_markdown", side_effect=lambda text: asked.append(text) or recorded(text)
            ):
                for _ in range(3):
                    helpers.placement_refusal(self.BODY, written, "Evidence Status")
        self.assertEqual(len(asked), 1, asked)


class TheNamedRepairIsOneThatRepairsTests(unittest.TestCase):
    """Which disclosure the refusal names (#1773, round 2).

    Two ways the first version named the wrong line. A `<details>` inside an
    HTML COMMENT counted toward the nesting, so the refusal pointed at a tag
    nobody can see and closing it does nothing -- and the factory writes its
    own metadata as a comment, so this is a shape every body it touches has.
    And of several disclosures left open, it named the innermost: closing that
    one leaves the section folded by the outer one, which is a repair that
    does not repair.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"

    def test_a_commented_out_disclosure_is_not_the_one_that_folds_it(self) -> None:
        body = (
            "## Summary\n\n- one change\n\n"
            "<!-- an earlier draft:\n<details>\n<summary>old</summary>\n-->\n\n"
            "<details>\n<summary>notes</summary>\n\nfolded prose\n"
        )
        line = helpers.section_heading_line(body + self.SECTION, self.HEADING)
        # The real one is on line 10 (one-based); the commented one is line 5.
        self.assertEqual(helpers.open_disclosure_line(body + self.SECTION, line), 9)

    def test_the_outermost_open_disclosure_is_the_one_named(self) -> None:
        body = (
            "## Summary\n\n- one change\n\n"
            "<details>\n<summary>outer</summary>\n\n"
            "<details>\n<summary>inner</summary>\n\nprose\n"
        )
        written = body + self.SECTION
        line = helpers.section_heading_line(written, self.HEADING)
        self.assertEqual(helpers.open_disclosure_line(written, line), 4)
        with recorded_page():
            refusal = helpers.placement_refusal(body, written, self.HEADING).refusal
        # Named by the line the OUTER one opened on: closing the inner one
        # leaves the section folded.
        self.assertIn("opened at line 5", refusal)


class TheUnreadPageReachesTheSurfaceTheAuthorReadsTests(unittest.TestCase):
    """The note has a channel where the check actually runs (#1773, round 2).

    `log()` is stderr, and every automated caller of this check runs where
    stderr is a step log nobody opens -- which is the whole of #1740. So the
    sentence comes back to the caller and travels in the announcements list,
    the surface that already carries a note about text a write could not keep
    (#1756). It travels on an ACCEPTED write as much as a refused one: that
    is the case it exists for, since a renderer 503 used to accept a folded
    placement with nothing visible anywhere.
    """

    ITEM = "`swift test` passes"
    FOLDED_BODY = (
        "## Summary\n\n- one change\n\n"
        "<details>\n<summary>notes</summary>\n\nfolded prose\n\n"
        "## Validation\n\n- ran it\n"
    )
    PLACEABLE_BODY = FOLDED_BODY.replace(
        "folded prose\n\n## Validation", "folded prose\n\n</details>\n\n## Validation"
    )

    def evidence(self):
        return sys.modules["evidence"]

    def meta(self) -> str:
        entry = {
            "index": 1,
            "item": self.ITEM,
            "status": "pending-ci",
            "detail": "the lane has not run yet",
            "kind": "test",
        }
        return "<!-- evidence-status:v1\n" + json.dumps({"entries": [entry]}) + "\n-->\n\n"

    def write(self, body: str):
        return self.evidence().write_evidence_status_section(
            self.meta() + body, ["- [complete] `swift test` passes -- 214 passed"]
        )

    def test_an_accepted_write_with_no_page_still_announces_the_unread_check(self) -> None:
        # The renderer is refused file-wide, so this is the 503 case: the
        # write goes ahead on the source model's answer and says so where the
        # author reads, rather than nowhere.
        write = self.write(self.PLACEABLE_BODY)
        self.assertIsNone(write.refusal)
        self.assertIn("## Evidence Status", write.body)
        unverified = [
            note for note in write.announcements if self.evidence().is_unverified_announcement(note)
        ]
        self.assertEqual(len(unverified), 1, write.announcements)
        self.assertIn(SUITE_UNVERIFIED, unverified[0])

    def test_a_stood_down_write_carries_both_sentences(self) -> None:
        # A stand-down returns early, and the note about the unread check is
        # not the stand-down's reason -- both have to survive, because they
        # are different claims about the same run.
        with recorded_page():
            write = self.write(self.FOLDED_BODY)
        self.assertIsNotNone(write.refusal)
        self.assertTrue(
            any(self.evidence().is_stood_down_announcement(n) for n in write.announcements)
        )

    # intent: control
    # Green on main: nothing to say when the page answers.
    def test_the_page_answering_leaves_no_note(self) -> None:
        with recorded_page():
            write = self.write(self.PLACEABLE_BODY)
        self.assertIsNone(write.refusal)
        self.assertEqual(
            [n for n in write.announcements if self.evidence().is_unverified_announcement(n)], []
        )

    def test_the_comment_the_author_reads_says_which_claim_this_is(self) -> None:
        # The composer's three buckets. Said under either of the other two
        # headlines this would be a claim about the author's text, which it is
        # not: nothing was deleted and nothing was left unwritten.
        execution = sys.modules["execution"]
        helpers = sys.modules["_helpers"]
        # Built by the constructor the classifier reads, so the note carries
        # its heading and the headline names the section it is about.
        note = helpers.unverified_announcement("Mergeability", "the renderer answered HTTP 503")
        comment = execution.compose_uncarried_notes_comment(None, [note], "abc1234")
        self.assertIn(execution.unverified_notes_headline("Mergeability"), comment)
        self.assertNotIn(execution.unverified_notes_headline("Evidence Status"), comment)
        self.assertNotIn(execution.UNCARRIED_NOTES_HEADLINE, comment)
        self.assertNotIn(execution.STOOD_DOWN_NOTES_HEADLINE, comment)
        self.assertIn("Nothing here says anything was lost", comment)
        self.assertIn("HTTP 503", comment)

    def test_a_deletion_and_an_unread_check_are_still_told_apart(self) -> None:
        execution = sys.modules["execution"]
        evidence = self.evidence()
        helpers = sys.modules["_helpers"]
        notes = [
            helpers.unverified_announcement("Evidence Status", "the renderer was unreachable"),
            "not carried to `## Evidence Notes`: a fence with no closing line",
        ]
        comment = execution.compose_uncarried_notes_comment(None, notes, "abc1234")
        # One headline, and it is the one about the author's text -- which is
        # the claim that names an edit. The unread check gets its own block
        # under its own sentence, so the two are not read as one loss.
        self.assertIn(execution.UNCARRIED_NOTES_HEADLINE, comment)
        self.assertNotIn(execution.unverified_notes_headline("Evidence Status"), comment)
        self.assertIn("could not be moved to `## Evidence Notes`", comment)
        self.assertIn("a fence with no closing line", comment)
        self.assertIn("Nothing here says anything was lost", comment)
        self.assertIn("the renderer was unreachable", comment)
        self.assertLess(
            comment.index("a fence with no closing line"),
            comment.index("the renderer was unreachable"),
        )


class ThePageIsAskedAboutTheHeadingThisWritePlacesTests(unittest.TestCase):
    """"Any heading of this name folded" refused placements a reader can see (#1773, round 3).

    Round 2 stopped taking an index into the page's headings, because which
    rendered heading matches which source heading needs a model of what the
    renderer does to a heading carrying a tag. The rule it left -- refuse if
    the page folds ANY heading of this name -- is monotone, but the claim that
    the refusals it adds land on bodies `rejected_heading_note` already flags
    is false. That note fires on an h2 TOKEN carrying an `html_inline` child,
    and the shapes that break this are headings the parser never reads as an
    h2 at all:

    - a raw `<h2>Evidence Status</h2>` inside a CLOSED `<details>` -- an
      earlier draft an author folded away;
    - a heading inside a `<summary>`, which a reader ALWAYS sees.

    Both render as a folded heading of this name beside the write's own
    unfolded one, so the write was refused with a sentence naming no line and
    no repair (`open_disclosure_line` correctly finds nothing open above it).

    The question is made unambiguous instead of the answer being guessed: the
    heading this write places is renamed to a mark nothing else carries, the
    page is asked about THAT heading, and renaming a heading cannot change
    what folds it. No index, no sanitizer model, and no dependence on anything
    GitHub could change without telling us.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"
    SUMMARY = "## Summary\n\n- one change\n\n"

    # Red at `a0bf18f3`: each of these was refused, and the page's own answer
    # for the write's heading is "not folded".
    A_RAW_H2_IN_A_CLOSED_DISCLOSURE = (
        f"{SUMMARY}<details>\n<summary>an earlier draft</summary>\n\n"
        "<h2>Evidence Status</h2>\n\n</details>\n"
    )
    A_HEADING_IN_A_SUMMARY = (
        f"{SUMMARY}<details>\n<summary><h2>Evidence Status</h2></summary>\n\nbody\n\n</details>\n"
    )
    # And the shape that must still refuse, so the widening is not a hole.
    A_FOLD_AROUND_THE_SECTION = f"{SUMMARY}<details>\n<summary>notes</summary>\n\nfolded prose\n"

    def answer(self, body: str):
        return helpers.placement_refusal(body, body + self.SECTION, self.HEADING)

    def test_a_folded_heading_the_parser_never_reads_does_not_refuse_the_write(self) -> None:
        for label, body in (
            ("a raw h2 inside a closed disclosure", self.A_RAW_H2_IN_A_CLOSED_DISCLOSURE),
            ("a heading inside a summary", self.A_HEADING_IN_A_SUMMARY),
        ):
            with self.subTest(shape=label), recorded_page():
                self.assertIsNone(self.answer(body).refusal, label)

    def test_the_page_does_show_a_folded_heading_of_this_name_in_both(self) -> None:
        # The measurement the rule used to act on, asserted so the test is not
        # vacuous: the page really does show two headings of this name, one of
        # them folded, and the write's own is the unfolded one.
        for label, body in (
            ("a raw h2 inside a closed disclosure", self.A_RAW_H2_IN_A_CLOSED_DISCLOSURE),
            ("a heading inside a summary", self.A_HEADING_IN_A_SUMMARY),
        ):
            with self.subTest(shape=label), recorded_page():
                page = helpers.rendered_page(body + self.SECTION)
                self.assertEqual(
                    helpers.folded_headings_on_the_page(page.html, self.HEADING), [True, False]
                )

    # intent: guard
    # Green on main: a property of main's own flagger.
    def test_neither_shape_is_one_the_rejected_heading_note_flags(self) -> None:
        # Why the round-2 justification did not hold: that note reads h2
        # TOKENS, and a raw `<h2>` inside raw HTML is not one.
        for body in (self.A_RAW_H2_IN_A_CLOSED_DISCLOSURE, self.A_HEADING_IN_A_SUMMARY):
            with self.subTest(body=body[:40]):
                self.assertIsNone(helpers.rejected_heading_note(body + self.SECTION, self.HEADING))

    def test_a_placement_inside_a_fold_is_still_refused(self) -> None:
        with recorded_page():
            refusal = self.answer(self.A_FOLD_AROUND_THE_SECTION).refusal
        self.assertIsNotNone(refusal)
        self.assertIn("the page folds it away", refusal)

    def test_the_probe_renames_one_heading_and_leaves_the_body_alone(self) -> None:
        written = self.A_RAW_H2_IN_A_CLOSED_DISCLOSURE + self.SECTION
        line = helpers.section_heading_line(written, self.HEADING)
        probe = helpers.probe_body_naming_one_heading(written, self.HEADING, line)
        self.assertEqual(probe.count(helpers.PLACEMENT_PROBE_MARK), 1)
        self.assertEqual(
            len(helpers.MARKDOWN_LINE_ENDING_RE.split(probe)),
            len(helpers.MARKDOWN_LINE_ENDING_RE.split(written)),
            "the probe is one line for one line, so every line number below it holds",
        )
        # Everything but the heading line is untouched, which is what makes
        # the probe's fold structure the real one.
        before = helpers.MARKDOWN_LINE_ENDING_RE.split(written)
        after = helpers.MARKDOWN_LINE_ENDING_RE.split(probe)
        self.assertEqual(
            [index for index, (a, b) in enumerate(zip(before, after)) if a != b], [line]
        )

    def test_a_setext_heading_is_renamed_without_leaving_its_underline(self) -> None:
        written = f"{self.SUMMARY}Evidence Status\n---------------\n\n- [complete] x -- y\n"
        line = helpers.section_heading_line(written, self.HEADING)
        probe = helpers.probe_body_naming_one_heading(written, self.HEADING, line)
        lines = helpers.MARKDOWN_LINE_ENDING_RE.split(probe)
        self.assertEqual(lines[line], f"## {self.HEADING} {helpers.PLACEMENT_PROBE_MARK}")
        self.assertEqual(lines[line + 1], "")

    def test_a_body_already_carrying_the_mark_is_placed(self) -> None:
        """Uniqueness is by construction, so carrying the base mark costs nothing (#1773, round 4).

        The base is a string no author writes, which is not a string no author
        CAN write -- by accident, or by someone who has read this code. When
        it was fixed, such a body put two headings of the probe's name on the
        page and drew the ambiguity refusal: safe, and a refusal on a
        legitimate body carrying a message about a heading its author cannot
        see.

        The mark now counts up until it is absent from the body, so this body
        is placed like any other, and the probe still names exactly one
        heading.
        """
        body = (
            f"{self.SUMMARY}"
            "<details>\n<summary>notes</summary>\n\nfolded prose\n\n</details>\n\n"
            f"## Evidence Status {helpers.PLACEMENT_PROBE_MARK}\n\nsomeone wrote this\n"
        )
        written = body + self.SECTION
        mark = helpers.placement_probe_mark(written)
        self.assertNotEqual(mark, helpers.PLACEMENT_PROBE_MARK)
        self.assertNotIn(mark, written)
        self.assertTrue(mark.startswith(helpers.PLACEMENT_PROBE_MARK))
        # The same body chooses the same mark every time, or no recording ever
        # matches: the fixtures are keyed by the sha256 of the probe body.
        self.assertEqual(helpers.placement_probe_mark(written), mark)
        with recorded_page():
            answer = self.answer(body)
        self.assertIsNone(answer.refusal)
        self.assertIsNone(answer.unverified)

    def test_the_mark_is_the_base_where_the_body_does_not_carry_it(self) -> None:
        self.assertEqual(
            helpers.placement_probe_mark("## Summary\n\n- one change\n"),
            helpers.PLACEMENT_PROBE_MARK,
        )
        # And counts past every spelling the body does carry.
        crowded = f"{helpers.PLACEMENT_PROBE_MARK} {helpers.PLACEMENT_PROBE_MARK}1"
        self.assertEqual(
            helpers.placement_probe_mark(crowded), f"{helpers.PLACEMENT_PROBE_MARK}2"
        )

    def test_a_page_showing_the_chosen_name_twice_is_refused(self) -> None:
        """The guard behind the construction, fed two matches at the seam (#1773, round 4).

        With the mark absent from the body, only the renderer can put two
        headings of that name on the page. That is what the exactly-one check
        is for, and `if not shown:` -- which catches none rather than
        "not exactly one" -- leaves it unproven.

        The two matches are handed in at the renderer seam the suite already
        owns, not by patching anything the runtime decides with.
        """
        body = f"{self.SUMMARY}<details>\n<summary>notes</summary>\n\nfolded prose\n\n</details>\n"
        written = body + self.SECTION
        mark = helpers.placement_probe_mark(written)
        doubled = (
            "<h2>Summary</h2>"
            f"<h2>Evidence Status {mark}</h2>"
            f"<h2>Evidence Status {mark}</h2>"
        )
        with (
            mock.patch.object(helpers, "render_markdown", return_value=doubled),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
        ):
            answer = self.answer(body)
        self.assertEqual(
            helpers.folded_headings_on_the_page(doubled, f"Evidence Status {mark}"), [False, False]
        )
        self.assertIsNotNone(answer.refusal, "an ambiguous find accepted the placement")
        self.assertIn("is not a heading on the page", answer.refusal)

    def test_the_gate_and_the_question_are_about_the_same_text(self) -> None:
        # `could_be_folded` read only the text ABOVE the heading, so the same
        # folded duplicate produced a refusal or not depending on where an
        # unrelated disclosure sat. It reads the whole body now.
        self.assertTrue(helpers.could_be_folded("## Evidence Status\n\nx\n\n<details>\n"))
        self.assertTrue(helpers.could_be_folded("<details>\n\n## Evidence Status\n\nx\n"))
        self.assertFalse(helpers.could_be_folded("## Evidence Status\n\nx\n"))


class AnOpenDisclosureIsNotAFoldTests(unittest.TestCase):
    """`<details open>` shows its contents on load, so it hides nothing (#1773, round 3).

    GitHub returns it as `<details open="">`. The reader counted every
    `<details>` alike and refused a section the page displays. A CLOSED
    disclosure nested inside an open one still folds what it holds, which is
    why the reader keeps a stack of closed-ness rather than a count.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"
    SUMMARY = "## Summary\n\n- one change\n\n"

    OPEN = f"{SUMMARY}<details open>\n<summary>notes</summary>\n\nshown prose\n"
    CLOSED_INSIDE_OPEN = (
        f"{SUMMARY}<details open>\n<summary>outer</summary>\n\n"
        "<details>\n<summary>inner</summary>\n\nprose\n"
    )

    def answer(self, body: str):
        return helpers.placement_refusal(body, body + self.SECTION, self.HEADING)

    def test_a_section_inside_an_open_disclosure_is_placed(self) -> None:
        with recorded_page():
            answer = self.answer(self.OPEN)
            page = helpers.rendered_page(self.OPEN + self.SECTION)
        self.assertEqual(helpers.folded_headings_on_the_page(page.html, self.HEADING), [False])
        self.assertIsNone(answer.refusal)

    def test_a_closed_disclosure_inside_an_open_one_still_folds(self) -> None:
        with recorded_page():
            answer = self.answer(self.CLOSED_INSIDE_OPEN)
            page = helpers.rendered_page(self.CLOSED_INSIDE_OPEN + self.SECTION)
        self.assertEqual(helpers.folded_headings_on_the_page(page.html, self.HEADING), [True])
        self.assertIsNotNone(answer.refusal)
        self.assertIn("the page folds it away", answer.refusal)

    def test_the_reader_answers_off_the_attribute_the_renderer_emits(self) -> None:
        # GitHub writes `open=""`, so the reader must not require a value.
        for html, folded in (
            ('<details open=""><h2>Evidence Status</h2></details>', [False]),
            ("<details open><h2>Evidence Status</h2></details>", [False]),
            ("<details OPEN><h2>Evidence Status</h2></details>", [False]),
            ("<details><h2>Evidence Status</h2></details>", [True]),
        ):
            with self.subTest(html=html[:40]):
                self.assertEqual(
                    helpers.folded_headings_on_the_page(html, self.HEADING), folded
                )


class TheRefusalSurvivesTheCommentsDedupTests(unittest.TestCase):
    """A `<details` quoted in a note is text, not a disclosure (#1773, round 3).

    `COLLAPSED_BLOCK_RE` strips a folded block so a note nobody opened does not
    suppress the next run's copy. It did not honour code spans, and the fold
    refusal quotes the author's opening line inside one -- so the strip ran
    from that quoted tag to the end of the posted comment and took
    `uncarried_notes_checked_line` with it. Nothing was then recorded as
    shown, and the app posted the identical comment again on every run at the
    same head.

    Fixed in the DEDUP rather than in the sentence, because any note quoting an
    author's tag hits it -- an uncarried-note announcement naming a
    `<details>` block was already one.
    """

    HEAD = "abc1234"
    FOLDED_BODY = (
        "## Summary\n\n- one change\n\n<details>\n<summary>notes</summary>\n\nfolded prose\n\n"
        "## Evidence Status\n\n- [complete] x -- y\n"
    )

    def evidence(self):
        return sys.modules["evidence"]

    def execution(self):
        return sys.modules["execution"]

    def note(self) -> str:
        refusal = helpers._folded_refusal(self.FOLDED_BODY, "Evidence Status")
        self.assertIn("<details", refusal)
        return f"{self.evidence().STOOD_DOWN_ANNOUNCEMENT_PREFIX}{refusal}"

    def test_the_checked_line_survives_a_comment_quoting_a_tag(self) -> None:
        execution = self.execution()
        comment = execution.compose_uncarried_notes_comment(None, [self.note()], self.HEAD)
        shown = execution._notes_a_reader_has_been_shown(
            comment, execution.uncarried_notes_checked_line(self.HEAD)
        )
        self.assertNotEqual(shown, set(), "the checked line was stripped with the quoted tag")
        self.assertEqual(len(shown), 1)

    def test_a_second_run_at_the_same_head_is_suppressed(self) -> None:
        execution = self.execution()
        note = self.note()
        comment = execution.compose_uncarried_notes_comment(None, [note], self.HEAD)
        shown = execution._notes_a_reader_has_been_shown(
            comment, execution.uncarried_notes_checked_line(self.HEAD)
        )
        self.assertIn(execution._as_the_page_shows_it(note), shown)

    # intent: control
    # Green on main: the case the strip must keep answering.
    def test_a_real_folded_block_is_still_stripped(self) -> None:
        # The property the strip exists for, unchanged: a note behind a
        # summary is a note nobody read, so it suppresses nothing.
        execution = self.execution()
        comment = (
            "**Text under your `## Evidence Status` heading was not carried.**\n\n"
            "<details><summary>more</summary>\n\n- a note nobody opened\n\n</details>\n\n"
            f"{execution.uncarried_notes_checked_line(self.HEAD)}\n"
        )
        shown = execution._notes_a_reader_has_been_shown(
            comment, execution.uncarried_notes_checked_line(self.HEAD)
        )
        self.assertEqual(shown, set())

    def test_the_blanking_keeps_every_offset(self) -> None:
        execution = self.execution()
        text = "a `<details open>` b ``a `tick` inside`` c"
        masked = execution._code_spans_blanked(text)
        self.assertEqual(len(masked), len(text))
        self.assertNotIn("<details", masked)
        self.assertEqual(execution._without_collapsed_blocks(text), text)


class TheTwoLowerFindingsTests(unittest.TestCase):
    """A quotation a comment can hold, and a note a later answer retracts (#1773, round 3).

    Both were relayed by the pass at low severity, both reproduced here, and
    both were a few lines to close, so neither was filed.

    A `<details …>` carrying a long attribute is a line a pull request body can
    hold 65,536 characters of. The refusal quoted it whole, which composed a
    comment past what GitHub stores -- and a comment past that is refused
    whole, so the note went unsaid entirely. The line is named by its NUMBER;
    the quotation is there to recognise it by.

    And a `RendererUnavailable` is no longer cached, so a question that went
    unasked can be asked again in the same run. When the later question
    answers, the earlier note is a sentence about a body that was reached
    after all, and an author cannot act on it.
    """

    HEADING = "Evidence Status"
    ITEM = "`swift test` passes"

    def evidence(self):
        return sys.modules["evidence"]

    def test_a_refusal_quoting_a_huge_tag_still_fits_a_comment(self) -> None:
        execution = sys.modules["execution"]
        tag = '<details data-note="' + "x" * 65_000 + '">'
        body = f"## Summary\n\n- one change\n\n{tag}\n<summary>n</summary>\n\nfolded\n"
        refusal = helpers._folded_refusal(
            body + "\n## Evidence Status\n\n- [complete] x -- y\n", self.HEADING
        )
        note = f"{self.evidence().STOOD_DOWN_ANNOUNCEMENT_PREFIX}{refusal}"
        chunks = execution._uncarried_notes_comments(None, [note], "abc1234")
        self.assertTrue(
            all(len(chunk) <= execution.PR_COMMENT_LIMIT for chunk in chunks),
            [len(chunk) for chunk in chunks],
        )
        # Enough of the line to recognise it by, and it says where the rest went.
        self.assertIn("…", refusal)
        self.assertIn("<details data-note=", refusal)
        self.assertLess(len(refusal), 1_000)

    def test_a_short_tag_is_quoted_whole(self) -> None:
        body = "## Summary\n\n- one change\n\n<details>\n<summary>n</summary>\n\nfolded\n"
        refusal = helpers._folded_refusal(
            body + "\n## Evidence Status\n\n- [complete] x -- y\n", self.HEADING
        )
        self.assertIn(helpers.code_span("<details>"), refusal)
        self.assertNotIn("…", refusal)

    def test_a_later_answer_in_the_same_run_retracts_the_unverified_note(self) -> None:
        evidence = self.evidence()
        body = (
            "## Summary\n\n- one change\n\n"
            "<details>\n<summary>notes</summary>\n\nfolded prose\n\n</details>\n\n"
            "## Validation\n\n- ran it\n"
        )
        attempts: list[str] = []

        def flaky(text: str) -> str:
            attempts.append(text)
            if len(attempts) == 1:
                raise helpers.RendererUnavailable("the renderer answered HTTP 503", cause="server error")
            return recorded_html(text)

        with (
            mock.patch.object(helpers, "render_markdown", side_effect=flaky),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
        ):
            write = evidence.write_evidence_status_section(
                body, [f"- [complete] {self.ITEM} -- 214 passed"]
            )
        self.assertGreaterEqual(len(attempts), 2, "the run asked only once")
        self.assertIsNone(write.refusal)
        self.assertEqual(
            [note for note in write.announcements if evidence.is_unverified_announcement(note)],
            [],
            write.announcements,
        )

    def test_a_run_that_never_reaches_the_renderer_still_says_so(self) -> None:
        # The retraction must not swallow the note when nothing answered.
        evidence = self.evidence()
        body = (
            "## Summary\n\n- one change\n\n"
            "<details>\n<summary>notes</summary>\n\nfolded prose\n\n</details>\n\n"
            "## Validation\n\n- ran it\n"
        )
        write = evidence.write_evidence_status_section(
            body, [f"- [complete] {self.ITEM} -- 214 passed"]
        )
        self.assertEqual(
            len([n for n in write.announcements if evidence.is_unverified_announcement(n)]), 1
        )


class UniquenessIsAClaimAboutThePageTests(unittest.TestCase):
    """The mark's uniqueness was established against the SOURCE (#1773, round 5).

    `while mark in written` is an exact, case-sensitive substring scan; the
    comparison it is meant to guarantee normalises whitespace and case over
    heading text GitHub has already decoded. Four spellings carry no such
    substring and render as a heading whose text IS the mark, so the page
    showed the name twice and the exactly-one guard refused a placement the
    page shows unfolded -- with a sentence saying the heading is not on the
    page.

    Mirroring `heading_identity` in the source scan would model the renderer,
    which is the thing the mark exists to avoid. So the scan is the cheap
    first guess and the PAGE settles it: render, and a name shown twice sends
    the loop back for the next candidate, bounded so a pathological body
    refuses rather than spins.
    """

    HEADING = "Evidence Status"
    SECTION = "\n## Evidence Status\n\n- [complete] `swift test` -- 1992 tests passed\n"
    SUMMARY = "## Summary\n\n- one change\n\n"
    FOLD = "<details>\n<summary>notes</summary>\n\nfolded prose\n\n</details>\n\n"

    # Each carries no substring the source scan can see, and each renders as a
    # heading whose text is exactly the mark. Red at `3f2d0980`.
    COLLIDING = {
        "a character reference": "## Evidence Status wsx7placementprob&#101;",
        "an empty comment inside the word": "## Evidence Status wsx7placem<!---->entprobe",
        "a case variant": "## Evidence Status WSX7PLACEMENTPROBE",
        "an em around its last letter": "## Evidence Status wsx7placementprob<em>e</em>",
    }

    def body(self, heading: str) -> str:
        return f"{self.SUMMARY}{self.FOLD}{heading}\n\nsomeone wrote this\n"

    def test_the_source_scan_calls_every_one_of_them_clean(self) -> None:
        # The premise, asserted so the tests below are not vacuous: the scan
        # the mark used to rest on sees nothing in any of these.
        for label, heading in self.COLLIDING.items():
            with self.subTest(spelling=label):
                written = self.body(heading) + self.SECTION
                self.assertNotIn(helpers.PLACEMENT_PROBE_MARK, written)
                self.assertEqual(
                    helpers.placement_probe_mark(written), helpers.PLACEMENT_PROBE_MARK
                )

    def test_a_rendered_heading_equal_to_the_mark_is_what_the_page_shows(self) -> None:
        # The test the suite could not express: a body whose RAW spelling
        # lacks the mark and whose RENDERED heading equals it.
        for label, heading in self.COLLIDING.items():
            with self.subTest(spelling=label), recorded_page():
                written = self.body(heading) + self.SECTION
                line = helpers.section_heading_line(written, self.HEADING)
                probe = helpers.probe_body_naming_one_heading(
                    written, self.HEADING, line, helpers.PLACEMENT_PROBE_MARK
                )
                page = helpers.rendered_page(probe)
                self.assertEqual(
                    len(
                        helpers.folded_headings_on_the_page(
                            page.html, f"{self.HEADING} {helpers.PLACEMENT_PROBE_MARK}"
                        )
                    ),
                    2,
                    f"{label}: the page did not show the name twice",
                )

    def test_each_one_is_placed_rather_than_refused(self) -> None:
        for label, heading in self.COLLIDING.items():
            with self.subTest(spelling=label), recorded_page():
                body = self.body(heading)
                answer = helpers.placement_refusal(body, body + self.SECTION, self.HEADING)
                self.assertIsNone(answer.refusal, label)

    def test_the_next_candidate_is_deterministic_and_skips_the_source(self) -> None:
        base = helpers.PLACEMENT_PROBE_MARK
        plain = "## Summary\n\n- one change\n"
        self.assertEqual(helpers.placement_probe_mark(plain, 0), base)
        self.assertEqual(helpers.placement_probe_mark(plain, 1), f"{base}1")
        self.assertEqual(helpers.placement_probe_mark(plain, 2), f"{base}2")
        # A candidate the body already carries is skipped, at every attempt.
        crowded = f"{base} and {base}1"
        self.assertEqual(helpers.placement_probe_mark(crowded, 0), f"{base}2")
        self.assertEqual(helpers.placement_probe_mark(crowded, 1), f"{base}3")
        # And the same body asks for the same mark every time, or no recording
        # ever matches.
        self.assertEqual(
            helpers.placement_probe_mark(crowded, 1), helpers.placement_probe_mark(crowded, 1)
        )

    def test_a_body_colliding_with_every_candidate_refuses_rather_than_spins(self) -> None:
        # The bound. The page is made to answer "twice" whatever is asked, so
        # the loop runs out and refuses instead of rendering forever.
        body = f"{self.SUMMARY}{self.FOLD}"
        written = body + self.SECTION
        asked: list[str] = []

        def always_twice(text: str) -> str:
            asked.append(text)
            mark = helpers.placement_probe_mark(written, len(asked) - 1)
            return (
                "<h2>Summary</h2>"
                f"<h2>{self.HEADING} {mark}</h2><h2>{self.HEADING} {mark}</h2>"
            )

        with (
            mock.patch.object(helpers, "render_markdown", side_effect=always_twice),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
        ):
            answer = helpers.placement_refusal(body, written, self.HEADING)
        self.assertEqual(len(asked), helpers.PLACEMENT_PROBE_ATTEMPTS)
        self.assertIsNotNone(answer.refusal)
        self.assertIn("is not a heading on the page", answer.refusal)

    def test_an_ordinary_body_still_asks_once(self) -> None:
        body = f"{self.SUMMARY}{self.FOLD}"
        asked: list[str] = []
        with recorded_page():
            recorded = helpers.render_markdown
            with mock.patch.object(
                helpers,
                "render_markdown",
                side_effect=lambda text: asked.append(text) or recorded(text),
            ):
                helpers.placement_refusal(body, body + self.SECTION, self.HEADING)
        self.assertEqual(len(asked), 1, asked)


class TheDedupUsesTheScannerThatAlreadyExistsTests(unittest.TestCase):
    """Round 3 closed over-stripping and opened under-stripping (#1773, round 5).

    The regex paired backticks with no model of which ones CommonMark treats
    as delimiters, so a backtick that opens no span still blanked a real
    `<details` between the pair -- the folded block was then not stripped, a
    note nobody was shown was recorded as shown, and the next run said nothing
    about a note the write had dropped. Plantable by anyone who can comment,
    using the public head sha and the deterministic checked line.

    `code_span_ranges` is the scanner that already existed for exactly this,
    and it lives in `_helpers` now so both callers share ONE function.

    Per LINE, because a code span cannot reach out of its block -- which the
    page confirms: it folds the note in every one of these shapes.
    """

    HEAD = "abc1234"
    NOTE = "not carried to `## Evidence Notes`: a fence with no closing line"

    def execution(self):
        return sys.modules["execution"]

    def comment(self, prefix: str) -> str:
        execution = self.execution()
        return (
            f"{execution.UNCARRIED_NOTES_HEADLINE}\n\n"
            f"{prefix}<details><summary>more</summary>\n\n- {self.NOTE}\n\n</details>\n\n"
            f"{execution.uncarried_notes_checked_line(self.HEAD)}\n"
        )

    BYPASSES = {
        "an escaped backtick before the tag": "a note \\` and ",
        "a lone backtick before the tag": "a note ` and ",
        "a backtick pair straddling the tag": "a `span ",
    }

    def shown(self, comment: str) -> set[str]:
        execution = self.execution()
        return execution._notes_a_reader_has_been_shown(
            comment, execution.uncarried_notes_checked_line(self.HEAD)
        )

    # intent: guard
    # Green on main: a regression this branch introduced in round 8 and fixed inside itself, so main never had it to fail on.
    def test_a_folded_note_is_never_recorded_as_shown(self) -> None:
        for label, prefix in {"no stray backtick": "", **self.BYPASSES}.items():
            with self.subTest(shape=label):
                self.assertEqual(self.shown(self.comment(prefix)), set(), label)

    # intent: control
    # Green on main: the unchanged case beside it.
    def test_a_note_in_the_open_is_still_recorded_as_shown(self) -> None:
        # The property the strip exists beside: a note a reader can see does
        # suppress the next run's copy.
        execution = self.execution()
        comment = (
            f"{execution.UNCARRIED_NOTES_HEADLINE}\n\n- {self.NOTE}\n\n"
            f"{execution.uncarried_notes_checked_line(self.HEAD)}\n"
        )
        self.assertEqual(len(self.shown(comment)), 1)

    def test_a_tag_inside_a_real_code_span_is_still_text(self) -> None:
        # The other direction, unchanged: a `<details` a note QUOTES is not a
        # disclosure, which is what round 3 fixed.
        execution = self.execution()
        quoted = helpers.code_span('<details data-note="a `tick`">')
        comment = (
            f"{execution.UNCARRIED_NOTES_HEADLINE}\n\n- a note naming {quoted}\n\n"
            f"{execution.uncarried_notes_checked_line(self.HEAD)}\n"
        )
        self.assertEqual(len(self.shown(comment)), 1)

    def test_the_scanner_is_one_function_both_callers_share(self) -> None:
        helpers_source = (
            REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
        ).read_text(encoding="utf-8")
        self.assertIn("def code_span_ranges(", helpers_source)
        for name in ("evidence.py", "execution.py"):
            source = (
                REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / name
            ).read_text(encoding="utf-8")
            with self.subTest(module=name):
                self.assertIn("code_span_ranges", source)
                self.assertNotIn("def code_span_ranges(", source)
                # The backtick-pairing regex this round removed, by its own
                # name. `LEADING_CODE_SPAN_RE` is a different, older thing --
                # it reads a command out of the START of a string -- so the
                # check names what went rather than matching a substring.
                self.assertNotIn("\nCODE_SPAN_RE = ", source)


class RecordedRendererResponseForThePlacementTests(unittest.TestCase):
    """The recordings this suite reads, and that they are the gate's own.

    The recordings live in one directory keyed by the sha256 of the body, so a
    body either suite asks about is answered by whichever of them recorded it
    first. What is checked here is that this suite's view of that directory is
    the same view `test_pr_readiness.py` has -- the path, the index and the
    naming rule -- because a second directory would age separately and neither
    suite would notice.
    """

    # intent: guard
    # Green on main: recorder tooling.
    def test_the_record_command_can_refresh_a_recording_that_drifted(self) -> None:
        """The command the drift test names has to be able to fix what it names (#1790).

        `recorded_html` returned an existing recording without re-asking, even
        under the record flag -- so an author told "this recording no longer
        matches the live renderer, re-record it with ..." ran a command that
        read the stale file back and changed nothing.

        Which half asks reality: none. The live renderer is stubbed, and what
        is asserted is that the recorder ASKS it and overwrites.
        """
        body = "## a body no fixture answers for\n\nwith a line\n"
        path = rendered_fixture_path(body)
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        asked: list[str] = []

        def live(text: str) -> str:
            asked.append(text)
            return f"<h2>answer {len(asked)}</h2>"

        index_before = RENDERED_INDEX.read_text(encoding="utf-8")
        self.addCleanup(lambda: RENDERED_INDEX.write_text(index_before, encoding="utf-8"))
        with mock.patch.dict(os.environ, {RECORD_ENV: "1"}, clear=False):
            with mock.patch.object(sys.modules["__main__"], "_LIVE_RENDER", live):
                first = recorded_html(body)
                second = recorded_html(body)
        self.assertEqual(len(asked), 2, "the recorder returned the file instead of re-asking")
        self.assertEqual(first, "<h2>answer 1</h2>")
        self.assertEqual(second, "<h2>answer 2</h2>")
        self.assertEqual(path.read_text(encoding="utf-8"), second)
        entry = json.loads(RENDERED_INDEX.read_text(encoding="utf-8"))[
            hashlib.sha256(body.encode("utf-8")).hexdigest()
        ]
        self.assertEqual(entry["body"], body)
        self.assertRegex(entry["recorded_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    # intent: guard
    # Green on main: recorder tooling: no run invents its own fixtures.
    def test_without_the_flag_a_recording_is_read_rather_than_re_asked(self) -> None:
        # The control: an ordinary run reads the checkout and reaches nothing.
        digest = next(iter(rendered_index()))
        body = indexed_body(rendered_index()[digest])
        with mock.patch.object(sys.modules["__main__"], "_LIVE_RENDER", None):
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(
                    recorded_html(body),
                    rendered_fixture_path(body).read_text(encoding="utf-8"),
                )

    def test_the_recordings_are_the_directory_the_gate_records_into(self) -> None:
        readiness = load_module("pr_readiness_placement", REPO_ROOT / "scripts" / "pr-readiness.py")
        self.assertTrue(RENDERED_FIXTURES.is_dir())
        self.assertEqual(RENDERED_FIXTURES, REPO_ROOT / "scripts" / "tests" / "fixtures" / "rendered")
        self.assertEqual(readiness.DEFAULT_REPOSITORY, helpers.DEFAULT_REPOSITORY)

    # Which shapes reach the renderer, written down here rather than asked of
    # the code under test. It used to call `could_be_folded` to decide which
    # bodies needed a recording, so regressing that function to always-False
    # emptied this test instead of failing it -- a guard that agrees with
    # whatever it is guarding (#1773, round 2).
    SHAPES_THAT_ASK_THE_PAGE = frozenset(
        {
            "an unclosed disclosure above the section",
            "a disclosure closed above the section",
            "a disclosure inside another, the outer left open",
            "a fenced example of a disclosure above the section",
        }
    )

    def test_this_suite_names_the_shapes_that_need_a_recording(self) -> None:
        # The enumeration and the function are compared, so a change to either
        # fails here. A shape that stops asking the page is a shape whose
        # recording is dead, and a shape that starts asking is one nobody
        # recorded -- both are this test's business.
        asking = set()
        for label, (body, _) in ThePlacementAsksThePageWhetherASectionIsFoldedTests.SHAPES.items():
            written = body + ThePlacementAsksThePageWhetherASectionIsFoldedTests.SECTION
            line = helpers.section_heading_line(written, "Evidence Status")
            if line is not None and helpers.could_be_folded(written):
                asking.add(label)
        self.assertEqual(asking, set(self.SHAPES_THAT_ASK_THE_PAGE))

    # intent: guard
    # Green on main: green on main only because this head's recordings are copied in with the tests; against a clean base tree it fails.
    def test_every_recording_this_suite_needs_is_committed(self) -> None:
        index = rendered_index()
        shapes = ThePlacementAsksThePageWhetherASectionIsFoldedTests.SHAPES
        # Anti-vacuity: the enumeration is this test's own, so a typo in it
        # must fail rather than skip.
        self.assertEqual(self.SHAPES_THAT_ASK_THE_PAGE - set(shapes), set())
        for label in sorted(self.SHAPES_THAT_ASK_THE_PAGE):
            written = shapes[label][0] + ThePlacementAsksThePageWhetherASectionIsFoldedTests.SECTION
            with self.subTest(shape=label):
                self.assertIn(hashlib.sha256(written.encode("utf-8")).hexdigest(), index)
                self.assertTrue(rendered_fixture_path(written).is_file())

    # intent: guard
    # Green on main: the recorder's own bookkeeping, which main has too.
    def test_every_recording_names_the_body_it_answers(self) -> None:
        for digest, entry in rendered_index().items():
            text = indexed_body(entry)
            with self.subTest(digest=digest[:12]):
                self.assertEqual(hashlib.sha256(text.encode("utf-8")).hexdigest(), digest)
                self.assertTrue(rendered_fixture_path(text).is_file())


class TheNotesPathTakesTheSameAnswerAsTheStatusPathTests(unittest.TestCase):
    """The failure this branch closed on the status path, kept on the notes path (#1773, round 6).

    `write_evidence_status_section` cuts the author's blocks out of the
    section BEFORE it places anything, then restored them through
    `insert_markdown_section` -- the back-compat wrapper, which discards both
    the refusal and the unverified note. So when that insert stood down the
    author's own words were already gone: a placed status section, no notes
    section, an empty announcement list, no refusal on the write, and the
    reason in a step log nobody opens.

    It calls `inserted_markdown_section` now and takes the same answer the
    status path takes: a refusal stands the whole write down, so the notes are
    not cut when they cannot be placed, and it is announced where the author
    reads it.
    """

    NOTE = "A note the author wrote under the heading."
    STATUS = "- [complete] run `swift test` -- passed"
    HEADING = "Evidence Notes"

    def evidence(self):
        return sys.modules["evidence"]

    def body(self, *, colliding: bool) -> str:
        mark = helpers.PLACEMENT_PROBE_MARK
        # Three rendered-only aliases of the notes heading's probe name: the
        # source scan sees no mark in any of them and the page shows each.
        aliases = "\n\n".join(
            [
                f"## {self.HEADING} {mark[:-1]}&#101;",
                f"## {self.HEADING} {mark[:-4]}<!---->{mark[-4:]}1",
                f"## {self.HEADING} {mark.upper()}2",
            ]
        ) if colliding else "## Notes\n\nnothing that collides"
        return (
            "## Summary\n\n<details>\n<summary>notes</summary>\n\n- one change\n\n</details>\n\n"
            f"{aliases}\n\n## Evidence Status\n\n{self.STATUS}\n\n{self.NOTE}\n\n"
            "## Validation\n\n- ran it\n"
        )

    def write(self, *, colliding: bool):
        with recorded_page():
            return self.evidence().write_evidence_status_section(
                self.body(colliding=colliding), [self.STATUS]
            )

    def test_a_notes_section_the_page_would_not_show_stands_the_write_down(self) -> None:
        written = self.write(colliding=True)
        self.assertIsNotNone(written.refusal, "the notes insert refused and the write did not")
        self.assertIn(self.NOTE, written.body, "the author's note was cut and never restored")
        self.assertTrue(
            any(self.HEADING in note for note in written.announcements),
            f"nothing said why: {written.announcements}",
        )

    def test_the_refusal_names_the_notes_section_rather_than_the_status_one(self) -> None:
        written = self.write(colliding=True)
        self.assertIn(f"`## {self.HEADING}`", written.refusal)

    def test_a_body_whose_notes_can_be_placed_is_written_as_before(self) -> None:
        written = self.write(colliding=False)
        self.assertIsNone(written.refusal)
        self.assertIn(f"## {self.HEADING}", written.body)
        self.assertIn(self.NOTE, written.body)

    def test_every_production_insert_reaches_an_announcement_channel(self) -> None:
        """The property, driven, not the name, grepped (#1773, round 9).

        This read production for `insert_markdown_section` -- the name round 8
        DELETED -- so the change that removed the name retired the guard, and
        the suite got greener while the property it names was violated at a
        default parameter the same round left behind. A guard keyed on a name
        is retired by any rename; one keyed on the property is not.

        So each seam that places a section is driven with the page refusing,
        and each is asked for the note an author can read.
        """
        evidence = sys.modules["evidence"]
        execution = sys.modules["execution"]
        folded = (
            "## Summary\n\n- one change\n\n<details>\n<summary>notes</summary>\n\n"
            "a note nobody closed\n"
        )

        def refuse(text: str) -> str:
            raise helpers.RendererUnavailable(
                "the renderer answered HTTP 503", cause="server error"
            )

        def seed(said: list[str]) -> None:
            said.extend(
                execution.seed_mergeability_section(
                    folded, changed_files=["docs/x.md"]
                ).announcements
            )

        def status_write(said: list[str]) -> None:
            said.extend(
                evidence.write_evidence_status_section(
                    folded, ["- [complete] the item -- proof"]
                ).announcements
            )

        def turn_render(said: list[str]) -> None:
            evidence.render_execution_summary_body(
                folded,
                requested_evidence=["the item"],
                evidence_complete=["1 -- proof"],
                evidence_blocked=[],
                evidence_pending_ci=[],
                announcements=said,
            )

        # Each seam reports the way it reports -- the seed RETURNS what it
        # said, the other two take the list their caller owns -- and what is
        # asserted is the same for all three: the author is told.
        seams = {
            "the Mergeability seed": seed,
            "the status section write": status_write,
            "the turn's own render": turn_render,
        }
        for name, drive in seams.items():
            with self.subTest(seam=name):
                said: list[str] = []
                with (
                    mock.patch.object(helpers, "render_markdown", side_effect=refuse),
                    mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    drive(said)
                self.assertTrue(
                    any("unverified" in note or "not seeded" in note for note in said),
                    f"{name}: the page went unread and the author was told nothing: {said}",
                )

    def test_the_seed_has_no_announcement_channel_to_hand_it(self) -> None:
        """The shape the defect took, twice, and what removed the choice.

        Round 8 left the note to a caller remembering to pass a list; round 9
        made the list required, and a required parameter can still be handed
        one that goes nowhere -- real, non-default, posted by nobody. There is
        no parameter now: the seed returns what it said, so the only caller
        that decides anything is the one with a comment to post.
        """
        import inspect

        execution = sys.modules["execution"]
        signature = inspect.signature(execution.seed_mergeability_section)
        self.assertNotIn(
            "announcements",
            signature.parameters,
            "a channel a caller can hand over is a channel a caller can drop",
        )
        self.assertEqual(
            sorted(execution.SeededSection._fields), ["announcements", "body"]
        )


class ACodeSpanCrossesASoftLineBreakTests(unittest.TestCase):
    """Round 5 closed over-stripping and opened under-stripping (#1773, round 6).

    The dedup blanks code spans before it looks for a folded block, so a
    quoted `<details` is read as the text it is. Round 5 scanned line by line,
    and a CommonMark code span crosses soft line breaks inside a paragraph: a
    backtick opening on one line and closing on the next is ONE span to the
    page, while the per-line read sees the next line's leftover backticks as a
    span of their own and blanks a real `<details` between them. The block is
    then not stripped, a note the page folds away is recorded as shown, and
    the next run says nothing about a note the write dropped -- which the
    review lane's comment reader turns into an approval decision.

    The scan is per BLOCK now, which is the span a code span can occupy.
    """

    NOTE = "a heading a reader cannot see"

    def execution(self):
        return sys.modules["execution"]

    def checked(self) -> str:
        return self.execution().uncarried_notes_checked_line("a" * 40)

    def comment(self, middle: str) -> str:
        return f"{self.checked()}\n\n{middle}\n<summary>click</summary>\n\n- {self.NOTE}\n\n</details>\n"

    def test_a_span_crossing_a_soft_break_does_not_hide_a_real_details(self) -> None:
        # `start `open` / `here `<details>` more` end`: two spans to the page,
        # with the tag as literal text between them, so the page folds the
        # note. Red at `61c5199f`, where the per-line read blanked the tag.
        comment = self.comment("start `open\nhere `<details>` more` end")
        stripped = self.execution()._without_collapsed_blocks(comment)
        self.assertNotIn("<details", stripped, "a real disclosure survived the strip")
        self.assertNotIn(self.NOTE, stripped)
        self.assertEqual(
            self.execution()._notes_a_reader_has_been_shown(comment, self.checked()),
            set(),
            "a note the page folds away was recorded as shown",
        )

    def test_a_quoted_tag_inside_one_span_is_still_read_as_text(self) -> None:
        # The round-5 property, unbroken: a `<details` genuinely inside a span
        # is not a disclosure, so the note beside it IS shown.
        comment = (
            f"{self.checked()}\n\nthe writer emits `<details>` when it folds\n\n- {self.NOTE}\n"
        )
        self.assertEqual(
            self.execution()._notes_a_reader_has_been_shown(comment, self.checked()),
            {self.NOTE},
        )

    INTERRUPTERS = {
        "an ATX heading": "## a heading",
        "an HTML block": "<div>x</div>",
        "a fence": "```\ncode\n```",
        "a list": "- an item",
    }

    def interrupted(self, interrupter: str) -> str:
        """Two stray backticks with a block boundary between them.

        Blank lines are not the only thing that ends a paragraph: a heading,
        an HTML block, a fence and a list each interrupt one with no blank
        line at all. Splitting on blank lines alone paired these backticks
        into a span and blanked the `<details` between them, so the fold went
        unstripped and the note below it -- folded away on the page -- was
        recorded as one a reader had been shown.
        """
        return (
            f"{self.checked()}\n\nstart `open\n{interrupter}\n<details>more` end\n\n"
            f"- {self.NOTE}\n"
        )

    def test_a_block_boundary_without_a_blank_line_still_ends_the_span(self) -> None:
        # Models the parser: the bounds come from `MARKDOWN.parse`, so this
        # asserts what CommonMark says a block is. The recorded fixture below
        # is where the page is asked.
        for label, interrupter in self.INTERRUPTERS.items():
            with self.subTest(interrupter=label):
                comment = self.interrupted(interrupter)
                self.assertIn(
                    "<details",
                    self.execution()._code_spans_blanked(comment),
                    f"{label}: a real disclosure was blanked as if it were quoted",
                )
                # The NOTE, not the whole set: a list interrupter is itself a
                # `- ` line the page shows, and saying so is right.
                self.assertNotIn(
                    self.NOTE,
                    self.execution()._notes_a_reader_has_been_shown(comment, self.checked()),
                    f"{label}: a note the page folds away was recorded as shown",
                )

    # intent: fix
    def test_a_comment_with_bare_cr_endings_reads_as_the_same_blocks(self) -> None:
        """A door into the rounds-5/6/8 class, closed at the boundary (#1773, round 11).

        `_inline_block_bounds` builds its offset table with `split("\n")`, so
        a comment whose lines end in bare CR was ONE inline span covering the
        whole comment — and two backticks anywhere in it then pair across a
        real `<details>` between them, which is the shape rounds 5, 6 and 8
        each closed for LF text. Measured at `9a5db027`: 4 blocks with LF or
        CRLF, 1 with CR. Line endings are normalised once at the boundary now.

        What I verified is the BOUNDS half. The onward consequence — a folded
        note recorded as shown — does not reproduce at either head, because a
        CR-only comment's checked line is unrecognised too and the reading
        returns nothing at all; the claim that it bypasses the dedup is
        relayed from a live render and stays unverified here.
        """
        execution = self.execution()
        note = "a heading a reader cannot see"
        lf = (
            f"{self.checked()}\n\nstart `open\n\n<details>\n<summary>click</summary>\n\n"
            f"- {note}\n\n</details>\n\nhere` end\n"
        )
        blocks = {}
        for label, ending in (("lf", "\n"), ("crlf", "\r\n"), ("cr", "\r")):
            with self.subTest(ending=label):
                comment = lf.replace("\n", ending)
                normalised = helpers.MARKDOWN_LINE_ENDING_RE.sub("\n", comment)
                blocks[label] = len(execution._inline_block_bounds(normalised))
                # The boundary does the normalising, so the caller passes the
                # comment as GitHub gave it.
                self.assertNotIn("<details", execution._without_collapsed_blocks(comment))
        self.assertEqual(blocks["cr"], blocks["lf"], blocks)
        self.assertEqual(blocks["crlf"], blocks["lf"], blocks)

    # intent: guard
    def test_the_dedup_reads_a_comment_the_same_way_however_its_lines_end(self) -> None:
        # The other half of the boundary: a note shown in the open is shown
        # under all three endings, and a note behind a disclosure is hidden
        # under all three. At `9a5db027` a CR-only comment read as neither —
        # the checked line was unrecognised, so the reading returned nothing
        # and every note in it counted as never said.
        execution = self.execution()
        note = "a note the page shows"
        plain = f"**headline**\n\n- {note}\n\n{self.checked()}\n"
        folded = (
            f"**headline**\n\n<details>\n<summary>click</summary>\n\n- {note}\n\n"
            f"</details>\n\n{self.checked()}\n"
        )
        for label, ending in (("lf", "\n"), ("crlf", "\r\n"), ("cr", "\r")):
            with self.subTest(ending=label):
                shown = execution._notes_a_reader_has_been_shown(
                    plain.replace("\n", ending), self.checked()
                )
                hidden = execution._notes_a_reader_has_been_shown(
                    folded.replace("\n", ending), self.checked()
                )
                self.assertIn(note, shown, f"{label}: a note said in the open read as unsaid")
                self.assertNotIn(note, hidden, f"{label}: a folded note read as shown")

    # intent: guard
    def test_the_page_folds_the_note_in_every_interrupted_shape(self) -> None:
        # Asks reality: the recorded answer from the live renderer for each
        # of the four bodies above. BOUNDED: `<details.*` with `re.S` runs to
        # the end of the document, so it is satisfied by a note anywhere after
        # the opening tag -- these recordings happen to fold the note, so the
        # unbounded form was weak here rather than false, and the sibling
        # below is where it was false (#1773, round 11).
        for label, interrupter in self.INTERRUPTERS.items():
            with self.subTest(interrupter=label), recorded_page():
                html = helpers.render_markdown(self.interrupted(interrupter))
            folded = re.search(r"<details.*?</details>", html, re.S)
            self.assertIsNotNone(folded, label)
            self.assertIn(self.NOTE, folded.group(0), f"{label}: the page did not fold the note")

    def test_a_table_row_gives_each_cell_its_own_span(self) -> None:
        """A row's cells shared the row's map (#1773, round 9).

        markdown-it gives every cell of a row the ROW's line map, so three
        cells came back as three copies of one span and two backticks in cells
        1 and 3 paired across cell 2 -- blanking a real `<details` between
        them, leaving the fold unstripped, and recording a note the page hides
        as one a reader was shown. Measured end to end before the fix: the
        module said shown, the page emitted a real disclosure.

        Models the parser: each cell is narrowed to where its own content
        sits. The sibling asks the page.
        """
        comment = (
            f"{self.checked()}\n\n| a | b | c |\n| --- | --- | --- |\n"
            f"| x `open | <details>more | y` end |\n\n- {self.NOTE}\n"
        )
        self.assertIn(
            "<details",
            self.execution()._code_spans_blanked(comment),
            "a real disclosure was blanked across cells",
        )
        self.assertNotIn(
            self.NOTE,
            self.execution()._notes_a_reader_has_been_shown(comment, self.checked()),
            "a note the page folds away was recorded as shown",
        )
        # Each cell is its own span, so a quoted tag inside ONE cell is still
        # read as text.
        quoted = (
            f"{self.checked()}\n\n| a | b |\n| --- | --- |\n"
            f"| the writer emits `<details>` when it folds | fine |\n\n- {self.NOTE}\n"
        )
        self.assertIn(
            self.NOTE,
            self.execution()._notes_a_reader_has_been_shown(quoted, self.checked()),
        )

    def test_two_cells_holding_one_text_keep_their_order(self) -> None:
        """The cursor's claim, pinned (#1773, round 10).

        The comment said two cells with the same text keep their order and
        nothing asserted it. Without the cursor, `find` returns the FIRST
        occurrence both times, so the third cell is given the first cell's
        span and the text between them -- including a `<details` -- is never
        looked at as its own block.
        """
        text = (
            "a line\n\n| a | b | c |\n| --- | --- | --- |\n"
            "| x `open | <details>more | x `open |\n\nafter\n"
        )
        bounds = self.execution()._inline_block_bounds(text)
        spans = [text[start:stop] for start, stop in bounds]
        self.assertEqual(spans.count("x `open"), 2, "both cells are their own span")
        first, second = [index for index, one in enumerate(spans) if one == "x `open"]
        self.assertLess(bounds[first][0], bounds[second][0], "in the order they appear")
        self.assertEqual(spans[first + 1], "<details>more", "and the cell between them is its own")

    def test_a_cell_whose_text_is_not_in_its_row_takes_its_row_rather_than_another_block(
        self,
    ) -> None:
        """The row's end, pinned (#1773, round 10).

        A cell's content is not always a substring of its row: markdown-it
        unescapes it, so `a \\| b` arrives as `a | b`, which the row does not
        contain. The search then finds nothing inside the row and the cell
        falls back to the whole row -- the safe answer. Without the bound it
        would keep looking and find those characters in a LATER block,
        handing one cell a span in someone else's paragraph.
        """
        body = (
            "| h1 | h2 |\n| --- | --- |\n| a \\| b | y |\n\n"
            "and later: a | b appears again here\n"
        )
        execution = self.execution()
        bounds = execution._inline_block_bounds(body)
        spans = [body[start:stop] for start, stop in bounds]
        # The cell falls back to its row, and no span reaches into the
        # paragraph below it.
        paragraph_at = body.index("and later")
        for start, stop in bounds[:-1]:
            self.assertLessEqual(stop, paragraph_at, f"a span reached past its block: {body[start:stop]!r}")
        self.assertIn("and later: a | b appears again here", spans)

    # intent: fix
    def test_the_page_does_not_fold_the_note_below_that_table(self) -> None:
        """A test named "asks reality" passed under the opposite of its claim.

        The slice was `<details.*` with `re.S`, which runs to the END of the
        document -- so "the note is inside the disclosure" was satisfied by a
        note anywhere after the opening tag. In this recording `</details>`
        closes at offset 286 and the note sits at 392: OUTSIDE the fold. The
        page does not fold this one, and the assertion is now the bounded
        slice saying so (#1773, round 11).

        What the module does with the same comment is the line under it: the
        note is recorded as SHOWN, which agrees with the page.
        """
        comment = (
            f"{self.checked()}\n\n| a | b | c |\n| --- | --- | --- |\n"
            f"| x `open | <details>more | y` end |\n\n- {self.NOTE}\n"
        )
        with recorded_page():
            html = helpers.render_markdown(comment)
        folded = re.search(r"<details.*?</details>", html, re.S)
        self.assertIsNotNone(folded, "the page did not open a disclosure at all")
        self.assertNotIn(
            self.NOTE, folded.group(0), "the note is below the disclosure, not inside it"
        )
        # And what the module makes of the same comment, asserted as it is
        # rather than as it ought to be: it strips from the `<details` in the
        # middle cell to the END of the comment, so the note below the table
        # is cut and reads as never shown. The page and the module disagree
        # about this shape. The direction is the safe one -- a note the reader
        # HAS seen is offered again, which is noise rather than silence -- and
        # it is a finding of this round, recorded in the body rather than
        # fixed here, because narrowing the strip to the block the page closes
        # is the same block-mapping change #1781 tracks.
        self.assertEqual(
            self.execution()._notes_a_reader_has_been_shown(comment, self.checked()),
            set(),
            "the module's answer moved; the body's residual needs restating",
        )

    def test_a_blank_line_ends_the_span_so_a_later_block_is_still_stripped(self) -> None:
        # The control the brief names: a span that closes on the next line,
        # and a `<details>` in a THIRD paragraph, which is still stripped
        # because a code span cannot cross a blank line.
        comment = (
            f"{self.checked()}\n\nstart `open\nhere` end\n\n<details>\n"
            f"<summary>click</summary>\n\n- {self.NOTE}\n\n</details>\n"
        )
        stripped = self.execution()._without_collapsed_blocks(comment)
        self.assertNotIn("<details", stripped)
        self.assertEqual(
            self.execution()._notes_a_reader_has_been_shown(comment, self.checked()), set()
        )

    def test_the_page_agrees_that_the_crossing_shape_folds_the_note(self) -> None:
        # The claim the module makes, asked of the renderer once and recorded.
        with recorded_page():
            html = helpers.render_markdown(self.comment("start `open\nhere `<details>` more` end"))
        self.assertIn("<details", html)
        folded = re.search(r"<details.*?</details>", html, re.S)
        self.assertIsNotNone(folded)
        self.assertIn(self.NOTE, folded.group(0))


class EveryInsertTakesTheWritesAnswerTests(unittest.TestCase):
    """The last two inserts that dropped a refusal on the floor (#1773, round 8).

    The status and notes paths take the answer; `## Mergeability` and the
    `blocked on evidence` line in `## Validation` still went through the
    back-compat wrapper, which returns the body alone. At a 503 with a token
    the section was appended below an unclosed `<details>` -- into the fold --
    and the caller was handed a body that looked written, with the reason on
    stderr.
    """

    FOLDED = (
        "## Summary\n\n- one change\n\n<details>\n<summary>notes</summary>\n\n"
        "a note nobody closed\n"
    )

    def seeded(self, *, transient: bool):
        execution = sys.modules["execution"]

        def refuse(text: str) -> str:
            raise helpers.RendererUnavailable(
                "the renderer answered HTTP 503" if transient else "the renderer answered HTTP 401",
                cause="server error" if transient else "rejected token",
            )

        with (
            mock.patch.object(helpers, "render_markdown", side_effect=refuse),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            seeded = execution.seed_mergeability_section(
                self.FOLDED, changed_files=["docs/x.md"]
            )
        return seeded.body, list(seeded.announcements)

    def test_a_permanent_cause_leaves_the_body_alone_and_says_why(self) -> None:
        body, said = self.seeded(transient=False)
        self.assertEqual(body, self.FOLDED, "a section was placed into a fold")
        self.assertTrue(any("Mergeability" in note for note in said), said)

    def test_a_blip_places_it_and_announces_that_the_page_went_unread(self) -> None:
        body, said = self.seeded(transient=True)
        self.assertIn("## Mergeability", body)
        self.assertTrue(any("unverified" in note for note in said), said)

    # intent: fix
    def test_the_note_arrives_under_the_headline_the_author_reads(self) -> None:
        """The channel held and the message did not (#1773, round 11).

        The seed appended the raw note while the classifier keys on a prefix
        only one other seam added, so the note fell into the UNCARRIED bucket
        and the author read "Text under your `## Evidence Status` heading was
        not carried" -- when nothing was dropped and the check was about
        `## Mergeability`. Asserted through the COMMENT the author reads
        rather than by finding a substring somewhere in the notes.
        """
        execution = sys.modules["execution"]
        evidence = sys.modules["evidence"]
        _, said = self.seeded(transient=True)
        self.assertTrue(said, "the seed said nothing")
        self.assertTrue(
            all(evidence.is_unverified_announcement(note) for note in said),
            f"the classifier does not recognise the seed's own note: {said}",
        )
        comment = execution.compose_uncarried_notes_comment(None, said, "abc1234")
        headline = comment.splitlines()[0]
        self.assertEqual(headline, execution.unverified_notes_headline("Mergeability"))
        self.assertNotIn(execution.UNCARRIED_NOTES_HEADLINE, comment)
        self.assertNotIn(execution.STOOD_DOWN_NOTES_HEADLINE, comment)
        self.assertIn("Nothing here says anything was lost", comment)

    # intent: fix
    def test_two_sections_unchecked_for_one_reason_are_two_notes(self) -> None:
        # The dedup keys on the whole sentence, and the sentence carries the
        # heading now: without it the second section's note collapsed into the
        # first's and the author heard about one section when two went
        # unchecked (#1773, round 11).
        helpers_module = sys.modules["_helpers"]
        evidence = sys.modules["evidence"]
        announcements: list[str] = []
        for heading in ("Evidence Status", "Evidence Notes"):
            evidence._announce_unverified(
                announcements, helpers_module.unverified_announcement(heading, "a reason")
            )
        # And once each, however many times a run asks.
        evidence._announce_unverified(
            announcements, helpers_module.unverified_announcement("Evidence Status", "a reason")
        )
        self.assertEqual(len(announcements), 2, announcements)
        self.assertEqual(
            [helpers_module.unverified_heading(note) for note in announcements],
            ["Evidence Status", "Evidence Notes"],
        )

    def test_the_seed_hands_its_caller_the_reason_rather_than_a_step_log(self) -> None:
        """The property this class is for, driven at the seam (#1773, round 9).

        The version of this test that grepped production for a deleted name
        could not fire again, and the property it named was violated at the
        production call the same round left on a default. Driven, both
        families of answer reach the caller: a blip announces and places, a
        permanent cause announces and leaves the body alone.
        """
        execution = sys.modules["execution"]
        for cause, places in (("server error", True), ("rejected token", False)):
            with self.subTest(cause=cause):
                said: list[str] = []

                def refuse(text: str, cause=cause) -> str:
                    raise helpers.RendererUnavailable("a reason", cause=cause)

                with (
                    mock.patch.object(helpers, "render_markdown", side_effect=refuse),
                    mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    seeded = execution.seed_mergeability_section(
                        self.FOLDED, changed_files=["docs/x.md"]
                    )
                self.assertEqual("## Mergeability" in seeded.body, places, cause)
                self.assertTrue(seeded.announcements, f"{cause}: nothing came back")


class AMissingTokenIsNotABlipTests(unittest.TestCase):
    """Which causes of an unreadable page proceed, and which refuse (#1773, round 6).

    `RendererUnavailable` carried only a message, so every cause read the same
    way and the placement check took the fail-open branch for all of them --
    including no token, which on a developer's laptop is every placement
    rather than a rare one.

    A missing token refuses because it is a permanent condition of the
    environment and one the author can act on. An HTTP failure or an
    unreachable renderer proceeds unverified with the announcement, because
    the harm there is a reading defect and refusing would turn a passing
    outage into a blocked PR.
    """

    HEADING = "Evidence Status"
    BODY = "## Summary\n\n- one change\n\n## Validation\n\n- ran it\n"
    WRITTEN = (
        "## Summary\n\n- one change\n\n<details>\n<summary>d</summary>\n\n"
        "## Evidence Status\n\n- [complete] a -- b\n\n</details>\n\n## Validation\n\n- ran it\n"
    )

    def answer_when(self, error: Exception):
        def raise_it(text: str) -> str:
            raise error

        with (
            mock.patch.object(helpers, "render_markdown", side_effect=raise_it),
            mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
        ):
            return helpers.placement_refusal(self.BODY, self.WRITTEN, self.HEADING)

    def test_no_token_refuses_and_says_what_to_do_about_it(self) -> None:
        answer = self.answer_when(
            helpers.RendererUnavailable(
                "no GH_TOKEN or GITHUB_TOKEN in the environment", cause="no token"
            )
        )
        self.assertIsNone(answer.unverified, "a permanent cause was announced as a blip")
        self.assertIn("no GH_TOKEN", answer.refusal)
        self.assertIn("export GH_TOKEN or GITHUB_TOKEN and run again", answer.refusal)

    def test_an_http_failure_and_an_unreachable_renderer_proceed_unverified(self) -> None:
        for label, reason in (
            ("a spent rate limit", "the renderer's rate limit is spent (it resets at soon)"),
            ("unreachable", "the renderer was unreachable (timed out)"),
        ):
            with self.subTest(cause=label):
                answer = self.answer_when(helpers.RendererUnavailable(reason, cause="server error"))
                self.assertIsNone(answer.refusal, f"{label}: a blip blocked the write")
                self.assertIn(reason, answer.unverified)

    def raised_by(self, error: Exception | None, environment: dict[str, str]):
        """What `render_markdown` raises for one cause, at its own raise site."""
        render = _LIVE_RENDER or helpers.render_markdown

        def urlopen(request, timeout=None):
            raise error

        with mock.patch.dict(os.environ, environment, clear=True):
            with (
                mock.patch.object(urllib.request, "urlopen", side_effect=urlopen)
                if error is not None
                else contextlib.nullcontext()
            ):
                with self.assertRaises(helpers.RendererUnavailable) as raised:
                    render("# body")
        return raised.exception

    def http_error(
        self,
        code: int,
        *,
        rate_limited: bool = False,
        retry_after: str | None = None,
        body: str = "",
    ):
        headers = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "soon"} if rate_limited else {}
        if retry_after is not None:
            # A SECONDARY rate limit: the quota is not spent, the renderer is
            # asking for a pause, and `Retry-After` is the time that fixes it.
            headers = {"retry-after": retry_after, "x-ratelimit-remaining": "42"}
        if body and not headers:
            # The header-less shape: quota remaining, no `Retry-After`, and
            # the message as the only witness (#1773, round 11).
            headers = {"x-ratelimit-remaining": "42"}
        return urllib.error.HTTPError(
            helpers.MARKDOWN_API_URL, code, "refused", email.message_from_string(
                "\n".join(f"{name}: {value}" for name, value in headers.items())
            ), io.BytesIO(body.encode("utf-8")) if body else None
        )

    SECONDARY_BODY = (
        '{"message": "You have exceeded a secondary rate limit. Please wait a few minutes '
        'before you try again.", "documentation_url": "https://docs.github.com/rest"}'
    )
    FORBIDDEN_BODY = '{"message": "Resource not accessible by integration"}'

    # intent: fix
    def test_a_header_less_secondary_limit_is_time_rather_than_the_token(self) -> None:
        """Permanence decides, and the message is the witness (#1773, round 11).

        GitHub documents secondary 403/429 responses that carry neither
        `Retry-After` nor an exhausted quota, and the classifier recognised a
        secondary limit by the header alone -- so such a response read as a
        forbidden token, refused the write, and told the author to export a
        token the renderer accepts, when waiting is what fixes it. Quota
        remaining cannot be the witness either: a real forbidden token has
        quota remaining too. The response body's own message separates them.

        What stays unverified: whether GitHub's live secondary 403 for THIS
        endpoint carries that message. Both shapes are classified here; the
        live shape has not been observed.
        """
        token = {"GH_TOKEN": "a-token"}
        paused = self.raised_by(self.http_error(403, body=self.SECONDARY_BODY), token)
        self.assertEqual(paused.cause, "secondary rate limit")
        self.assertTrue(paused.transient)
        self.assertIsNone(paused.repair)
        self.assertIn("secondary rate limit", paused.args[0])
        for code in (403, 429):
            with self.subTest(code=code):
                self.assertEqual(
                    helpers.http_failure_cause(self.http_error(code, body=self.SECONDARY_BODY)),
                    "secondary rate limit",
                )

    # intent: control
    def test_a_header_less_403_that_says_nothing_is_still_the_token(self) -> None:
        # The control the decision needs: a forbidden token also has quota
        # remaining and no `Retry-After`, so without the message the answer is
        # unchanged -- permanent, refusing, with a repair the author can act
        # on.
        token = {"GH_TOKEN": "a-token"}
        refused = self.raised_by(self.http_error(403, body=self.FORBIDDEN_BODY), token)
        self.assertEqual(refused.cause, "forbidden token")
        self.assertFalse(refused.transient)
        self.assertEqual(
            helpers.http_failure_cause(self.http_error(403)), "forbidden token"
        )

    # intent: guard
    def test_reading_the_body_leaves_it_readable(self) -> None:
        # The body is a stream: reading it to classify consumed it, so a
        # caller that reads it afterwards for its own message got nothing.
        error = self.http_error(403, body=self.SECONDARY_BODY)
        self.assertTrue(helpers.says_secondary_rate_limit(error))
        self.assertTrue(helpers.says_secondary_rate_limit(error))
        self.assertIn("secondary rate limit", error._body_text)

    def test_each_raise_site_decides_which_family_it_is(self) -> None:
        """All THREE sites, and the permanence split inside one of them.

        This named three raise sites and drove one, so flipping the HTTP
        site's answer left the suite green -- and that site had every
        `HTTPError` transient, which put a REJECTED token in the fail-open
        family while an ABSENT one refused (#1773, round 8).

        Which half asks reality: none of it. Each cause is raised at the seam
        the runtime raises it from, with the environment as an input.
        """
        token = {"GH_TOKEN": "a-token", "GITHUB_REPOSITORY": "acme/thing"}
        cases = (
            ("no token at all", None, {}, False),
            ("a rejected token (401)", self.http_error(401), token, False),
            ("a forbidden token (403, not the rate limit)", self.http_error(403), token, False),
            ("a spent rate limit (403)", self.http_error(403, rate_limited=True), token, True),
            (
                "a secondary rate limit (403 with Retry-After)",
                self.http_error(403, retry_after="60"),
                token,
                True,
            ),
            ("a spent rate limit (429)", self.http_error(429, rate_limited=True), token, True),
            ("the renderer erroring (503)", self.http_error(503), token, True),
            ("an unreachable renderer", urllib.error.URLError("timed out"), token, True),
            ("a dropped connection", OSError("connection reset"), token, True),
        )
        for label, error, environment, transient in cases:
            with self.subTest(cause=label):
                raised = self.raised_by(error, environment)
                self.assertEqual(raised.transient, transient, label)
        # And the type refuses to be raised without the decision being made.
        # A raise site names a cause the table holds, or it raises: a family
        # and a repair cannot be invented at the site any more.
        with self.assertRaises(TypeError):
            helpers.RendererUnavailable("a cause nobody named")
        with self.assertRaises(KeyError):
            helpers.RendererUnavailable("a cause the table does not hold", cause="a new thing")

    def test_a_rejected_token_refuses_the_placement_like_an_absent_one(self) -> None:
        # The consequence, at the placement: a token the renderer will not
        # take is a local condition the author can act on, so it gets the
        # answer no token gets rather than a write that went ahead unverified.
        raised = self.raised_by(self.http_error(401), {"GH_TOKEN": "a-token"})
        self.assertEqual(raised.cause, "rejected token")
        # And the cause a secondary limit gets, which used to be this one: a
        # 403 that is not the quota being spent read as a refused token and
        # told the author to export a different one, which would not have
        # helped (#1773, round 9).
        paused = self.raised_by(self.http_error(403, retry_after="60"), {"GH_TOKEN": "a-token"})
        self.assertEqual(paused.cause, "secondary rate limit")
        self.assertTrue(paused.transient)
        self.assertIsNone(paused.repair)
        answer = self.answer_when(raised)
        self.assertIsNone(answer.unverified)
        self.assertIn("HTTP 401", answer.refusal)
        # The repair fits the cause: telling an author whose token came back
        # 401 to export a token the renderer accepts is what they just did.
        self.assertIn("the renderer rejected the token", answer.refusal)
        self.assertNotIn("export a token the renderer accepts", answer.refusal)

    def test_every_refusing_cause_names_an_action_and_no_proceeding_one_does(self) -> None:
        """The semantic difference between the families, as a property (#1773, round 8).

        Driving each raise site pins the classification of the causes that
        exist. This pins what the classification MEANS, so a cause added later
        that refuses without saying what to do -- or proceeds while implying
        the author should act -- goes red without anyone adding it to a list.

        Which half asks reality: none. Every cause is raised at the seam, and
        the assertion is about the sentence each family produces.
        """
        token = {"GH_TOKEN": "a-token", "GITHUB_REPOSITORY": "acme/thing"}
        causes = (
            ("no token at all", None, {}),
            ("a rejected token (401)", self.http_error(401), token),
            ("a forbidden token (403)", self.http_error(403), token),
            ("a spent rate limit", self.http_error(403, rate_limited=True), token),
            ("a secondary rate limit", self.http_error(403, retry_after="60"), token),
            ("the renderer erroring (503)", self.http_error(503), token),
            ("an unreachable renderer", urllib.error.URLError("timed out"), token),
        )
        for label, error, environment in causes:
            with self.subTest(cause=label):
                raised = self.raised_by(error, environment)
                answer = self.answer_when(raised)
                if raised.transient:
                    self.assertIsNone(raised.repair, f"{label}: a blip named an action")
                    self.assertIsNone(answer.refusal, f"{label}: a blip blocked the write")
                    self.assertIn(str(raised), answer.unverified)
                else:
                    self.assertTrue(raised.repair, f"{label}: a refusal named no action")
                    self.assertIsNone(answer.unverified, f"{label}: a refusal read as a blip")
                    self.assertIn(raised.repair, answer.refusal, f"{label}: the action went unsaid")

    def test_every_cause_in_the_table_carries_its_family_and_its_repair(self) -> None:
        """The table is the only constructor input (#1773, round 9).

        Round 8 made the TYPE enforce that a permanent cause has a repair. It
        did not and could not enforce that the repair FITS: a secondary rate
        limit was classified as a rejected token and told the author to export
        a different one, which is a message and a classification disagreeing
        while both satisfy the type. Pairing them in one table makes the
        mismatch unconstructible rather than untested.
        """
        for cause, (transient, repair) in helpers.RENDERER_CAUSES.items():
            with self.subTest(cause=cause):
                raised = helpers.RendererUnavailable("a reason", cause=cause)
                self.assertEqual(raised.transient, transient)
                self.assertEqual(raised.repair, repair)
                self.assertEqual(bool(repair), not transient, "a family without its repair")

    def test_a_raise_site_cannot_choose_a_family_or_a_repair(self) -> None:
        with self.assertRaises(TypeError):
            helpers.RendererUnavailable("x", transient=True)
        with self.assertRaises(TypeError):
            helpers.RendererUnavailable("x", cause="no token", repair="something else")

    def test_the_page_carries_the_cause_through_rendered_page(self) -> None:
        for transient in (True, False):
            with self.subTest(transient=transient):
                def raise_it(text: str) -> str:
                    raise helpers.RendererUnavailable(
                        "a reason", cause="server error" if transient else "no token"
                    )

                with (
                    mock.patch.object(helpers, "render_markdown", side_effect=raise_it),
                    mock.patch.dict(helpers._RENDERED_PAGES, {}, clear=True),
                ):
                    page = helpers.rendered_page("anything")
                self.assertEqual(page.transient, transient)
                self.assertEqual(page.unverified, "a reason")


if __name__ == "__main__":
    unittest.main()
