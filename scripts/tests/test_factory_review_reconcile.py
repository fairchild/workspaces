#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture and contract tests for the review-lane staleness reconciler (#1507).

Intent: prove the sweep flags exactly a PR that is currently due for a
counterpart review and has been due past the threshold, leaves everything
else alone (fresh, already-reviewed, signal-not-run-yet, draft), reuses
`evaluate_review` rather than a second routing opinion, and never re-flags a
head it has already commented on.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review-reconcile.py"
FIXTURES_DIR = REPO_ROOT / "fixtures" / "factory-review-reconcile" / "basic"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review_reconcile = load_module("factory_review_reconcile", SCRIPT_PATH)


def pull_request(
    number: int,
    *,
    draft: bool = False,
    head_sha: str = "sha1",
    author_label: str = "author:claude-code",
) -> dict[str, object]:
    return {
        "number": number,
        "state": "open",
        "draft": draft,
        "labels": [{"name": author_label}],
        "user": {"login": "fairchild"},
        "head": {"sha": head_sha},
        "body": "",
    }


def successful_run(updated_at: str) -> dict[str, object]:
    return {"status": "completed", "conclusion": "success", "updated_at": updated_at}


NOW = datetime(2026, 8, 31, 14, 0, 0, tzinfo=UTC)


class LatestSuccessfulRunCompletionTests(unittest.TestCase):
    def test_picks_the_newest_of_several_successful_runs(self) -> None:
        runs = [successful_run("2026-08-31T09:00:00Z"), successful_run("2026-08-31T11:00:00Z")]

        self.assertEqual(
            factory_review_reconcile.latest_successful_run_completion(runs),
            "2026-08-31T11:00:00Z",
        )

    def test_ignores_failed_and_in_progress_runs(self) -> None:
        runs = [
            {"status": "completed", "conclusion": "failure", "updated_at": "2026-08-31T13:00:00Z"},
            {"status": "in_progress", "conclusion": None, "updated_at": "2026-08-31T13:30:00Z"},
        ]

        self.assertIsNone(factory_review_reconcile.latest_successful_run_completion(runs))

    def test_no_runs_at_all_is_none(self) -> None:
        self.assertIsNone(factory_review_reconcile.latest_successful_run_completion([]))


class EvaluatePullRequestTests(unittest.TestCase):
    def test_flags_a_pr_due_past_the_threshold(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1485, head_sha="sha-stale"),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNotNone(finding)
        self.assertEqual(finding.pr_number, 1485)
        self.assertEqual(finding.reviewer, "april")
        self.assertEqual(finding.head_sha, "sha-stale")
        self.assertAlmostEqual(finding.age_hours, 5.0, places=3)

    def test_does_not_flag_within_the_threshold(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1490),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T13:30:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)

    def test_does_not_flag_a_head_already_reviewed(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1492, head_sha="sha-reviewed"),
            files=[],
            reviews=[
                {
                    "user": {"login": "april-clearwater[bot]"},
                    "commit_id": "sha-reviewed",
                    "state": "CHANGES_REQUESTED",
                }
            ],
            signal_runs=[successful_run("2026-08-31T08:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)

    def test_does_not_flag_when_the_signal_has_not_succeeded_yet(self) -> None:
        # Distinguishes "still building, or the signal itself is broken" from
        # the Executor-delivery gap this sweep exists to catch (#1507) — a PR
        # with no successful signal run has nothing to be stale relative to.
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1494), files=[], reviews=[], signal_runs=[], now=NOW, threshold_hours=3
        )

        self.assertIsNone(finding)

    def test_does_not_flag_a_draft(self) -> None:
        # Reused from evaluate_review, not reimplemented — proves the reuse
        # actually engages rather than silently falling through.
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1496, draft=True),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)

    def test_does_not_flag_an_author_with_no_counterpart_route(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1498, author_label="author:someone-else"),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)


