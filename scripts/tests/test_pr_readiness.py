#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Policy tests for the PR readiness workflow helper.

Intent: make the mergeability gate predictable by proving the script accepts
the PR body sections this repo requires and reports missing evidence or policy
sections in a form GitHub Actions can surface cleanly.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "pr-readiness.py"

spec = importlib.util.spec_from_file_location("pr_readiness", SCRIPT_PATH)
assert spec and spec.loader
pr_readiness = importlib.util.module_from_spec(spec)
sys.modules["pr_readiness"] = pr_readiness
spec.loader.exec_module(pr_readiness)


def pr(body: str, *, labels: list[str] | None = None, draft: bool = False) -> dict:
    return {
        "title": "Example PR",
        "body": body,
        "draft": draft,
        "labels": [{"name": name} for name in labels or []],
    }


GOOD_BODY = """The Ghostty callback helpers each reached for userdata their own way, so a nil
pointer was a crash in one of them and a no-op in the next. This gives them one
helper with the nil and zero-address cases decided in a single place, which is
what the tests below now cover. Two files, +48 -31; no behavior a user sees.

## What

- Improve callback helper maintainability

## Mergeability

- Surface: desktop
- User-facing behavior changed: none; refactor only
- Non-happy paths considered: nil userdata and zero address behavior covered
- Release/ops preconditions: not applicable
- Residual risk or follow-up: none

## Validation

- [x] Other checks run: swift test --filter GhosttyCallbackUserdata

## Evidence

- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed

## Blockers

- [x] None
- [ ] Blocked on evidence
"""


