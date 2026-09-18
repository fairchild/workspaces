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
import hashlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
import urllib.error
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


# The pending failure's own text, read off the gate where it defines it. The
# fallback is for the red-at-base measurement only: the suite is run with an
# older `pr-readiness.py` swapped in to say which shapes are new and which are
# inherited, and a missing name there would report every expectation as an
# error rather than as the behaviour difference being measured.
PENDING_TEXT = getattr(
    pr_readiness, "PENDING_FAILURE", "Requested evidence is blocked or still pending CI."
)


def pending(matched: str) -> str:
    """The pending failure as the rendered view reports it, naming the line it matched.

    The written view's match is a line the author typed and can find; the
    rendered view's may be a table cell, a decoded reference or the text a raw
    HTML block puts on a line, so when it is the only view that saw one the
    failure carries it (#1736). Every expectation below states the line the
    page shows rather than importing the gate's own answer.
    """
    note = getattr(pr_readiness, "matched_line_note", None)
    return PENDING_TEXT if note is None else f"{PENDING_TEXT} {note(matched)}"


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
        # Which view reports the `[blocked]` line depends on the shadow. An h3
        # is nobody's section, so the written view reads the real heading below
        # it and reports the line the author typed. The two h2 shadows ARE this
        # section to a parse, and the first heading wins, so the written view
        # reads the shadow's own `[complete]` line and the rendered view -- which
        # reads every matching heading -- is the one that sees the `[blocked]`
        # and names the line (#1742). Both refusals stand either way; only
        # which view spoke changes.
        blocked = "[blocked] other -- reconciliation required"
        for shadow, expected in (
            ("### Evidence Status", "Requested evidence is blocked or still pending CI."),
            ("##  Evidence Status", pending(blocked)),
            ("## evidence status ##", pending(blocked)),
        ):
            with self.subTest(shadow=shadow):
                body = (
                    GOOD_BODY
                    + f"\n{shadow}\n- [complete] other -- self-attested\n"
                    + f"\n## Evidence Status\n- {blocked}\n"
                )
                result = pr_readiness.evaluate(pr(body), [])
                self.assertIn(
                    "Ambiguous Evidence Status headings; use at most one exact "
                    "'## Evidence Status' heading and no variants.",
                    result.failures,
                )
                self.assertIn(expected, result.failures)

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
        # reported as pending: both views read the heading GitHub shows since
        # the written view's start became a parse, so the failure is the plain
        # one rather than the rendered view's noted form -- the author's own
        # line is findable by eye (#1742).
        # The paragraph closes the list GOOD_BODY ends on, so the heading is at
        # the top level at each of the three indents rather than nested inside
        # that list's last item, which two or three spaces would otherwise be.
        prose = GOOD_BODY + "\nThat is every blocker.\n"
        waiting = "- [pending-ci] swift test -- waiting"
        complete = "- [complete] swift test -- 1992 tests passed"
        for indent in (" ", "  ", "   "):
            expected_pending = [self.AMBIGUOUS, self.PENDING]
            for line, expected in ((waiting, expected_pending), (complete, [self.AMBIGUOUS])):
                with self.subTest(indent=len(indent), line=line):
                    body = prose + f"\n{indent}## Evidence Status\n{line}\n"
                    self.assertEqual(self.failures(body), expected)

    def test_an_indented_heading_neither_opens_nor_ends_a_section(self) -> None:
        # Three spaces in, directly under this body's list, is inside that
        # list's last item and not a top-level heading at all -- the parser's
        # answer, and the one both readers take. An indent of up to three
        # spaces on its own IS a section since #1742; being nested is what
        # this fixture is about.
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
        self.assertEqual(self.failures(body), [pending("[pending-ci] example")])

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
                self.assertEqual(
                    self.failures(self.body(f"{shape}\n")), [pending("[pending-ci] item -- waiting")]
                )

    def test_a_blocked_token_fails_in_the_same_three_shapes(self) -> None:
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                self.assertEqual(
                    self.failures(self.body(f"{shape.replace('pending-ci', 'blocked')}\n")),
                    [pending("[blocked] item -- waiting")],
                )

    def test_a_crlf_body_fails_on_a_rendered_only_shape(self) -> None:
        # `evaluate` rewrites CR and CRLF to LF before anything reads the body,
        # and reads the section from that same normalized text, so the rendered
        # view sees the shape the author wrote.
        for shape in self.SHAPES:
            with self.subTest(shape=shape):
                body = self.body(f"{shape}\n").replace("\n", "\r\n")
                self.assertEqual(self.failures(body), [pending("[pending-ci] item -- waiting")])

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
                    self.assertEqual(
                        self.failures(self.body(f"{line}\n")),
                        [pending(f"{box.split(' ', 1)[1].strip()} [pending-ci] item -- waiting")],
                    )

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
                self.assertEqual(self.failures(body), [pending("[pending-ci] below -- waiting")])

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
                self.assertEqual(self.failures(self.body(section)), [pending(status)])

    def test_a_status_in_a_paragraph_is_pending(self) -> None:
        # The table is the instance the issue reports; the class is a visible
        # status under the heading that is not a list item.
        for status in ("[blocked]", "[pending-ci]"):
            with self.subTest(status=status):
                section = self.COMPLETE + f"\n{status} release log\n"
                self.assertEqual(self.failures(self.body(section)), [pending(f"{status} release log")])

    def test_a_status_in_a_sub_heading_or_a_quote_is_pending(self) -> None:
        # A sub-heading is inside the section: the read closes at the next h1
        # or h2, so an h3 is a line under the heading like any other, and the
        # owner read in the contributor skill refuses one outright rather than
        # tolerating it.
        for shape in ("### [blocked] release log", "> [blocked] release log"):
            with self.subTest(shape=shape):
                self.assertEqual(
                    self.failures(self.body(self.COMPLETE + f"\n{shape}\n")),
                    [pending("[blocked] release log")],
                )

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
                # The escaped shape is the rendered view's alone, so its
                # failure carries the cell; the other three the written view
                # reads as typed.
                self.assertEqual(
                    self.failures(body), [pending(cell) if "\\" in item else self.PENDING]
                )

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
                self.assertEqual(self.failures(body), [pending("[blocked] item -- waiting")])

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