class AlreadyFlaggedTests(unittest.TestCase):
    def test_true_when_the_marker_for_this_head_is_present(self) -> None:
        comments = [{"body": "<!-- factory-review-reconcile:head=sha-stale -->\nsome text"}]

        self.assertTrue(factory_review_reconcile.already_flagged(comments, "sha-stale"))

    def test_false_for_a_different_heads_marker(self) -> None:
        comments = [{"body": "<!-- factory-review-reconcile:head=sha-old -->"}]

        self.assertFalse(factory_review_reconcile.already_flagged(comments, "sha-stale"))

    def test_false_with_no_comments(self) -> None:
        self.assertFalse(factory_review_reconcile.already_flagged([], "sha-stale"))


class FindStaleReviewsTests(unittest.TestCase):
    def test_fetches_per_pr_state_and_flags_only_the_stale_one(self) -> None:
        client = mock.Mock()
        client.pull_request_files.return_value = []
        client.pull_request_reviews.return_value = []
        client.workflow_runs_for_head.side_effect = [
            [successful_run("2026-08-31T09:00:00Z")],
            [successful_run("2026-08-31T13:30:00Z")],
        ]

        findings = factory_review_reconcile.find_stale_reviews(
            client,
            [pull_request(1485, head_sha="sha-a"), pull_request(1490, head_sha="sha-b")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertEqual([finding.pr_number for finding in findings], [1485])
        client.pull_request_files.assert_has_calls([mock.call(1485), mock.call(1490)])
        client.workflow_runs_for_head.assert_has_calls(
            [mock.call("factory-review.yml", "sha-a"), mock.call("factory-review.yml", "sha-b")]
        )

    def test_never_fetches_anything_for_a_pr_with_no_author_label(self) -> None:
        client = mock.Mock()
        unlabeled = {
            "number": 1500,
            "state": "open",
            "draft": False,
            "labels": [],
            "user": {"login": "fairchild"},
            "head": {"sha": "sha-unlabeled"},
            "body": "",
        }

        findings = factory_review_reconcile.find_stale_reviews(
            client, [unlabeled], now=NOW, threshold_hours=3
        )

        self.assertEqual(findings, [])
        client.pull_request_files.assert_not_called()
        client.workflow_runs_for_head.assert_not_called()

    def test_never_calls_workflow_runs_for_head_when_already_reviewed(self) -> None:
        # The runs lookup is the one call this sweep exists to make sparing use
        # of — every PR evaluate_review already settles must skip it.
        client = mock.Mock()
        client.pull_request_files.return_value = []
        client.pull_request_reviews.return_value = [
            {
                "user": {"login": "april-clearwater[bot]"},
                "commit_id": "sha-reviewed",
                "state": "APPROVED",
            }
        ]

        findings = factory_review_reconcile.find_stale_reviews(
            client, [pull_request(1492, head_sha="sha-reviewed")], now=NOW, threshold_hours=3
        )

        self.assertEqual(findings, [])
        client.workflow_runs_for_head.assert_not_called()


class ApplyFindingsTests(unittest.TestCase):
    def finding(self, **overrides) -> "factory_review_reconcile.StaleReview":
        defaults = dict(
            pr_number=1485,
            reviewer="april",
            head_sha="sha-stale",
            signal_completed_at="2026-08-31T09:00:00Z",
            age_hours=5.0,
        )
        defaults.update(overrides)
        return factory_review_reconcile.StaleReview(**defaults)

    def test_labels_and_comments_a_pr_with_no_existing_flag(self) -> None:
        client = mock.Mock()
        client.issue_comments.return_value = []

        factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_called_once_with(1485)
        client.post_comment.assert_called_once()
        posted_body = client.post_comment.call_args.args[1]
        self.assertIn("<!-- factory-review-reconcile:head=sha-stale -->", posted_body)
        self.assertIn("5.0h ago", posted_body)

    def test_skips_a_pr_already_flagged_for_this_head(self) -> None:
        client = mock.Mock()
        client.issue_comments.return_value = [
            {"body": "<!-- factory-review-reconcile:head=sha-stale -->\nalready posted"}
        ]

        factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_not_called()
        client.post_comment.assert_not_called()

    def test_a_new_push_after_being_flagged_reflags(self) -> None:
        # The marker is keyed by head SHA, so a new commit clears the old
        # diagnosis and the sweep can flag the PR again on its new head.
        client = mock.Mock()
        client.issue_comments.return_value = [
            {"body": "<!-- factory-review-reconcile:head=sha-old -->\nprevious diagnosis"}
        ]

        factory_review_reconcile.apply_findings(
            client, [self.finding(head_sha="sha-new")], threshold_hours=3
        )

        client.add_flag_labels.assert_called_once_with(1485)
        client.post_comment.assert_called_once()

    def test_a_failure_on_one_pr_does_not_block_flagging_the_rest(self) -> None:
        client = mock.Mock()
        client.issue_comments.return_value = []
        client.add_flag_labels.side_effect = [
            factory_review_reconcile.FactoryReviewReconcileError("boom"),
            None,
        ]
        findings = [self.finding(pr_number=1485), self.finding(pr_number=1490, head_sha="sha-b")]

        with self.assertRaisesRegex(
            factory_review_reconcile.FactoryReviewReconcileError, "#1485: boom"
        ):
            factory_review_reconcile.apply_findings(client, findings, threshold_hours=3)

        # The second PR still got its label + comment despite the first's
        # write failure -- the aggregated error is raised only after the
        # whole batch has been attempted.
        client.add_flag_labels.assert_has_calls([mock.call(1485), mock.call(1490)])
        client.post_comment.assert_called_once()


class GitHubClientTests(unittest.TestCase):
    def test_open_pull_requests_paginates(self) -> None:
        client = factory_review_reconcile.GitHubClient("fairchild/workspaces", "token")
        first_page = [{"number": number} for number in range(1, 101)]
        second_page = [{"number": 101}]
        client.request = mock.Mock(side_effect=[first_page, second_page])  # type: ignore[method-assign]

        pulls = client.open_pull_requests()

        self.assertEqual([pull["number"] for pull in pulls], list(range(1, 102)))
        self.assertEqual(client.request.call_count, 2)
        self.assertIn("state=open", client.request.call_args_list[0].args[0])

    def test_workflow_runs_for_head_builds_the_query(self) -> None:
        client = factory_review_reconcile.GitHubClient("fairchild/workspaces", "token")
        client.request = mock.Mock(return_value={"workflow_runs": [{"id": 1}]})  # type: ignore[method-assign]

        runs = client.workflow_runs_for_head("factory-review.yml", "sha-abc")

        self.assertEqual(runs, [{"id": 1}])
        client.request.assert_called_once_with(
            "/repos/fairchild/workspaces/actions/workflows/factory-review.yml/runs"
            "?head_sha=sha-abc&per_page=20"
        )


class CliFixtureTests(unittest.TestCase):
    def test_basic_fixture_flags_only_the_stale_pr(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--fixtures-dir", str(FIXTURES_DIR)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[stale] #1485: due for april", result.stdout)
        self.assertNotIn("#1490", result.stdout)
        self.assertNotIn("#1492", result.stdout)
        self.assertNotIn("#1494", result.stdout)
        self.assertNotIn("#1496", result.stdout)
        self.assertIn("Dry run: 1 finding(s); no writes.", result.stdout)

    def test_threshold_hours_override_changes_what_counts_as_stale(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR),
                "--threshold-hours",
                "10",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no stale reviews found", result.stdout)

    def test_fixtures_dir_rejects_apply(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--fixtures-dir", str(FIXTURES_DIR), "--apply"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("--fixtures-dir cannot be combined with --apply", result.stderr)

    def test_zero_or_negative_threshold_is_rejected(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR),
                "--threshold-hours",
                "0",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("--threshold-hours must be positive", result.stderr)


if __name__ == "__main__":
    unittest.main()
