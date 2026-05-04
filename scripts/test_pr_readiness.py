#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/pr-readiness.py."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
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

- ![tests](https://evidence.cloudcompute.com/workspaces/pr-1/tests.svg)

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

    def test_draft_pr_is_advisory(self) -> None:
        result = pr_readiness.evaluate(pr("", draft=True), [".github/workflows/release.yml"])
        self.assertEqual(result.failures, [])
        self.assertTrue(result.notices)


if __name__ == "__main__":
    unittest.main()