class HtmlBlockStatusLineTests(unittest.TestCase):
    """A status a raw HTML block puts on the page is a status line (#1736).

    GitHub prints a raw HTML block as itself, so the text between its tags is
    text a reader acts on -- and the parser models no inline inside an
    `html_block`, so the rendered view read nothing there at all. The written
    view caught the shapes its own anchor covers, a list marker in front of the
    token, and missed a bare `[blocked]` line, a `<summary>` and a comment. The
    rendered view now reads each run of text between the block's markup through
    `RENDERED_PENDING_RE`, which can only add refusals to what stands.

    HTML is still never interpreted: taking the markup out of a line is not
    deciding which elements are open, and no run is called visible or hidden.
    Text inside a comment is read, and refusing on `<!-- [blocked] x -->` costs
    an author a minute and costs the gate no soundness, where accepting on it
    would be the hole this closes (#1729).

    The boundary is unchanged, and the `# Notes` line in the issue's own
    reproduction stays inside the section for both views: the page shows no
    heading there -- the block prints those characters as text -- so ending the
    section at that line is what neither view should do. The gap was the status
    below it going unread, not where the section ends.

    Refusing any HTML block under the heading outright, which is the owner read
    in the contributor skill, is not available here: the factory writes its own
    metadata comment as an HTML block, and 13 of the 63 stored bodies with this
    heading carry one.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    PENDING = PendingLineShapeTests.PENDING
    COMPLETE = "- [complete] swift test -- 1992 tests passed\n"

    # The issue's reproduction: no blank line before the block, so `<div>` opens
    # a raw HTML block that runs to the blank line after `</div>`.
    ISSUE_BLOCK = "<div>\n# Notes\n- {status} the UI lane -- a status line\n</div>\n"

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def body(self, section: str) -> str:
        return GOOD_BODY + f"\n## Evidence Status\n{section}"

    def test_the_issue_reproduction_fails_for_either_token(self) -> None:
        # Green before this change as well as after it, and kept as the pin
        # that says so: #1736 was filed against a tree where the written view
        # stopped at the `#` line inside the block, and #1737 landed the
        # parsed boundary the same day, which put the status back inside the
        # section for that view. This shape is now caught twice over.
        for status in ("[blocked]", "[pending-ci]"):
            with self.subTest(status=status):
                self.assertEqual(self.failures(self.body(self.ISSUE_BLOCK.format(status=status))), [self.PENDING])

    def test_the_rendered_view_reads_the_blocks_text_and_leaves_the_boundary_alone(self) -> None:
        # The read reached directly. `# Notes` comes back as one of the block's
        # lines rather than ending the section, because the page prints it as
        # text; the written view keeps it inside the section for the same
        # reason.
        body = self.body(self.ISSUE_BLOCK.format(status="[blocked]"))
        self.assertEqual(
            pr_readiness.rendered_status_lines(body),
            ["# Notes", "- [blocked] the UI lane -- a status line"],
        )
        self.assertIn("[blocked] the UI lane", pr_readiness.extract_section(body, "Evidence Status"))

    def test_a_status_with_no_list_marker_in_a_block_fails(self) -> None:
        # What the written view's anchor cannot reach: it asks for a list
        # marker, and the page shows the line with or without one.
        section = self.COMPLETE + "\n<div>\n[blocked] the UI lane\n</div>\n"
        body = self.body(section)
        # Asserted on the written view's own reading rather than through the
        # gate: the conjunction of refusals lets one view answer for a line the
        # other cannot see, so a verdict alone cannot tell the two apart.
        written = pr_readiness.extract_section(body, "Evidence Status", strip=False)
        self.assertIn("[blocked] the UI lane", written)
        self.assertIsNone(pr_readiness.PENDING_STATUS_RE.search(written))
        self.assertEqual(self.failures(body), [pending("[blocked] the UI lane")])

    def test_a_status_inside_a_tag_pair_on_one_line_fails(self) -> None:
        # `<details>` renders its summary, so the reader sees the status; the
        # line's own text opens with a tag, which is why reading the source
        # line whole would miss it.
        for block in (
            "<details><summary>[blocked] the UI lane</summary></details>\n",
            "<details>\n<summary>[blocked] the UI lane</summary>\n</details>\n",
            "<table>\n<tr><td>[pending-ci]</td><td>the UI lane</td></tr>\n</table>\n",
        ):
            with self.subTest(block=block.splitlines()[0]):
                shown = "[pending-ci]" if block.startswith("<table") else "[blocked] the UI lane"
                self.assertEqual(
                    self.failures(self.body(self.COMPLETE + "\n" + block)), [pending(shown)]
                )

    def test_a_status_inside_a_comment_refuses(self) -> None:
        # A comment renders as nothing, and the rule is that invisible text may
        # refuse and may never accept: the gate does not weigh what is visible,
        # so a hidden `[blocked]` fails rather than passing quietly.
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n<!-- [blocked] hidden -->\n")),
            [pending("[blocked] hidden")],
        )

    def test_a_comment_ends_at_an_abrupt_closer_too(self) -> None:
        # A browser ends a comment at `--!>` as well as at `-->`, so the text
        # after one is on the page while a reader of `-->` alone still has it
        # inside the comment. The contributor skill refuses a metadata block
        # carrying `--!>` for the same reason. Found by CodeQL
        # (`py/bad-tag-filter`, high) on the first push.
        block = "<!-- a note --!> [blocked] the UI lane -->\n"
        # The trailing `-->` is on the line too: the comment already closed at
        # the `--!>`, so those three characters are text a reader sees. A
        # delimiter with no comment open is not a delimiter (#1736).
        self.assertIn(
            "[blocked] the UI lane -->", pr_readiness.rendered_status_lines(self.body(block))
        )
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + block)),
            [pending("[blocked] the UI lane -->")],
        )

    def test_a_block_of_complete_text_passes(self) -> None:
        for block in (
            "<div>\n- [complete] the UI lane -- swift test passed\n</div>\n",
            "<div>\n[complete] the UI lane -- swift test passed\n</div>\n",
            "<div>\nsee the [blocked] label on the issue for context\n</div>\n",
        ):
            with self.subTest(block=block.splitlines()[1]):
                self.assertEqual(self.failures(self.body(block)), [])

    def test_a_character_reference_inside_a_block_is_the_character_it_shows(self) -> None:
        # A browser decodes a character reference inside raw HTML, so
        # `&#91;blocked&#93;` is a visible `[blocked]` on the page -- the same
        # writing #1706 was filed for, in the one place the parser does not
        # decode it for us. Found by codex (gpt-5.6-sol, xhigh).
        for token in ("&#91;blocked&#93;", "&lbrack;pending-ci&rbrack;", "&#x5B;blocked&#x5D;"):
            with self.subTest(token=token):
                block = f"<div>\n{token} the UI lane\n</div>\n"
                shown = "[pending-ci] the UI lane" if "pending-ci" in token else "[blocked] the UI lane"
                self.assertEqual(
                    self.failures(self.body(self.COMPLETE + "\n" + block)), [pending(shown)]
                )

    def test_a_status_split_across_tags_on_one_line_is_read_whole(self) -> None:
        # Markup inside a line shows nothing, so the page puts
        # `<span>[block</span><strong>ed]</strong> the UI lane` on one line
        # reading `[blocked] the UI lane`. Run by run each piece is a fragment
        # and neither anchors, which is why the line is also read with its
        # markup joined out. Found by codex (gpt-5.6-sol, xhigh).
        block = "<div><span>[block</span><strong>ed]</strong> the UI lane</div>\n"
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + block)),
            [pending("[blocked] the UI lane")],
        )
        self.assertIn("[blocked] the UI lane", pr_readiness.rendered_status_lines(self.body(block)))

    def test_an_inline_tag_does_not_start_a_line_and_a_block_tag_does(self) -> None:
        # The line this model draws, in one pair. `<span>` shows nothing of its
        # own, so the page puts `Context: [blocked] is a label` on one line
        # that does not open with a status -- and an earlier reading, which cut
        # at every tag, refused it. `<td>` is a cell, which is a line a reader
        # really does see on its own, so the status at its head is one.
        for shape in (
            "<div>Context: <span>[blocked] is a label</span></div>\n",
            "<div>Context: [blocked] is a label on the issue</div>\n",
            "<div>Context: <code>[blocked]</code> is a label</div>\n",
        ):
            with self.subTest(shape=shape.strip()):
                self.assertEqual(self.failures(self.body(self.COMPLETE + "\n" + shape)), [])
        cell = "<table>\n<tr><td>Context</td><td>[blocked] the UI lane</td></tr>\n</table>\n"
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + cell)),
            [pending("[blocked] the UI lane")],
        )

    def test_a_block_inside_a_quote_is_read(self) -> None:
        # The block is nested one level inside the quote and renders on the
        # page like any other. Found by codex (gpt-5.6-sol, xhigh).
        section = self.COMPLETE + "\n> <div>\n> [blocked] the UI lane\n> </div>\n"
        self.assertEqual(self.failures(self.body(section)), [pending("[blocked] the UI lane")])

    def test_the_factory_metadata_comment_is_not_a_status_line(self) -> None:
        # The factory writes its own evidence metadata as an HTML block, and a
        # stored entry's status is a JSON value rather than a line that opens
        # with `[blocked]`. It is read like any other block -- no shape of it is
        # special-cased -- and trips nothing, in both the shapes the writer
        # emits. This is a control and passes at the merge base too; the test
        # below is the one that says why it stays true.
        payload = '{"entries": [{"index": 1, "item": "the UI lane", "status": "blocked", "detail": "[blocked] waiting"}]}'
        indented = (
            "{\n"
            '  "entries": [\n'
            "    {\n"
            '      "item": "the UI lane",\n'
            '      "status": "blocked",\n'
            '      "detail": "[blocked] waiting"\n'
            "    }\n"
            "  ]\n"
            "}"
        )
        for name, body_text in (("compact", payload), ("indented", indented)):
            with self.subTest(payload=name):
                block = f"<!-- evidence-status:v1\n{body_text}\n-->\n"
                self.assertEqual(self.failures(self.body(self.COMPLETE + "\n" + block)), [])

    SKILL_SCRIPTS = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
    METADATA_OPENER = "<!-- evidence-status:v"

    def evidence_writer(self, scripts_dir: Path | None = None):
        """The skill's evidence writer, loaded by path, with its one local import pre-registered.

        `evidence.py` opens with `from _helpers import ...`, and putting the
        skill's directory on `sys.path` to satisfy that would leave it there
        for every later test in the run -- the care `ParserDefinitionTests`
        takes when it loads `_helpers` on its own. Registering the module under
        the name the import asks for satisfies it without a path search, and
        the name comes back off `sys.modules` afterwards.
        """
        scripts_dir = scripts_dir or self.SKILL_SCRIPTS
        restore = sys.modules.get("_helpers")
        try:
            modules = {}
            for name, path in (("_helpers", "_helpers.py"), ("contributor_evidence", "evidence.py")):
                spec = importlib.util.spec_from_file_location(name, scripts_dir / path)
                assert spec and spec.loader
                modules[name] = importlib.util.module_from_spec(spec)
                sys.modules[name] = modules[name]
                spec.loader.exec_module(modules[name])
            return modules["contributor_evidence"]
        finally:
            # Both names go: the loader borrows `_helpers` so the writer's own
            # import resolves, and registers the writer under a name of its
            # own. Leaving either behind hands the next loader in this process
            # a module it did not load.
            sys.modules.pop("contributor_evidence", None)
            sys.modules.pop("_helpers", None)
            if restore is not None:
                sys.modules["_helpers"] = restore

    def shown_status_section(self, body: str) -> tuple[int, int]:
        """Where the `## Evidence Status` section the page shows starts and ends, in characters.

        The heading is asked of the parser rather than matched, so a `## `
        line inside a fenced example is not it -- which is the distinction the
        writer's own placement turns on.
        """
        lines = body.split("\n")
        starts, offset = [], 0
        for line in lines:
            starts.append(offset)
            offset += len(line) + 1
        starts.append(offset)
        tokens = pr_readiness.MARKDOWN.parse(body)
        for index, token in enumerate(tokens):
            if not (token.type == "heading_open" and token.tag == "h2" and token.level == 0):
                continue
            text = pr_readiness.rendered_inline_text(tokens[index + 1].children)
            if " ".join(text.split()).casefold() != "evidence status":
                continue
            end = next(
                (
                    later.map[0]
                    for later in tokens[index + 3 :]
                    if later.map and pr_readiness.section_boundary_token(later)
                ),
                len(lines),
            )
            return starts[token.map[0]], starts[end]
        raise AssertionError("the page shows no `## Evidence Status` heading")

    def test_the_metadata_comment_cannot_anchor_and_the_writer_places_it_above(self) -> None:
        # Two claims, and the first is stronger than it was. Round two had the
        # metadata comment unreachable only by PLACEMENT -- a detail an author
        # supplied could carry HTML and anchor if the comment ever sat under
        # the heading (codex, gpt-5.6-sol xhigh). It cannot now, for a reason
        # that does not depend on placement at all.
        #
        # Nothing inside a comment is markup: a comment's content is text, so
        # a `<div>` in a detail an author supplied starts no line and the
        # payload's own lines open on a brace or a quote. Under the heading or
        # above it, the metadata comment cannot anchor. That is stronger than
        # the round-2 reading, which had it unreachable only by placement.
        detail = '<div>[blocked] quoted</div>'
        under = f'<!-- evidence-status:v1\n{{"entries": [{{"item": "x", "detail": "{detail}"}}]}}\n-->\n'
        self.assertEqual(self.failures(self.body(self.COMPLETE + "\n" + under)), [])

        # What makes that unreachable is placement, so placement is what is
        # asserted -- by calling the writer, not by pinning a line of its
        # source. The source form is a moving target: #1739 rewrites this very
        # placement to find the heading through the parser, and a test pinned to
        # the string on `main` would go red whichever of the two merged second.
        # The behaviour is the same on both, and that is what the guard needs.
        evidence = self.evidence_writer()
        payload = {"entries": {"the UI lane": {"status": "complete", "detail": detail}}}
        plain = "Why this exists.\n\n## Evidence Status\n\n- [complete] the UI lane -- proof\n"
        fenced = (
            "Why this exists.\n\n## What\n\n```markdown\n## Evidence Status\n\n- [complete] example\n```\n"
            "\n## Evidence Status\n\n- [complete] the UI lane -- proof\n"
        )
        for name, body in (("plain", plain), ("a fenced example above the real heading", fenced)):
            with self.subTest(body=name):
                written = evidence._insert_evidence_metadata(body, payload)
                start, end = self.shown_status_section(written)
                self.assertLess(written.index(self.METADATA_OPENER), start)
                self.assertNotIn(self.METADATA_OPENER, written[start:end])
                # And so the gate has nothing to refuse in a body the factory
                # wrote, HTML in the detail and all.
                self.assertEqual(
                    [
                        line
                        for line in pr_readiness.rendered_status_lines(written)
                        if pr_readiness.RENDERED_PENDING_RE.match(line)
                    ],
                    [],
                )

    def test_a_line_the_page_shows_whole_is_not_four_lines(self) -> None:
        """The four over-refusals a lexical tag cut produced, each a body with nothing pending (#1736).

        Every one of these passed at the merge base and refused at the head
        this round answers, and the author got "Requested evidence is blocked
        or still pending CI." on a body a reader sees no pending status in.
        Each is the same mistake: a cut that is not a line start.
        """
        for label, block in (
            # An unknown tag shows nothing, so the sanitizer drops `<T>` and
            # the text stays on one line, with the status mid-line.
            ("an unknown inline tag", "<div>\nAPI note: Vec<T> [blocked] names an enum case\n</div>\n"),
            # No comment is open, so `-->` is three characters of prose.
            ("a bare comment closer", "<div>\nbase --> [blocked] head is the comparison\n</div>\n"),
            # The `>` is inside a quoted attribute value; the page shows the
            # element's text and nothing of the attribute.
            (
                "a `>` inside an attribute",
                '<div title="CI result > [blocked] threshold">All checks complete</div>\n',
            ),
            # Two boxes on the page. Joining their text invented a line start
            # between them.
            ("two blocks on one source line", "<div>[block</div><div>ed] the UI lane</div>\n"),
            (
                "two cells on one source line",
                "<table>\n<tr><td>[block</td><td>ed] the UI lane</td></tr>\n</table>\n",
            ),
        ):
            with self.subTest(shape=label):
                self.assertEqual(self.failures(self.body(self.COMPLETE + "\n" + block)), [])

    def test_a_comment_that_closes_as_it_opens_leaves_its_tail_on_the_page(self) -> None:
        # `<!-->` and `<!--->` are HTML's abrupt-closing comments, the same
        # class as the `--!>` already handled: the text after them is on the
        # page and was inside a comment for this reader. Inherited -- it passed
        # at the merge base and at the head this round answers.
        for opener in ("<!-->", "<!--->"):
            with self.subTest(opener=opener):
                block = f"{opener}[blocked] the UI lane is visible\n"
                self.assertEqual(
                    self.failures(self.body(self.COMPLETE + "\n" + block)),
                    [pending("[blocked] the UI lane is visible")],
                )

    def test_a_reference_that_decodes_to_a_newline_makes_two_lines(self) -> None:
        # `&#10;` is a line break on the page, so the status after it is at a
        # line start. Decoding after the split left it inside a run that was
        # never split again, and the anchor never saw it. Inherited, like the
        # abrupt closer above.
        block = "<pre>complete&#10;[blocked] visible</pre>\n"
        self.assertIn("[blocked] visible", pr_readiness.rendered_status_lines(self.body(block)))
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + block)),
            [pending("[blocked] visible")],
        )

    def test_the_refusal_names_the_line_the_page_shows(self) -> None:
        """A refusal the author cannot see in what they wrote says what it matched.

        The written view's match is a line as typed, so the failure stands
        alone. The rendered view's may be a table cell, a decoded reference or
        the text a raw HTML block puts on a line -- and a false positive there
        was unreadable: the same sentence whether the gate had matched the
        author's own `[blocked]` or a run it had cut out of an attribute. It
        names the run now, so a disagreement is one read to settle.
        """
        rendered_only = self.body(self.COMPLETE + "\n<div>\n[blocked] the UI lane\n</div>\n")
        self.assertEqual(
            self.failures(rendered_only),
            ['Requested evidence is blocked or still pending CI. '
             'The page shows this line under the heading: "[blocked] the UI lane".'],
        )
        # Written view: the line is in the section as typed, so no run is named.
        written = self.body("- [pending-ci] the UI lane -- waiting\n")
        self.assertEqual(self.failures(written), [PENDING_TEXT])
        # A long run is cut rather than pasted whole into a comment bullet.
        long_line = "[blocked] " + "the UI lane " * 30
        block = f"<div>\n{long_line}\n</div>\n"
        named = self.failures(self.body(self.COMPLETE + "\n" + block))[0]
        self.assertLess(len(named), len(long_line))
        self.assertIn("\u2026", named)

    def test_a_block_below_the_section_is_not_read(self) -> None:
        for tail in ("\n# Notes\n", "\n## Notes\n", "\n---\n"):
            with self.subTest(tail=tail.strip()):
                body = self.body(self.COMPLETE + tail + "<div>\n- [blocked] not this section's\n</div>\n")
                self.assertEqual(pr_readiness.rendered_status_lines(body), [self.COMPLETE.strip()[2:]])
                self.assertEqual(self.failures(body), [])

    def test_a_block_inside_a_fence_is_still_an_example(self) -> None:
        # A fenced block is a code block to the parser, with no `html_block`
        # token and no inline of its own, which is what both views say of every
        # other fenced line.
        section = self.COMPLETE + "\n```markdown\n<div>\n[blocked] example\n</div>\n```\n"
        body = self.body(section)
        self.assertEqual(pr_readiness.rendered_status_lines(body), [self.COMPLETE.strip()[2:]])
        self.assertEqual(self.failures(body), [])

    def test_a_block_above_the_heading_is_not_read(self) -> None:
        body = GOOD_BODY + "\n<div>\n[blocked] above the heading\n</div>\n\n## Evidence Status\n" + self.COMPLETE
        self.assertEqual(pr_readiness.rendered_status_lines(body), [self.COMPLETE.strip()[2:]])
        self.assertEqual(self.failures(body), [])

    def test_a_fence_inside_a_block_is_not_a_fence_on_the_page(self) -> None:
        # Markdown is not processed inside a raw HTML block, so the backticks
        # and the line under them are characters the page prints. The written
        # view's line scanner cannot see the block it is in and takes the
        # opener for a fence -- stripping the example on the closed shape, and
        # reporting an unclosed fence on the other. The rendered view reads the
        # block's own lines either way, which is what makes the status visible
        # to the gate on both.
        opener, status = "```markdown", "[blocked] printed as raw HTML"
        closed = f"<div>\n{opener}\n{status}\n```\n</div>\n"
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + closed)),
            [pending(status)],
        )
        unclosed = f"<div>\n{opener}\n{status}\n</div>\n"
        self.assertEqual(
            self.failures(self.body(self.COMPLETE + "\n" + unclosed)),
            [
                f'Evidence Status opens a code fence that never closes: "{opener}". '
                "Close it so the status lines after it are read.",
                pending(status),
            ],
        )

    def test_a_heading_a_block_swallows_does_not_end_the_section(self) -> None:
        # An HTML block runs to a blank line, so a `## Notes` line inside one is
        # characters the block prints rather than a heading. Neither view ends
        # the section there -- the parser models no heading token, and that is
        # the page's answer too -- so the status under it is this section's and
        # fails the gate.
        section = self.COMPLETE + "\n<div>\n## Notes\n[blocked] under a line that only looks like a heading\n"
        body = self.body(section)
        self.assertEqual(
            pr_readiness.rendered_status_lines(body),
            [
                self.COMPLETE.strip()[2:],
                "## Notes",
                "[blocked] under a line that only looks like a heading",
            ],
        )
        self.assertEqual(
            self.failures(body),
            [pending("[blocked] under a line that only looks like a heading")],
        )

    def test_a_block_nested_in_a_list_item_is_read_too(self) -> None:
        # The walk reads every line under the heading whatever depth it sits
        # at, the way it already reads an inline inside a quote or an item, and
        # an indented block renders on the page like any other.
        section = self.COMPLETE + "\n- the UI lane\n\n  <div>\n  [blocked] still waiting\n  </div>\n"
        self.assertEqual(self.failures(self.body(section)), [pending("[blocked] still waiting")])

    # CommonMark's own HTML-block start conditions, kept here as the spec's
    # text so the set is derived from something a reader can check rather than
    # from a list somebody typed. Condition 1 opens a block that runs to its
    # own closer; condition 6 is the long list of block-level names. `br` is
    # neither and is a line break.
    COMMONMARK_CONDITION_1 = "pre script style textarea"
    COMMONMARK_CONDITION_6 = """address article aside base basefont blockquote body caption
    center col colgroup dd details dialog dir div dl dt fieldset figcaption figure footer form
    frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu
    menuitem nav noframes ol optgroup option p param search section summary table tbody td
    tfoot th thead title tr track ul"""

    def test_the_line_starting_tags_are_conditions_one_and_six_plus_br(self) -> None:
        """The set's derivation, stated and checked (#1736, round 4).

        It was condition 6 plus `br`, described as "CommonMark's own list of
        block tags" -- which left out condition 1, four tags that open a block
        of their own. `<div>note<pre>[blocked] x</pre></div>` read as one run
        and accepted, where GitHub renders the `<pre>` as its own block.
        """
        expected = (
            set(self.COMMONMARK_CONDITION_1.split())
            | set(self.COMMONMARK_CONDITION_6.split())
            | {"br"}
        )
        self.assertEqual(set(pr_readiness.LINE_STARTING_TAGS), expected)
        for tag in self.COMMONMARK_CONDITION_1.split():
            with self.subTest(tag=tag):
                self.assertIn(tag, pr_readiness.LINE_STARTING_TAGS)

    def test_a_condition_one_tag_inside_another_block_starts_its_own_line(self) -> None:
        # The regression: `pre` was not a line start, so the run before it and
        # the status after it were one line and the anchor missed.
        self.assertEqual(
            pr_readiness.html_block_text_lines("<div>note<pre>[blocked] x</pre></div>"),
            ["note", "[blocked] x"],
        )
        self.assertEqual(
            pr_readiness.html_block_text_lines("<pre>context</pre><pre>[blocked] x</pre>"),
            ["context", "[blocked] x"],
        )

    # A `<...>` GitHub's parser takes and this grammar does not. Each renders
    # with the status on a line of its own, and each was accepted because the
    # unparsed text sat in front of it.
    UNPARSED_TAGS = {
        "two attributes with no space between them": '<div a="1"b="2">[blocked] x</div>',
        "an attribute with an empty value": "<div title=>[blocked] x</div>",
        "a slash inside the name": "<div a/b>[blocked] x</div>",
        "a quote inside an unquoted value": '<div title=a"b>[blocked] x</div>',
        "a namespaced name": "<x:y>[blocked] x</x:y>",
    }

    def test_a_tag_this_grammar_cannot_parse_is_read_both_ways(self) -> None:
        """The arc's rule made concrete: uncertain reads refuse (#1736, round 4).

        This model lives on the refusing side, so where it cannot tell what the
        page does it reads the body under every plausible reading and refuses
        if any of them anchors a status. Round 3 put it on the accepting side
        by mistake -- an unparsed `<...>` stayed as text, the status sat behind
        it, and nothing refused.

        The over-refusals this brings back land on malformed markup alone, and
        each names the run it matched, which is the cost the rule accepts.
        """
        for name, under in self.UNPARSED_TAGS.items():
            with self.subTest(shape=name):
                failures = self.failures(self.body(f"{under}\n"))
                pending = [text for text in failures if text.startswith(self.PENDING)]
                self.assertEqual(len(pending), 1, failures)
                self.assertIn('"[blocked] x"', pending[0])

    def test_well_formed_markup_is_read_once_and_still_accepted(self) -> None:
        # The bound on the second reading: it fires only where a `<...>` opens
        # like a tag and parses as none. Round 2's three over-refusals are the
        # control, and each is a shape this grammar DOES parse or does not take
        # for a tag at all.
        for name, under in (
            ("a generic mid-line", "- [complete] the `Vec<T>` case -- ok, nothing [blocked] here"),
            ("a bare comment closer", "- [complete] base --> head -- ok, nothing [blocked] here"),
            (
                "a status inside a quoted attribute",
                '<div title="CI result > [blocked] threshold">all good</div>',
            ),
        ):
            with self.subTest(shape=name):
                self.assertEqual(
                    [
                        text
                        for text in self.failures(self.body(f"{under}\n"))
                        if text.startswith(self.PENDING)
                    ],
                    [],
                )
        self.assertFalse(pr_readiness._holds_an_unparsed_tag("<div>ok</div>"))
        self.assertFalse(pr_readiness._holds_an_unparsed_tag("a < b and c > d"))
        self.assertTrue(pr_readiness._holds_an_unparsed_tag("<div title=>x</div>"))

    def test_a_carriage_return_reference_is_a_line_break_too(self) -> None:
        # `&#10;` was split and `&#13;` was not, so a status after one stayed
        # mid-run for this reader and started a line on the page.
        self.assertEqual(
            pr_readiness.html_block_text_lines("<div>a&#13;[blocked] x</div>"),
            ["a", "[blocked] x"],
        )
        self.assertEqual(
            pr_readiness.html_block_text_lines("<div>a&#13;&#10;[blocked] x</div>"),
            ["a", "[blocked] x"],
        )
        self.assertEqual(
            pr_readiness.html_block_text_lines("<div>a&#10;[blocked] x</div>"),
            ["a", "[blocked] x"],
        )

    def test_the_scan_is_linear_in_the_block(self) -> None:
        """A gate a body can make hang is a gate an author bypasses by timeout.

        The attribute name allowed a `<`, so `<div <div <div ...` matched one
        attribute per repetition and then backtracked over all of them at every
        offset: 50 KB took 13 seconds at `2a0261c6` where 1 KB took 0.005. The
        bound here is generous on purpose -- what it catches is a return to
        quadratic time, not a slow machine.
        """
        payload = "<div " * (50 * 1024 // 5)
        started = time.monotonic()
        pr_readiness.html_block_text_lines(payload)
        self.assertLess(time.monotonic() - started, 1.0)

RENDERED_FIXTURES = REPO_ROOT / "scripts" / "tests" / "fixtures" / "rendered"
RENDERED_INDEX = RENDERED_FIXTURES / "index.json"
RECORD_ENV = "WORKSPACES_RECORD_RENDERED"
RECORD_COMMAND = (
    f"{RECORD_ENV}=1 GH_TOKEN=$(gh auth token) "
    "uv run --script scripts/tests/test_pr_readiness.py"
)


# Captured before `setUpModule` refuses the renderer for the whole file: the
# recorder and the staleness check are the two places that DO ask GitHub, and
# they ask the real function rather than the suite's refusal of it.
#
# Absent on a tree whose gate has no renderer, which is the red-at-base
# measurement: the suite is run with an older `pr-readiness.py` swapped in to
# say which shapes are new, and refusing a function that is not there would
# error the whole file instead of failing the tests being measured.
_LIVE_RENDER = getattr(pr_readiness, "render_markdown", None)


def rendered_fixture_path(text: str) -> Path:
    """Where the recorded answer for one body lives: its sha256, as HTML."""
    return RENDERED_FIXTURES / f"{hashlib.sha256(text.encode('utf-8')).hexdigest()}.html"


def rendered_index() -> dict[str, str]:
    """Which body each recording answers, so a stale one can be re-asked.

    The file name is a hash and a hash goes one way, so the source text is kept
    beside the recordings. Without it nothing could re-render what was recorded
    and the fixtures would age against the renderer with no way to notice.
    """
    if not RENDERED_INDEX.is_file():
        return {}
    return json.loads(RENDERED_INDEX.read_text(encoding="utf-8"))


def record_rendered(text: str) -> str:
    """Ask the live renderer once and store what it said under this body's hash."""
    rendered = _LIVE_RENDER(text)
    RENDERED_FIXTURES.mkdir(parents=True, exist_ok=True)
    rendered_fixture_path(text).write_text(rendered, encoding="utf-8")
    index = rendered_index()
    index[hashlib.sha256(text.encode("utf-8")).hexdigest()] = text
    RENDERED_INDEX.write_text(
        json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return rendered


@contextlib.contextmanager
def recorded_page():
    """Answer the gate from checked-in renderer responses instead of the network.

    Every other test in this file runs with the renderer refused outright
    (`setUpModule`), so the suite reaches no network whether or not a token is
    in the environment, and the gate takes the same fallback a laptop takes.
    A test that needs the page's own answer wraps itself in this.

    A body with no recording fails naming the command that records it: a
    recording is a file someone committed after reading it, not something a
    test run invents, and a run that quietly recorded its own fixtures would
    assert whatever the renderer did that day.
    """

    if _LIVE_RENDER is None:
        yield
        return

    def answer(text: str) -> str:
        path = rendered_fixture_path(text)
        if path.is_file():
            return path.read_text(encoding="utf-8")
        if os.environ.get(RECORD_ENV):
            return record_rendered(text)
        raise AssertionError(
            f"No recorded renderer response for this body ({path.name}). Record it with:\n"
            f"  {RECORD_COMMAND}"
        )

    with (
        mock.patch.object(pr_readiness, "render_markdown", side_effect=answer),
        mock.patch.dict(pr_readiness._PAGE_VIEWS, {}, clear=True),
    ):
        yield


_RENDERER_REFUSED = None
SUITE_UNVERIFIED = "the suite does not reach the renderer"


def setUpModule() -> None:
    """No test in this file reaches the network.

    The gate asks GitHub to render a body, and a suite that let that call out
    would be slow, would spend a rate limit, and would answer differently on a
    laptop with a token and in a sandbox without one. So the renderer is
    refused for the whole file and the tests that need its answer opt back in
    through `recorded_page`, which reads what was recorded.
    """
    global _RENDERER_REFUSED
    if _LIVE_RENDER is None:
        return

    def refuse(text: str) -> str:
        raise pr_readiness.RendererUnavailable(SUITE_UNVERIFIED)

    _RENDERER_REFUSED = mock.patch.object(pr_readiness, "render_markdown", side_effect=refuse)
    _RENDERER_REFUSED.start()


def tearDownModule() -> None:
    if _RENDERER_REFUSED is not None:
        _RENDERER_REFUSED.stop()


class ThePageSaysWhereALineStartsTests(unittest.TestCase):
    """The rendered view asks GitHub where a line starts instead of modelling it (#1745).

    The source model answers one question -- where does a line start on the
    page? -- with a tag grammar, a block-element list and comment state, and
    every round of #1736 added a fixture to it. `POST /markdown` answers the
    same question with the HTML the pull request page will show, and a line
    start read off that HTML needs none of the three.

    The two are a conjunction of refusals, so the renderer only ever ADDS
    refusals. That is the whole safety argument and it has a consequence worth
    stating: the model's over-refusals survive. `<x:y>[blocked] x</x:y>`
    renders as one literal line the page opens with `<x:y>`, so the page would
    accept it and the gate still refuses, because a reader on the refusing side
    may add refusals and may never take one away (#1729).

    What the renderer brings are the four shapes of #1755, where a block-level
    tag sits after prose inside one paragraph: the source model drops the
    parsed tag and keeps the text either side on one line, and the page starts
    a new line at the tag.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]

    # Each accepts on `main` while the page shows the status at a line start.
    SHAPES = {
        "a div after prose": "Context <div>[blocked] x</div>",
        "a pre after prose": "Context <pre>[blocked] x</pre>",
        "a break after prose": "Context <br>[blocked] x",
        "a break inside a list item": "- complete <br>[blocked] x",
    }

    def body(self, section: str) -> str:
        return GOOD_BODY + f"\n## Evidence Status\n\n{section}\n"

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def result(self, body: str):
        return pr_readiness.evaluate(pr(body), self.FILES)

    def test_a_block_tag_after_prose_starts_a_line_the_page_shows(self) -> None:
        for shape, section in self.SHAPES.items():
            with self.subTest(shape=shape), recorded_page():
                failures = self.failures(self.body(section))
                self.assertTrue(
                    any(pr_readiness.PENDING_FAILURE in failure for failure in failures),
                    f"{shape}: {failures}",
                )

    def test_the_refusal_names_the_line_as_the_page_shows_it(self) -> None:
        with recorded_page():
            failures = self.failures(self.body(self.SHAPES["a div after prose"]))
        self.assertIn(pr_readiness.matched_line_note("[blocked] x"), failures[0])

    def test_the_same_shapes_are_accepted_when_the_page_went_unread(self) -> None:
        # The fallback, stated as the cost it is: with no renderer the gate
        # stands on the source model, which does not see these, and it says so
        # rather than passing quietly.
        for shape, section in self.SHAPES.items():
            with self.subTest(shape=shape):
                result = self.result(self.body(section))
                self.assertEqual(result.failures, [])
                self.assertTrue(
                    any("rendered view unverified" in notice.lower() for notice in result.notices),
                    result.notices,
                )

    def test_a_status_the_model_over_refuses_stays_refused(self) -> None:
        # `<x:y>` is not a tag this grammar parses, so the model reads the
        # block both ways and refuses under the reading where it is one. The
        # page shows the whole thing as one literal line and would accept.
        # The model is a refuser, so the refusal stands (#1755, #1729).
        section = "<x:y>[blocked] x</x:y>"
        with recorded_page():
            failures = self.failures(self.body(section))
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures))

    def test_a_status_neither_reader_anchors_stays_accepted(self) -> None:
        # Part A's three over-refusals, closed in round 4 of #1736 and left
        # closed: the page agrees with the model that each of these is one
        # line with the token in the middle of it.
        for shape, section in {
            "a type parameter mid-line": "<div>API note: Vec<T> [blocked] names an enum case</div>",
            "a bare arrow in prose": "<div>base --> [blocked] head is the merge</div>",
            "a status inside an attribute": (
                '<div title="CI result > [blocked] threshold">All checks complete</div>'
            ),
        }.items():
            with self.subTest(shape=shape), recorded_page():
                self.assertEqual(self.failures(self.body(section)), [])

    def test_a_plain_status_line_is_refused_by_both(self) -> None:
        with recorded_page():
            self.assertTrue(self.failures(self.body("- [blocked] the UI lane")))

    def test_a_fenced_example_is_not_a_status_on_the_page_either(self) -> None:
        # A fenced block, an indented block and a code span all reach the page
        # inside `<code>`, which this reader does not read: the written view
        # already drops fenced code, and reading it here would refuse a
        # documentation example that quotes a status (#1742, item 1).
        with recorded_page():
            self.assertEqual(self.failures(self.body("```\n- [blocked] x\n```")), [])

    def test_a_code_block_contributes_no_line_to_this_reader(self) -> None:
        # Asserted on the lines rather than on the verdict, because an
        # INDENTED block is still refused by the written view: that view reads
        # the section as typed and strips only fenced blocks. Unchanged here,
        # and the page adds no refusal of its own to it either way.
        for shape, section in {
            "a fence": "```\n- [blocked] x\n```",
            "an indented block": "    - [blocked] x",
        }.items():
            with self.subTest(shape=shape), recorded_page():
                page = pr_readiness.page_view(self.body(section))
                self.assertEqual(page.unverified, None)
                self.assertEqual(
                    [line for line in page.lines if pr_readiness.RENDERED_PENDING_RE.match(line)],
                    [],
                )

    def test_a_code_span_is_text_the_page_shows(self) -> None:
        # The other half of the same distinction: a span is ordinary text in a
        # sentence, and the `<pre>` around a block is what marks the block as
        # someone's example. Dropping both let a status the page prints at the
        # start of its own line through (#1745, round 2).
        with recorded_page():
            page = pr_readiness.page_view(self.body("- `[blocked]` x"))
        self.assertEqual(page.unverified, None)
        self.assertIn("[blocked] x", page.lines)

    def test_a_code_span_status_is_still_refused_by_the_model(self) -> None:
        # The page reader drops it with the rest of `<code>`; the source model
        # reads a code span as the text it shows, and one reader is enough.
        with recorded_page():
            self.assertTrue(self.failures(self.body("- `[blocked]` x")))


class ThePageReaderMayOnlyAddRefusalsTests(unittest.TestCase):
    """Three ways the page reader answered a smaller question than it claimed (#1745, round 2).

    Each is the same failure: the reader stopped reading somewhere the page
    keeps showing text, so a status at the start of a line reached neither
    view and the body passed. A reader that may only ADD refusals cannot
    afford to stop early anywhere, and the mirror -- reading further than the
    written view does -- costs a refusal that names its line.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    BR_STATUS = "Context <br>[blocked] x"

    def body(self, section: str) -> str:
        return GOOD_BODY + f"\n## Evidence Status\n\n{section}\n"

    def failures(self, body: str) -> list[str]:
        return pr_readiness.evaluate(pr(body), self.FILES).failures

    def test_a_rule_does_not_end_the_section_on_the_page(self) -> None:
        # A rule of asterisks reaches the page as the same `<hr>` a dash rule
        # does, and the source model runs past that one on purpose -- so
        # ending here meant the status below it was read by nobody.
        for shape, rule in {"asterisks": "***", "underscores": "___"}.items():
            with self.subTest(rule=shape), recorded_page():
                failures = self.failures(self.body(f"{rule}\n\n{self.BR_STATUS}"))
                self.assertTrue(
                    any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures
                )

    def test_a_dash_rule_is_the_mirror_and_refuses_too(self) -> None:
        # The cost of the line above, stated rather than left to be found: the
        # written view stops at a dash rule and this reader does not, so a
        # status below `---` under this heading draws a refusal from the page
        # alone. It fails closed and the message quotes the line.
        with recorded_page():
            failures = self.failures(self.body(f"---\n\n{self.BR_STATUS}"))
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)
        self.assertIn(pr_readiness.matched_line_note("[blocked] x"), failures[0])

    def test_a_code_span_at_a_line_start_is_a_status(self) -> None:
        with recorded_page():
            failures = self.failures(self.body("Context <br>`[blocked]` x"))
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)

    def test_a_quoted_heading_inside_the_section_does_not_end_it(self) -> None:
        # `> ## Note` is a heading in a quotation, not one of this document's.
        with recorded_page():
            failures = self.failures(self.body(f"> ## Note\n\n{self.BR_STATUS}"))
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)

    def test_a_quoted_heading_elsewhere_does_not_open_a_section(self) -> None:
        # The over-refusal the same blindness caused: an example of this
        # section quoted under another heading was read as this section, and
        # the gate refused a body every other reader accepts.
        body = (
            GOOD_BODY
            + "\n## Notes\n\n> ## Evidence Status\n> - [blocked] an example\n"
            + "\n## Evidence Status\n\n- [complete] ran it -- 1992 tests passed\n"
        )
        with recorded_page():
            self.assertEqual(self.failures(body), [])

    def test_a_heading_inside_a_list_item_is_not_this_section_either(self) -> None:
        # The same rule, the other container CommonMark lets hold a heading.
        section = "- outer\n  - ## Note\n\n" + self.BR_STATUS
        with recorded_page():
            failures = self.failures(self.body(section))
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)

    def test_a_long_s_heading_is_not_this_section_to_the_page_reader(self) -> None:
        # The ride-along: this reader folded with `casefold()`, which maps a
        # printer's long s onto `s`, so `## Evidence Statuſ` opened the
        # section here and opens it for no other reader in the repo. Asserted
        # on the page's lines rather than on the verdict, because the source
        # model still takes that heading until #1759 lands and would refuse
        # the body either way.
        body = GOOD_BODY + "\n## Evidence Statu\u017f\n\n- [blocked] x\n"
        with recorded_page():
            page = pr_readiness.page_view(body)
        self.assertEqual(page.unverified, None)
        self.assertEqual(page.lines, ())

    # An opaque container an author opened and never closed. GitHub's
    # sanitizer balances it around the rest of the document, so the body's one
    # `## Evidence Status` renders inside a `<blockquote>` or an `<li>` it was
    # never meant to be in -- and a heading in someone else's structure is not
    # this section, so the reader opened nothing and the status below it
    # reached neither view (#1745, round 3).
    UNCLOSED_BEFORE_THE_HEADING = {
        "a blockquote": "<blockquote>",
        "a list item": "<ul><li>",
    }

    def test_an_unclosed_container_before_the_heading_hides_nothing(self) -> None:
        for shape, container in self.UNCLOSED_BEFORE_THE_HEADING.items():
            with self.subTest(shape=shape), recorded_page():
                body = GOOD_BODY + f"\n{container}\n\n## Evidence Status\n\n{self.BR_STATUS}\n"
                failures = self.failures(body)
                self.assertTrue(
                    any(pr_readiness.PENDING_FAILURE in failure for failure in failures),
                    (shape, failures),
                )

    def test_an_unclosed_container_inside_the_section_still_refuses(self) -> None:
        # The control the second read must not cost: the heading is already at
        # the top level here, so the first read finds it and the second never
        # runs.
        with recorded_page():
            body = self.body(f"<blockquote>\n\n{self.BR_STATUS}")
            failures = self.failures(body)
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)

    def test_a_quoted_heading_inside_a_fold_still_does_not_end_the_section(self) -> None:
        # `<details>` stays transparent and `> ## Note` stays opaque, together.
        with recorded_page():
            failures = self.failures(
                self.body(f"<details>\n<summary>s</summary>\n\n> ## Note\n\n{self.BR_STATUS}")
            )
        self.assertTrue(any(pr_readiness.PENDING_FAILURE in failure for failure in failures), failures)

    def test_a_fold_stays_transparent(self) -> None:
        # `<details>` is not an opaque container: part B's rule is that folded
        # text is text a reader opens, so a heading inside one is still this
        # section's. Pinned here because the nesting rule is what could have
        # taken it away.
        body = (
            "<details>\n<summary>notes</summary>\n\n"
            + GOOD_BODY
            + "\n## Evidence Status\n\n- [blocked] x\n"
        )
        with recorded_page():
            page = pr_readiness.page_view(body)
        self.assertEqual(page.unverified, None)
        self.assertIn("[blocked] x", page.lines)