class PRReadinessTests(unittest.TestCase):
    def test_clean_pr_passes(self) -> None:
        result = pr_readiness.evaluate(pr(GOOD_BODY), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(result.failures, [])

    def test_default_mergeability_surface_fails(self) -> None:
        body = GOOD_BODY.replace("- Surface: desktop", "- Surface: desktop / web / agent-runtime / infra / docs")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertIn("Mergeability field is empty or still default: Surface.", result.failures)

    def test_blocked_label_fails(self) -> None:
        result = pr_readiness.evaluate(pr(GOOD_BODY, labels=["blocked:ci"]), [])
        self.assertIn("Blocking label present: blocked:ci.", result.failures)

    def test_checked_blocked_evidence_fails(self) -> None:
        body = GOOD_BODY.replace("- [ ] Blocked on evidence", "- [x] Blocked on evidence")
        result = pr_readiness.evaluate(pr(body), [])
        self.assertIn("PR is checked as blocked on evidence.", result.failures)

    def test_structured_pending_or_blocked_evidence_fails(self) -> None:
        for status in ("pending-ci", "blocked"):
            with self.subTest(status=status):
                body = GOOD_BODY + f"\n## Evidence Status\n\n- [{status}] swift test -- awaiting proof\n"
                result = pr_readiness.evaluate(pr(body), [])
                self.assertIn(
                    "Requested evidence is blocked or still pending CI.",
                    result.failures,
                )

    def test_shadow_or_duplicate_evidence_status_headings_fail_closed(self) -> None:
        for shadow in (
            "### Evidence Status",
            "##  Evidence Status",
            "## evidence status ##",
        ):
            with self.subTest(shadow=shadow):
                body = (
                    GOOD_BODY
                    + f"\n{shadow}\n- [complete] other -- self-attested\n"
                    + "\n## Evidence Status\n- [blocked] other -- reconciliation required\n"
                )
                result = pr_readiness.evaluate(pr(body), [])
                self.assertIn(
                    "Ambiguous Evidence Status headings; use at most one exact "
                    "'## Evidence Status' heading and no variants.",
                    result.failures,
                )
                self.assertIn(
                    "Requested evidence is blocked or still pending CI.",
                    result.failures,
                )

        duplicate = GOOD_BODY + (
            "\n## Evidence Status\n- [complete] other -- first\n"
            "\n## Evidence Status\n- [complete] other -- duplicate\n"
        )
        self.assertIn(
            "Ambiguous Evidence Status headings; use at most one exact "
            "'## Evidence Status' heading and no variants.",
            pr_readiness.evaluate(pr(duplicate), []).failures,
        )

    def test_template_guidance_does_not_trigger_merge_stop(self) -> None:
        body = GOOD_BODY + "\nUI-affecting work needs explicit approval before shipping without visual proof.\n"
        result = pr_readiness.evaluate(pr(body), [])
        self.assertEqual(result.failures, [])

    def test_explicit_do_not_merge_fails(self) -> None:
        body = GOOD_BODY + "\nDo not merge this PR until the secret is present.\n"
        result = pr_readiness.evaluate(pr(body), [])
        self.assertIn("PR text contains a merge-stop instruction.", result.failures)

    def test_release_pr_requires_preconditions(self) -> None:
        body = GOOD_BODY.replace("- Release/ops preconditions: not applicable", "- Release/ops preconditions:")
        result = pr_readiness.evaluate(pr(body), ["scripts/verify-installed-perf.sh"])
        self.assertIn(
            "Release-sensitive files changed; fill 'Release/ops preconditions' in the PR body.",
            result.failures,
        )

    def test_release_pr_with_unresolved_secret_precondition_fails(self) -> None:
        body = GOOD_BODY + "\nThree new GitHub secrets must be added BEFORE merging.\n"
        result = pr_readiness.evaluate(pr(body), ["scripts/notarize.sh"])
        self.assertIn(
            "Release PR says secrets/credentials must be added before merging; use blocked:secrets until complete.",
            result.failures,
        )

    def test_an_image_of_text_does_not_satisfy_a_change_nobody_looks_at(self) -> None:
        # The loophole that made rendering a test summary to an SVG worth
        # doing: an image satisfied this gate for any change at all. Michael,
        # 2026-09: "We will never again choose to create an svg of text just
        # to have evidence. That was a reward hack I allowed to go through for
        # a while."
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- ![tests](https://evidence.cloudcompute.com/workspaces/pr-1/tests.svg)",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn(
            "The only evidence in the PR body is an image, and this change is not one "
            "anyone looks at. State the command you ran and the line it printed.",
            result.failures,
        )

    def test_an_image_still_satisfies_a_change_someone_looks_at(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- ![sidebar](https://evidence.cloudcompute.com/workspaces/pr-1/sidebar.png)",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Sidebar.swift"])
        self.assertEqual(result.failures, [])

    def test_an_uploaded_text_log_satisfies_any_change(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- [test-output](https://evidence.cloudcompute.com/workspaces/pr-1/test-output.txt)",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertEqual(result.failures, [])

    def test_a_pass_word_with_no_command_is_not_a_report(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- Everything passed.",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_failed_run_is_not_an_evidence_signal(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- `swift test` -- 12 tests failed",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_pass_phrased_as_an_absence_still_counts(self) -> None:
        # `TEST_RESULT_RE` accepts "no lint errors" as a pass. A failure guard
        # spelled with a bare `errors?` matches inside that same phrase, which
        # made the branch dead the moment the guard existed.
        for line in (
            "- `mise run lint` -- no lint errors",
            "- `mise run lint` -- zero failures",
            "- `./scripts/check.sh` -- 0 errors",
        ):
            with self.subTest(line=line):
                body = GOOD_BODY.replace(
                    "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
                    line,
                ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
                result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
                self.assertEqual(result.failures, [])

    def test_a_nonzero_exit_is_not_an_evidence_signal(self) -> None:
        for line in (
            "- `pytest` -> Ran 12 tests; Process completed with exit code 1",
            "- `swift test` -> 12 tests passed; exit status 1",
            "- `pytest` -> 0 tests failed",
            "- `pytest` -> Ran 12 tests, no failures but errors=2",
        ):
            with self.subTest(line=line):
                body = GOOD_BODY.replace(
                    "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
                    line,
                ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
                result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
                self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_multi_digit_exit_code_is_not_an_evidence_signal(self) -> None:
        for line in (
            "- `pytest` -> Ran 12 tests; Process completed with exit code 127",
            "- `swift test` -> 12 tests passed; exit status: 1",
            "- `swift test` -> 12 tests passed; status: ERROR",
            "- `swift test` -> 12 tests passed; process exited with status 127",
        ):
            with self.subTest(line=line):
                body = GOOD_BODY.replace(
                    "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
                    line,
                ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
                result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
                self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_count_with_no_verdict_is_not_output(self) -> None:
        # "This patch changes 12 files" sat in the window under a command and
        # read as the command's output.
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- `swift test`\n- This patch changes 12 files.",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_trusted_host_after_an_at_sign_is_not_our_store(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- see https://evil.example/@https://evidence.cloudcompute.com/fake.txt",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_plan_to_run_is_not_a_report(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "We will run `swift test` after review.\n\nThe change adds 12 tests.",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_trusted_host_after_a_path_separator_is_not_our_store(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- see https://evil.example/path;https://evidence.cloudcompute.com/fake.txt",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_an_image_url_with_a_query_is_still_an_image(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- https://evidence.cloudcompute.com/workspaces/pr-1/sidebar.png?raw=1",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Sidebar.swift"])
        self.assertEqual(result.failures, [])

    def test_a_command_that_was_not_run_is_not_a_report(self) -> None:
        # The widened window joined a "was not run" line to a count several
        # lines below it and read the pair as a passing run.
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- `swift test`\n- was not run in this environment\n- The change adds 12 tests.",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_a_trusted_host_inside_another_url_is_not_our_store(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- see https://evil.example/?next=https://evidence.cloudcompute.com/fake.txt",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_an_image_does_not_stand_in_for_a_cli_change(self) -> None:
        # `WorkspaceManagerCLI` draws nothing, so widening the visual surfaces
        # to all of `Sources/` restored the bypass there.
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- ![out](https://evidence.cloudcompute.com/workspaces/pr-1/out.png)",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(
            pr(body), ["Sources/WorkspaceManagerCLI/main.swift"]
        )
        self.assertIn(
            "The only evidence in the PR body is an image, and this change is not one "
            "anyone looks at. State the command you ran and the line it printed.",
            result.failures,
        )

    def test_a_fenced_result_under_a_command_still_counts(self) -> None:
        # A blank line and a fence between the command and its output is
        # ordinary formatting, and a two-line window called it no evidence.
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "I ran `swift test`:\n\n```\nTest run with 1992 tests in 214 suites passed\n```",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertEqual(result.failures, [])

    def test_a_release_body_listing_what_this_gate_asks_for_passes(self) -> None:
        # `./scripts/...` could never match behind a word boundary, and
        # `bash -n` and `actionlint` were missing though the release branch of
        # this same gate names them.
        for command in (
            "`bash -n scripts/release.sh` -- ok",
            "`actionlint` -- clean",
            "`./scripts/validate-release-changes.sh` -- passed",
        ):
            with self.subTest(command=command):
                body = GOOD_BODY.replace(
                    "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
                    f"- {command}",
                ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
                result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
                self.assertEqual(result.failures, [])

    def test_a_screenshot_on_core_swift_still_counts(self) -> None:
        # `WorkspaceManagerCore` renders nothing itself but defines the
        # labels, icons and colors the app draws, so a real app capture is
        # evidence about a change there.
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- ![sidebar](https://evidence.cloudcompute.com/workspaces/pr-1/sidebar.png)",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(
            pr(body), ["Sources/WorkspaceManagerCore/Models/Models.swift"]
        )
        self.assertEqual(result.failures, [])

    def test_a_host_lookalike_is_not_our_evidence_store(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- see https://evil.example/https://evidence.cloudcompute.com/tests.txt",
        ).replace("- [x] Other checks run: swift test --filter GhosttyCallbackUserdata", "- [x] Other checks run:")
        result = pr_readiness.evaluate(pr(body), ["scripts/factory-implement.py"])
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_docs_only_pr_without_evidence_passes(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- Docs-only change; no test or screenshot evidence applicable.",
        )
        result = pr_readiness.evaluate(pr(body), ["backlog/ROADMAP.md"])
        self.assertEqual(result.failures, [])

    def test_mixed_docs_and_code_still_requires_evidence(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed",
            "- Docs-only change; no test or screenshot evidence applicable.",
        )
        result = pr_readiness.evaluate(
            pr(body), ["backlog/ROADMAP.md", "Sources/WorkspaceManager/Foo.swift"]
        )
        self.assertIn("No test/evidence signal found in PR body.", result.failures)

    def test_draft_pr_is_advisory(self) -> None:
        result = pr_readiness.evaluate(pr("", draft=True), [".github/workflows/release.yml"])
        self.assertEqual(result.failures, [])
        self.assertTrue(result.notices)


class TolerantFieldMatchingTests(unittest.TestCase):
    """Near-miss labels kept failing substantively-complete PRs (2026-07-04:
    #781 wrote "Residual risk:", #779 wrote prose). The gate now accepts the
    label variants agents actually write; only truly missing answers fail."""

    def test_residual_risk_synonym_passes(self) -> None:
        # PR #781's exact shape: "Residual risk:" instead of the canonical label.
        body = GOOD_BODY.replace(
            "- Residual risk or follow-up: none",
            "- Residual risk: links now resolve under archive/ (intended)",
        )
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(result.failures, [])

    def test_scope_synonym_for_surface_passes(self) -> None:
        body = GOOD_BODY.replace("- Surface: desktop", "- Scope: desktop terminal wrapper")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(result.failures, [])

    def test_bold_label_without_bullet_passes(self) -> None:
        body = GOOD_BODY.replace("- Surface: desktop", "**Surface**: desktop")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(result.failures, [])

    def test_em_dash_separator_passes(self) -> None:
        body = GOOD_BODY.replace("- Surface: desktop", "- Surface — desktop")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(result.failures, [])

    def test_unlabeled_prose_section_still_fails(self) -> None:
        # PR #779's shape: a Mergeability section with no labeled answers.
        # The gate asks four specific questions; prose that never labels them
        # is indistinguishable from not answering, so it still fails.
        body = GOOD_BODY.replace(
            """- Surface: desktop
- User-facing behavior changed: none; refactor only
- Non-happy paths considered: nil userdata and zero address behavior covered
- Release/ops preconditions: not applicable
- Residual risk or follow-up: none""",
            "Scoped to three files; no schema, API, or dependency changes.",
        )
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        self.assertTrue(any("Mergeability field" in failure for failure in result.failures))


class SectionHeadingCaseTests(unittest.TestCase):
    """A heading's case does not decide whether its section exists (#1609).

    GitHub renders `## evidence status` and `## Evidence Status` alike, so the
    gate reads either spelling as the section and reports what is wrong with
    the body itself: a missing Mergeability field, or a line still pending.
    Two status headings together are ambiguous whatever their case.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    AMBIGUOUS = (
        "Ambiguous Evidence Status headings; use at most one exact "
        "'## Evidence Status' heading and no variants."
    )

    def test_a_lower_case_mergeability_heading_is_the_section(self) -> None:
        for heading in ("## mergeability", "## MERGEABILITY"):
            with self.subTest(heading=heading):
                body = GOOD_BODY.replace("## Mergeability", heading)
                self.assertEqual(
                    pr_readiness.extract_section(body, "Mergeability"),
                    pr_readiness.extract_section(GOOD_BODY, "Mergeability"),
                )
                self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [])

    def test_a_lower_case_evidence_status_heading_is_the_section(self) -> None:
        body = GOOD_BODY + "\n## evidence status\n- [complete] swift test -- 1992 tests passed\n"
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] swift test -- 1992 tests passed",
        )
        self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [])

    def test_a_lone_lower_case_status_heading_is_not_refused_as_ambiguous(self) -> None:
        # The heading is never the failure on its own: an empty or complete
        # section passes, and a pending one fails as pending.
        pending = "Requested evidence is blocked or still pending CI."
        for section, expected in (
            ("", []),
            ("- [complete] swift test -- 1992 tests passed\n", []),
            ("- [pending-ci] swift test -- awaiting proof\n", [pending]),
        ):
            with self.subTest(section=section):
                body = GOOD_BODY + f"\n## evidence status\n{section}"
                self.assertIsNone(pr_readiness.evidence_status_heading_failure(body))
                self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, expected)

    def test_a_pending_line_under_a_lower_case_heading_is_reported_as_pending(self) -> None:
        for status in ("pending-ci", "blocked"):
            with self.subTest(status=status):
                body = GOOD_BODY + f"\n## evidence status\n- [{status}] swift test -- awaiting proof\n"
                self.assertIn(
                    "Requested evidence is blocked or still pending CI.",
                    pr_readiness.evaluate(pr(body), self.FILES).failures,
                )

    def test_two_spellings_of_the_status_heading_together_are_still_ambiguous(self) -> None:
        # The gate reads only the first section, and the two can disagree
        # about the same item.
        for first, second in (
            ("## evidence status", "## Evidence Status"),
            ("## Evidence Status", "## EVIDENCE STATUS"),
        ):
            with self.subTest(first=first, second=second):
                body = GOOD_BODY + (
                    f"\n{first}\n- [complete] other -- self-attested\n"
                    f"\n{second}\n- [blocked] other -- reconciliation required\n"
                )
                self.assertIn(self.AMBIGUOUS, pr_readiness.evaluate(pr(body), self.FILES).failures)


class PendingLineShapeTests(unittest.TestCase):
    """A pending line is pending in every shape GitHub renders as one (#1625).

    A CR or CRLF line ending, a heading up to three spaces in, and a list item
    opened by `*`, `+` or a number all render the way `- [pending-ci]` under
    `## Evidence Status` does, so each fails the gate as pending.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    PENDING = "Requested evidence is blocked or still pending CI."
    AMBIGUOUS = SectionHeadingCaseTests.AMBIGUOUS

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def test_a_crlf_status_section_in_an_lf_body_is_pending(self) -> None:
        for ending in ("\r\n", "\r"):
            with self.subTest(ending=repr(ending)):
                body = GOOD_BODY + f"\n## Evidence Status{ending}- [pending-ci] swift test -- waiting{ending}"
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_a_crlf_body_fails_for_its_pending_line_not_a_missing_section(self) -> None:
        body = GOOD_BODY + "\n## Evidence Status\n- [pending-ci] swift test -- waiting\n"
        self.assertEqual(self.failures(body.replace("\n", "\r\n")), [self.PENDING])

    def test_a_status_heading_up_to_three_spaces_in_is_a_variant(self) -> None:
        # It renders as the heading, but the factory's writer cannot find it and
        # would add a second section beside it, so it fails whatever it holds.
        # A reader still sees the section, so a pending line under it is also
        # reported as pending: the rendered view reads the heading GitHub shows.
        # The paragraph closes the list GOOD_BODY ends on, so the heading is at
        # the top level at each of the three indents rather than nested inside
        # that list's last item, which two or three spaces would otherwise be.
        prose = GOOD_BODY + "\nThat is every blocker.\n"
        pending = "- [pending-ci] swift test -- waiting"
        complete = "- [complete] swift test -- 1992 tests passed"
        for indent in (" ", "  ", "   "):
            for line, expected in ((pending, [self.AMBIGUOUS, self.PENDING]), (complete, [self.AMBIGUOUS])):
                with self.subTest(indent=len(indent), line=line):
                    body = prose + f"\n{indent}## Evidence Status\n{line}\n"
                    self.assertEqual(self.failures(body), expected)

    def test_an_indented_heading_neither_opens_nor_ends_a_section(self) -> None:
        # A regex cannot tell a heading nested in a list item from a top-level
        # one, so a section opens and closes at a column-0 heading only.
        indented = GOOD_BODY.replace("## Mergeability", "   ## Mergeability")
        self.assertIn("Missing ## Mergeability section from the PR body.", self.failures(indented))
        nested = "- Supporting context:\n\n   ## Nested detail\n\n   Inside the list item.\n\n"
        body = GOOD_BODY.replace("## Mergeability\n\n", "## Mergeability\n\n" + nested, 1)
        self.assertEqual(self.failures(body), [])

    def test_four_spaces_in_is_a_code_block_not_a_heading(self) -> None:
        body = GOOD_BODY + "\n    ## Evidence Status\n    - [pending-ci] swift test -- quoted example\n"
        self.assertEqual(pr_readiness.extract_section(body, "Evidence Status"), "")
        self.assertEqual(self.failures(body), [])

    def test_a_pending_line_opened_by_any_list_marker_is_pending(self) -> None:
        for heading in ("## Evidence Status", "## evidence status"):
            for marker in ("*", "+", "1.", "1)"):
                with self.subTest(heading=heading, marker=marker):
                    body = GOOD_BODY + f"\n{heading}\n{marker} [pending-ci] swift build -- waiting\n"
                    self.assertEqual(self.failures(body), [self.PENDING])

    def test_a_status_marker_with_nothing_after_it_is_pending(self) -> None:
        for line in ("- [pending-ci]", "+ [blocked]\n"):
            with self.subTest(line=line):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{line}"), [self.PENDING])

    def test_a_blocked_on_evidence_box_under_any_list_marker_is_checked(self) -> None:
        # A box that holds a PR back is read as leniently as a pending line.
        for box in ("* [x]", "+ [x]", "1. [x]", "123456789. [x]", "-[x]"):
            with self.subTest(box=box):
                body = GOOD_BODY.replace("- [ ] Blocked on evidence", f"{box} Blocked on evidence")
                self.assertIn("PR is checked as blocked on evidence.", self.failures(body))

    def test_only_a_checkbox_github_renders_excuses_evidence(self) -> None:
        evidence = "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed"
        untested = GOOD_BODY.replace(evidence, "-")
        for line in (
            "1234567890. [x] Not a testable change",
            "123456789.[x] Not a testable change",
            "-[x] Not a testable change",
        ):
            with self.subTest(line=line):
                self.assertIn("No test/evidence signal found in PR body.", self.failures(untested + f"\n{line}\n"))
        self.assertEqual(self.failures(untested + "\n123456789. [x] Not a testable change\n"), [])
        blocked = GOOD_BODY + "\n## Notes\n\n1234567890. [x] Blocked on evidence\n"
        self.assertNotIn("PR is checked as blocked on evidence.", self.failures(blocked))

    def test_a_status_token_in_inline_code_is_pending(self) -> None:
        for line in ("- `[pending-ci]` swift test -- waiting", "* ``[blocked]`` swift build -- waiting"):
            with self.subTest(line=line):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{line}\n"), [self.PENDING])
        complete = GOOD_BODY + "\n## Evidence Status\n- `[complete]` swift test -- 1992 tests passed\n"
        self.assertEqual(self.failures(complete), [])

    def test_a_status_token_in_bold_or_italics_is_pending(self) -> None:
        for line in ("- **[pending-ci]** swift test -- waiting", "- _[blocked]_ swift build -- waiting"):
            with self.subTest(line=line):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{line}\n"), [self.PENDING])

    def test_a_status_token_on_a_task_item_is_pending(self) -> None:
        for line in ("- [ ] [pending-ci] swift test -- waiting", "1. [x] [blocked] swift build -- waiting"):
            with self.subTest(line=line):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{line}\n"), [self.PENDING])

    def test_an_excusing_box_needs_a_space_after_it_too(self) -> None:
        evidence = "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed"
        untested = GOOD_BODY.replace(evidence, "-")
        self.assertIn(
            "No test/evidence signal found in PR body.",
            self.failures(untested + "\n1. [x]Not a testable change\n"),
        )
        self.assertIn(
            "PR is checked as blocked on evidence.",
            self.failures(GOOD_BODY + "\n- [x]Blocked on evidence\n"),
        )

    def test_a_pending_example_inside_a_fence_is_not_a_status_line(self) -> None:
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        for fence in ("```", "~~~"):
            for line in ("* [pending-ci] example", "1. [pending-ci] example", "- [blocked] example"):
                with self.subTest(fence=fence, line=line):
                    self.assertEqual(self.failures(complete + f"\n{fence}markdown\n{line}\n{fence}\n"), [])
                    self.assertEqual(self.failures(complete + f"\n{line}\n"), [self.PENDING])

    def unclosed(self, opener: str) -> str:
        return f'Evidence Status opens a code fence that never closes: "{opener}". Close it so the status lines after it are read.'

    def test_a_fence_line_four_spaces_in_is_not_a_fence(self) -> None:
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        for opener in ("    ```", "    ~~~"):
            with self.subTest(opener=opener):
                body = complete + f"\n{opener}\n- [pending-ci] swift build -- waiting\n"
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_a_line_that_opens_on_a_code_span_is_not_a_fence(self) -> None:
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        body = complete + "```swift test``` ran clean\n- [pending-ci] swift build -- waiting\n"
        self.assertEqual(self.failures(body), [self.PENDING])
        # Only a backtick fence refuses a backtick in its info string.
        self.assertEqual(self.failures(complete + "\n~~~ a`b\n- [pending-ci] example\n~~~\n"), [])

    def test_a_fence_at_the_margin_holds_its_example(self) -> None:
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        body = complete + "\n````markdown\n- [pending-ci] example\n```\n````\n"
        self.assertEqual(self.failures(body), [])

    def test_a_fence_indented_into_a_list_item_does_not_hold_a_dedented_example(self) -> None:
        # A fence three spaces in, under a list item whose content starts at two,
        # opens inside that item; the next line at the margin is indented too
        # little to stay in the item, so the item and its fence both end there
        # and GitHub renders `[pending-ci] example` as a visible list item. The
        # line reader cannot see the item the fence sits in, so it reads the
        # fence as still open; the rendered view is what catches this.
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        body = complete + "\n   ````markdown\n- [pending-ci] example\n```\n   ````\n"
        self.assertEqual(pr_readiness.rendered_status_lines(body)[-1], "[pending-ci] example")
        self.assertEqual(self.failures(body), [self.PENDING])

    def test_an_unclosed_fence_fails_with_its_own_message(self) -> None:
        complete = GOOD_BODY + "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
        self.assertEqual(self.failures(complete + "\n```\n"), [self.unclosed("```")])
        self.assertEqual(
            self.failures(complete + "\n```markdown\n- [pending-ci] example\n"),
            [self.unclosed("```markdown"), self.PENDING],
        )
        # A closer four spaces in does not close the fence.
        self.assertEqual(
            self.failures(complete + "\n```\n- [complete] example -- ok\n    ```\n"),
            [self.unclosed("```")],
        )

    def test_a_fence_line_four_spaces_in_is_not_a_fence_wherever_it_sits_in_the_section(self) -> None:
        # Stripping the section takes its first line's indent, so the fence
        # reader sees the section as the body wrote it.
        pending = "- [pending-ci] real one -- waiting"
        complete = "- [complete] swift test -- 1992 tests passed"
        for position, section in (
            ("first", f"\n    ```\n{pending}\n"),
            ("after a status line", f"{complete}\n\n    ```\n{pending}\n"),
        ):
            with self.subTest(position=position):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{section}"), [self.PENDING])

    def test_an_indented_code_example_opening_the_section_passes(self) -> None:
        complete = "- [complete] swift test -- 1992 tests passed"
        for section in (f"\n    ```\n{complete}\n", f"\n    ```swift\n    swift test\n    ```\n{complete}\n"):
            with self.subTest(section=section):
                self.assertEqual(self.failures(GOOD_BODY + f"\n## Evidence Status\n{section}"), [])

    def test_a_fence_line_four_spaces_in_inside_a_real_fence_is_content(self) -> None:
        body = GOOD_BODY + "\n## Evidence Status\n\n```markdown\n    ```\n- [pending-ci] example\n```\n"
        self.assertEqual(self.failures(body), [])

    def test_a_heading_or_rule_inside_a_closed_fence_stays_in_the_section(self) -> None:
        for opener, closer in (("```markdown", "```"), ("~~~", "~~~")):
            with self.subTest(opener=opener):
                fence = f"\n{opener}\n# Example\n## Example\n---\n- [pending-ci] example\n{closer}\n"
                status = GOOD_BODY + f"\n## Evidence Status\n{fence}"
                self.assertEqual(self.failures(status + "- [complete] swift test -- 1992 tests passed\n"), [])
                self.assertEqual(self.failures(status + "- [pending-ci] swift build -- waiting\n"), [self.PENDING])

    def test_an_unclosed_fence_holding_a_heading_still_fails(self) -> None:
        body = GOOD_BODY + "\n## Evidence Status\n\n```markdown\n## Example\n- [complete] swift test -- 1992 tests passed\n"
        self.assertEqual(self.failures(body), [self.unclosed("```markdown")])

    def test_a_heading_after_a_closed_fence_still_ends_the_section(self) -> None:
        body = GOOD_BODY + (
            "\n## Evidence Status\n\n```\n## Example\n```\n- [complete] swift test -- 1992 tests passed\n"
            "\n## Next\n\n- [pending-ci] a later section -- not a status line\n"
        )
        self.assertEqual(self.failures(body), [])

    def test_a_rule_outside_a_fence_still_ends_the_section(self) -> None:
        body = GOOD_BODY + (
            "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
            "\n---\n\n- [pending-ci] below the rule -- not a status line\n"
        )
        self.assertEqual(self.failures(body), [])

    def test_a_heading_of_level_one_ends_the_section_for_both_views(self) -> None:
        # An h1 below the h2 opens a new top-level section, so a status under it
        # is outside this section on the page. The rendered view stopped there
        # before this and the written view read on, which put a line in one view
        # and not the other; both stop there now (#1674).
        body = GOOD_BODY + (
            "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
            "\n# Notes\n\n- [blocked] a later section -- not a status line\n"
        )
        self.assertEqual(self.failures(body), [])
        self.assertEqual(
            pr_readiness.rendered_status_lines(body),
            ["[complete] swift test -- 1992 tests passed"],
        )
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] swift test -- 1992 tests passed",
        )

    def test_a_heading_with_no_text_ends_the_section_too(self) -> None:
        # `#` or `##` alone is a heading whose text is empty, and the page shows
        # a heading there, so what follows it is the next section whether or not
        # the author named it.
        for heading in ("#", "##"):
            with self.subTest(heading=heading):
                body = GOOD_BODY + (
                    "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
                    f"\n{heading}\n\n- [blocked] a later section -- not a status line\n"
                )
                self.assertEqual(self.failures(body), [])
                self.assertEqual(pr_readiness.rendered_status_lines(body), ["[complete] swift test -- 1992 tests passed"])

    def test_the_marker_opens_a_heading_on_a_space_a_tab_or_nothing_at_all(self) -> None:
        # CommonMark ends the opening run of hashes on a space, a tab or the
        # line's end. A nonbreaking space or a vertical tab renders as a
        # paragraph, and `#Notes` is not a heading either, so the section holds
        # all three and a status under one is still a status. `\s` took them for
        # headings and stopped the written view there while the page -- and the
        # rendered view -- read on (codex, gpt-5.6-sol xhigh).
        blocked = "- [blocked] the UI lane -- a status line"
        for name, marker in (
            ("space", "#" + chr(32)),
            ("tab", "#" + chr(9)),
            ("nonbreaking space", "#" + chr(160)),
            ("vertical tab", "#" + chr(11)),
            ("nothing", "#"),
        ):
            with self.subTest(marker=name):
                body = GOOD_BODY + (
                    "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
                    f"\n{marker}Notes\n\n{blocked}\n"
                )
                ends = name in ("space", "tab")
                # The written view is asserted on its own reading rather than
                # through the gate: the conjunction of refusals lets the
                # rendered view answer for a line the written view stopped
                # short of, so a verdict alone cannot tell the two apart.
                section = pr_readiness.extract_section(body, "Evidence Status")
                self.assertEqual(blocked in section, not ends)
                self.assertEqual(
                    any("[blocked]" in line for line in pr_readiness.rendered_status_lines(body)),
                    not ends,
                )
                self.assertEqual(self.failures(body), [] if ends else [self.PENDING])

    def test_a_sub_heading_stays_inside_the_section(self) -> None:
        # Level 3 and below is a heading within the section rather than after
        # it, so its lines are read by both views and a status under one is
        # still a status.
        body = GOOD_BODY + (
            "\n## Evidence Status\n- [complete] swift test -- 1992 tests passed\n"
            "\n### Detail\n\n- [blocked] the UI lane -- still a status line\n"
        )
        self.assertEqual(self.failures(body), [self.PENDING])
        self.assertIn("### Detail", pr_readiness.extract_section(body, "Evidence Status"))
        self.assertIn("[blocked] the UI lane -- still a status line", pr_readiness.rendered_status_lines(body))


class RenderedStatusLineTests(unittest.TestCase):
    """A status line is pending in every shape GitHub renders as one (#1706).

    A backslash escape, a character reference and inline HTML around the status
    token each render as a visible `[pending-ci]` item, and none of the three
    matches the written view's `PENDING_STATUS_RE`. The gate reads the section
    a second way, as rendered, and fails when either view sees a pending line;
    since the two are combined as a conjunction of refusals, the rendered view
    can only add failures to what the written one already catches.

    The shapes below were confirmed against GitHub's own `POST /markdown`
    endpoint in `gfm` mode, which renders each as `<li>[pending-ci] item --
    waiting</li>`.

    A list item is not the only line a reader sees, and since #1727 it is not
    the only line read: a table cell, a paragraph and a sub-heading under the
    heading are lines too, and the owner read in the contributor skill refuses
    every one of them rather than tolerating it.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    PENDING = PendingLineShapeTests.PENDING
    # The three writings of `- [pending-ci] item -- waiting` the written view
    # misses: an escaped bracket, bracket character references, and a tag pair
    # around the token.
    SHAPES = (
        "- \\[pending-ci] item -- waiting",
        "- &#91;pending-ci&#93; item -- waiting",
        "- <span>[pending-ci]</span> item -- waiting",
    )

    # #1727. The issue's own reproduction: a section whose list item is
    # complete and whose table cell is not.
    TABLE = (
        "| artifact     | status      |\n"
        "| ------------ | ----------- |\n"
        "| release log  | {status}   |\n"
    )
    COMPLETE = "- [complete] swift test -- 1992 tests passed\n"

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def body(self, section: str) -> str:
        return GOOD_BODY + f"\n## Evidence Status\n{section}"

    def test_each_written_shape_of_a_pending_line_fails(self) -> None:
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                self.assertEqual(self.failures(self.body(f"{shape}\n")), [self.PENDING])

    def test_a_blocked_token_fails_in_the_same_three_shapes(self) -> None:
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                self.assertEqual(
                    self.failures(self.body(f"{shape.replace('pending-ci', 'blocked')}\n")), [self.PENDING]
                )

    def test_a_crlf_body_fails_on_a_rendered_only_shape(self) -> None:
        # `evaluate` rewrites CR and CRLF to LF before anything reads the body,
        # and reads the section from that same normalized text, so the rendered
        # view sees the shape the author wrote.
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                body = self.body(f"{shape}\n").replace("\n", "\r\n")
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_the_written_view_still_catches_a_plain_pending_line(self) -> None:
        self.assertEqual(self.failures(self.body("- [pending-ci] item -- waiting\n")), [self.PENDING])

    def test_a_complete_line_still_passes_in_every_shape(self) -> None:
        for shape in ("- [complete] item -- proof", *(s.replace("pending-ci", "complete") for s in self.SHAPES)):
            with self.subTest(shape=shape):
                self.assertEqual(self.failures(self.body(f"{shape}\n")), [])

    def test_a_rendered_only_shape_inside_a_fence_is_still_an_example(self) -> None:
        complete = "- [complete] swift test -- 1992 tests passed\n"
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                self.assertEqual(self.failures(self.body(f"{complete}\n```markdown\n{shape}\n```\n")), [])

    def test_a_task_box_in_front_of_a_rendered_only_shape_still_fails(self) -> None:
        for box in ("- [ ] ", "- [x] ", "1. [X] "):
            for shape in self.SHAPES:
                with self.subTest(box=box, shape=shape):
                    line = box + shape.split(" ", 1)[1]
                    self.assertEqual(self.failures(self.body(f"{line}\n")), [self.PENDING])

    def test_the_rendered_view_reads_a_raw_body_without_the_gate(self) -> None:
        # The check reached directly, on the body as written: each shape
        # flattens to the text a reader sees.
        section = "".join(f"{shape}\n" for shape in self.SHAPES)
        self.assertEqual(
            pr_readiness.rendered_status_lines(self.body(section)),
            ["[pending-ci] item -- waiting"] * 3,
        )

    def test_the_rendered_view_reads_the_section_the_written_view_reads(self) -> None:
        # Same boundaries: it opens at the `## Evidence Status` heading and
        # closes at the next h1 or h2 or at a rule, so an item below either one
        # is not a status line.
        below = "- \\[pending-ci] a later section -- not a status line\n"
        for tail in (f"\n# Next\n\n{below}", f"\n## Next\n\n{below}", f"\n---\n\n{below}"):
            with self.subTest(tail=tail.splitlines()[1]):
                body = self.body("- [complete] swift test -- 1992 tests passed\n" + tail)
                self.assertEqual(pr_readiness.rendered_status_lines(body), ["[complete] swift test -- 1992 tests passed"])
                self.assertEqual(self.failures(body), [])

    def test_a_rule_of_asterisks_does_not_end_the_section_for_either_view(self) -> None:
        # `extract_section` ends the section at the exact line `---` and reads
        # past every other rule, so the rendered view breaks on a dash rule
        # only. A rule the written view reads past that ended the rendered one
        # would be a gap between them: a shape only the rendered view sees,
        # below it, would reach neither.
        for rule in ("***", "___"):
            with self.subTest(rule=rule):
                body = self.body(f"- [complete] swift test -- 1992 tests passed\n\n{rule}\n\n- \\[pending-ci] below -- waiting\n")
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_the_gate_normalizes_only_line_endings_before_reading_the_section(self) -> None:
        # The entry point's first statement rewrites CR and CRLF to LF, and
        # nothing else touches the body, so both views read what the author
        # wrote. A body already in LF reaches them unchanged.
        seen: list[str] = []
        with mock.patch.object(pr_readiness, "rendered_status_lines", side_effect=lambda body: seen.append(body) or []):
            body = self.body("- [complete] swift test -- 1992 tests passed\n")
            pr_readiness.evaluate(pr(body), self.FILES)
            self.assertEqual(seen, [body])
            seen.clear()
            pr_readiness.evaluate(pr(body.replace("\n", "\r\n")), self.FILES)
            self.assertEqual(seen, [body])

    def test_a_status_in_a_table_cell_is_pending(self) -> None:
        # A cell is a line a reader sees, and the section it sits in is the
        # one the gate reads (#1727). Neither view saw it before: the written
        # view's markers do not include `|`, and the rendered view had no
        # table plugin, so the cell was not a token with text of its own.
        for status in ("[blocked]", "[pending-ci]"):
            with self.subTest(status=status):
                section = self.COMPLETE + "\n" + self.TABLE.format(status=status)
                self.assertEqual(self.failures(self.body(section)), [self.PENDING])

    def test_a_status_in_a_paragraph_is_pending(self) -> None:
        # The table is the instance the issue reports; the class is a visible
        # status under the heading that is not a list item.
        for status in ("[blocked]", "[pending-ci]"):
            with self.subTest(status=status):
                section = self.COMPLETE + f"\n{status} release log\n"
                self.assertEqual(self.failures(self.body(section)), [self.PENDING])

    def test_a_status_in_a_sub_heading_or_a_quote_is_pending(self) -> None:
        # A sub-heading is inside the section: the read closes at the next h1
        # or h2, so an h3 is a line under the heading like any other, and the
        # owner read in the contributor skill refuses one outright rather than
        # tolerating it.
        for shape in ("### [blocked] release log", "> [blocked] release log"):
            with self.subTest(shape=shape):
                self.assertEqual(self.failures(self.body(self.COMPLETE + f"\n{shape}\n")), [self.PENDING])

    def test_a_table_of_complete_cells_passes(self) -> None:
        section = self.COMPLETE + "\n" + self.TABLE.format(status="[complete]")
        self.assertEqual(self.failures(self.body(section)), [])

    def test_a_table_inside_a_fence_is_still_an_example(self) -> None:
        # A fenced table is a code block to the parser and holds no inline of
        # its own, which is what the written view says of a fenced line. The
        # cell is asserted absent from what the read returns, not only absent
        # from the failures, so the case cannot pass by reading nothing.
        section = self.COMPLETE + "\n```markdown\n" + self.TABLE.format(status="[blocked]") + "```\n"
        body = self.body(section)
        self.assertEqual(pr_readiness.rendered_status_lines(body), [self.COMPLETE.strip()[2:]])
        self.assertEqual(self.failures(body), [])

    def test_a_status_in_a_table_below_the_section_is_not_a_status_line(self) -> None:
        for tail in ("\n## Notes\n\n", "\n---\n\n"):
            with self.subTest(tail=tail.splitlines()[1]):
                body = self.body(self.COMPLETE + tail + self.TABLE.format(status="[blocked]"))
                self.assertEqual(pr_readiness.rendered_status_lines(body), [self.COMPLETE.strip()[2:]])
                self.assertEqual(self.failures(body), [])

    def test_a_struck_status_is_not_the_status_wherever_it_sits(self) -> None:
        # Strikethrough is read the way the owner read reads it: the tildes
        # stay, so a struck token is not a status token. The page shows it
        # struck, and a struck line is a line withdrawn. The line is asserted
        # to come back struck, so the case cannot pass by not reading it.
        for shape, read in (
            ("- ~~[blocked] release log~~\n", "~~[blocked] release log~~"),
            ("\n" + self.TABLE.format(status="~~[blocked]~~"), "~~[blocked]~~"),
        ):
            with self.subTest(shape=shape.strip().splitlines()[-1]):
                body = self.body(self.COMPLETE + shape)
                self.assertIn(read, pr_readiness.rendered_status_lines(body))
                self.assertEqual(self.failures(body), [])

    def test_a_bulleted_row_that_became_a_table_keeps_its_marker_and_is_still_pending(self) -> None:
        # A bullet written above a delimiter row is not a list item at all: the
        # whole thing is one table, and the marker reaches the first cell as
        # the characters `- `. Without the optional marker in
        # `RENDERED_PENDING_RE` this widening LOSES a refusal the parser with
        # no table plugin made -- the escaped form below is invisible to the
        # written view, so nothing else catches it, and the gate passed a body
        # the merge base failed. Found by codex (gpt-5.6-sol, xhigh).
        items = ("- [blocked] | x |", "- \\[blocked] | x |", "* [pending-ci] | x |", "1. [blocked] | x |")
        for item in items:
            with self.subTest(item=item):
                body = self.body(f"{item}\n  | --- | --- |\n")
                cell = item.split("|")[0].strip().replace("\\", "")
                self.assertEqual(pr_readiness.rendered_status_lines(body)[0], cell)
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_a_break_inside_one_item_makes_two_lines_and_the_second_is_read(self) -> None:
        # GitHub renders a break in a pull request body as a line break: `POST
        # /markdown` in `gfm` mode returns `<del>…</del><br>[blocked] item --
        # waiting` for both shapes below, so the status is on its own rendered
        # line and the struck text above it is not in front of it. Flattening
        # the item to one string put them on one line and the anchor missed
        # the status. Found by codex (gpt-5.6-sol, xhigh).
        withdrawn = "- ~~[complete] old -- withdrawn~~"
        for tail in ("\\\n  \\[blocked] item -- waiting", "\n  \\[blocked] item -- waiting"):
            with self.subTest(tail=tail.splitlines()[-1].strip()):
                body = self.body(withdrawn + tail + "\n")
                self.assertEqual(
                    pr_readiness.rendered_status_lines(body),
                    ["~~[complete] old -- withdrawn~~", "[blocked] item -- waiting"],
                )
                self.assertEqual(self.failures(body), [self.PENDING])

    def test_the_rendered_view_reads_every_line_under_the_heading(self) -> None:
        # The read reached directly: each cell of a table is its own line, and
        # a paragraph and a sub-heading are lines too.
        section = self.COMPLETE + "\n" + self.TABLE.format(status="[blocked]") + "\n### note\n\nprose\n"
        self.assertEqual(
            pr_readiness.rendered_status_lines(self.body(section)),
            [
                "[complete] swift test -- 1992 tests passed",
                "artifact", "status",
                "release log", "[blocked]",
                "note",
                "prose",
            ],
        )


class ParserDefinitionTests(unittest.TestCase):
    """The gate and the contributor skill read one section by one definition of markdown.

    `pr-readiness.py` writes its `MarkdownIt` line rather than importing the
    skill's, so the gate every PR runs through keeps its own PEP 723 pin and
    its own import graph; the cost of that is two places to change, and this
    is what makes forgetting one of them fail here (#1727).
    """

    HELPERS_PATH = (
        REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
    )
    # Every construct the two definitions can differ on, beside a status line,
    # so a dropped plugin shows as a missing token type rather than as nothing.
    # A drifted parser need not change this body's shape, though -- disabling
    # `escape` does not -- so the rules and options are compared as well.
    SAMPLE = """## Evidence Status

- [complete] swift test -- 1992 tests passed
- ~~[blocked] release log~~
- \\[pending-ci] &#91;escaped&#93; `code` **bold** <span>tag</span> [link](https://example.com)
- an item that runs on\\
  to a second line

| artifact    | status    |
| ----------- | --------- |
| release log | [blocked] |
"""

    def owner_parser(self):
        """The skill's parser, loaded by path so the test does not put its directory on `sys.path`."""
        spec = importlib.util.spec_from_file_location("contributor_helpers", self.HELPERS_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.MARKDOWN

    def test_the_gate_and_the_owner_read_parse_a_body_the_same_way(self) -> None:
        def shape(tokens):
            return [
                (part.type, part.tag, part.level, part.markup, part.content, part.attrs)
                for token in tokens
                for part in [token, *(token.children or [])]
            ]

        owner = self.owner_parser()
        self.assertEqual(
            shape(pr_readiness.MARKDOWN.parse(self.SAMPLE)),
            shape(owner.parse(self.SAMPLE)),
        )

    def test_the_gate_and_the_owner_read_enable_the_same_rules(self) -> None:
        # A parser can drift without moving a token on any one body -- codex
        # (gpt-5.6-sol, xhigh) showed `.disable("escape")` leaving the sample
        # above unchanged. What the two parsers are configured to do is
        # compared directly, so a difference does not have to be witnessed.
        owner = self.owner_parser()
        self.assertEqual(pr_readiness.MARKDOWN.get_active_rules(), owner.get_active_rules())
        self.assertEqual(pr_readiness.MARKDOWN.options, owner.options)

    def test_the_gate_parses_gfm_and_not_bare_commonmark(self) -> None:
        # The equality above holds for two parsers that have both lost a
        # plugin, so what the gate's parser reads is also named outright.
        self.assertIn("table_open", {token.type for token in pr_readiness.MARKDOWN.parse(self.SAMPLE)})
        inline = pr_readiness.MARKDOWN.parseInline("~~[blocked]~~")
        self.assertIn("s_open", {token.type for token in inline[0].children or []})


class SectionBoundaryAgreementBetweenTheGateAndTheSkillTests(unittest.TestCase):
    """The gate and the contributor skill end `## Evidence Status` in the same place (#1734).

    Two files answer this, and neither can import the other: the gate runs on
    every PR in the repo from its own PEP 723 pin, and the skill's reader is a
    private module in a skill directory. So the rule is written twice -- a line
    scanner here, a parser predicate there -- and agreement is a property to
    assert rather than a thing the code structure gives. Where they part
    company, a body is one section to the gate and another to the reader that
    rewrites it, which is how a `# Release blockers` after the section came to
    be carried into `## Evidence Notes` with its `- [blocked]` bullet dropped.

    The fixtures are derived rather than listed: every line shape on which the
    two rules CAN differ, crossed with both line endings GitHub stores. Listing
    the shapes someone thought of is how this test passed while the two sides
    disagreed on a setext h1, on three dash rules CommonMark ends a section at,
    on a heading indented one space and on a heading under an unterminated HTML
    block -- four divergences the list did not name and a derivation does
    (#1734, round 2). A shape the two answer differently belongs in `DIVERGE`
    with its reason, and a new one goes red here.
    """

    HELPERS_PATH = (
        REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
    )
    STATUS = "## Evidence Status\n\n- [complete] unit tests -- 10 passed\n\n"
    FIXTURES = {
        "an h1 after the section": STATUS
        + "# Release blockers\n- [blocked] the signing profile is missing\n\n## Validation\n- ran it\n",
        "an h2 after the section": STATUS + "## Validation\n- ran it\n",
        "a dash rule after the section": STATUS + "---\n\nafter the rule\n",
        "a body title h1 above the section": "# Pull request\n\n" + STATUS + "## Validation\n- ran it\n",
        "an h3 inside the section": STATUS + "### How it was run\n- on this head\n\n## Validation\n- ran it\n",
        "an h1 inside a closed fence": STATUS
        + "```markdown\n# Release blockers\n```\n\nstill inside\n\n## Validation\n- ran it\n",
        "an h2 inside a closed fence": STATUS
        + "```markdown\n## Validation\n```\n\nstill inside\n\n## Validation\n- ran it\n",
        # Neither side addresses a section by an h1, so neither finds one here.
        # The fix for the boundary could have widened the level a section is
        # matched at, which would make this body a section to one and not the
        # other.
        "the heading itself written as an h1": "# Evidence Status\n\n- [complete] unit tests -- 10 passed\n\n## Validation\n- ran it\n",
    }

    # Every line shape that could end a section, derived from the two rules
    # rather than recalled: the heading levels and the ways to write one
    # (hashes, hashes with no text, a closing run, an underline), the indents
    # CommonMark allows and the one it does not, the dash rules of every
    # length and spacing, the rules that are not dashes, the fence forms, the
    # blocks that hide a heading, and the nestings that stop one from being
    # top-level.
    BOUNDARY_CANDIDATES = {
        "atx h1": "# Release blockers\n",
        "atx h2": "## Release blockers\n",
        "atx h3": "### Release blockers\n",
        "atx h1 indented one": " # Release blockers\n",
        "atx h1 indented three": "   # Release blockers\n",
        "atx h1 indented four": "    # Release blockers\n",
        "atx h2 indented three": "   ## Release blockers\n",
        "bare hash": "#\n",
        "bare double hash": "##\n",
        "hash tab": "#\tRelease blockers\n",
        "hash nonbreaking space": "#\u00a0Release blockers\n",
        "hash no space": "#Release blockers\n",
        "atx h1 trailing spaces": "# Release blockers   \n",
        "atx h1 closed form": "# Release blockers #\n",
        "setext h1 three equals": "Release blockers\n===\n",
        "setext h1 one equal": "Release blockers\n=\n",
        "setext h1 trailing spaces": "Release blockers\n===   \n",
        "setext h1 indented three": "Release blockers\n   ===\n",
        "setext h2 dashes": "Release blockers\n---\n",
        "setext h2 five dashes": "Release blockers\n-----\n",
        "setext h2 indented": "Release blockers\n  ---\n",
        "dash rule": "\n---\n",
        "dash rule four": "\n----\n",
        "dash rule spaced": "\n- - -\n",
        "dash rule trailing spaces": "\n---   \n",
        "dash rule indented": "\n   ---\n",
        "asterisk rule": "\n***\n",
        "underscore rule": "\n___\n",
        "h1 in closed fence": "```markdown\n# Release blockers\n```\n",
        "h1 in closed tilde fence": "~~~\n# Release blockers\n~~~\n",
        "h1 in fence indented three": "   ```\n   # Release blockers\n   ```\n",
        "h1 in four backtick fence": "````\n# Release blockers\n````\n",
        "h1 in fence with info backtick": "``` a`b\n# Release blockers\n```\n",
        "h1 under runaway fence": "```\nthe log, never closed\n\n# Release blockers\n",
        "h1 after closed comment": "<!-- a note -->\n\n# Release blockers\n",
        "h1 after unclosed comment": "<!-- a note\n\n# Release blockers\n",
        "h1 in a list item": "- # Release blockers\n",
        "h1 in a quote": "> # Release blockers\n",
        "h2 in a quote": "> ## Release blockers\n",
        "h1 in an indented code block": "    # Release blockers\n\ntext\n",
    }
    CANDIDATE_TAIL = "- [blocked] the signing profile is missing\n\n## Validation\n- ran it\n"

    # The shapes the two answer differently, each with why it is not a defect
    # to fix. Anything else differing is.
    DIVERGE = {
        "h1 under runaway fence": (
            "a fence with no closing line hides every heading below it, and the skill blanks "
            "the opener and parses again to read the heading the author wrote, where the gate "
            "reads the page as CommonMark leaves it and runs the section to the end of the "
            "body. The page is on the gate's side and the author on the skill's, so this one "
            "is a judgement rather than a rule; the gate reads longer, which can add a refusal "
            "and cannot drop one"
        ),
    }

    @staticmethod
    def _lf(text: str) -> str:
        return text.replace("\r\n", "\n").replace("\r", "\n")

    def candidate_bodies(self):
        """Each boundary shape, under the status section, in every line ending GitHub stores.

        Bare `\r` is the third: the gate normalises it before reading and the
        skill's heading pattern did not take it, so the two read different
        sections of one body -- an axis the first derivation missed because it
        generated only the two endings anyone types (#1734, round 2).
        """
        for name, candidate in self.BOUNDARY_CANDIDATES.items():
            for ending in ("\n", "\r\n", "\r"):
                body = (self.STATUS + candidate + "\n" + self.CANDIDATE_TAIL).replace("\n", ending)
                yield name, ending, body

    def owner_reader(self):
        """The skill's reader, loaded by path so the test does not put its directory on `sys.path`."""
        spec = importlib.util.spec_from_file_location("contributor_helpers", self.HELPERS_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_both_files_bound_the_section_identically_on_every_boundary_kind(self) -> None:
        owner = self.owner_reader()
        for name, body in self.FIXTURES.items():
            with self.subTest(fixture=name):
                self.assertEqual(
                    pr_readiness.extract_section(body, "Evidence Status"),
                    owner.markdown_section(body, "Evidence Status"),
                )

    def test_the_two_rules_agree_on_every_shape_that_could_end_a_section(self) -> None:
        # The derived property. Each shape is put under the status section and
        # read by both files; the extent has to match, so the comparison is on
        # one kind of line ending rather than on the author's bytes.
        owner = self.owner_reader()
        compared = 0
        for name, ending, body in self.candidate_bodies():
            label = {"\n": "lf", "\r\n": "crlf", "\r": "cr"}[ending]
            with self.subTest(shape=name, ending=label):
                gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
                skill = self._lf(owner.markdown_section(body, "Evidence Status"))
                compared += 1
                if name in self.DIVERGE:
                    self.assertNotEqual(gate, skill, self.DIVERGE[name])
                    continue
                self.assertEqual(gate, skill)
        self.assertEqual(compared, len(self.BOUNDARY_CANDIDATES) * 3)

    def test_the_agreement_is_not_vacuous(self) -> None:
        # Two readers that both returned "" would agree on everything. Each
        # shape has to move the boundary for at least one of them, and the
        # status line has to survive in every reading.
        owner = self.owner_reader()
        ended_early = 0
        for name, _, body in self.candidate_bodies():
            gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
            with self.subTest(shape=name):
                self.assertIn("[complete] unit tests -- 10 passed", gate)
                self.assertIn(
                    "[complete] unit tests -- 10 passed",
                    self._lf(owner.markdown_section(body, "Evidence Status")),
                )
            if "[blocked]" not in gate:
                ended_early += 1
        # A little over half the shapes are boundaries; the rest are the
        # controls that must not be.
        self.assertGreater(ended_early, 30)
        self.assertGreater(len(self.BOUNDARY_CANDIDATES) * 3 - ended_early, 15)

    def test_a_crlf_body_reaches_the_written_reader_as_the_page_reads_it(self) -> None:
        # The gate's own entry normalises, and the reader repeats it: called
        # directly with a CRLF body -- which is what a test or a future caller
        # does -- the `\r` before the newline stopped the heading pattern
        # matching and every section came back empty.
        body = self.FIXTURES["an h1 after the section"].replace("\n", "\r\n")
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] unit tests -- 10 passed",
        )
        self.assertEqual(
            pr_readiness.evaluate(pr(body), []).__class__,
            pr_readiness.evaluate(pr(self.FIXTURES["an h1 after the section"]), []).__class__,
        )

    def test_the_gate_s_own_two_views_share_one_boundary_definition(self) -> None:
        # Written and rendered ask the same function, so a shape cannot end the
        # section for one view and not the other inside this file.
        body = self.FIXTURES["an h1 after the section"]
        tokens = pr_readiness.MARKDOWN.parse(body)
        self.assertTrue(
            any(
                pr_readiness.section_boundary_token(token)
                and token.type == "heading_open"
                and token.tag == "h1"
                for token in tokens
            )
        )
        self.assertNotIn("[blocked]", pr_readiness.extract_section(body, "Evidence Status"))
        self.assertEqual(
            [line for line in pr_readiness.rendered_status_lines(body) if "[blocked]" in line], []
        )

    def test_the_contract_section_is_bounded_alike_too(self) -> None:
        # The boundary is not particular to one heading, and the section it
        # matters most for after Evidence Status is the contract: read long, it
        # holds an item the author wrote under their own h1, and a PR is then
        # asked to prove something the page does not list. Both files end it at
        # the h1.
        owner = self.owner_reader()
        body = (
            "## Requested Evidence\n\n- `swift test` passes\n\n"
            "# Reviewer notes\n\n- a screenshot of the narrowed row\n\n"
            "## Evidence Status\n\n- [complete] `swift test` passes -- 1992 tests passed\n"
        )
        self.assertEqual(
            pr_readiness.extract_section(body, "Requested Evidence"),
            owner.markdown_section(body, "Requested Evidence"),
        )
        self.assertEqual(
            owner.markdown_section(body, "Requested Evidence"), "- `swift test` passes"
        )
        # And on this one section agreeing on a shorter read is not the end of
        # it: a shorter contract is fewer obligations, so the reader every
        # caller goes through refuses the body outright and names the line.
        # This gate reads the contract through that same function
        # (`github_state.requested_evidence_contract`), not through
        # `extract_section`, so the refusal is what reaches it (#1734).
        def bullets(section: str) -> list[str]:
            return [line for line in section.splitlines() if line.startswith("- ")]

        self.assertIsNotNone(owner.contract_read_refusal(body, "Requested Evidence", bullets))
        self.assertIsNone(owner.contract_read_refusal(body, "Evidence Status", bullets))
        self.assertIsNone(
            owner.contract_read_refusal(
                body.replace("# Reviewer notes", "## Reviewer notes"), "Requested Evidence", bullets
            )
        )

    def test_the_h1_fixture_is_the_one_the_boundary_level_is_witnessed_on(self) -> None:
        # The property above passes for two sides that both read past an h1,
        # which is the state this arc started from. So what the shared answer
        # is on that fixture is named outright: the section is the status line
        # and nothing below the h1.
        owner = self.owner_reader()
        body = self.FIXTURES["an h1 after the section"]
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] unit tests -- 10 passed",
        )
        self.assertEqual(
            owner.markdown_section(body, "Evidence Status"),
            "- [complete] unit tests -- 10 passed",
        )
        # The rendered view reads the text of a line, so the list marker is
        # the parser's rather than the line's.
        self.assertEqual(pr_readiness.rendered_status_lines(body), ["[complete] unit tests -- 10 passed"])

    def test_the_gate_s_two_views_take_the_h1_boundary_together(self) -> None:
        # The gate reads this section twice, once as written and once as
        # rendered, and a status line the page shows outside the section must
        # be outside it for both -- otherwise the `[blocked]` under the h1
        # fails the PR on one view while the other has already excluded it.
        body = self.FIXTURES["an h1 after the section"]
        self.assertNotIn("[blocked]", pr_readiness.extract_section(body, "Evidence Status"))
        self.assertEqual(
            [line for line in pr_readiness.rendered_status_lines(body) if "[blocked]" in line], []
        )


class TheRuntimeSeedsASectionWhereThisGateStillMatchesALineTests(unittest.TestCase):
    """What the seeder writes, and what this gate still reads instead (#1730).

    `seed_mergeability_section` decided whether a body already had the section
    by matching a `## Mergeability` line anywhere, so a body documenting the
    section's format in a fenced example got nothing written and said nothing
    about it. The runtime's presence check is a parse now and it writes the
    section.

    This gate is the other half, and it is not fixed here. Since #1734 its
    written read ENDS where the parser says, but it still STARTS at the first
    line matching `^## <heading>`, so on a body like this one it reads the
    example as the section. Out of scope by measurement rather than by
    preference: of 400 stored pull-request bodies, none carries a section
    heading this gate reads that the page shows as code -- the shape is real
    (three stored issues carry a fenced `## Evidence Status`) but has not
    landed on a body this gate reads. The pinning is here so the next person
    inherits the residual rather than rediscovering it.
    """

    SCRIPTS = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"

    def seeder(self):
        """The runtime's own module, loaded by path so this file's imports stay its own."""
        sys.path.insert(0, str(self.SCRIPTS))
        try:
            spec = importlib.util.spec_from_file_location(
                "contributor_execution", self.SCRIPTS / "execution.py"
            )
            assert spec and spec.loader
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        finally:
            sys.path.remove(str(self.SCRIPTS))

    def reader(self):
        """The skill's reader, loaded by path, for what the page shows."""
        spec = importlib.util.spec_from_file_location(
            "contributor_helpers", self.SCRIPTS / "_helpers.py"
        )
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    FENCED_EXAMPLE_BODY = GOOD_BODY.replace(
        """## Mergeability

- Surface: desktop
- User-facing behavior changed: none; refactor only
- Non-happy paths considered: nil userdata and zero address behavior covered
- Release/ops preconditions: not applicable
- Residual risk or follow-up: none
""",
        """The format this PR is about, for reference:

```markdown
## Mergeability

- Surface: desktop
```
""",
    )

    def test_the_runtime_writes_the_section_the_page_did_not_show(self) -> None:
        # The fix: the body had no Mergeability section a reader could see,
        # and now it has one, with the author's example left alone.
        reader = self.reader()
        self.assertFalse(reader.has_markdown_section(self.FENCED_EXAMPLE_BODY, "Mergeability"))
        seeded = self.seeder().seed_mergeability_section(
            self.FENCED_EXAMPLE_BODY, changed_files=["Sources/Foo.swift"]
        )
        self.assertTrue(reader.has_markdown_section(seeded, "Mergeability"))
        self.assertEqual(
            reader.markdown_section(seeded, "Mergeability").splitlines()[0],
            "- Surface: desktop — `Sources/Foo.swift`",
        )
        self.assertIn("```markdown\n## Mergeability", seeded)

    def test_this_gate_still_takes_the_first_line_it_matches_as_the_start(self) -> None:
        # The residual, pinned rather than claimed fixed. The gate reads the
        # example's field list on the seeded body, where the skill reads the
        # section the runtime wrote; both end where the parser says, and only
        # the start disagrees.
        seeded = self.seeder().seed_mergeability_section(
            self.FENCED_EXAMPLE_BODY, changed_files=["Sources/Foo.swift"]
        )
        gate_read = pr_readiness.extract_section(seeded, "Mergeability")
        self.assertIn("- Surface: desktop", gate_read)
        self.assertNotIn("`Sources/Foo.swift`", gate_read)
        self.assertNotEqual(gate_read, self.reader().markdown_section(seeded, "Mergeability"))
        # On THIS fixture it costs a refusal: the example carries one field, so
        # the three it omits are reported unanswered. That is the fixture's
        # doing, not the rule's -- a fenced example carrying all four fields is
        # read as a filled section and approved, which is the same misread
        # spending an approval instead. #1742 owns moving this start onto a
        # parse; the shape is pinned there rather than claimed fixed here.
        result = pr_readiness.evaluate(pr(seeded), ["Sources/Foo.swift"])
        self.assertFalse(result.ok)
        self.assertTrue(all("field is empty or still default" in text for text in result.failures), result.failures)


class TheSeedersIdentityIsNoWiderThanThisGatesTests(unittest.TestCase):
    """A heading this gate cannot read is not one the seeder treats as present (#1730).

    The runtime's presence check asks the parser now, so a heading the page
    shows is a heading to it: `## **Mergeability**`, one indented up to three
    spaces, and a setext `Mergeability` over a rule. This gate still finds a
    section's START with a literal `^## <heading>` line. Left alone, the two
    compose into a body the factory believes it healed and the gate then
    blocks: seeding is skipped because the section is there, and
    `extract_section` returns nothing, so `Missing ## Mergeability section from
    the PR body` — main PASS, head FAIL, on three shapes that pass today.

    Fail-closed, and still a body that used to merge and would not. So the
    seeder asks both questions and skips only when both say yes: the page shows
    the heading, AND this gate can read it. Each half is load-bearing — without
    the first a fenced example counts and the body goes out with no section at
    all (#1730's own bug), without the second the shapes above go unseeded.

    The narrowing is this gate's, not the runtime's, and it comes out when
    #1742 moves this start onto a parse. Until then the copy of the rule lives
    beside the reader that needs it, and the test below fails if the two drift.
    """

    SCRIPTS = TheRuntimeSeedsASectionWhereThisGateStillMatchesALineTests.SCRIPTS
    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    BODY = """A paragraph long enough to say why this pull request exists at all, plainly.

{heading}

- Surface: desktop
- User-facing behavior changed: none
- Non-happy paths considered: yes
- Residual risk or follow-up: none

## Evidence

- [x] Not a testable change
"""
    # Each is a heading the page shows and this gate's literal start misses.
    SHAPES = {
        "emphasis": "## **Mergeability**",
        "indented three spaces": "   ## Mergeability",
        "setext": "Mergeability\n---",
        "trailing spaces": "## Mergeability  ",
    }

    def seeder(self):
        return TheRuntimeSeedsASectionWhereThisGateStillMatchesALineTests.seeder(self)

    def reader(self):
        return TheRuntimeSeedsASectionWhereThisGateStillMatchesALineTests.reader(self)

    def test_a_heading_only_the_page_shows_is_seeded_and_the_gate_then_passes(self) -> None:
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.BODY.format(heading=heading)
                seeded = self.seeder().seed_mergeability_section(body, changed_files=self.FILES)
                self.assertNotEqual(seeded, body, "the seeder returned the body unwritten")
                self.assertIn("\n## Mergeability\n", seeded)
                self.assertEqual(pr_readiness.evaluate(pr(seeded), self.FILES).failures, [])

    def test_the_two_halves_are_both_load_bearing(self) -> None:
        reader, seeder = self.reader(), self.seeder()
        # A literal heading the page shows: both yes, so nothing is written.
        literal = self.BODY.format(heading="## Mergeability")
        self.assertTrue(reader.has_markdown_section(literal, "Mergeability"))
        self.assertTrue(reader.gate_reads_markdown_section(literal, "Mergeability"))
        self.assertEqual(seeder.seed_mergeability_section(literal, changed_files=self.FILES), literal)
        # A fenced example: this gate's literal start finds it and the page
        # does not show it, so the parse is what sends the seeder in.
        fenced = TheRuntimeSeedsASectionWhereThisGateStillMatchesALineTests.FENCED_EXAMPLE_BODY
        self.assertTrue(reader.gate_reads_markdown_section(fenced, "Mergeability"))
        self.assertFalse(reader.has_markdown_section(fenced, "Mergeability"))
        # And the other way for each shape above.
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.BODY.format(heading=heading)
                self.assertTrue(reader.has_markdown_section(body, "Mergeability"))
                self.assertFalse(reader.gate_reads_markdown_section(body, "Mergeability"))

    def test_the_skills_copy_of_this_gates_start_answers_as_this_gate_does(self) -> None:
        # The rule is written twice -- this script is a PEP 723 entry point
        # with its own pin and no package for the skill to import -- so the
        # shapes are enumerated against both readers rather than trusted to
        # stay in step. `extract_section` returning text is this gate finding
        # the start; the skill's predicate has to say the same thing.
        reader = self.reader()
        shapes = (
            "## Mergeability",
            "## mergeability",
            "##  Mergeability",
            "## Mergeability  ",
            "## **Mergeability**",
            "   ## Mergeability",
            "    ## Mergeability",
            "Mergeability\n---",
            "### Mergeability",
            "## Mergeability extra",
            "## Mergeability\r",
        )
        for shape in shapes:
            for ending in ("\n", "\r\n"):
                with self.subTest(shape=shape, ending=ending.encode("unicode_escape").decode()):
                    body = f"Why this exists.{ending}{ending}{shape}{ending}{ending}- Surface: desktop{ending}"
                    # This gate itself is the oracle rather than a second copy
                    # of its pattern. The section has content in every fixture,
                    # so text back means the start was found and "" means it
                    # was not.
                    gate_finds = bool(pr_readiness.extract_section(body, "Mergeability"))
                    self.assertEqual(
                        reader.gate_reads_markdown_section(body, "Mergeability"),
                        gate_finds,
                        shape,
                    )


class ReadinessCommentTests(unittest.TestCase):
    def test_failure_comment_names_failures_and_pastes_template(self) -> None:
        body = GOOD_BODY.replace("- Residual risk or follow-up: none", "")
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        comment = pr_readiness.comment_markdown(result)
        self.assertIn(pr_readiness.COMMENT_MARKER, comment)
        self.assertIn("Residual risk or follow-up", comment)
        self.assertIn("```markdown", comment)
        self.assertIn("## Mergeability", comment)

    def test_evidence_failure_comment_lists_accepted_signals(self) -> None:
        body = GOOD_BODY.replace(
            "- `swift test --filter GhosttyCallbackUserdata` -- Test run with 1992 tests in 214 suites passed", "-"
        )
        result = pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"])
        comment = pr_readiness.comment_markdown(result)
        self.assertIn("the command you ran and the line it printed", comment)
        self.assertIn("Not a testable change", comment)

    def test_pass_comment_is_a_single_resolved_line(self) -> None:
        result = pr_readiness.evaluate(pr(GOOD_BODY), ["Sources/WorkspaceManager/Foo.swift"])
        comment = pr_readiness.comment_markdown(result)
        self.assertIn("passed", comment)
        self.assertNotIn("```", comment)


# Env the CI path writes through; a preflight test must not append to a real
# step summary or readiness comment when the suite itself runs in Actions.
CI_ENV_KEYS = ("GITHUB_ACTIONS", "GITHUB_STEP_SUMMARY", "READINESS_COMMENT_PATH")


def preflight(body: str, *, files: list[str] | None = None, args: list[str] | None = None):
    """Run the `--body-file` entry point end to end; return (exit code, stdout)."""
    with tempfile.TemporaryDirectory() as tmp:
        body_path = Path(tmp) / "body.md"
        body_path.write_text(body, encoding="utf-8")
        files_path = Path(tmp) / "changed-files.json"
        files_path.write_text(json.dumps(files or []), encoding="utf-8")
        argv = [
            "--body-file", str(body_path),
            "--changed-files", str(files_path),
            *(args or []),
        ]
        local_env = {k: v for k, v in os.environ.items() if k not in CI_ENV_KEYS}
        stdout = io.StringIO()
        with mock.patch.dict(os.environ, local_env, clear=True):
            with contextlib.redirect_stdout(stdout):
                code = pr_readiness.main(argv)
    return code, stdout.getvalue()


class PreflightBodyFileTests(unittest.TestCase):
    """`--body-file` is the same gate, one step earlier.

    Authors — agents most of all — reconstructed the body from memory and
    learned it was wrong from a failed CI run. This entry point moves that
    verdict to before `gh pr create`, so it has to give the same answer in the
    same words as the event path.
    """

    def test_good_body_passes_and_exits_zero(self) -> None:
        code, output = preflight(GOOD_BODY, files=["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(code, 0)
        self.assertIn("PR readiness passed.", output)

    def test_missing_mergeability_section_fails_with_the_ci_message(self) -> None:
        body = GOOD_BODY.replace("## Mergeability", "## Notes")
        code, output = preflight(body, files=["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(code, 1)
        self.assertIn("Missing ## Mergeability section from the PR body.", output)

    def test_empty_mergeability_field_fails_and_pastes_the_fix(self) -> None:
        body = GOOD_BODY.replace(
            "- Non-happy paths considered: nil userdata and zero address behavior covered",
            "- Non-happy paths considered:",
        )
        code, output = preflight(body, files=["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(code, 1)
        self.assertIn(
            "Mergeability field is empty or still default: Non-happy paths considered.",
            output,
        )
        # The paste-ready block CI would post as a comment, printed locally.
        self.assertIn("```markdown", output)
        self.assertIn("## Mergeability", output)

    def test_preflight_and_event_path_report_identical_failures(self) -> None:
        body = GOOD_BODY.replace("## Mergeability", "## Notes")
        files = ["Sources/WorkspaceManager/Foo.swift"]
        _, output = preflight(body, files=files)
        for failure in pr_readiness.evaluate(pr(body), files).failures:
            self.assertIn(failure, output)

    def test_labels_and_title_reach_the_same_checks(self) -> None:
        code, output = preflight(
            GOOD_BODY,
            files=["Sources/WorkspaceManager/Foo.swift"],
            args=["--label", "blocked:evidence", "--title", "Do not merge until signed"],
        )
        self.assertEqual(code, 1)
        self.assertIn("Blocking label present: blocked:evidence.", output)
        self.assertIn("PR text contains a merge-stop instruction.", output)

    def test_missing_body_file_is_a_usage_error(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = pr_readiness.main(["--body-file", "/nonexistent/pr-body.md"])
        self.assertEqual(code, 2)
        self.assertIn("No such body file", stdout.getvalue())

    def test_unedited_template_does_not_pass(self) -> None:
        """Copying the template is the start of a body, not the end of one."""
        code, output = preflight(
            pr_readiness.template_body(), files=["Sources/WorkspaceManager/Foo.swift"]
        )
        self.assertEqual(code, 1)
        self.assertIn("Mergeability field is empty or still default: Surface.", output)


class EvidenceDeliveryPreflightTests(unittest.TestCase):
    """The network mode is explicit, read-only, and cannot stand in for review."""

    HEAD = "a" * 40
    BASE = "b" * 40

    def setUp(self):
        self.pr = {
            "number": 42, "headRefOid": self.HEAD, "baseRefOid": self.BASE,
            "body": "## Evidence\n![screen](https://evidence.cloudcompute.com/workspaces/pr-42/screen.png)",
        }
        self.checks = [{"name": "test", "bucket": "pass"}]
        self.github = SimpleNamespace(
            repo_owner_name=mock.Mock(return_value=("fairchild", "workspaces")),
            fetch_detailed_pull_request=mock.Mock(return_value=self.pr),
            fetch_review_checks=mock.Mock(return_value=self.checks),
            extract_pr_issue_reference=mock.Mock(return_value=(None, None)),
            fetch_detailed_issue=mock.Mock(),
            requested_evidence_contract=mock.Mock(
                return_value=(["Screenshot of terminal"], None)
            ),
        )
        self.prepared = mock.Mock(status="ready", reason_code="ready", artifacts=[{
            "id": "image-1", "url": "https://evidence.cloudcompute.com/workspaces/pr-42/screen.png",
            "sha256": "c" * 64, "local_path": "/private/tmp/staged/image-1.png",
            "author_claim": "Author-controlled text", "width": 800, "height": 600,
        }])
        self.prepared.outcome.side_effect = lambda: {
            "status": self.prepared.status, "reason_code": self.prepared.reason_code,
            "head_sha": self.HEAD, "base_sha": self.BASE,
        }

        class PreparationError(ValueError):
            def __init__(self, reason_code):
                self.reason_code = reason_code

        def fail(error):
            self.prepared.status = "unavailable"
            self.prepared.reason_code = error.reason_code

        self.prepared.fail.side_effect = fail
        self.evidence = SimpleNamespace(
            prepare_review_evidence=mock.Mock(return_value=self.prepared),
            EvidencePreparationError=PreparationError,
        )

    def run_delivery(self, *extra):
        output = io.StringIO()
        with (
            mock.patch.object(pr_readiness, "evidence_delivery_modules", return_value=(self.github, self.evidence)),
            contextlib.redirect_stdout(output),
        ):
            code = pr_readiness.main(["--check-evidence-delivery", "42", *extra])
        return code, json.loads(output.getvalue())

    def test_body_and_event_modes_do_not_load_network_or_image_dependencies(self):
        with mock.patch.object(pr_readiness, "evidence_delivery_modules", side_effect=AssertionError("offline")):
            code, _ = preflight(GOOD_BODY, files=["Sources/WorkspaceManager/Foo.swift"])
            self.assertEqual(code, 0)
            with tempfile.TemporaryDirectory() as tmp:
                event = Path(tmp) / "event.json"
                event.write_text(json.dumps({"pull_request": pr(GOOD_BODY)}))
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(pr_readiness.main(["--event", str(event)]), 0)

    def test_explicit_delivery_uses_live_readers_and_shared_preparation_then_cleans_up(self):
        code, report = self.run_delivery("--expected-head", self.HEAD)
        self.assertEqual(code, 0)
        args, kwargs = self.evidence.prepare_review_evidence.call_args
        self.assertEqual(args, (self.pr, self.checks, pr_readiness.REPO_ROOT))
        self.assertEqual(kwargs, {"expected_head": self.HEAD, "requested_evidence": []})
        self.assertEqual(self.github.fetch_detailed_pull_request.call_count, 2)
        self.assertEqual(report["status"], "delivered")
        self.assertEqual(report["scope"], "local_evidence_delivery")
        self.assertEqual(report["factory_inspection"], "not_performed")
        self.assertEqual(report["review_approval"], "not_evaluated")
        self.assertEqual(report["artifacts"][0]["sha256"], "c" * 64)
        self.assertNotIn("local_path", report["artifacts"][0])
        self.assertNotIn("author_claim", report["artifacts"][0])
        self.prepared.cleanup.assert_called_once_with()

    def test_linked_issue_requested_evidence_is_forwarded_without_reparsing(self):
        self.github.extract_pr_issue_reference.return_value = (12, None)
        self.github.fetch_detailed_issue.return_value = {"body": "## Requested Evidence\n- Screenshot of terminal"}
        code, _ = self.run_delivery()
        self.assertEqual(code, 0)
        self.assertEqual(self.github.fetch_detailed_issue.call_args.args[:3], ("fairchild", "workspaces", 12))
        self.assertEqual(self.evidence.prepare_review_evidence.call_args.kwargs["requested_evidence"],
                         ["Screenshot of terminal"])

    def test_a_linked_issue_whose_contract_is_cut_stops_the_delivery(self):
        # The third of the three readers of this contract. Delivering over the
        # items above the cut would prepare evidence for a smaller promise than
        # the issue made and report the PR delivered; the reason names the line.
        self.github.extract_pr_issue_reference.return_value = (12, None)
        self.github.requested_evidence_contract.return_value = (
            [],
            "the `## Requested Evidence` section is cut by the top-level heading at line 5 "
            "(`# Reviewer notes`); move the heading below the section or the items under it",
        )
        code, report = self.run_delivery()
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "unavailable")
        self.assertEqual(report["reason_code"], "requested_evidence_unreadable")
        self.assertIn("# Reviewer notes", report["reason"])
        self.evidence.prepare_review_evidence.assert_not_called()

    def test_missing_live_pr_or_requested_issue_cannot_pass(self):
        for missing in ("pr", "issue"):
            with self.subTest(missing=missing):
                self.setUp()
                if missing == "pr":
                    self.github.fetch_detailed_pull_request.return_value = None
                else:
                    self.github.extract_pr_issue_reference.return_value = (12, None)
                    self.github.fetch_detailed_issue.return_value = None
                code, report = self.run_delivery()
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "unavailable")
                self.evidence.prepare_review_evidence.assert_not_called()

    def test_preparation_failure_is_not_retried_or_relabelled_success(self):
        self.prepared.status = "unavailable"
        self.prepared.reason_code = "disallowed_url"
        code, report = self.run_delivery()
        self.assertEqual(code, 1)
        self.assertEqual(report["preparation"]["reason_code"], "disallowed_url")
        self.assertEqual(report["status"], "unavailable")
        self.evidence.prepare_review_evidence.assert_called_once()
        self.github.fetch_detailed_pull_request.assert_called_once()
        self.prepared.cleanup.assert_called_once_with()

    def test_changed_live_head_base_or_body_invalidates_the_delivery(self):
        for field, reason in (("headRefOid", "stale_head"), ("baseRefOid", "stale_base"), ("body", "invalid_evidence")):
            with self.subTest(field=field):
                self.setUp()
                self.github.fetch_detailed_pull_request.side_effect = [self.pr, {**self.pr, field: "changed"}]
                code, report = self.run_delivery()
                self.assertEqual(code, 1)
                self.assertEqual(report["preparation"]["reason_code"], reason)
                self.prepared.cleanup.assert_called_once_with()

    def test_failed_final_identity_read_cleans_up_and_cannot_pass(self):
        self.github.fetch_detailed_pull_request.side_effect = [self.pr, None]
        code, report = self.run_delivery()
        self.assertEqual(code, 1)
        self.assertEqual(report["reason_code"], "pr_unavailable")
        self.prepared.cleanup.assert_called_once_with()

    def test_no_images_is_not_reported_as_delivery_or_inspection(self):
        self.prepared.artifacts = []
        self.github.fetch_review_checks.return_value = None
        code, report = self.run_delivery()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "no_images_selected")
        self.assertIsNone(report["required_checks"])
        self.assertEqual(report["factory_inspection"], "not_performed")

    def test_unexpected_error_still_cleans_staged_files(self):
        self.github.fetch_detailed_pull_request.side_effect = [self.pr, RuntimeError("API failed")]
        with self.assertRaisesRegex(RuntimeError, "API failed"):
            self.run_delivery()
        self.prepared.cleanup.assert_called_once_with()

    def test_delivery_flags_reject_ambiguous_or_invalid_invocations(self):
        invalid = [
            ["--check-evidence-delivery", "0"],
            ["--check-evidence-delivery", "-1"],
            ["--check-evidence-delivery", "42", "--body-file", "body.md"],
            ["--check-evidence-delivery", "42", "--event=event.json"],
            ["--check-evidence-delivery", "42", "--changed-files", "files.json"],
            ["--check-evidence-delivery", "42", "--base", "other"],
            ["--expected-head", self.HEAD],
        ]
        for argv in invalid:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                pr_readiness.parse_args(argv)
            self.assertEqual(error.exception.code, 2)


class TemplateContractTests(unittest.TestCase):
    """The template is the single source of truth producers seed from, so the
    fields it declares and the fields the gate grades must be the same set."""

    def test_template_declares_exactly_the_graded_fields(self) -> None:
        self.assertEqual(
            set(pr_readiness.mergeability_field_labels()),
            set(pr_readiness.FIELD_LABELS),
        )

    def test_labels_are_read_in_template_order(self) -> None:
        labels = pr_readiness.mergeability_field_labels()
        section = pr_readiness.extract_section(pr_readiness.template_body(), "Mergeability")
        self.assertEqual(labels, sorted(labels, key=section.index))

    def test_unreadable_template_yields_no_labels_rather_than_raising(self) -> None:
        self.assertEqual(
            pr_readiness.mergeability_field_labels(Path("/nonexistent/template.md")), []
        )

    def test_paste_block_has_a_line_for_every_template_field(self) -> None:
        """The paste-ready block CI hands out on failure must never omit a
        field the template (and therefore the gate) requires — that is
        exactly the bug that let the gate demand a field its own guidance
        never mentioned."""
        block = pr_readiness.mergeability_paste_block()
        for label in pr_readiness.mergeability_field_labels():
            self.assertIn(f"- {label}:", block)


class LeadingParagraphTests(unittest.TestCase):
    """The body opens with a paragraph, or the gate says what it opened with.

    Michael, 2026-09-12, on a body that opened with `## Summary` and a bullet:
    "too dense and hard to follow ... Why do I care about this? why did we open
    this pr?" The paragraph is where those get answered, and its position is
    what makes it the first thing read.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def only_paragraph_failure(self, body: str) -> str:
        failures = self.failures(body)
        paragraph = [failure for failure in failures if "paragraph" in failure]
        self.assertEqual(len(paragraph), 1, failures)
        return paragraph[0]

    def test_the_good_body_opens_with_its_paragraph(self) -> None:
        self.assertEqual(self.failures(GOOD_BODY), [])

    def test_a_body_that_opens_on_a_heading_is_refused(self) -> None:
        body = GOOD_BODY[GOOD_BODY.index("## What") :]
        self.assertIn("it opens with a heading", self.only_paragraph_failure(body))

    def test_a_body_that_opens_on_a_list_is_refused(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        body = f"- Improve callback helper maintainability\n\n{rest}"
        self.assertIn("it opens with a list", self.only_paragraph_failure(body))

    def test_a_body_that_opens_on_a_table_or_a_fence_is_refused(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        self.assertIn("a table", self.only_paragraph_failure(f"| a | b |\n| - | - |\n\n{rest}"))
        self.assertIn("a code block", self.only_paragraph_failure(f"```\nswift test\n```\n\n{rest}"))

    def test_the_unedited_template_is_refused(self) -> None:
        """Its guidance is an HTML comment, so the first thing a reader sees is
        a heading — which is what the gate refuses."""
        self.assertIn(
            "it opens with a heading",
            self.only_paragraph_failure(pr_readiness.template_body()),
        )

    def test_a_one_line_opening_is_too_short_to_be_the_paragraph(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        self.assertIn("is 16 characters", self.only_paragraph_failure(f"Fixes the thing.\n\n{rest}"))

    def test_a_short_paragraph_that_says_why_is_enough(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        opening = "Nil userdata crashed one Ghostty callback and not the next; one helper now decides it. Two files."
        self.assertEqual(self.failures(f"{opening}\n\n{rest}"), [])

    def test_a_paragraph_that_opens_on_an_autolink_is_prose(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        self.assertEqual(self.failures(f"<https://example.com> explains the crash. {GOOD_BODY}"), [])
        self.assertIn("an HTML block", self.only_paragraph_failure(f"<details>\n\n{rest}"))

    def test_a_comment_a_browser_closes_at_bang_is_skipped_too(self) -> None:
        self.assertEqual(self.failures(f"<!-- contributor:issue=1621 --!>\n\n{GOOD_BODY}"), [])

    def test_a_heading_under_the_opening_line_ends_the_paragraph(self) -> None:
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        opening = GOOD_BODY[: GOOD_BODY.index("\n\n## What")]
        body = f"Fixes.\n### Details\n{opening}\n\n{rest}"
        self.assertIn("is 6 characters", self.only_paragraph_failure(body))

    def test_a_heading_indented_up_to_three_spaces_still_ends_the_paragraph(self) -> None:
        """CommonMark allows an ATX heading up to three spaces of indent."""
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        opening = GOOD_BODY[: GOOD_BODY.index("\n\n## What")]
        body = f"Fixes.\n ### Details\n{opening}\n\n{rest}"
        self.assertIn("is 6 characters", self.only_paragraph_failure(body))

    def test_an_empty_heading_ends_the_paragraph_too(self) -> None:
        """An ATX heading with no text after the `#`s is still a heading."""
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        opening = GOOD_BODY[: GOOD_BODY.index("\n\n## What")]
        body = f"Fixes.\n###\n{opening}\n\n{rest}"
        self.assertIn("is 6 characters", self.only_paragraph_failure(body))

    def test_a_heading_indented_four_spaces_is_a_code_block_not_a_heading(self) -> None:
        """Four spaces of indent is a code block per CommonMark, and indented
        code can't interrupt a paragraph — so the line stays part of it."""
        rest = GOOD_BODY[GOOD_BODY.index("## What") :]
        opening = GOOD_BODY[: GOOD_BODY.index("\n\n## What")]
        body = f"Fixes.\n    ### not a heading\n{opening}\n\n{rest}"
        text = pr_readiness.pr_body.read_opening(body).text
        self.assertTrue(text.startswith("Fixes. ### not a heading "))
        self.assertNotIn("\n", text)

    def test_the_persona_byline_and_the_review_page_link_sit_above_it(self) -> None:
        body = (
            "*April Clearwater, Application Lead*\n\n"
            "Review page: https://evidence.cloudcompute.com/pr/1621.html\n\n"
            f"{GOOD_BODY}"
        )
        self.assertEqual(self.failures(body), [])

    def test_a_comment_above_the_paragraph_is_not_the_paragraph(self) -> None:
        self.assertEqual(self.failures(f"<!-- contributor:issue=1621 -->\n\n{GOOD_BODY}"), [])

    def test_a_paragraph_wrapped_over_several_lines_is_one_paragraph(self) -> None:
        opening = GOOD_BODY[: GOOD_BODY.index("\n\n## What")]
        self.assertGreater(len(opening.splitlines()), 1)
        self.assertNotIn("\n", pr_readiness.pr_body.read_opening(GOOD_BODY).text)

    def test_the_guidance_shows_the_shape_by_example(self) -> None:
        result = pr_readiness.evaluate(pr("## What\n\n- A thing\n"), self.FILES)
        guidance = pr_readiness.guidance_markdown(result)
        self.assertIn(pr_readiness.LEADING_PARAGRAPH_EXAMPLE, guidance)
        self.assertIn("not a block to paste and fill in", guidance)

    def test_a_draft_is_not_held_to_it(self) -> None:
        result = pr_readiness.evaluate(pr("## What\n", draft=True), self.FILES)
        self.assertEqual(result.failures, [])


if __name__ == "__main__":
    unittest.main()
