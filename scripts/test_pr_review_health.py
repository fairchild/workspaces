#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/pr-review-health.py."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "pr-review-health.py"

spec = importlib.util.spec_from_file_location("pr_review_health", SCRIPT_PATH)
assert spec and spec.loader
pr_review_health = importlib.util.module_from_spec(spec)
sys.modules["pr_review_health"] = pr_review_health
spec.loader.exec_module(pr_review_health)


NOW = datetime(2026, 5, 23, 12, 0, tzinfo=UTC)
HEAD = "abc123456789"


def iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def status(state: str, *, started_at: datetime | None = None) -> dict:
    return {
        "__typename": "StatusContext",
        "context": "WorkSpaces Managed Review",
        "state": state,
        "createdAt": iso(started_at or NOW),
        "targetUrl": "https://github.com/fairchild/workspaces/pull/1",
    }


def legacy_status(state: str, *, started_at: datetime | None = None) -> dict:
    return {
        "__typename": "StatusContext",
        "context": "WorkSpaces Managed Review",
        "state": state,
        "startedAt": iso(started_at or NOW),
        "targetUrl": "https://github.com/fairchild/workspaces/pull/1",
    }


def review(state: str, *, commit: str = HEAD, login: str = "workspaces-claude-pr-reviewer") -> dict:
    return {
        "state": state,
        "submittedAt": iso(NOW),
        "author": {"login": login},
        "commit": {"oid": commit},
    }


def pr(
    *,
    updated_at: datetime | None = None,
    is_draft: bool = False,
    statuses: list[dict] | None = None,
    reviews: list[dict] | None = None,
    merge_state: str = "CLEAN",
) -> dict:
    return {
        "number": 1,
        "title": "Example",
        "url": "https://github.com/fairchild/workspaces/pull/1",
        "isDraft": is_draft,
        "updatedAt": iso(updated_at or NOW),
        "headRefOid": HEAD,
        "mergeStateStatus": merge_state,
        "reviews": {"nodes": reviews or []},
        "statusCheckRollup": {"contexts": {"nodes": statuses or []}},
    }


def evaluate(one_pr: dict) -> pr_review_health.HealthReport:
    return pr_review_health.evaluate(
        [one_pr],
        now=NOW,
        updated_within=timedelta(hours=72),
        pending_timeout=timedelta(minutes=30),
    )


class PRReviewHealthTests(unittest.TestCase):
    def test_success_status_with_current_head_review_passes(self) -> None:
        report = evaluate(pr(statuses=[status("SUCCESS")], reviews=[review("APPROVED")]))
        self.assertEqual(report.failures, [])

    def test_changes_requested_is_healthy_but_noticed(self) -> None:
        report = evaluate(pr(statuses=[status("SUCCESS")], reviews=[review("CHANGES_REQUESTED")]))
        self.assertEqual(report.failures, [])
        self.assertIn("managed reviewer requested changes", report.results[0].notices)

    def test_missing_status_fails_recent_pr(self) -> None:
        report = evaluate(pr(reviews=[review("APPROVED")]))
        self.assertIn("missing WorkSpaces Managed Review status", report.failures[0].problems[0])

    def test_success_status_without_current_head_review_fails(self) -> None:
        report = evaluate(
            pr(
                statuses=[status("SUCCESS")],
                reviews=[review("APPROVED", commit="oldhead")],
            )
        )
        self.assertIn("no current-head managed review", report.failures[0].problems[0])

    def test_fresh_pending_status_passes(self) -> None:
        report = evaluate(pr(statuses=[status("PENDING", started_at=NOW - timedelta(minutes=5))]))
        self.assertEqual(report.failures, [])

    def test_stale_pending_status_fails(self) -> None:
        report = evaluate(pr(statuses=[status("PENDING", started_at=NOW - timedelta(minutes=45))]))
        self.assertIn("has been pending for 45m", report.failures[0].problems[0])

    def test_started_at_status_timestamp_fallback_still_works(self) -> None:
        report = evaluate(
            pr(statuses=[legacy_status("PENDING", started_at=NOW - timedelta(minutes=45))])
        )
        self.assertIn("has been pending for 45m", report.failures[0].problems[0])

    def test_failed_status_fails(self) -> None:
        report = evaluate(pr(statuses=[status("FAILURE")]))
        self.assertIn("status is failure", report.failures[0].problems[0])

    def test_old_pr_is_skipped(self) -> None:
        report = evaluate(pr(updated_at=NOW - timedelta(days=10)))
        self.assertEqual(report.failures, [])
        self.assertEqual(report.results[0].skipped_reason, "not updated within 3d")

    def test_draft_pr_is_skipped(self) -> None:
        report = evaluate(pr(is_draft=True))
        self.assertEqual(report.failures, [])
        self.assertEqual(report.results[0].skipped_reason, "draft")

    def test_bot_suffix_login_counts_as_managed_review(self) -> None:
        report = evaluate(
            pr(
                statuses=[status("SUCCESS")],
                reviews=[review("APPROVED", login="workspaces-claude-pr-reviewer[bot]")],
            )
        )
        self.assertEqual(report.failures, [])

    def test_workspace_agents_login_counts_as_managed_review(self) -> None:
        report = evaluate(
            pr(
                statuses=[status("SUCCESS")],
                reviews=[review("APPROVED", login="workspace-agents")],
            )
        )
        self.assertEqual(report.failures, [])

    def test_render_markdown_preserves_pending_status_with_notices(self) -> None:
        report = pr_review_health.evaluate(
            [
                pr(
                    statuses=[status("PENDING", started_at=NOW - timedelta(minutes=1))],
                    merge_state="BLOCKED",
                ),
            ],
            now=NOW,
            updated_within=timedelta(hours=72),
            pending_timeout=timedelta(minutes=30),
        )
        rendered = pr_review_health.render_markdown(
            report,
            updated_within=timedelta(hours=72),
            pending_timeout=timedelta(minutes=30),
        )

        self.assertIn("pending within timeout; PR merge state is blocked", rendered)

    def test_render_markdown_does_not_treat_skipped_prs_as_global_health(self) -> None:
        report = pr_review_health.evaluate(
            [
                pr(statuses=[status("SUCCESS")], reviews=[review("APPROVED")]),
                pr(updated_at=NOW - timedelta(days=10)),
            ],
            now=NOW,
            updated_within=timedelta(hours=72),
            pending_timeout=timedelta(minutes=30),
        )
        rendered = pr_review_health.render_markdown(
            report,
            updated_within=timedelta(hours=72),
            pending_timeout=timedelta(minutes=30),
        )

        self.assertIn("- Active failures: 0", rendered)
        self.assertIn("- Skipped/unassessed PRs: 1", rendered)
        self.assertIn("- Queue coverage: incomplete (1 skipped/unassessed PR)", rendered)
        self.assertIn("unassessed: not updated within 3d", rendered)
        self.assertNotIn("- Failures: 0", rendered)


if __name__ == "__main__":
    unittest.main()