# The page reader's two rules, and every shape four rounds have probed them
# on. Three times a fix here moved the failure to a neighbouring shape, each
# found by someone reading the code; this is so the next pass reads a list.
#
# LINE-SPLITTING -- what starts a line:
#   a boundary of any element in `LINE_STARTING_TAGS`; `<br>` anywhere,
#   including inside a heading; a newline inside a raw `<pre>`.
# and what does not:
#   a newline anywhere else (the page collapses it); an inline tag; the
#   boundaries of a code span.
#
# SECTION-BOUNDING -- what opens it:
#   a top-level `<h2>` whose text reads as `Evidence Status` by
#   `heading_identity`; a nested one only when no top-level one did.
# what closes it:
#   the next `<h1>` or `<h2>` at the depth the section was opened at.
# what is transparent (a heading inside it is still the document's):
#   `<details>`.
# what is opaque (a heading inside it is someone else's):
#   `<blockquote>`, `<li>`.
# what is not read: text inside `<pre><code>`.
# what is read: a bare `<code>`, a raw `<pre>`, and the text of a `<details>`.
#
# A row is (name, middle, lines, ok): the text placed after a passing body's
# opening, every line the page shows under the heading, and the gate's
# verdict. Adding a shape here is adding a test.
PAGE_READER_TABLE = (
    ("a block tag after prose", '## Evidence Status\n\nContext <div>[blocked] x</div>\n', ('Context', '[blocked] x'), False),
    ("a pre after prose", '## Evidence Status\n\nContext <pre>[blocked] x</pre>\n', ('Context', '[blocked] x'), False),
    ("a break after prose", '## Evidence Status\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("a break inside a list item", '## Evidence Status\n\n- complete <br>[blocked] x\n', ('complete', '[blocked] x'), False),
    ("an unparsed tag the page prints", '## Evidence Status\n\n<x:y>[blocked] x</x:y>\n', ('<x:y>[blocked] x</x:y>',), False),
    ("a type parameter mid-line", '## Evidence Status\n\n<div>API note: Vec<T> [blocked] names an enum case</div>\n', ('API note: Vec [blocked] names an enum case',), True),
    ("a fenced example", '## Evidence Status\n\n```\n- [blocked] x\n```\n', (), True),
    ("an indented example", '## Evidence Status\n\n    - [blocked] x\n', (), False),
    ("a code span", '## Evidence Status\n\n- `[blocked]` x\n', ('[blocked] x',), False),
    ("a code span after a break", '## Evidence Status\n\nContext <br>`[blocked]` x\n', ('Context', '[blocked] x'), False),
    ("a rule of asterisks", '## Evidence Status\n\n***\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("a dash rule", '## Evidence Status\n\n---\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("a quoted heading inside", '## Evidence Status\n\n> ## Note\n\nContext <br>[blocked] x\n', ('Note', 'Context', '[blocked] x'), False),
    ("a heading inside a list item", '## Evidence Status\n\n- outer\n  - ## Note\n\nContext <br>[blocked] x\n', ('outer', 'Note', 'Context', '[blocked] x'), False),
    ("a quoted example elsewhere", '## Notes\n\n> ## Evidence Status\n> - [blocked] an example\n\n## Evidence Status\n\n- [complete] ran it -- 1992 tests passed\n', ('[complete] ran it -- 1992 tests passed',), True),
    ("a long-s heading", '## Evidence Statuſ\n\n- [blocked] x\n', (), False),
    ("a fold holding the section", '<details>\n<summary>notes</summary>\n\n## Evidence Status\n\n- [blocked] x\n', ('[blocked] x',), False),
    ("a fold holding a quoted heading", '## Evidence Status\n\n<details>\n<summary>s</summary>\n\n> ## Note\n\nContext <br>[blocked] x\n', ('s', 'Note', 'Context', '[blocked] x'), False),
    ("an unclosed blockquote before", '<blockquote>\n\n## Evidence Status\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("an unclosed list item before", '<ul><li>\n\n## Evidence Status\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("an unclosed blockquote inside", '## Evidence Status\n\n<blockquote>\n\nContext <br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("a break inside a quoted heading", '## Evidence Status\n\n> ## Context<br>[blocked] x\n', ('Context', '[blocked] x'), False),
    ("a sibling heading after a top-level section", '## Evidence Status\n\n## Notes\n\nContext <br>[blocked] x\n', (), True),
    ("a sibling heading after a nested section", '<blockquote>\n\n## Evidence Status\n\n## Notes\n\nContext <br>[blocked] x\n', (), True),
    ("a raw pre holding the status", '## Evidence Status\n\n<pre>\nnote\n[blocked] x\n</pre>\n', ('note', '[blocked] x'), False),
)


class ThePageReaderTableTests(unittest.TestCase):
    """The table, run.

    Two assertions per row rather than one: the lines are what this reader
    exists to produce, and the verdict is what an author sees. A fix that
    keeps a verdict by reading different lines -- which is how round 4's
    swallowed `<br>` hid -- fails the first.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]

    def body(self, middle: str) -> str:
        return GOOD_BODY + f"\n{middle}"

    def test_every_probed_shape_shows_the_lines_the_table_says(self) -> None:
        for name, middle, lines, _ in PAGE_READER_TABLE:
            with self.subTest(shape=name), recorded_page():
                page = pr_readiness.page_view(self.body(middle))
                self.assertIsNone(page.unverified, name)
                self.assertEqual(page.lines, lines, name)

    def test_every_probed_shape_gets_the_verdict_the_table_says(self) -> None:
        for name, middle, _, ok in PAGE_READER_TABLE:
            with self.subTest(shape=name), recorded_page():
                result = pr_readiness.evaluate(pr(self.body(middle)), self.FILES)
                self.assertEqual(result.ok, ok, (name, result.failures))

    def test_the_table_exercises_both_rules(self) -> None:
        # A table nobody checks the shape of grows lopsided. These are the
        # axes the four rounds actually moved along.
        shapes = "\n".join(middle for _, middle, _, _ in PAGE_READER_TABLE)
        for splitter in ("<br>", "<div>", "<pre>", "```", "`[blocked]`", "    - [blocked]"):
            self.assertIn(splitter, shapes)
        for bound in ("***", "---", "> ##", "<details>", "<blockquote>", "<ul><li>", "## Notes"):
            self.assertIn(bound, shapes)
        self.assertIn("Statu\u017f", shapes)


class ThePageSeesThroughAFoldTests(unittest.TestCase):
    """A section inside a collapsed block is a section a reader can open (#1742, item 3).

    An unclosed `<details>` above the heading renders the whole section inside
    the collapsed element. Folded text is shown on a click, so the status
    question is answered there like anywhere else: the heading is taken
    wherever the rendered HTML puts it rather than only at the top level, and
    refusing is the side this reader errs on.

    Whether a section may be PLACED inside a fold is a different question, and
    it stays with the contributor skill's placement check. This says only that
    folding does not hide a status from the gate.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]

    def test_a_status_under_a_folded_heading_is_read(self) -> None:
        body = f"<details>\n<summary>notes</summary>\n\n{GOOD_BODY}\n## Evidence Status\n\n- [blocked] x\n"
        with recorded_page():
            page = pr_readiness.page_view(body)
        self.assertEqual(page.unverified, None)
        self.assertIn("[blocked] x", page.lines)


class TheGateSaysWhenThePageWentUnreadTests(unittest.TestCase):
    """Offline is a state the gate reports, never one it passes quietly.

    A laptop preflight with no token, a network that is down, a non-2xx, a
    spent rate limit: each leaves the gate standing on the source model, which
    refuses on the page's behalf and never accepts for it. An author who
    cleared a gate that could not reach the renderer cleared a different gate
    from the one CI runs, so the note goes in the output AND in the comment
    the workflow posts.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]

    def test_no_token_is_a_reason_not_an_error(self) -> None:
        # With no token it makes no call at all. The anonymous allowance is 60
        # an hour shared across the host, and a gate spending it would pass for
        # one author and fail for the next with no change in the body.
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(pr_readiness.RendererUnavailable) as raised:
                _LIVE_RENDER("x")
        self.assertIn("GH_TOKEN", str(raised.exception))

    def test_a_spent_rate_limit_is_named(self) -> None:
        error = urllib.error.HTTPError(
            pr_readiness.MARKDOWN_API_URL, 403, "rate limited", {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1789759202"}, None
        )
        self.assertIn("rate limit", pr_readiness.http_failure_reason(error))

    def test_another_non_2xx_is_named_by_its_code(self) -> None:
        error = urllib.error.HTTPError(pr_readiness.MARKDOWN_API_URL, 502, "bad gateway", {}, None)
        self.assertIn("502", pr_readiness.http_failure_reason(error))

    def test_the_readiness_comment_carries_the_note(self) -> None:
        result = pr_readiness.evaluate(pr(GOOD_BODY), self.FILES)
        comment = pr_readiness.comment_markdown(result)
        self.assertIn("passed", comment)
        self.assertIn("Rendered view unverified", comment)

    def test_a_failing_body_keeps_both_the_failures_and_the_note(self) -> None:
        result = pr_readiness.evaluate(pr(GOOD_BODY.replace("## Mergeability", "## Notes")), self.FILES)
        comment = pr_readiness.comment_markdown(result)
        self.assertIn("Missing ## Mergeability section", comment)
        self.assertIn("Rendered view unverified", comment)

    def test_preflight_with_no_token_prints_the_note_and_the_models_verdict(self) -> None:
        # `preflight` clears the environment, so this is the laptop case: the
        # note is printed and the exit code is the source model's answer.
        code, output = preflight(GOOD_BODY, files=["Sources/WorkspaceManager/Foo.swift"])
        self.assertEqual(code, 0)
        self.assertIn("PR readiness passed.", output)
        self.assertIn("Rendered view unverified", output)

    def test_the_page_is_asked_once_per_body(self) -> None:
        # One request per gate run, whatever the caller does: the Factory
        # review lane evaluates the same body through this same `evaluate`.
        asked: list[str] = []
        body = GOOD_BODY + "\n## Evidence Status\n\n- [complete] swift test -- 1992 tests passed\n"
        with recorded_page():
            recorded = pr_readiness.render_markdown
            with mock.patch.object(
                pr_readiness,
                "render_markdown",
                side_effect=lambda text: asked.append(text) or recorded(text),
            ):
                for _ in range(3):
                    pr_readiness.evaluate(pr(body), self.FILES)
        self.assertEqual(len(asked), 1, asked)


class RecordedRendererResponseTests(unittest.TestCase):
    """The recordings, and what keeps them honest.

    A recorded response is a claim about what GitHub does today. The renderer's
    output format is not a contract -- attributes, class names and wrapping can
    change -- so the recordings are checked against the live renderer whenever
    a token is there to check them with, and that check is the detector for the
    one risk this design adds. With no token it skips, because a suite that
    failed for want of a network would fail in every sandbox in the repo.
    """

    def test_a_body_with_no_recording_names_the_command_that_records_it(self) -> None:
        # Recording off and the recordings out of reach, so this says what a
        # contributor sees when a test asks for a body nobody has recorded --
        # not what the one invocation that refreshes the fixtures sees.
        module = sys.modules[__name__]
        with tempfile.TemporaryDirectory() as empty:
            with (
                mock.patch.dict(os.environ, {RECORD_ENV: ""}),
                mock.patch.object(module, "RENDERED_FIXTURES", Path(empty)),
                recorded_page(),
            ):
                with self.assertRaises(AssertionError) as raised:
                    pr_readiness.page_view(GOOD_BODY)
        self.assertIn(RECORD_COMMAND, str(raised.exception))

    def test_every_recording_names_the_body_it_answers(self) -> None:
        for digest, text in rendered_index().items():
            with self.subTest(digest=digest[:12]):
                self.assertEqual(hashlib.sha256(text.encode("utf-8")).hexdigest(), digest)
                self.assertTrue(rendered_fixture_path(text).is_file())

    def test_every_recorded_file_is_named_in_the_index(self) -> None:
        index = rendered_index()
        for path in sorted(RENDERED_FIXTURES.glob("*.html")):
            with self.subTest(name=path.name):
                self.assertIn(path.stem, index)

    def test_the_recordings_still_match_the_live_renderer(self) -> None:
        if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
            self.skipTest("no GH_TOKEN or GITHUB_TOKEN: the live renderer cannot be asked")
        for digest, text in rendered_index().items():
            with self.subTest(digest=digest[:12]):
                self.assertEqual(
                    _LIVE_RENDER(text),
                    rendered_fixture_path(text).read_text(encoding="utf-8"),
                    f"the renderer's output changed; re-record with {RECORD_COMMAND}",
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


class ThisGateFindsASectionWherePageShowsOneTests(unittest.TestCase):
    """The gate's section START is a parse, so an example is an example (#1742).

    `extract_section` ended where the parser said since #1734 and still began
    at the first line matching `^## <heading>`, so a `## Mergeability` block
    written inside a fenced example was the body's own section. Where the
    example was COMPLETE -- four fields, as a documentation sample or a quoted
    body is -- the gate returned `ok=True failures=[]` on a pull request with
    no section at all: the one shape where this misread spends an approval
    rather than a refusal.

    The start now asks the same question the contributor skill's
    `section_heading_index` asks, and by the same identity rule: a top-level
    h2 whose rendered text reads as the heading, carrying no inline HTML. So
    the shapes the page shows and the pattern missed -- emphasis, an indent of
    up to three spaces, a setext underline, trailing spaces, a closing hash
    run -- are sections here too, which is the widening #1730 already made on
    the skill's side and the narrowing this gate carried alone until now.
    """

    HELPERS_PATH = (
        REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
    )
    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    OPENING = (
        "The release lane lost its provisioning step, so a signed build never reached the "
        "appcast and the update check stalled. This restores it, with the lane's own log as "
        "the proof. One file, +12 -3; no behavior a user sees.\n\n"
    )
    FIELDS = (
        "- Surface: desktop\n"
        "- User-facing behavior changed: none; refactor only\n"
        "- Non-happy paths considered: nil userdata and zero address behavior covered\n"
        "- Residual risk or follow-up: none\n"
    )
    EVIDENCE = "## Evidence\n\n- [x] Not a testable change\n"

    def owner(self):
        spec = importlib.util.spec_from_file_location("contributor_helpers", self.HELPERS_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def complete_example_body(self) -> str:
        return (
            f"{self.OPENING}"
            "The format this PR is about, for reference:\n\n"
            f"```markdown\n## Mergeability\n\n{self.FIELDS}```\n\n"
            f"{self.EVIDENCE}"
        )

    def test_a_complete_fenced_example_is_no_longer_an_approval(self) -> None:
        # The headline: the body the page shows has no section, and the gate
        # now says so instead of reading the example's fields and approving.
        body = self.complete_example_body()
        self.assertFalse(self.owner().has_markdown_section(body, "Mergeability"))
        self.assertEqual(pr_readiness.extract_section(body, "Mergeability"), "")
        result = pr_readiness.evaluate(pr(body, labels=["author:claude-code"]), self.FILES)
        self.assertFalse(result.ok)
        self.assertIn("Missing ## Mergeability section from the PR body.", result.failures)

    def test_the_same_body_with_a_real_section_beside_the_example_passes(self) -> None:
        # The control: the example is left alone and the section below it is
        # the one read, so the refusal above is about absence and not about
        # fences.
        body = (
            f"{self.OPENING}"
            "The format this PR is about, for reference:\n\n"
            f"```markdown\n## Mergeability\n\n- Surface: desktop\n```\n\n"
            f"## Mergeability\n\n{self.FIELDS}\n"
            f"{self.EVIDENCE}"
        )
        self.assertEqual(pr_readiness.extract_section(body, "Mergeability"), self.FIELDS.strip())
        self.assertEqual(pr_readiness.evaluate(pr(body, labels=["author:claude-code"]), self.FILES).failures, [])

    # Every heading the page shows that this gate's pattern could not find,
    # and every one it found that the page does not show. Read off the two
    # rule sets: the pattern's literal `## ` at column 0 with a line ending
    # directly after, against CommonMark's h2 grammar and the skill's identity
    # rule (a top-level h2, no inline HTML, text as `inline_text` reads it).
    SHOWN_BUT_UNMATCHED = {
        "emphasis": "## **Mergeability**",
        "underscore emphasis": "## _Mergeability_",
        "indented three spaces": "   ## Mergeability",
        "setext dashes": "Mergeability\n---",
        "trailing spaces": "## Mergeability  ",
        "trailing tab": "## Mergeability\t",
        "closing hash run": "## Mergeability ##",
        "tab separator": "##\tMergeability",
    }
    # Shown, and shown as something else. A code span is the word in code
    # font, a link is a link and an image is an image, and `inline_text` keeps
    # each one's markup precisely so identity does not read them as the plain
    # word -- the rule the skill settled on in #1730, mirrored here rather
    # than re-decided.
    SHOWN_AS_SOMETHING_ELSE = {
        "code span": "## `Mergeability`",
        "link": "## [Mergeability](https://example.com)",
        "image": "## ![Mergeability](https://example.com/x.png)",
    }
    MATCHED_BUT_UNSHOWN = {
        "in a fenced example": "```markdown\n## Mergeability\n```\n\n## Mergeability",
        "in an indented code block": "    ## Mergeability",
    }

    def test_every_heading_the_page_shows_is_a_section_to_this_gate(self) -> None:
        owner = self.owner()
        for name, heading in self.SHOWN_BUT_UNMATCHED.items():
            with self.subTest(shape=name):
                body = f"{self.OPENING}{heading}\n\n{self.FIELDS}\n{self.EVIDENCE}"
                self.assertTrue(owner.has_markdown_section(body, "Mergeability"))
                self.assertEqual(
                    pr_readiness.extract_section(body, "Mergeability"),
                    owner.markdown_section(body, "Mergeability"),
                )
                self.assertEqual(
                    pr_readiness.evaluate(pr(body, labels=["author:claude-code"]), self.FILES).failures,
                    [],
                )

    def test_a_heading_only_the_source_holds_is_no_section_to_either(self) -> None:
        owner = self.owner()
        for name, heading in self.MATCHED_BUT_UNSHOWN.items():
            with self.subTest(shape=name):
                body = f"{self.OPENING}{heading}\n\n{self.FIELDS}\n{self.EVIDENCE}"
                self.assertEqual(
                    owner.has_markdown_section(body, "Mergeability"),
                    bool(pr_readiness.extract_section(body, "Mergeability")),
                )

    # A heading carrying inline HTML is not this section, whatever its text
    # reads as: struck through, a disclosure widget, two lines, an empty span
    # (#1730). The gate took each of them as the section while the skill
    # refused, so a rewrite and a gate read two different bodies.
    TAGGED = {
        "del": "## Merge<del>ability</del>",
        "details": "## <details>Mergeability</details>",
        "br": "## Merge<br>ability",
        "span": "## <span>Mergeability</span>",
        "trailing comment": "## Mergeability<!-- a note -->",
    }

    def test_a_tagged_heading_is_not_this_section_in_either_reader(self) -> None:
        owner = self.owner()
        for name, heading in self.TAGGED.items():
            with self.subTest(shape=name):
                body = f"{self.OPENING}{heading}\n\n{self.FIELDS}\n{self.EVIDENCE}"
                self.assertFalse(owner.has_markdown_section(body, "Mergeability"))
                self.assertEqual(pr_readiness.extract_section(body, "Mergeability"), "")

    def test_a_heading_the_page_shows_as_something_else_is_not_this_section(self) -> None:
        owner = self.owner()
        for name, heading in self.SHOWN_AS_SOMETHING_ELSE.items():
            with self.subTest(shape=name):
                body = f"{self.OPENING}{heading}\n\n{self.FIELDS}\n{self.EVIDENCE}"
                self.assertFalse(owner.has_markdown_section(body, "Mergeability"))
                self.assertEqual(pr_readiness.extract_section(body, "Mergeability"), "")

    def test_a_heading_that_is_not_top_level_is_not_this_section(self) -> None:
        # A quote and a list item each hold an h2 the parser calls nested, and
        # the pattern's `^` never reached one anyway. Both readers refuse, and
        # the fixture says so rather than leaving it to the pattern's shape.
        owner = self.owner()
        for name, heading in (
            ("in a block quote", "> ## Mergeability"),
            ("in a list item", "- ## Mergeability"),
        ):
            with self.subTest(shape=name):
                body = f"{self.OPENING}{heading}\n\n{self.FIELDS}\n{self.EVIDENCE}"
                self.assertFalse(owner.has_markdown_section(body, "Mergeability"))
                self.assertEqual(pr_readiness.extract_section(body, "Mergeability"), "")

    def test_a_setext_heading_does_not_keep_its_underline_in_the_section(self) -> None:
        # The slice starts where the heading BLOCK stops, not one line below
        # its first line, so a setext heading's underline is not the section's
        # first line -- the arithmetic the skill's `_section_bounds` already
        # does.
        body = f"{self.OPENING}Mergeability\n---\n\n{self.FIELDS}\n{self.EVIDENCE}"
        section = pr_readiness.extract_section(body, "Mergeability", strip=False)
        self.assertNotIn("---", section)
        self.assertEqual(
            pr_readiness.extract_section(body, "Mergeability"), self.FIELDS.strip()
        )


class WhatTheParsedStartCostsTheEvidenceRefusalTests(unittest.TestCase):
    """Which refusals the parsed start drops, and why each one was an example's (#1742).

    `Mergeability` and `Validation` are POSITIVE checks -- no section is a
    failure -- so a stricter start can only add refusals there. `Evidence
    Status` is NEGATIVE: a `[blocked]` or `[pending-ci]` line inside the
    section is the failure, so a section this gate no longer reads is a
    refusal it no longer makes. That direction is the one worth measuring
    rather than asserting, and every case below is the same shape: the text
    that supplied the refusal is inside a fenced example, which the page shows
    as code and no reader acts on.

    It is also the direction in which the two views now AGREE. The rendered
    read finds its heading by parse already, so it never saw a fenced section
    either; the written read making a refusal the rendered read could not was
    the disagreement, not the safety. Measured on stored data: of the three
    issues in this repo carrying a fenced `## Evidence Status`, the gate's old
    start manufactured a refusal from an example's text on all three, and none
    of the 1,000 stored pull request bodies changes verdict at all.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    OPENING = (
        "The release lane lost its provisioning step, so a signed build never reached the "
        "appcast and the update check stalled. This restores it, with the lane's own log as "
        "the proof. One file, +12 -3; no behavior a user sees.\n\n"
    )
    MERGEABILITY = (
        "## Mergeability\n\n"
        "- Surface: desktop\n"
        "- User-facing behavior changed: none; refactor only\n"
        "- Non-happy paths considered: nil userdata and zero address behavior covered\n"
        "- Residual risk or follow-up: none\n\n"
    )
    EVIDENCE = "## Evidence\n\n- [x] Not a testable change\n"

    def body(self, middle: str) -> str:
        return f"{self.OPENING}{self.MERGEABILITY}{middle}{self.EVIDENCE}"

    def test_a_fenced_example_no_longer_supplies_a_pending_refusal(self) -> None:
        # The refusal this drops. The page shows a documentation sample; a
        # reader sees no status line, and neither view reads one now.
        body = self.body(
            "The format an author fills in, for reference:\n\n"
            "```markdown\n## Evidence Status\n\n- [blocked] the UI lane -- waiting\n```\n\n"
        )
        self.assertEqual(pr_readiness.extract_section(body, "Evidence Status"), "")
        self.assertEqual(pr_readiness.rendered_status_lines(body), [])
        self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [])

    def test_the_real_section_below_that_example_is_the_one_read(self) -> None:
        # And the refusal it gains: with a real section under the example, the
        # old start read the example and missed the author's own blocked line,
        # leaving the rendered view to report a line the author could not find.
        # The written view reads it now, so the failure names nothing.
        body = self.body(
            "The format an author fills in, for reference:\n\n"
            "```markdown\n## Evidence Status\n\n- [complete] an item -- proof\n```\n\n"
            "## Evidence Status\n\n- [blocked] the UI lane -- waiting\n\n"
        )
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [blocked] the UI lane -- waiting",
        )
        # Two failures, and the second is main's and not this change's:
        # `evidence_status_heading_failure` is a line scan, so the example's
        # heading line counts toward the heading count even though the page
        # shows it as code. A refusal on text nobody sees is allowed and this
        # change neither adds nor widens it; the split between a line-scanned
        # count and a parsed section is named at that function.
        self.assertEqual(
            pr_readiness.evaluate(pr(body), self.FILES).failures,
            [
                "Ambiguous Evidence Status headings; use at most one exact "
                "'## Evidence Status' heading and no variants.",
                PENDING_TEXT,
            ],
        )

    def test_the_false_unclosed_fence_refusal_is_gone(self) -> None:
        # The other refusal the old start manufactured, and the one that cost
        # an author a round: the slice began inside a closed fence, so the
        # fence's own CLOSING line was the first fence marker in it and read as
        # an opener with nothing after it. The gate told authors to close a
        # fence they had closed -- twice on stored issues (#1728, #1590).
        body = self.body(
            "```markdown\n## Evidence Status\n\n- [complete] an item -- proof\n```\n\n"
        )
        self.assertIsNone(pr_readiness.split_fenced_blocks(body)[1])
        self.assertIsNone(
            pr_readiness.split_fenced_blocks(
                pr_readiness.extract_section(body, "Evidence Status", strip=False)
            )[1]
        )
        self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [])

    # The two fail-opens this read does not close, each main's own, each now
    # reachable through more heading spellings. Found by a confirmation pass
    # over this branch, measured here so the widening is a number rather than
    # a sentence, and filed rather than carried as prose.
    FENCED_FIELDS = (
        "```markdown\n"
        "- Surface: desktop\n"
        "- User-facing behavior changed: none; refactor only\n"
        "- Non-happy paths considered: covered\n"
        "- Release/ops preconditions: not applicable\n"
        "- Residual risk or follow-up: none\n"
        "```\n"
    )
    WIDENED_SPELLINGS = ("## **{h}**", "## _{h}_", "   ## {h}", "{h}\n---", "## {h}  ", "## {h}\t", "## {h} ##", "##\t{h}")

    def test_a_positive_field_read_still_credits_fenced_text(self) -> None:
        # `field_value` searches the section's raw text, so the page showing
        # those lines as code changes nothing: the fields are answered. True
        # under a literal heading on main -- the control below -- and this
        # read adds eight spellings that reach it.
        literal = f"{self.OPENING}## Mergeability\n\n{self.FENCED_FIELDS}\n{self.EVIDENCE}"
        self.assertEqual(pr_readiness.evaluate(pr(literal), self.FILES).failures, [])
        reached = [
            shape
            for shape in self.WIDENED_SPELLINGS
            if not pr_readiness.evaluate(
                pr(f"{self.OPENING}{shape.format(h='Mergeability')}\n\n{self.FENCED_FIELDS}\n{self.EVIDENCE}"),
                self.FILES,
            ).failures
        ]
        self.assertEqual(len(reached), len(self.WIDENED_SPELLINGS), reached)

    def test_a_section_below_an_unclosed_details_is_still_a_heading_here(self) -> None:
        # #1742's third item, blocked on #1745: the page folds this section
        # into the disclosure and every reader in this repo calls the heading
        # top-level, because telling which elements are open is a renderer.
        # Main answers the same way under a literal heading -- the control --
        # and this read adds the same eight spellings.
        fields = (
            "- Surface: desktop\n- User-facing behavior changed: none; refactor only\n"
            "- Non-happy paths considered: covered\n"
            "- Release/ops preconditions: not applicable\n- Residual risk or follow-up: none\n"
        )
        folded = "<details>\n<summary>the log</summary>\n\n"
        literal = f"{self.OPENING}{folded}## Mergeability\n\n{fields}\n{self.EVIDENCE}"
        self.assertEqual(pr_readiness.evaluate(pr(literal), self.FILES).failures, [])
        reached = [
            shape
            for shape in self.WIDENED_SPELLINGS
            if not pr_readiness.evaluate(
                pr(f"{self.OPENING}{folded}{shape.format(h='Mergeability')}\n\n{fields}\n{self.EVIDENCE}"),
                self.FILES,
            ).failures
        ]
        self.assertEqual(len(reached), len(self.WIDENED_SPELLINGS), reached)

    def test_a_real_unclosed_fence_in_the_section_still_refuses(self) -> None:
        # The control: the refusal exists for a reason and still fires where
        # the author's own section opens a fence and leaves it open.
        body = self.body(
            "## Evidence Status\n\n- [complete] an item -- proof\n\n```\nthe log\n\n"
        )
        failures = pr_readiness.evaluate(pr(body), self.FILES).failures
        self.assertTrue(
            any("opens a code fence that never closes" in failure for failure in failures),
            failures,
        )


