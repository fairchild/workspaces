#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
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


GOOD_BODY = """## Summary

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


if __name__ == "__main__":
    unittest.main()