class AHeadingNoReaderTakesIsNamedRatherThanIgnoredTests(unittest.TestCase):
    """The narrowing says what it declined, instead of going quiet (#1742).

    `Mergeability` and `Validation` are positive checks, so a start that reads
    fewer sections only refuses more there. `Evidence Status` is negative -- a
    `[blocked]` line in the section is the failure -- so a heading this gate
    stops reading is a refusal it stops making, and three shapes reached that
    silence, each found by a confirmation pass over this branch rather than by
    a test written for it:

    - `## EVİDENCE STATUS`. The old literal start matched it, because `re`'s
      IGNORECASE folds the whole Unicode table and maps a dotted capital I
      onto `i`; no parse-backed identity in this repo ever did, so the
      contributor skill's reader already saw zero headings there.
    - `## Evidence Statuſ`. The fold declines it now, which is the point of
      the change, and the section under it then belonged to nobody.
    - `## **Evidence Status**` above the real heading. The line-scanned
      ambiguity check sees one exact heading and the page shows two; this gate
      reads the first, so an unclosed fence or a `[blocked]` line under the
      second went unread where the old start had read that second one.

    None of the three is a body the factory writes, and the skill's owner read
    refuses all three for its heading count -- so the factory lane already
    failed closed and this is the readiness gate saying the same thing. What
    it adds is the line number, because an author cannot see a long s.

    The refusal is deliberately NOT extended to a heading carrying a tag or a
    code span. A heading with inline HTML is not this section and the repair
    writes a plain one below it, leaving both on the page (#1730); counting
    the rejected one would refuse the body that repair produces, which is the
    failure this lane exists to prevent, and there is a fixture below for it.
    """

    FILES = ["Sources/WorkspaceManager/Foo.swift"]
    OPENING = WhatTheParsedStartCostsTheEvidenceRefusalTests.OPENING
    MERGEABILITY = WhatTheParsedStartCostsTheEvidenceRefusalTests.MERGEABILITY
    EVIDENCE = WhatTheParsedStartCostsTheEvidenceRefusalTests.EVIDENCE
    BLOCKED = "- [blocked] the UI lane -- waiting"

    def body(self, middle: str) -> str:
        return f"{self.OPENING}{self.MERGEABILITY}{middle}{self.EVIDENCE}"

    def failures(self, body: str) -> list[str]:
        return list(pr_readiness.evaluate(pr(body), self.FILES).failures)

    # Derived, not listed: every single-character substitution in the heading
    # that the old literal start's fold took and this identity declines. There
    # are four, over three characters -- a dotted capital I, a dotless i, and
    # the long s at either `s` -- and a listed set would have been wrong about
    # which: `ß` reads as this heading to neither fold, so a fixture for it
    # asserts nothing and scored as a missing refusal when it was written.
    @staticmethod
    def declined_spellings() -> list[str]:
        heading = "Evidence Status"
        loose = re.compile(f"(?i){re.escape(heading)}")
        return [
            candidate
            for point in range(0x110000)
            for position in range(len(heading))
            for candidate in [heading[:position] + chr(point) + heading[position + 1 :]]
            if heading[position] != " "
            and candidate != heading
            and loose.fullmatch(candidate)
            and pr_readiness.heading_identity(candidate) != pr_readiness.heading_identity(heading)
        ]

    DECLINED_SPELLING_COUNT = 4

    def test_a_spelling_no_reader_takes_is_refused_and_its_line_named(self) -> None:
        spellings = self.declined_spellings()
        self.assertEqual(len(spellings), self.DECLINED_SPELLING_COUNT, spellings)
        self.assertEqual(
            sorted({hex(ord(char)) for word in spellings for char in word if not char.isascii()}),
            ["0x130", "0x131", "0x17f"],
        )
        for heading in spellings:
            with self.subTest(spelling=heading):
                body = self.body(f"## {heading}\n\n{self.BLOCKED}\n\n")
                self.assertEqual(pr_readiness.extract_section(body, "Evidence Status"), "")
                failures = self.failures(body)
                self.assertEqual(len(failures), 1, failures)
                self.assertIn(f"is spelled '{heading}'", failures[0])
                line = body[: body.index("## " + heading)].count("\n") + 1
                self.assertIn(f"line {line}", failures[0])

    def test_two_headings_a_reader_sees_are_refused_together(self) -> None:
        # The shape the line-scanned ambiguity check cannot see.
        body = self.body(
            "## **Evidence Status**\n\n- [complete] first -- done\n\n"
            f"## Evidence Status\n\n{self.BLOCKED}\n\n"
        )
        self.assertIsNone(pr_readiness.evidence_status_heading_failure(body))
        failures = self.failures(body)
        self.assertTrue(
            any("A reader sees 2 headings that read as" in failure for failure in failures),
            failures,
        )

    def test_the_line_scans_own_message_wins_where_both_would_speak(self) -> None:
        # One body, one failure about its headings: the line scan's message
        # names the exact spelling to write, which is the repair, so it is the
        # one asked first.
        body = self.body(
            "##  Evidence Status\n\n- [complete] first -- done\n\n"
            f"## Evidence Status\n\n{self.BLOCKED}\n\n"
        )
        failures = self.failures(body)
        heading_failures = [f for f in failures if "read as" in f or "Ambiguous" in f]
        self.assertEqual(
            heading_failures,
            [
                "Ambiguous Evidence Status headings; use at most one exact "
                "'## Evidence Status' heading and no variants."
            ],
        )

    def test_the_repaired_body_the_factory_writes_is_not_refused(self) -> None:
        # The control that matters most: a heading carrying a tag, with the
        # plain heading the repair wrote below it. The page shows two headings
        # and only one of them is ever this section, so the candidate list
        # holds one and nothing here refuses (#1730).
        for name, tagged in (
            ("a span", "## <span>Evidence Status</span>"),
            ("struck through", "## Evidence <del>Status</del>"),
            ("a code span", "## `Evidence Status`"),
            ("a trailing comment", "## Evidence Status<!-- a note -->"),
        ):
            with self.subTest(heading=name):
                body = self.body(
                    f"{tagged}\n\n- [complete] the author's own line -- proof\n\n"
                    "## Evidence Status\n\n- [complete] the item -- checked\n\n"
                )
                self.assertEqual(pr_readiness.status_heading_candidates(body).__len__(), 1)
                self.assertEqual(self.failures(body), [])

    def test_a_fenced_heading_is_not_a_candidate(self) -> None:
        # A documentation sample is code, so it is not a heading a reader
        # could take for this section and adds no refusal here either.
        body = self.body(
            "```markdown\n## Evidence Status\n\n- [blocked] an example -- waiting\n```\n\n"
            "## Evidence Status\n\n- [complete] the item -- checked\n\n"
        )
        self.assertEqual(pr_readiness.status_heading_candidates(body), [(16, "Evidence Status")])
        self.assertIsNone(pr_readiness.unread_status_heading_failure(body))
        # The body still draws main's own refusal, from main's own reader:
        # `evidence_status_heading_failure` is a line scan and counts the
        # example's heading line, so it reports two exact headings. Inherited,
        # not added here, and named where that function is.
        self.assertEqual(
            self.failures(body),
            [
                "Ambiguous Evidence Status headings; use at most one exact "
                "'## Evidence Status' heading and no variants."
            ],
        )

    def test_the_plain_body_draws_nothing(self) -> None:
        body = self.body("## Evidence Status\n\n- [complete] the item -- checked\n\n")
        self.assertIsNone(pr_readiness.unread_status_heading_failure(body))
        self.assertEqual(self.failures(body), [])

    # A heading line CommonMark puts INSIDE a raw HTML block. Each of these is
    # a section on main -- its literal start matched the line wherever it sat
    # -- and a section to no reader here, so the `[blocked]` under it turned
    # from a refusal into a pass: the one fail-open this branch introduced.
    # GitHub's renderer shows the literal `## Evidence Status` text and the
    # status line under it for all four, so the loss is visible on the page.
    SWALLOWED = {
        "a details closer with no blank line after it": "</details>\n## Evidence Status",
        "an img tag": '<img src="https://example.invalid/a.png">\n## Evidence Status',
        "a div around the heading and the status": "<div>\n## Evidence Status",
        "a comment a browser closes at --!>": "<!-- note --!>\n\n## Evidence Status",
    }

    def test_a_heading_inside_an_html_block_is_refused_by_name(self) -> None:
        for name, opener in self.SWALLOWED.items():
            with self.subTest(shape=name):
                body = self.body(f"{opener}\n\n{self.BLOCKED}\n\n")
                # No candidate: the parse does not see a heading at all.
                self.assertEqual(pr_readiness.status_heading_candidates(body), [])
                # And the line scan is satisfied, which is the disagreement
                # this refusal exists to name.
                self.assertIsNone(pr_readiness.evidence_status_heading_failure(body))
                failure = pr_readiness.unread_status_heading_failure(body)
                self.assertIsNotNone(failure, name)
                self.assertIn("inside a raw HTML block", failure)
                heading_line = body[: body.index("## Evidence Status")].count("\n") + 1
                self.assertIn(f"line {heading_line}", failure)
                self.assertIn("blank line", failure)
                self.assertFalse(pr_readiness.evaluate(pr(body), self.FILES).ok)

    # A heading line the same scan calls exact, inside a block that carries no
    # status at all: a comment the author closed, a `<pre>` they wrote. These
    # bodies have no Evidence Status section, which is allowed -- the section
    # is optional -- and the round-2 refusal told their authors they had
    # hidden a status they had not written (#1742, round 3).
    SWALLOWED_WITH_NOTHING_PENDING = {
        "a closed comment holding only the heading": "<!--\n## Evidence Status\n-->",
        "a closed comment holding a complete item": (
            "<!--\n## Evidence Status\n- [complete] ran it -- 1992 tests passed\n-->"
        ),
        "a pre block holding a complete item": (
            "<pre>\n## Evidence Status\n- [complete] ran it -- 1992 tests passed\n</pre>"
        ),
    }

    def test_a_swallowed_heading_with_no_pending_status_under_it_is_silent(self) -> None:
        for name, block in self.SWALLOWED_WITH_NOTHING_PENDING.items():
            with self.subTest(shape=name):
                body = self.body(f"{block}\n\n")
                self.assertEqual(pr_readiness.status_heading_candidates(body), [])
                self.assertIsNone(pr_readiness.unread_status_heading_failure(body), name)
                self.assertEqual(self.failures(body), [])

    # A heading-shaped line INSIDE the swallowing block, with the status below
    # the block. The block prints those characters as text, so `## Notes` is a
    # heading to nobody -- but the check handed the text from the swallowed
    # heading's end to a markdown parser, which read it as one and closed the
    # section before the status was reached (#1742, round 4).
    INNER_HEADING = {
        "a pre block": "<pre>\n## Evidence Status\n## Notes\n</pre>",
        "a closed comment": "<!--\n## Evidence Status\n## Notes\n-->",
    }

    def test_a_heading_shaped_line_inside_the_block_does_not_hide_the_status_below_it(self) -> None:
        for name, block in self.INNER_HEADING.items():
            with self.subTest(shape=name):
                body = self.body(f"{block}\n{self.BLOCKED}\n\n")
                failure = pr_readiness.unread_status_heading_failure(body)
                self.assertIsNotNone(failure, name)
                self.assertIn("inside a raw HTML block", failure)
                heading_line = body[: body.index("## Evidence Status")].count("\n") + 1
                self.assertIn(f"line {heading_line}", failure)
                self.assertFalse(pr_readiness.evaluate(pr(body), self.FILES).ok)

    def test_a_pending_status_inside_the_same_comment_is_still_refused(self) -> None:
        # The choice the comment case forces, made the way #1744 made it: a
        # run this gate cannot see on the page may refuse and may never
        # accept, so a `[blocked]` under a commented-out heading is named
        # rather than waved through. The author reads one message; the hole
        # the other way is a pending status nobody sees.
        body = self.body(f"<!--\n## Evidence Status\n{self.BLOCKED}\n-->\n\n")
        failure = pr_readiness.unread_status_heading_failure(body)
        self.assertIsNotNone(failure)
        self.assertIn("inside a raw HTML block", failure)

    def test_the_blank_line_control_is_the_section_and_still_refuses_its_status(self) -> None:
        # The repair the message asks for, and the proof the refusal is about
        # the swallowing rather than about the block: one blank line and the
        # heading is the section, whose `[blocked]` line refuses as it always
        # did -- main's verdict, kept.
        body = self.body(f"</details>\n\n## Evidence Status\n\n{self.BLOCKED}\n\n")
        self.assertEqual(len(pr_readiness.status_heading_candidates(body)), 1)
        self.assertIsNone(pr_readiness.unread_status_heading_failure(body))
        self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [PENDING_TEXT])

    def test_a_heading_the_page_shows_as_code_is_still_silent(self) -> None:
        # The line the refusal must NOT cross. A fenced or indented example
        # matches the line scan too, and there the page shows code: no section
        # is the right answer and the section is optional, so a body
        # documenting the format is not a body to refuse.
        for name, example in {
            "a fenced example": "```markdown\n## Evidence Status\n\n- [blocked] an example\n```",
            "an indented example": "    ## Evidence Status\n\n    - [blocked] an example",
        }.items():
            with self.subTest(shape=name):
                body = self.body(f"{example}\n\n")
                self.assertEqual(pr_readiness.status_heading_candidates(body), [])
                self.assertIsNone(pr_readiness.unread_status_heading_failure(body))
                self.assertEqual(self.failures(body), [])

    def test_the_two_heading_message_names_the_heading_this_gate_reads(self) -> None:
        # It said "this gate reads the first", and the first CANDIDATE is not
        # always the one read: the candidate list uses the loose fold, so a
        # long-s heading above the real one is in it and is not the section.
        # The message measures which one is read and says that (#1742,
        # round 2).
        body = self.body(
            "## **Evidence Statuſ**\n\n- [complete] the printer's item -- proof\n\n"
            f"## Evidence Status\n\n{self.BLOCKED}\n\n"
        )
        candidates = pr_readiness.status_heading_candidates(body)
        self.assertEqual(len(candidates), 2, candidates)
        failure = pr_readiness.unread_status_heading_failure(body)
        self.assertIsNotNone(failure)
        read_line = candidates[1][0]
        self.assertIn(f"reads the one at line {read_line}", failure)
        self.assertNotIn("reads the first", failure)

    def test_the_two_heading_message_does_not_say_a_named_line_goes_unread(self) -> None:
        # The other half: the rendered view reads every matching heading, so
        # the same run that said a status "goes unread" then quoted it. What
        # is true of it is that it is not this section's.
        body = self.body(
            "## **Evidence Status**\n\n- [complete] the first -- proof\n\n"
            f"## Evidence Status\n\n{self.BLOCKED}\n\n"
        )
        failure = pr_readiness.unread_status_heading_failure(body)
        self.assertIsNotNone(failure)
        self.assertNotIn("goes unread", failure)
        self.assertIn("is not this section's", failure)
        # And the run does name that status, from the rendered view.
        self.assertTrue(
            any(text.startswith(PENDING_TEXT) for text in self.failures(body)),
            self.failures(body),
        )

    def test_no_candidate_is_read_and_the_message_says_so(self) -> None:
        # Two candidates and neither is the section: the message cannot name a
        # line this gate reads, so it says there is none rather than naming
        # one.
        body = self.body(
            "## Evidence Statuſ\n\n- [complete] one -- proof\n\n"
            f"## Evidence Statuſ\n\n{self.BLOCKED}\n\n"
        )
        failure = pr_readiness.unread_status_heading_failure(body)
        self.assertIsNotNone(failure)
        self.assertIn("none of them is", failure)

# Every shape this one predicate has been probed on, with the verdict it owes
# and the words the refusal owes an author. Four confirmation passes in a row
# each opened a new hole in `_a_status_is_kept_out` and its refusal -- a
# swallowed heading with nothing pending under it, a heading-shaped line
# inside the block, a status wrapped in markup inside it -- and each was found
# by someone reading the code rather than by a test. The table is so the fifth
# pass checks a list it can read instead of hunting for the eleventh shape.
#
# A row is (name, block, refused, fragment): the text placed between the
# Mergeability and Evidence sections of an otherwise passing body, whether
# `evaluate` refuses it, and a phrase the failure must carry. Adding a shape
# here is adding a test.
HEADING_LINE_PREFIX = "The heading at line"
INSIDE_A_BLOCK = "inside a raw HTML block"
BLOCKED_LINE = "- [blocked] the UI lane -- waiting"

SWALLOWED_HEADING_TABLE = (
    # Round 2: the heading is swallowed by an opener a line above it and the
    # status sits below the block in ordinary markdown.
    ("a details closer, status below", f"</details>\n## Evidence Status\n\n{BLOCKED_LINE}\n\n", True, INSIDE_A_BLOCK),
    ("an img tag, status below", f'<img src="https://example.invalid/a.png">\n## Evidence Status\n\n{BLOCKED_LINE}\n\n', True, INSIDE_A_BLOCK),
    ("a div around heading and status", f"<div>\n## Evidence Status\n\n{BLOCKED_LINE}\n\n", True, INSIDE_A_BLOCK),
    ("a comment a browser ends at --!>", f"<!-- note --!>\n\n## Evidence Status\n\n{BLOCKED_LINE}\n\n", True, INSIDE_A_BLOCK),
    # Round 3: the block covers the heading and hides nothing. The section is
    # optional, so its absence is not a body to refuse.
    ("a closed comment, heading alone", "<!--\n## Evidence Status\n-->\n\n", False, None),
    ("a closed comment, a complete item", "<!--\n## Evidence Status\n- [complete] ran it -- 1992 tests passed\n-->\n\n", False, None),
    ("a pre block, a complete item", "<pre>\n## Evidence Status\n- [complete] ran it -- 1992 tests passed\n</pre>\n\n", False, None),
    ("a pre block, a wrapped complete item", "<pre>\n## Evidence Status\n- **[complete]** ran it\n</pre>\n\n", False, None),
    # Round 4: a heading-shaped line INSIDE the block, status below the block.
    # The block prints it as characters; a markdown parser reads it as a
    # heading and ended the synthetic section before the status.
    ("a pre block holding a second heading", f"<pre>\n## Evidence Status\n## Notes\n</pre>\n{BLOCKED_LINE}\n\n", True, INSIDE_A_BLOCK),
    ("a comment holding a second heading", f"<!--\n## Evidence Status\n## Notes\n-->\n{BLOCKED_LINE}\n\n", True, INSIDE_A_BLOCK),
    # Round 5: the status inside the block wrapped in markup the block prints
    # as characters. The list marker is optional here, which is why neither
    # existing pattern covered the pair.
    ("a comment, a bold status", "<!--\n## Evidence Status\n- **[blocked]** waiting\n-->\n\n", True, INSIDE_A_BLOCK),
    ("a comment, a backticked status", "<!--\n## Evidence Status\n- `[blocked]` waiting\n-->\n\n", True, INSIDE_A_BLOCK),
    ("a pre block, a bold status", "<pre>\n## Evidence Status\n- **[blocked]** waiting\n</pre>\n\n", True, INSIDE_A_BLOCK),
    ("a pre block, a bold status with no marker", "<pre>\n## Evidence Status\n**[blocked]** waiting\n</pre>\n\n", True, INSIDE_A_BLOCK),
    ("a pre block, a backticked status with no marker", "<pre>\n## Evidence Status\n`[blocked]` waiting\n</pre>\n\n", True, INSIDE_A_BLOCK),
    ("a pre block, an underscored status", "<pre>\n## Evidence Status\n- _[blocked]_ waiting\n</pre>\n\n", True, INSIDE_A_BLOCK),
    ("a comment, a wrapped pending-ci", "<!--\n## Evidence Status\n- **[pending-ci]** waiting\n-->\n\n", True, INSIDE_A_BLOCK),
    ("a pre block, a backticked pending-ci with no marker", "<pre>\n## Evidence Status\n`[pending-ci]` waiting\n</pre>\n\n", True, INSIDE_A_BLOCK),
    # Controls the refusal must not cost.
    ("a comment, a plain status", "<!--\n## Evidence Status\n- [blocked] waiting\n-->\n\n", True, INSIDE_A_BLOCK),
    ("the blank line the message asks for", f"</details>\n\n## Evidence Status\n\n{BLOCKED_LINE}\n\n", True, PENDING_TEXT),
    ("a fenced example of the heading", "```markdown\n## Evidence Status\n\n- [blocked] an example\n```\n\n", False, None),
    ("an indented example of the heading", "    ## Evidence Status\n\n    - [blocked] an example\n\n", False, None),
)


class TheSwallowedHeadingTableTests(unittest.TestCase):
    """The table, run.

    Each pass over this branch found its shape by reading the predicate. This
    runs every shape any of them found, so the next one reads a list rather
    than looking for the shape nobody has thought of yet -- and so a fix that
    closes one hole and opens another fails here rather than on a pull request.
    """

    FILES = AHeadingNoReaderTakesIsNamedRatherThanIgnoredTests.FILES
    OPENING = AHeadingNoReaderTakesIsNamedRatherThanIgnoredTests.OPENING
    MERGEABILITY = AHeadingNoReaderTakesIsNamedRatherThanIgnoredTests.MERGEABILITY
    EVIDENCE = AHeadingNoReaderTakesIsNamedRatherThanIgnoredTests.EVIDENCE

    def body(self, middle: str) -> str:
        return f"{self.OPENING}{self.MERGEABILITY}{middle}{self.EVIDENCE}"

    def test_every_probed_shape_gets_the_verdict_it_owes(self) -> None:
        for name, block, refused, fragment in SWALLOWED_HEADING_TABLE:
            with self.subTest(shape=name):
                result = pr_readiness.evaluate(pr(self.body(block)), self.FILES)
                self.assertEqual(result.ok, not refused, (name, result.failures))
                if fragment is not None:
                    self.assertTrue(
                        any(fragment in failure for failure in result.failures),
                        (name, result.failures),
                    )

    def test_a_refused_shape_names_the_heading_line_and_the_block_line(self) -> None:
        # The message is the whole value of refusing rather than going quiet,
        # so the table checks that every swallowed-heading refusal still
        # carries both line numbers and the repair.
        for name, block, refused, fragment in SWALLOWED_HEADING_TABLE:
            if not refused or fragment != INSIDE_A_BLOCK:
                continue
            with self.subTest(shape=name):
                body = self.body(block)
                failure = pr_readiness.unread_status_heading_failure(body)
                self.assertIsNotNone(failure, name)
                heading_line = body[: body.index("## Evidence Status")].count("\n") + 1
                self.assertIn(f"{HEADING_LINE_PREFIX} {heading_line}", failure)
                self.assertIn("blank line", failure)

    def test_the_table_covers_both_status_tokens_and_every_wrapper(self) -> None:
        # A table nobody checks the shape of grows lopsided. These are the
        # axes the four passes actually moved along.
        rows = "\n".join(block for _, block, _, _ in SWALLOWED_HEADING_TABLE)
        for token in ("[blocked]", "[pending-ci]", "[complete]"):
            self.assertIn(token, rows)
        for wrapper in ("**[", "`[", "_["):
            self.assertIn(wrapper, rows)
        for container in ("<!--", "<pre>", "<div>", "</details>", "<img"):
            self.assertIn(container, rows)


class HeadingIdentityFoldsCaseAndNotLettersTests(unittest.TestCase):
    """Which two heading texts are one heading, and which are two (#1742).

    Identity was compared after `casefold()`, and full case folding maps
    characters no reader calls the same letter. `## Evidence Statu\u017f` -- a long
    s, the eighteenth-century printer's `s` -- folded onto `Evidence Status`,
    so a body carrying it above the real heading had one heading to every
    reader here and two on the page. The first one won the identity, the
    rewrite then removed every section under that name, and the body came back
    with neither section's contents (#1742).

    `lower()` is the fold, and what it accepts is every single-character case
    pair Unicode records: `STATUS` and `Status` are one heading in any
    alphabet, `\u03a9` and `\u03c9` with them. What it declines is a fold that
    changes the letters rather than their case -- `\u017f`/`s`, `\u00df`/`ss`,
    `\ufb01`/`fi` -- which is the set a reader reads as a different word.

    NFKC was the other candidate on the table and it goes the wrong way: it
    maps a fullwidth `\uff33` onto `s` as well, so `## Evidence Statu\uff33` would
    alias too, and that is a heading the page shows as a visibly different
    word.
    """

    HELPERS_PATH = (
        REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
    )

    # (left, right, one heading?) -- read off the rule rather than recalled,
    # one member per branch of it.
    PAIRS = (
        ("Evidence Status", "Evidence Status", True),
        ("Evidence Status", "EVIDENCE STATUS", True),
        ("Evidence Status", "evidence status", True),
        ("Evidence  Status", "Evidence Status", True),
        ("Evidence\tStatus", "Evidence Status", True),
        # Every one of these is a fold that changes letters, not case.
        ("Evidence Statu\u017f", "Evidence Status", False),
        ("Evidence Statu\uff33", "Evidence Status", False),
        ("Stra\u00dfe", "STRASSE", False),
        ("O\ufb01ce", "Ofice", False),
        # And the one the gate's old `(?i)` pattern matched and no parse did.
        ("MERGEAB\u0130LITY", "Mergeability", False),
    )

    def owner(self):
        spec = importlib.util.spec_from_file_location("contributor_helpers", self.HELPERS_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_the_fold_calls_two_texts_one_heading_only_when_a_reader_would(self) -> None:
        for left, right, same in self.PAIRS:
            with self.subTest(left=left, right=right):
                self.assertEqual(
                    pr_readiness.heading_identity(left) == pr_readiness.heading_identity(right),
                    same,
                )

    def test_the_skills_copy_of_the_fold_answers_as_this_gates_does(self) -> None:
        # Written twice for the reason `MARKDOWN` is: this gate is a PEP 723
        # entry point with its own pin and no package for the skill to import.
        owner = self.owner()
        for left, right, _ in self.PAIRS:
            for text in (left, right):
                with self.subTest(text=text):
                    self.assertEqual(
                        pr_readiness.heading_identity(text), owner.heading_identity(text)
                    )

    def test_only_one_codepoint_could_alias_an_ascii_heading(self) -> None:
        # Why a fold that declines these is enough, measured over the whole
        # table rather than over the characters someone thought of. Every
        # section this repo addresses is spelled in ASCII, so what matters is
        # which codepoints `casefold()` maps ONTO an ASCII letter and `lower()`
        # does not -- and there is exactly one of them.
        differ = [
            char
            for point in range(0x110000)
            for char in [chr(point)]
            if char.casefold() != char.lower()
        ]
        onto_ascii = [
            char for char in differ if len(folded := char.casefold()) == 1 and folded.isascii()
        ]
        self.assertEqual(onto_ascii, ["\u017f"])
        # The rest of the difference, named so the number is not a bare fact:
        # the multi-character foldings (`\u00df` -> `ss`, `\ufb01` -> `fi`) and
        # the non-ASCII singletons (`\u03c2` -> `\u03c3`, `\u00b5` -> `\u03bc`).
        self.assertEqual(len(differ), 297)
        self.assertEqual(len([char for char in differ if len(char.casefold()) > 1]), 103)

    def test_a_setext_heading_over_two_lines_is_still_this_heading(self) -> None:
        # A line break in a heading is a space in both readers, so a heading
        # underlined over two lines reads as the one heading the page shows.
        owner = self.owner()
        body = "Why this exists.\n\nEvidence\nStatus\n---\n- [complete] the item -- checked\n"
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] the item -- checked",
        )
        self.assertEqual(
            owner.markdown_section(body, "Evidence Status"), "- [complete] the item -- checked"
        )
        # And a single word broken across those lines is not, because the page
        # shows a space in it too.
        split = "Why this exists.\n\nEviden\nce Status\n---\n- [complete] the item -- checked\n"
        self.assertEqual(pr_readiness.extract_section(split, "Evidence Status"), "")
        self.assertEqual(owner.markdown_section(split, "Evidence Status"), "")

    def test_casefold_is_the_rule_that_was_replaced(self) -> None:
        # The measurement that says the change is not a no-op: every declining
        # pair above that `casefold()` called one heading.
        aliased = [
            (left, right)
            for left, right, same in self.PAIRS
            if not same
            and " ".join(left.split()).casefold() == " ".join(right.split()).casefold()
        ]
        self.assertEqual(
            aliased,
            [
                ("Evidence Statu\u017f", "Evidence Status"),
                ("Stra\u00dfe", "STRASSE"),
                ("O\ufb01ce", "Ofice"),
            ],
        )


class TheLongSHeadingIsNotThisSectionInEitherReaderTests(unittest.TestCase):
    """A body with `## Evidence Statu\u017f` above the real heading keeps both sections (#1742).

    The harm this closes, stated as a body rather than as a fold: with the two
    headings aliased, `section_heading_index` answered with the FIRST one, the
    rewrite's cut removed every section matching that name -- both of them --
    and the body came back holding neither the author's long-s section nor
    their real one. Two visibly different headings on the page, one heading to
    the reader that rewrites them.
    """

    HELPERS_PATH = HeadingIdentityFoldsCaseAndNotLettersTests.HELPERS_PATH
    LONG_S = "## Evidence Statu\u017f"
    ALIASED = (
        "Why this exists, plainly, in a paragraph long enough to read as one.\n\n"
        f"{LONG_S}\n\n"
        "- [complete] the printer's heading -- not this section\n\n"
        "## Evidence Status\n\n"
        "- [complete] the real item -- checked\n"
    )

    def owner(self):
        return HeadingIdentityFoldsCaseAndNotLettersTests.owner(self)

    def test_the_section_is_the_one_whose_heading_reads_as_it(self) -> None:
        owner = self.owner()
        tokens = owner._parsed(self.ALIASED)
        index = owner.section_heading_index(tokens, "Evidence Status")
        self.assertIsNotNone(index)
        # The real heading, not the long-s one three lines above it.
        self.assertEqual(tokens[index].map[0], 6)
        self.assertEqual(
            owner.markdown_section(self.ALIASED, "Evidence Status"),
            "- [complete] the real item -- checked",
        )

    def test_a_rewrite_leaves_the_long_s_section_alone(self) -> None:
        owner = self.owner()
        texts, refusal = owner.removed_section_texts(self.ALIASED, "Evidence Status")
        self.assertIsNone(refusal)
        self.assertEqual(len(texts), 1)
        written = owner.insert_markdown_section(
            self.ALIASED, "Evidence Status", "- [complete] the real item -- re-checked"
        )
        self.assertIn(self.LONG_S, written)
        self.assertIn("- [complete] the printer's heading -- not this section", written)
        self.assertIn("- [complete] the real item -- re-checked", written)

    def test_this_gate_reads_the_same_section(self) -> None:
        # The gate's old literal start aliased too: `re` with `(?i)` on a str
        # pattern applies full case folding, so `^## Evidence Status\n` matched
        # the long-s line and the gate read the printer's section.
        self.assertEqual(
            pr_readiness.extract_section(self.ALIASED, "Evidence Status"),
            "- [complete] the real item -- checked",
        )

    # Every reader that decides which heading is this section, on one body.
    # They were four separate `casefold()` calls and one pattern; a fold moved
    # in one of them and not the others is two readers disagreeing about a
    # body, which is the whole subject of #1730, #1734, #1736 and this issue.
    def test_all_five_readers_of_this_heading_answer_together(self) -> None:
        owner = self.owner()
        evidence = self.evidence()
        body = (
            "Why this exists, plainly, in a paragraph long enough to read as one.\n\n"
            f"{self.LONG_S}\n\n"
            "- [pending-ci] the printer's item -- waiting\n\n"
            "## Evidence Status\n\n"
            "- [complete] the real item -- checked\n"
        )
        tokens = owner._parsed(body)
        # 1. the skill's written read: the real heading, not the long-s one.
        self.assertEqual(tokens[owner.section_heading_index(tokens, "Evidence Status")].map[0], 6)
        # 2. the skill's rejected-heading read: the long-s heading carries no
        #    tag, so it is not a REJECTED heading either -- it is another
        #    heading, which is what the page shows.
        self.assertEqual(owner.rejected_section_headings(tokens, "Evidence Status"), [])
        # 3. the owner read's heading count: one heading reads as this
        #    section, so it reads the section rather than refusing for two.
        lines, reason = evidence._rendered_status_lines(body)
        self.assertIsNone(reason)
        self.assertEqual(lines, ["[complete] the real item -- checked"])
        # 4. this gate's rendered read: the same one section.
        self.assertEqual(
            pr_readiness.rendered_status_lines(body), ["[complete] the real item -- checked"]
        )
        # 5. this gate's written read, and so no pending failure from a
        #    section that is not this section.
        self.assertEqual(
            pr_readiness.extract_section(body, "Evidence Status"),
            "- [complete] the real item -- checked",
        )
        self.assertNotIn(
            PENDING_TEXT,
            [failure.split(" The page shows")[0] for failure in
             pr_readiness.evaluate(pr(body), ["Sources/WorkspaceManager/Foo.swift"]).failures],
        )

    def test_no_heading_identity_site_still_folds_with_casefold(self) -> None:
        # The fold is one function now, and this is what says so about the
        # call sites rather than about the function: a reader that kept its own
        # `casefold()` would pass every behavioural test above on every body
        # that does not carry an aliasing character.
        import inspect

        owner = self.owner()
        evidence = self.evidence()
        for label, function in (
            ("the skill's written read", owner.section_heading_index),
            ("the skill's rejected-heading read", owner.rejected_section_headings),
            ("the owner read's heading count", evidence._rendered_status_lines),
            ("this gate's section start", pr_readiness.section_heading_index),
            ("this gate's rendered read", pr_readiness.rendered_status_lines),
        ):
            with self.subTest(reader=label):
                source = inspect.getsource(function)
                body = source[source.index('"""', source.index('"""') + 3) + 3 :]
                self.assertNotIn("casefold", body, label)
                self.assertIn("heading_identity", body, label)

    def evidence(self):
        spec = importlib.util.spec_from_file_location(
            "contributor_evidence",
            self.HELPERS_PATH.with_name("evidence.py"),
        )
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(self.HELPERS_PATH.parent))
        try:
            spec.loader.exec_module(module)
        finally:
            sys.path.remove(str(self.HELPERS_PATH.parent))
        return module


class SectionBoundaryAgreementBetweenTheGateAndTheSkillTests(unittest.TestCase):
    """Where the gate and the contributor skill end `## Evidence Status`, and where they do not (#1734).

    They agree on 1,158 of the 1,596 cells below and part company on 438, all
    of them under a fence that never closes. "In the same place" is what this
    line said while the class measured both answers, which is the shape of
    claim the whole round is about (#1738, round 2).

    Two files answer this, and neither can import the other: the gate runs on
    every PR in the repo from its own PEP 723 pin, and the skill's reader is a
    private module in a skill directory. So the rule is written twice and
    agreement is a property to assert rather than a thing the code structure
    gives. Where they part company, a body is one section to the gate and
    another to the reader that rewrites it, which is how a `# Release blockers`
    after the section came to be carried into `## Evidence Notes` with its
    `- [blocked]` bullet dropped.

    The fixtures are the cross product of two axes rather than a list: the line
    shape being tested as a boundary, and the block it is written inside or
    under, over all three line endings GitHub stores. Listing the shapes
    someone thought of is how this test passed while the two sides disagreed on
    a setext h1, on three dash rules, on a heading indented one space and on a
    heading under an unterminated HTML block (#1734, round 2); listing them
    along ONE axis is how it then passed naming a single divergence while
    eighteen more cells diverged, because the shape and the block it sits in
    were varied together and `h1 under runaway fence` reads as one fixture
    (#1738).

    Where they diverge is declared per CONTEXT and never per cell, because the
    context is where the cause lives. The two readers run the same parser over
    the same body, so a construct alone cannot tell them apart: the whole of
    the difference is the skill's repair of a top-level fence that never closes
    (`reparsed_without_runaway`), which the gate does not make. `CONTEXT_VERDICTS`
    is that statement, one line per context, and a context added without one
    goes red -- which is the guard the old per-shape list did not have, since a
    shape could be added to it and simply not be named a divergence.
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

    # The line shapes that could end a section, derived from the two rules
    # rather than recalled: the heading levels and the ways to write one
    # (hashes, hashes with no text, a closing run, an underline), the indents
    # CommonMark allows and the one it does not, the dash rules of every
    # length and spacing, and the rules that are not dashes.
    #
    # Shapes only, with nothing around them. WHERE a shape sits is the second
    # axis, and keeping the two apart is the point: as a single fixture, `h1
    # under runaway fence` said the divergence belonged to the h1, and it
    # belongs to the fence.
    BOUNDARY_CONSTRUCTS = {
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
    }

    # Where the shape is written: the fence forms it can sit inside or under,
    # the blocks that hide a heading, and the nestings that stop one being
    # top-level. `(above, below, first, rest)` -- the text written above the
    # construct, the text written below it, and the prefix its first and its
    # later lines carry.
    #
    # Four runaway forms, because a fence's closing rule has four ways to go
    # unmet and one ``` example proved only the first: a tilde fence closes on
    # tildes, a four-backtick fence is not closed by three, and a three-tick
    # line inside a four-tick one opens a second fence once the first is
    # repaired -- the loop in `reparsed_without_runaway` is written for that
    # and had no fixture reaching it.
    BOUNDARY_CONTEXTS = {
        "bare": ("", "", "", ""),
        "in a closed backtick fence": ("```markdown\n", "```\n", "", ""),
        "in a closed tilde fence": ("~~~\n", "~~~\n", "", ""),
        "in a closed fence indented three": ("   ```\n", "   ```\n", "   ", "   "),
        "in a closed four backtick fence": ("````\n", "````\n", "", ""),
        # A backtick inside a backtick fence's info string means the line opens
        # no fence, so the construct below it is live markdown and the line
        # meant to CLOSE the fence is the one that opens one -- and that one
        # never closes. This is the context where divergence depends on the
        # construct: a construct that ends the section ends it above the
        # runaway fence and the two agree, and one that does not leaves both
        # readers looking at the fence, where they do not.
        "under a voided fence opener, above a real one": ("``` a`b\n", "```\n", "", ""),
        "under a runaway backtick fence": ("```\nthe log, never closed\n\n", "", "", ""),
        "under a runaway tilde fence": ("~~~\nthe log, never closed\n\n", "", "", ""),
        "under a runaway four backtick fence": ("````\nthe log, never closed\n\n", "", "", ""),
        "under a nested four then three fence": ("````\nthe log\n```\nstill code\n\n", "", "", ""),
        # Only a BACKTICK fence's info string forbids a backtick. A tilde
        # fence takes one, so `~~~ a`b` opens a fence where ``` a`b opens
        # none -- the two contexts read as a matched pair and are opposites.
        # Found by codex (gpt-5.6-sol, xhigh): with no tilde opener carrying an
        # info string anywhere in the grid, a skill that skipped the repair for
        # exactly that shape kept all 160 tests green.
        "under a runaway tilde fence with a backtick info": ("~~~ a`b\nthe log, never closed\n\n", "", "", ""),
        "after a closed comment": ("<!-- a note -->\n\n", "", "", ""),
        # CommonMark runs an unclosed comment to the end of the document too,
        # and neither reader repairs it -- the skill's repair is fences only.
        # So this context hides as much as a runaway fence and costs no
        # divergence at all, which is the control saying the divergence is
        # about the repair rather than about hiding.
        "under an unclosed comment": ("<!-- a note\n\n", "", "", ""),
        "in a list item": ("", "", "- ", "  "),
        "in a block quote": ("", "", "> ", "> "),
        "in an indented code block": ("", "\ntext\n", "    ", "    "),
        # A fence that never closes but is not TOP-LEVEL. The skill's
        # `runaway_fence` asks `token.level == 0`, so it does not repair one
        # nested in a list item or a quote, and neither reader is looking past
        # it -- these are the contexts that say the divergence is about the
        # repair's own condition and not about a fence anywhere in the body.
        "under a runaway fence nested in a list item": ("- an item\n  ```\n  a log\n\n", "", "", ""),
        "under a runaway fence nested in a block quote": ("> quoted\n> ```\n> a log\n\n", "", "", ""),
        # Four spaces in is an indented code block and not a fence at all, so
        # nothing runs away and nothing is hidden.
        "under a fence opener indented four": ("    ```\n    a log\n\n", "", "", ""),
    }

    # Whether the two readers part company in each context, and nothing per
    # cell. `by the fence the section runs into` is the single context whose
    # answer depends on the construct written into it: the line that was meant
    # to close the voided opener opens a fence of its own, so a construct that
    # ends the section ends it ABOVE that fence and the two agree, and one that
    # does not leaves both readers looking at it and they do not.
    CONTEXT_VERDICTS = {
        "bare": "agree",
        "in a closed backtick fence": "agree",
        "in a closed tilde fence": "agree",
        "in a closed fence indented three": "agree",
        "in a closed four backtick fence": "agree",
        "under a voided fence opener, above a real one": "by the fence the section runs into",
        "under a runaway backtick fence": "diverge",
        "under a runaway tilde fence": "diverge",
        "under a runaway four backtick fence": "diverge",
        "under a nested four then three fence": "diverge",
        "under a runaway tilde fence with a backtick info": "diverge",
        "after a closed comment": "agree",
        # CommonMark runs an unclosed comment to the end of the document too,
        # and neither reader repairs it -- the skill's repair is fences only.
        # So this hides as much as a runaway fence and costs no divergence,
        # which is the control saying the divergence is about the repair rather
        # than about hiding.
        "under an unclosed comment": "agree",
        "in a list item": "agree",
        "in a block quote": "agree",
        "in an indented code block": "agree",
        "under a runaway fence nested in a list item": "agree",
        "under a runaway fence nested in a block quote": "agree",
        "under a fence opener indented four": "agree",
    }
    CANDIDATE_TAIL = "- [blocked] the signing profile is missing\n\n## Validation\n- ran it\n"

    @staticmethod
    def _lf(text: str) -> str:
        return text.replace("\r\n", "\n").replace("\r", "\n")

    @staticmethod
    def in_context(construct: str, context: tuple[str, str, str, str]) -> str:
        """One construct written into one context, so the grid is generated rather than transcribed."""
        above, below, first, rest = context
        lines = construct.split("\n")
        indented = [
            line if index == len(lines) - 1 and line == "" else (first if index == 0 else rest) + line
            for index, line in enumerate(lines)
        ]
        return above + "\n".join(indented) + below

    def candidate_bodies(self):
        """Every construct, in every context, in every line ending GitHub stores.

        Bare `\r` is the third: the gate normalises it before reading and the
        skill's heading pattern did not take it, so the two read different
        sections of one body -- an axis the first derivation missed because it
        generated only the two endings anyone types (#1734, round 2).
        """
        for construct_name, construct in self.BOUNDARY_CONSTRUCTS.items():
            for context_name, context in self.BOUNDARY_CONTEXTS.items():
                for ending in ("\n", "\r\n", "\r"):
                    candidate = self.in_context(construct, context)
                    body = (self.STATUS + candidate + "\n" + self.CANDIDATE_TAIL).replace("\n", ending)
                    yield construct_name, context_name, ending, body

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

    # The whole of the difference between the two readers, stated as the one
    # thing that causes it rather than as a list of shapes it shows up on.
    DIVERGENCE = (
        "the skill ends the section at the first boundary the REPAIRED parse finds -- it blanks "
        "the opener of a top-level fence that never closes and asks the parser again, so it reads "
        "the heading the author wrote -- and the gate ends it at the next boundary the unrepaired "
        "parse finds, which is the end of the body, because CommonMark runs an unclosed fence to "
        "the last line and every heading below it is code. The page is on the gate's side and "
        "the author on the skill's. What the longer reading costs is measured in "
        "`WhatTheGateSLongerReadingCostsTests`: it is not one direction"
    )

    # Both counts, so the property cannot be satisfied by a grid that stopped
    # generating. 28 constructs x 19 contexts x 3 line endings.
    CELL_COUNT = 28 * 19 * 3
    DIVERGING_CELLS = 438
    # Every diverging cell in the one context whose answer varies by construct.
    SPLIT_CONTEXT = "under a voided fence opener, above a real one"
    SPLIT_CONTEXT_DIVERGING_CELLS = 18

    def test_every_context_says_whether_the_two_readers_part_company_in_it(self) -> None:
        # The guard the old list did not have. A shape could be added to
        # `BOUNDARY_CANDIDATES` and simply not be named in `DIVERGE`, which
        # reads as "they agree" whether or not anyone checked -- and that is
        # how `h1 under runaway fence` came to stand for eighteen cells nobody
        # had looked at (#1738). A context with no verdict fails here.
        self.assertEqual(set(self.CONTEXT_VERDICTS), set(self.BOUNDARY_CONTEXTS))
        self.assertEqual(
            set(self.CONTEXT_VERDICTS.values()),
            {"agree", "diverge", "by the fence the section runs into"},
        )

    def test_the_two_rules_agree_on_every_shape_that_could_end_a_section(self) -> None:
        # The derived property. Each cell is read by both files and the extents
        # have to match -- on one kind of line ending rather than on the
        # author's bytes -- unless its context says otherwise.
        owner = self.owner_reader()
        agreed = diverged = split_diverged = 0
        for construct, context, ending, body in self.candidate_bodies():
            label = {"\n": "lf", "\r\n": "crlf", "\r": "cr"}[ending]
            with self.subTest(shape=construct, context=context, ending=label):
                gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
                skill = self._lf(owner.markdown_section(body, "Evidence Status"))
                verdict = self.CONTEXT_VERDICTS[context]
                if verdict == "by the fence the section runs into":
                    # Whether the section ran INTO that fence, asked of this
                    # gate's own line scanner. It is an oracle for this one
                    # context, where the fence is top-level and the slice
                    # starts above it -- not a general rule, which
                    # `test_the_line_scanner_is_an_oracle_here_and_not_a_law`
                    # is the fixture for.
                    expected = pr_readiness.split_fenced_blocks(gate)[1] is not None
                    split_diverged += expected
                else:
                    expected = verdict == "diverge"
                if expected:
                    self.assertNotEqual(gate, skill, self.DIVERGENCE)
                    diverged += 1
                else:
                    self.assertEqual(gate, skill)
                    agreed += 1
        self.assertEqual(agreed + diverged, self.CELL_COUNT)
        self.assertEqual(diverged, self.DIVERGING_CELLS)
        # The oracle's own share, pinned, so it cannot quietly answer for every
        # cell of its context or for none of them.
        self.assertEqual(split_diverged, self.SPLIT_CONTEXT_DIVERGING_CELLS)

    def test_the_line_scanner_is_an_oracle_here_and_not_a_law(self) -> None:
        # `split_fenced_blocks` reads lines and knows nothing about nesting, so
        # "the gate's reading holds an unclosed fence" is not the same sentence
        # as "the two readers disagree". A fence that never closes inside a
        # list item is the counterexample: the skill's repair asks for a
        # TOP-LEVEL fence and this is not one, so neither reader looks past it
        # and they agree -- while the scanner reports an opener with nothing
        # closing it. Written as a fixture because the grid passing is what
        # would otherwise make the coincidence look like a rule.
        owner = self.owner_reader()
        nested = self.BOUNDARY_CONTEXTS["under a runaway fence nested in a list item"]
        body = (
            self.STATUS
            + self.in_context(self.BOUNDARY_CONSTRUCTS["atx h1"], nested)
            + "\n"
            + self.CANDIDATE_TAIL
        )
        gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
        self.assertEqual(gate, self._lf(owner.markdown_section(body, "Evidence Status")))
        self.assertEqual(pr_readiness.split_fenced_blocks(gate)[1], "```")
        # The other way it comes apart, found by codex (gpt-5.6-sol, xhigh): a
        # fence opener on the section's last line. The skill DOES repair here
        # -- the fence is top-level -- and the repaired parse finds no boundary
        # the unrepaired one missed, because there is nothing below to find. So
        # the extent is the same to both while the scanner still reports an
        # opener. The grid cannot reach it: every cell is followed by
        # `CANDIDATE_TAIL`, so the opener is never the last line.
        last_line = "## Evidence Status\n```\n"
        gate = pr_readiness.extract_section(last_line, "Evidence Status")
        self.assertEqual(gate, owner.markdown_section(last_line, "Evidence Status"))
        self.assertEqual(pr_readiness.split_fenced_blocks(gate)[1], "```")

    def test_the_divergence_is_the_repair_and_not_the_hiding(self) -> None:
        # The verdicts, measured. Every runaway top-level fence form diverges
        # on every construct; the contexts that hide as much without being a
        # top-level fence -- an unclosed comment, and a runaway fence nested in
        # a list item or a quote -- diverge on none. And one context splits,
        # which is the cell the old one-axis list could not express.
        owner = self.owner_reader()
        measured: dict[str, set[bool]] = {name: set() for name in self.BOUNDARY_CONTEXTS}
        for _, context, _, body in self.candidate_bodies():
            gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
            measured[context].add(gate != self._lf(owner.markdown_section(body, "Evidence Status")))
        for context, verdict in self.CONTEXT_VERDICTS.items():
            with self.subTest(context=context):
                expected = {
                    "agree": {False},
                    "diverge": {True},
                    "by the fence the section runs into": {True, False},
                }[verdict]
                self.assertEqual(measured[context], expected)
        # And the shape of the table itself: the divergence belongs to five
        # fence forms and nothing else, so a sixth appearing is a finding.
        self.assertEqual(
            {name for name, verdict in self.CONTEXT_VERDICTS.items() if verdict == "diverge"},
            {
                "under a runaway backtick fence",
                "under a runaway tilde fence",
                "under a runaway four backtick fence",
                "under a nested four then three fence",
                "under a runaway tilde fence with a backtick info",
            },
        )

    def test_the_agreement_is_not_vacuous(self) -> None:
        # Two readers that both returned "" would agree on everything. The
        # status line has to survive in every reading, and the boundary has to
        # actually move: each reader has to end the section early on some
        # cells and run past the `[blocked]` line on others.
        owner = self.owner_reader()
        gate_early = skill_early = 0
        for construct, context, _, body in self.candidate_bodies():
            gate = self._lf(pr_readiness.extract_section(body, "Evidence Status"))
            skill = self._lf(owner.markdown_section(body, "Evidence Status"))
            with self.subTest(shape=construct, context=context):
                self.assertIn("[complete] unit tests -- 10 passed", gate)
                self.assertIn("[complete] unit tests -- 10 passed", skill)
            gate_early += "[blocked]" not in gate
            skill_early += "[blocked]" not in skill
        # Floors on both readers in both directions, so neither can be a
        # function that always stops or always runs on.
        for reader, early in (("gate", gate_early), ("skill", skill_early)):
            with self.subTest(reader=reader):
                self.assertGreater(early, 100)
                self.assertGreater(self.CELL_COUNT - early, 100)

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


class TheRuntimeSeedsASectionAndThisGateThenReadsItTests(unittest.TestCase):
    """What the seeder writes, and what this gate now reads with it (#1730, #1742).

    `seed_mergeability_section` decided whether a body already had the section
    by matching a `## Mergeability` line anywhere, so a body documenting the
    section's format in a fenced example got nothing written and said nothing
    about it. The runtime's presence check is a parse now and it writes the
    section.

    This gate was the other half, and for one release longer it was not fixed
    here: its written read ENDED where the parser said since #1734 and still
    STARTED at the first line matching `^## <heading>`, so on a body like this
    one it read the example as the section. Out of scope then by measurement --
    of 400 stored pull-request bodies, none carried a section heading this gate
    read that the page showed as code -- and the shape was pinned rather than
    claimed fixed, because a fenced example carrying all four fields is the
    same misread spending an approval instead of a refusal. #1742 moved the
    start onto the same parse, and the pins below now read the other way.
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

    def test_this_gate_no_longer_takes_the_first_line_it_matches_as_the_start(self) -> None:
        # The pin, read the other way round. The gate used to read the
        # example's one-field list on the seeded body while the skill read the
        # section the runtime wrote; both ends came from the parser and only
        # the start disagreed. Now both starts do too, so the two readers
        # return the same text and the gate passes the body the factory heals.
        seeded = self.seeder().seed_mergeability_section(
            self.FENCED_EXAMPLE_BODY, changed_files=["Sources/Foo.swift"]
        )
        gate_read = pr_readiness.extract_section(seeded, "Mergeability")
        self.assertIn("`Sources/Foo.swift`", gate_read)
        self.assertEqual(gate_read, self.reader().markdown_section(seeded, "Mergeability"))
        self.assertEqual(pr_readiness.evaluate(pr(seeded), ["Sources/Foo.swift"]).failures, [])

    def test_the_unseeded_example_is_a_refusal_rather_than_an_approval(self) -> None:
        # And the shape the pin named as the one that costs an approval: the
        # same example with all four fields, on a body the factory never
        # touched. The gate read it as a filled section and approved a pull
        # request whose page shows no section at all; it now says the section
        # is missing.
        complete = GOOD_BODY.replace(
            "## Mergeability\n", "```markdown\n## Mergeability\n", 1
        ).replace("- Residual risk or follow-up: none\n", "- Residual risk or follow-up: none\n```\n", 1)
        self.assertFalse(self.reader().has_markdown_section(complete, "Mergeability"))
        result = pr_readiness.evaluate(pr(complete), ["Sources/Foo.swift"])
        self.assertFalse(result.ok)
        self.assertIn("Missing ## Mergeability section from the PR body.", result.failures)

    def test_the_fence_refusal_this_start_used_to_invent_is_gone(self) -> None:
        """The fail-open the old start caused, and the bad refusal it also caused (#1738).

        `WhatTheGateSLongerReadingCostsTests` measures what the gate's longer
        reading costs. The obvious answer to the fail-open was for this gate to
        refuse a section it reads two ways, which it already does for
        `Evidence Status` -- `split_fenced_blocks` names the opener and the
        author closes the fence.

        Run over `Mergeability` on main, that refusal fired on this body, whose
        fences all close, because the slice BEGAN inside a closed fence and the
        fence's own closing line was then the first fence marker in it. It
        would have told an author to close a fence they closed, on a body the
        factory itself writes. The parsed start begins below the heading the
        runtime wrote, so the slice holds no fence marker at all and the
        question does not arise.
        """
        seeded = self.seeder().seed_mergeability_section(
            self.FENCED_EXAMPLE_BODY, changed_files=["Sources/Foo.swift"]
        )
        # Every fence in the body closes, and now so does every fence in the
        # gate's slice of it -- because there is none.
        self.assertIsNone(pr_readiness.split_fenced_blocks(seeded)[1])
        section = pr_readiness.extract_section(seeded, "Mergeability", strip=False)
        self.assertNotIn("```", section)
        self.assertIsNone(pr_readiness.split_fenced_blocks(section)[1])


class TheSeederAndThisGateAskOneQuestionTests(unittest.TestCase):
    """A heading the page shows is a section to both readers (#1730, #1742).

    The runtime's presence check asks the parser, so a heading the page shows
    is a heading to it: `## **Mergeability**`, one indented up to three spaces,
    and a setext `Mergeability` over a rule. This gate found a section's START
    with a literal `^## <heading>` line, and the two composed into a body the
    factory believed it had healed and the gate then blocked: seeding skipped
    because the section was there, `extract_section` returning nothing, so
    `Missing ## Mergeability section from the PR body`.

    The seeder's answer was to ask both questions and skip only when both said
    yes -- the page shows the heading AND this gate can read it -- with a copy
    of the gate's pattern living beside it. This gate asks the parser now, by
    the same identity rule, so the second question had the same answer as the
    first: the copy is gone, the seeder asks one question, and what this class
    measures is that the two readers find the same start on every shape either
    rule set can tell apart for a plain-word heading -- which is every heading
    this repo addresses. The one divergence outside that, a heading argument
    whose own text holds markup, has its own fixture below.
    """

    SCRIPTS = TheRuntimeSeedsASectionAndThisGateThenReadsItTests.SCRIPTS
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
    # Each is a heading the page shows and the gate's old literal start missed.
    SHAPES = {
        "emphasis": "## **Mergeability**",
        "indented three spaces": "   ## Mergeability",
        "setext": "Mergeability\n---",
        "trailing spaces": "## Mergeability  ",
    }

    def seeder(self):
        return TheRuntimeSeedsASectionAndThisGateThenReadsItTests.seeder(self)

    def reader(self):
        return TheRuntimeSeedsASectionAndThisGateThenReadsItTests.reader(self)

    def test_a_heading_only_the_page_shows_needs_no_seeding_and_passes(self) -> None:
        # What the two questions were for, now answered by one: the body is
        # returned unwritten because the section is there, and the gate reads
        # the author's own section rather than reporting it missing.
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.BODY.format(heading=heading)
                seeded = self.seeder().seed_mergeability_section(body, changed_files=self.FILES)
                self.assertEqual(seeded, body, "the seeder wrote a section the body already showed")
                self.assertEqual(pr_readiness.evaluate(pr(body), self.FILES).failures, [])

    def test_the_one_question_is_the_parse(self) -> None:
        reader, seeder = self.reader(), self.seeder()
        # A literal heading the page shows: nothing is written.
        literal = self.BODY.format(heading="## Mergeability")
        self.assertTrue(reader.has_markdown_section(literal, "Mergeability"))
        self.assertEqual(seeder.seed_mergeability_section(literal, changed_files=self.FILES), literal)
        # A fenced example: the page does not show it, so the seeder goes in --
        # and this gate does not read it either.
        fenced = TheRuntimeSeedsASectionAndThisGateThenReadsItTests.FENCED_EXAMPLE_BODY
        self.assertFalse(reader.has_markdown_section(fenced, "Mergeability"))
        self.assertEqual(pr_readiness.extract_section(fenced, "Mergeability"), "")
        self.assertNotEqual(
            seeder.seed_mergeability_section(fenced, changed_files=self.FILES), fenced
        )
        # And the shapes the page shows: both readers find them, so neither
        # half of the old conjunction is left to be load-bearing.
        for name, heading in self.SHAPES.items():
            with self.subTest(shape=name):
                body = self.BODY.format(heading=heading)
                self.assertTrue(reader.has_markdown_section(body, "Mergeability"))
                self.assertTrue(bool(pr_readiness.extract_section(body, "Mergeability")))

    HEADING = "Mergeability"
    ATX = f"## {HEADING}"

    # Every axis on which this gate's start and the skill's could disagree,
    # each read off the two rule sets rather than remembered. Both are now a
    # parse over the same tokens, so the axes are CommonMark's ways of making
    # an h2 -- and, since #1742, the identity rule the two share: the heading's
    # rendered text, whitespace collapsed and case folded with `lower()`, with
    # any inline construct that shows something of its own disqualifying it.
    #
    # Derived rather than listed because a listed set is blind on the axis
    # nobody thought of: widening the gate to accept a closing hash run
    # (`## Mergeability ##`, an ordinary ATX heading) left all 153 tests green,
    # because no fixture carried one.
    #
    # And GENERATED rather than typed, because a listed set is also wrong on
    # the shape somebody mistyped. One member was `"## MERGEABILITY"[:-1] + "Y"`,
    # which is `## MERGEABILITY` -- the case axis a second time -- so the set
    # held 23 distinct shapes under a count of 24 and the count was the only
    # thing that noticed nothing (#1730, round 2). Each axis is a rule applied
    # to the grammar's own shape, and the distinct count is asserted.
    @classmethod
    def start_axes(cls) -> dict[str, tuple[str, ...]]:
        text, atx = cls.HEADING, cls.ATX
        return {
            "the plain shape": (atx,),
            "case": (atx.lower(), atx.upper()),
            # `(?i)` on a str pattern folds the whole Unicode table and
            # neither `lower()` nor `casefold()` folds the same way. A dotted
            # capital I matched the gate's old literal start and is this
            # heading to no parse, so that reader found a section under a name
            # the page does not show -- the divergence #1742 closed. The fold
            # itself is measured on `Evidence Status`, which has an `s` for a
            # long s to alias (`HeadingIdentityFoldsCaseAndNotLettersTests`).
            "unicode case folding": (f"## MERGEABİLİTY",),
            "closing hashes": tuple(f"{atx}{run}" for run in (" ##", " #", "  ###")),
            # CommonMark allows a space or a tab after the hashes and nothing
            # else, so every other blank-looking character is a widening
            # neither reader must make. Without a fixture carrying one,
            # relaxing the old pattern's literal space to `\s` -- which reads
            # like a tidy-up -- left the suite green while the gate started
            # finding sections on lines the page shows as paragraphs.
            # Named for the separator rather than for whitespace, because the
            # empty member -- `##Mergeability` -- is the absence of one
            # (codex, gpt-5.6-sol, xhigh).
            "separator after the marker": tuple(
                f"##{gap}{text}" for gap in ("  ", "\t", "\xa0", "\x0c", "\x0b", "")
            ),
            "trailing whitespace": tuple(
                f"{atx}{tail}" for tail in ("  ", "\t", " ", "\x0c")
            ),
            "indent": tuple(f"{' ' * count}{atx}" for count in (1, 3, 4)),
            "setext, both underlines": tuple(f"{text}\n{rule}" for rule in ("---", "===")),
            "emphasis": tuple(f"## {mark}{text}{mark}" for mark in ("**", "_")),
            "level": tuple(f"{'#' * level} {text}" for level in (1, 3)),
            "text that is not the heading": (f"{atx} extra", "## Merge ability"),
            "a stray carriage return": (f"{atx}\r",),
            # The identity axis. Each of these shows something of its own on
            # the page -- a struck run, a disclosure widget, two lines, code
            # font, a link -- so neither reader calls it this heading (#1730,
            # #1742).
            "inline html": (
                f"## Merge<del>ability</del>",
                f"## <details>{text}</details>",
                "## Merge<br>ability",
                f"## <span>{text}</span>",
                f"{atx}<!-- a note -->",
            ),
            "a construct that shows something else": (
                f"## `{text}`",
                f"## [{text}](https://example.com)",
            ),
            # Not top-level, so not a section however the line reads.
            "nested": (f"> {atx}", f"- {atx}"),
        }

    # A floor under the derivation, not a substitute for it: the axes above
    # are the guard, and this fails when one is dropped wholesale. The distinct
    # count is the second half, and it is the half that catches a member
    # written twice.
    START_AXIS_COUNT = 15
    START_SHAPE_COUNT = 38

    def test_the_start_shapes_are_distinct(self) -> None:
        # A duplicate is a fixture that pins nothing and a count that says it
        # did. This is what the two numbers together mean.
        axes = self.start_axes()
        shapes = [shape for members in axes.values() for shape in members]
        self.assertEqual(len(axes), self.START_AXIS_COUNT)
        self.assertEqual(len(shapes), self.START_SHAPE_COUNT)
        self.assertEqual(len(set(shapes)), self.START_SHAPE_COUNT, "a shape is listed twice")

    def test_this_gate_and_the_skill_find_the_same_start_on_every_shape(self) -> None:
        # The derived property. The rule is written twice -- this script is a
        # PEP 723 entry point with its own pin and no package for the skill to
        # import -- so the shapes are enumerated against both readers rather
        # than trusted to stay in step. The SECTION's text is the oracle, not a
        # predicate: text back means the start was found, and the two texts
        # have to be the same text.
        #
        # One axis is stated here rather than fixtured. A heading whose section
        # is empty (`## Mergeability` with the next heading directly below):
        # this oracle cannot see it, since both readers return "" for a start
        # they did not find and for one with nothing under it. The two do agree
        # on it -- the start is the same parse to both -- and that is an
        # argument, not a measurement, which is why it is written here and not
        # asserted.
        reader = self.reader()
        agreed = 0
        for axis, shapes in self.start_axes().items():
            for shape in shapes:
                for ending in ("\n", "\r\n"):
                    with self.subTest(axis=axis, shape=shape, ending=ending.encode("unicode_escape").decode()):
                        body = (
                            f"Why this exists.{ending}{ending}{shape}{ending}{ending}"
                            f"- Surface: desktop{ending}"
                        )
                        self.assertEqual(
                            pr_readiness.extract_section(body, "Mergeability").replace("\r\n", "\n"),
                            reader.markdown_section(body, "Mergeability").replace("\r\n", "\n"),
                            f"{axis}: {shape!r}",
                        )
                        agreed += 1
        self.assertEqual(agreed, self.START_SHAPE_COUNT * 2)

    def test_a_heading_argument_holding_markup_is_where_the_two_part_company(self) -> None:
        # The one divergence the grid above cannot carry, because every
        # heading this repo addresses is a plain word. Asked for a heading
        # whose own text holds a code span, the skill matches -- its
        # `inline_text` re-emits the backticks -- and this gate does not,
        # because any construct but text and emphasis makes
        # `heading_identity_text` return None. No caller asks that, and the
        # narrowing fails closed: the section reads as missing. Written as a
        # fixture rather than as a claim of full equivalence (codex,
        # gpt-5.6-sol, xhigh).
        reader = self.reader()
        body = "Why this exists.\n\n## `Mergeability`\n\n- Surface: desktop\n"
        self.assertEqual(reader.markdown_section(body, "`Mergeability`"), "- Surface: desktop")
        self.assertEqual(pr_readiness.extract_section(body, "`Mergeability`"), "")

    def test_a_heading_on_the_body_s_last_line_answers_the_same_in_both(self) -> None:
        """The shape that was argued to be unreachable, and is not (#1730, round 2).

        The argument was that every body this gate reads comes from GitHub,
        which stores a trailing newline, so a heading with no line ending after
        it is a path no body takes. `--body-file` is the other entry point: it
        reads a file an author wrote locally, and a file need not end in a
        newline. So the shape is reachable -- and where the old literal start
        refused it for want of the `\\n` its pattern named, both readers now see
        the heading the page shows, and only the empty section keeps the text
        empty.
        """
        reader = self.reader()
        for label, body in (
            ("nothing under the heading", "Why this exists.\n\n## Mergeability"),
            ("content, no trailing newline", "Why this exists.\n\n## Mergeability\n\n- Surface: desktop"),
        ):
            with self.subTest(body=label):
                self.assertEqual(
                    reader.markdown_section(body, "Mergeability"),
                    pr_readiness.extract_section(body, "Mergeability"),
                )
        # And the residual this shape used to name is closed: a heading on the
        # last line is a heading to both, and the gate reads the section under
        # it where there is one.
        terminal = "Why this exists.\n\n## Mergeability"
        self.assertTrue(reader.has_markdown_section(terminal, "Mergeability"))
        self.assertEqual(
            pr_readiness.extract_section(
                "Why this exists.\n\n## Mergeability\n- Surface: desktop", "Mergeability"
            ),
            "- Surface: desktop",
        )

    def test_the_axes_are_not_all_one_answer(self) -> None:
        # A guard whose fixtures all score the same way tests nothing about
        # where the line is. The set has to carry both answers, and a shape the
        # readers take has to sit beside one they do not.
        reader = self.reader()
        found = {True: [], False: []}
        for axis, shapes in self.start_axes().items():
            for shape in shapes:
                body = f"Why this exists.\n\n{shape}\n\n- Surface: desktop\n"
                found[reader.has_markdown_section(body, "Mergeability")].append(
                    f"{axis}: {shape!r}"
                )
        self.assertGreaterEqual(len(found[True]), 3, found)
        self.assertGreaterEqual(len(found[False]), 8, found)


class WhatTheGateSLongerReadingCostsTests(unittest.TestCase):
    """The over-long reading adds a refusal in one place and drops one in two (#1738).

    `SectionBoundaryAgreementBetweenTheGateAndTheSkillTests` says where the two
    readers part company. This says what it costs, per caller, measured rather
    than reasoned: the label carried since #1734 read "the gate reads longer,
    which can add a refusal and cannot drop one", and that is true of one of
    the three sections this gate reads from a body.

    Which way it goes is decided by the check, not by the section. A NEGATIVE
    pattern -- `Evidence Status`, where a `[blocked]` line is a failure -- has
    more text to match on when the read runs long, so the long read can only
    add. A POSITIVE one has more text to be satisfied by: `Validation`'s
    release-proof pattern (`pr-readiness.py:773`) and `Mergeability`'s field
    lines are both answered by text the author wrote under a LATER heading, or
    by text the page shows as code, and the refusal that was owed is not made.

    Each case is measured through `evaluate` with the skill's boundary patched
    in, and the patch reaches all three of its section reads at once, not only
    the one under test -- so each fixture is written to move exactly one check
    and the assertion is on the whole set of failures that moved, in both
    directions. A fixture that disturbed a second check would fail on the
    failure it did not predict rather than pass quietly (codex, gpt-5.6-sol,
    xhigh).
    """

    HELPERS_PATH = (
        REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "_helpers.py"
    )
    OPENING = (
        "Why this exists: the release lane lost its provisioning step, so a signed build never "
        "reached the appcast and the update check stalled.\n\n"
    )

    def owner_reader(self):
        spec = importlib.util.spec_from_file_location("contributor_helpers", self.HELPERS_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def both_readings(self, body: str, heading: str) -> tuple[str, str]:
        """This gate's reading of a section and the skill's, on one body."""
        return (
            pr_readiness.extract_section(body, heading),
            self.owner_reader().markdown_section(body, heading),
        )

    def failures(self, body: str, files: list[str], *, boundary: str = "gate") -> list[str]:
        """What this gate refuses, reading section ends its own way or the skill's.

        The skill's boundary is put in by patching `extract_section`, not by
        rewriting the body: a fixture with the fence closed would be a
        different body and would measure a different thing. Every other part
        of the gate -- the field reader, the status pattern, the release proof
        pattern -- is the shipped one, so what moves between the two calls is
        the boundary.

        `strip` is honoured rather than ignored, and it has to be. The gate
        asks for `Evidence Status` unstripped and hands the result to
        `split_fenced_blocks`, which reads lines: a stripped section has the
        indent off its FIRST line only, so an indented code block holding a
        ` ``` ` comes back as a fence nothing closes and the gate refuses a
        body it reads cleanly. That is a second thing moving, and it was
        moving here until codex (gpt-5.6-sol, xhigh) named it. The unstripped
        slice comes from `_section_bounds`, which is where `markdown_section`
        takes its own.
        """
        if boundary == "gate":
            return pr_readiness.evaluate(pr(body), files).failures
        reader = self.owner_reader()

        def repaired(text: str, heading: str, *, strip: bool = True) -> str:
            if strip:
                return reader.markdown_section(text, heading)
            bounds = reader._section_bounds(text, heading)
            return "" if bounds is None else text[bounds[1] : bounds[2]]

        with mock.patch.object(pr_readiness, "extract_section", repaired):
            return pr_readiness.evaluate(pr(body), files).failures

    def moved(self, body: str, files: list[str]) -> tuple[list[str], list[str]]:
        """What the gate's longer reading adds, and what it drops, against the skill's boundary."""
        long_read, short_read = self.failures(body, files), self.failures(body, files, boundary="skill")
        return (
            [text for text in long_read if text not in short_read],
            [text for text in short_read if text not in long_read],
        )

    RELEASE_BODY = OPENING + (
        "## Mergeability\n\n"
        "- Surface: infra\n"
        "- User-facing behavior changed: none\n"
        "- Non-happy paths considered: unsigned build\n"
        "- Release/ops preconditions: none\n"
        "- Residual risk or follow-up: none\n\n"
        "## Validation\n\n"
        "- [x] ran the lane\n\n"
        "```text\n"
        "a log, never closed\n\n"
        "## Evidence\n\n"
        "- ran actionlint\n"
    )

    def test_the_release_proof_pattern_is_satisfied_by_a_line_the_page_shows_as_code(self) -> None:
        # `:773`. The author's `- ran actionlint` sits under `## Evidence`,
        # which the runaway fence above it turns into code -- so the page has
        # no Evidence section and the line is part of a log. The gate reads
        # `Validation` to the end of the body and credits it anyway.
        gate, skill = self.both_readings(self.RELEASE_BODY, "Validation")
        self.assertIn("- ran actionlint", gate)
        self.assertNotIn("- ran actionlint", skill)
        added, dropped = self.moved(self.RELEASE_BODY, ["scripts/release.py"])
        self.assertEqual(added, [])
        self.assertEqual(
            dropped,
            [
                "Release-sensitive files changed; validation should include "
                "validate-release-changes, bash -n, actionlint, or workflow syntax proof."
            ],
        )

    MERGEABILITY_BODY = OPENING + (
        "## Mergeability\n\n"
        "```text\n"
        "a log, never closed\n\n"
        "## Design notes\n\n"
        "- Surface: infra\n"
        "- User-facing behavior changed: none\n"
        "- Non-happy paths considered: unsigned build\n"
        "- Residual risk or follow-up: none\n\n"
        "## Evidence Status\n\n"
        "- [complete] unit tests -- 10 passed\n"
    )

    def test_the_mergeability_fields_are_answered_from_the_author_s_next_section(self) -> None:
        # `:712`, and the one the issue did not name. Every field this gate
        # requires is written under `## Design notes`, which is a heading the
        # page does not show -- so a reader sees a Mergeability section holding
        # a log and nothing else, and the gate sees four answered fields.
        gate, skill = self.both_readings(self.MERGEABILITY_BODY, "Mergeability")
        required = (
            "Surface",
            "User-facing behavior changed",
            "Non-happy paths considered",
            "Residual risk or follow-up",
        )
        for field in required:
            with self.subTest(field=field):
                self.assertIsNotNone(pr_readiness.field_value(gate, field))
                self.assertIsNone(pr_readiness.field_value(skill, field))
        added, dropped = self.moved(self.MERGEABILITY_BODY, ["Sources/App.swift"])
        self.assertEqual(added, [])
        self.assertEqual(
            dropped,
            [f"Mergeability field is empty or still default: {field}." for field in required],
        )

    INDENTED_FENCE_BODY = OPENING + (
        "## Mergeability\n\n"
        "- Surface: infra\n"
        "- User-facing behavior changed: none\n"
        "- Non-happy paths considered: unsigned build\n"
        "- Residual risk or follow-up: none\n\n"
        "## Evidence Status\n\n"
        "    ```\n"
        "    harmless\n"
        "    ```\n\n"
        "- [complete] unit tests -- 10 passed\n"
    )

    def test_the_measurement_moves_the_boundary_and_nothing_else(self) -> None:
        # The harness's own guard. Both readings end this section in the same
        # place -- there is no runaway fence and nothing to repair -- so every
        # failure has to match, and any that does not is the apparatus and not
        # the boundary.
        #
        # This body is the one that caught it (codex, gpt-5.6-sol, xhigh). The
        # section opens with an indented code block holding fence lines; the
        # gate asks for it unstripped, and a reading that stripped it took the
        # indent off the FIRST line only, so ` ``` ` became a fence opener and
        # the four-space line below could not close it. The measurement then
        # reported a refusal the boundary had nothing to do with.
        self.assertEqual(
            self.failures(self.INDENTED_FENCE_BODY, ["Sources/App.swift"]),
            self.failures(self.INDENTED_FENCE_BODY, ["Sources/App.swift"], boundary="skill"),
        )
        added, dropped = self.moved(self.INDENTED_FENCE_BODY, ["Sources/App.swift"])
        self.assertEqual((added, dropped), ([], []))

    STATUS_BODY = OPENING + (
        "## Mergeability\n\n"
        "- Surface: infra\n"
        "- User-facing behavior changed: none\n"
        "- Non-happy paths considered: unsigned build\n"
        "- Residual risk or follow-up: none\n\n"
        "## Evidence Status\n\n"
        "```text\n"
        "a log, never closed\n\n"
        "## Release blockers\n\n"
        "- [blocked] the signing profile is missing\n"
    )

    def test_the_status_pattern_reaches_a_blocked_line_the_shorter_read_leaves_out(self) -> None:
        # The direction the old label described, and the only one it got
        # right: the check here is a negative pattern, so the extra text is
        # extra chances to fail.
        gate, skill = self.both_readings(self.STATUS_BODY, "Evidence Status")
        self.assertIsNotNone(pr_readiness.PENDING_STATUS_RE.search(gate))
        self.assertIsNone(pr_readiness.PENDING_STATUS_RE.search(skill))
        added, dropped = self.moved(self.STATUS_BODY, ["Sources/App.swift"])
        self.assertEqual(added, ["Requested evidence is blocked or still pending CI."])
        self.assertEqual(dropped, [])


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
        # The paragraph check skips it, which is what this test is for. The
        # body still fails, and correctly: CommonMark ends a comment block at
        # `-->` alone, so an opener closed only at `--!>` runs to the last
        # line and every heading below it is raw HTML. A browser that does
        # close at `--!>` then shows `## Mergeability` as literal text -- so
        # neither reader of the page sees a heading, and the gate's parsed
        # start says so where its old literal one read a section the page
        # never showed (#1742). Nothing here writes this shape: the metadata
        # comment is closed with `-->`, and `evidence.py` refuses one carrying
        # `--!>` outright.
        body = f"<!-- contributor:issue=1621 --!>\n\n{GOOD_BODY}"
        failures = self.failures(body)
        self.assertEqual([failure for failure in failures if "paragraph" in failure], [])
        self.assertEqual(failures, ["Missing ## Mergeability section from the PR body."])

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
