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

import argparse
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
    head_repository: str = "fairchild/workspaces",
) -> dict[str, object]:
    return {
        "number": number,
        "state": "open",
        "draft": draft,
        "labels": [{"name": author_label}],
        "user": {"login": "fairchild"},
        "head": {"sha": head_sha, "repo": {"full_name": head_repository}},
        "base": {"repo": {"full_name": "fairchild/workspaces"}},
        "body": "",
    }


def successful_run(updated_at: str) -> dict[str, object]:
    return {"status": "completed", "conclusion": "success", "updated_at": updated_at}


NOW = datetime(2026, 8, 31, 14, 0, 0, tzinfo=UTC)


class RunsAssociatedWithPullRequestTests(unittest.TestCase):
    def test_filters_to_runs_naming_this_pr_number(self) -> None:
        runs = [
            {"id": 1, "pull_requests": [{"number": 1485}]},
            {"id": 2, "pull_requests": [{"number": 1490}]},
        ]

        self.assertEqual(
            factory_review_reconcile.runs_associated_with_pull_request(runs, 1485),
            [{"id": 1, "pull_requests": [{"number": 1485}]}],
        )

    def test_falls_back_to_the_unfiltered_set_when_none_carry_pull_requests(self) -> None:
        # Cross-repo/fork-triggered runs carry an empty pull_requests array --
        # head_sha is the only signal GitHub gives there, so discard nothing.
        runs = [{"id": 1, "pull_requests": []}, {"id": 2}]

        self.assertEqual(factory_review_reconcile.runs_associated_with_pull_request(runs, 1485), runs)

    def test_excludes_only_the_run_explicitly_scoped_to_a_different_pr(self) -> None:
        # A run naming a different PR is discarded even when a sibling run in
        # the same batch is ambiguous (no pull_requests info at all) -- the
        # ambiguous one stays, on the same best-effort basis head_sha alone
        # already was; the scoped-elsewhere one is definite, so it goes.
        runs = [
            {"id": 1, "pull_requests": [{"number": 1490}]},
            {"id": 2, "pull_requests": []},
        ]

        self.assertEqual(
            factory_review_reconcile.runs_associated_with_pull_request(runs, 1485),
            [{"id": 2, "pull_requests": []}],
        )


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

    def test_flags_a_draft_that_has_not_had_its_first_read(self) -> None:
        # Reused from evaluate_review, not reimplemented — proves the reuse
        # actually engages rather than silently falling through. A draft is
        # reviewable exactly once, so an unreviewed one is still due.
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1496, draft=True),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNotNone(finding)

    def test_does_not_flag_a_draft_that_has_already_been_read(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1496, draft=True),
            files=[],
            reviews=[
                {
                    "user": {"login": "april-clearwater[bot]"},
                    "commit_id": "an-older-head",
                    "state": "APPROVED",
                }
            ],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)

    def test_flags_an_author_label_with_no_counterpart_route(self) -> None:
        """An unrecognised author label routes by surface like any other. It used
        to mean no review, which is the miss this lane stopped having."""
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1498, author_label="author:someone-else"),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNotNone(finding)

    def test_does_not_flag_a_fork(self) -> None:
        finding = factory_review_reconcile.evaluate_pull_request(
            pull_request(1499, head_repository="stranger/workspaces"),
            files=[],
            reviews=[],
            signal_runs=[successful_run("2026-08-31T09:00:00Z")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertIsNone(finding)


class AlreadyFlaggedTests(unittest.TestCase):
    def test_true_when_the_marker_for_this_head_is_present(self) -> None:
        comments = [
            {
                "body": "<!-- factory-review-reconcile:head=sha-stale -->\nsome text",
                "user": {"login": "github-actions[bot]"},
            }
        ]

        self.assertTrue(factory_review_reconcile.already_flagged(comments, "sha-stale"))

    def test_false_for_a_different_heads_marker(self) -> None:
        comments = [
            {
                "body": "<!-- factory-review-reconcile:head=sha-old -->",
                "user": {"login": "github-actions[bot]"},
            }
        ]

        self.assertFalse(factory_review_reconcile.already_flagged(comments, "sha-stale"))

    def test_false_with_no_comments(self) -> None:
        self.assertFalse(factory_review_reconcile.already_flagged([], "sha-stale"))

    def test_false_when_the_marker_comes_from_an_untrusted_author(self) -> None:
        # Anyone who can comment on the PR can paste this exact text. Only a
        # marker the sweep itself posted (github-actions[bot]) counts.
        comments = [
            {
                "body": "<!-- factory-review-reconcile:head=sha-stale -->",
                "user": {"login": "the-pr-author"},
            }
        ]

        self.assertFalse(factory_review_reconcile.already_flagged(comments, "sha-stale"))


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

    def test_never_fetches_anything_for_a_fork_pull_request(self) -> None:
        client = mock.Mock()
        fork = pull_request(1500, head_repository="stranger/workspaces")

        findings = factory_review_reconcile.find_stale_reviews(
            client, [fork], now=NOW, threshold_hours=3
        )

        self.assertEqual(findings, [])
        client.pull_request_files.assert_not_called()
        client.workflow_runs_for_head.assert_not_called()

    def test_an_unlabelled_pull_request_is_still_swept(self) -> None:
        """The sweep used to skip these, which is the same silent miss the
        review lane stopped having."""
        client = mock.Mock()
        client.pull_request_files.return_value = [{"filename": "Sources/Feature.swift"}]
        client.pull_request_reviews.return_value = []
        client.workflow_runs_for_head.return_value = []
        unlabelled = pull_request(1500, author_label="quality")

        factory_review_reconcile.find_stale_reviews(
            client, [unlabelled], now=NOW, threshold_hours=3
        )

        client.pull_request_files.assert_called_once()

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


def flagged_comment(head_sha: str) -> dict[str, object]:
    return {
        "body": f"<!-- factory-review-reconcile:head={head_sha} -->\nprevious diagnosis",
        "user": {"login": "github-actions[bot]"},
    }


class StillDueTests(unittest.TestCase):
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

    def client(self, *, state: str = "open", head_sha: str = "sha-stale", reviews=None):
        c = mock.Mock()
        c.pull_request.return_value = {"state": state, "head": {"sha": head_sha}}
        c.pull_request_reviews.return_value = reviews or []
        return c

    def test_true_when_open_same_head_and_unreviewed(self) -> None:
        c = self.client()

        self.assertTrue(factory_review_reconcile.still_due(c, self.finding()))

    def test_false_once_the_pr_is_no_longer_open(self) -> None:
        c = self.client(state="closed")

        self.assertFalse(factory_review_reconcile.still_due(c, self.finding()))

    def test_false_once_the_head_has_moved(self) -> None:
        # A push landed between discovery and apply -- the new head deserves
        # its own staleness clock, not the old head's diagnosis.
        c = self.client(head_sha="sha-newer")

        self.assertFalse(factory_review_reconcile.still_due(c, self.finding()))

    def test_false_once_a_review_landed(self) -> None:
        c = self.client(
            reviews=[
                {
                    "user": {"login": "april-clearwater[bot]"},
                    "commit_id": "sha-stale",
                    "state": "APPROVED",
                }
            ]
        )

        self.assertFalse(factory_review_reconcile.still_due(c, self.finding()))


class FindStaleReviewsIsolationTests(unittest.TestCase):
    def test_a_read_failure_on_one_pr_does_not_lose_findings_already_discovered(self) -> None:
        client = mock.Mock()
        client.pull_request_files.side_effect = [
            factory_review_reconcile.factory_review.FactoryReviewError("boom"),
            [],
        ]
        client.pull_request_reviews.return_value = []
        client.workflow_runs_for_head.return_value = [successful_run("2026-08-31T09:00:00Z")]

        findings = factory_review_reconcile.find_stale_reviews(
            client,
            [pull_request(1485, head_sha="sha-a"), pull_request(1490, head_sha="sha-b")],
            now=NOW,
            threshold_hours=3,
        )

        self.assertEqual([finding.pr_number for finding in findings], [1490])


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

    def still_due_client(self, *, head_sha: str = "sha-stale") -> mock.Mock:
        client = mock.Mock()
        client.pull_request.return_value = {"state": "open", "head": {"sha": head_sha}}
        client.pull_request_reviews.return_value = []
        client.issue_comments.return_value = []
        return client

    def test_labels_and_comments_a_pr_with_no_existing_flag(self) -> None:
        client = self.still_due_client()

        with mock.patch.object(factory_review_reconcile.time, "sleep"):
            factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_called_once_with(1485)
        client.post_comment.assert_called_once()
        posted_body = client.post_comment.call_args.args[1]
        self.assertIn("<!-- factory-review-reconcile:head=sha-stale -->", posted_body)
        self.assertIn("5.0h ago", posted_body)

    def test_skips_a_pr_already_flagged_for_this_head(self) -> None:
        client = self.still_due_client()
        client.issue_comments.return_value = [flagged_comment("sha-stale")]

        factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_not_called()
        client.post_comment.assert_not_called()

    def test_an_untrusted_authors_marker_does_not_suppress_the_flag(self) -> None:
        # Anyone who can comment can paste this exact HTML comment. Only a
        # marker posted by the sweep's own identity may stand it down.
        client = self.still_due_client()
        client.issue_comments.return_value = [
            {
                "body": "<!-- factory-review-reconcile:head=sha-stale -->\nnothing to see here",
                "user": {"login": "the-pr-author"},
            }
        ]

        with mock.patch.object(factory_review_reconcile.time, "sleep"):
            factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_called_once_with(1485)
        client.post_comment.assert_called_once()

    def test_a_new_push_after_being_flagged_reflags(self) -> None:
        # The marker is keyed by head SHA, so a new commit clears the old
        # diagnosis and the sweep can flag the PR again on its new head.
        client = self.still_due_client(head_sha="sha-new")
        client.issue_comments.return_value = [flagged_comment("sha-old")]

        with mock.patch.object(factory_review_reconcile.time, "sleep"):
            factory_review_reconcile.apply_findings(
                client, [self.finding(head_sha="sha-new")], threshold_hours=3
            )

        client.add_flag_labels.assert_called_once_with(1485)
        client.post_comment.assert_called_once()

    def test_skips_a_pr_that_moved_on_before_it_was_applied(self) -> None:
        # Discovery and application are two passes; a PR merged or reviewed
        # in between must not receive a stale diagnosis it no longer earns.
        client = self.still_due_client()
        client.pull_request.return_value = {"state": "closed", "head": {"sha": "sha-stale"}}

        factory_review_reconcile.apply_findings(client, [self.finding()], threshold_hours=3)

        client.add_flag_labels.assert_not_called()
        client.post_comment.assert_not_called()

    def test_a_failure_on_one_pr_does_not_block_flagging_the_rest(self) -> None:
        client = self.still_due_client()
        client.pull_request.side_effect = lambda number, _heads={
            1485: "sha-stale",
            1490: "sha-b",
        }: {"state": "open", "head": {"sha": _heads[number]}}
        client.add_flag_labels.side_effect = [
            factory_review_reconcile.FactoryReviewReconcileError("boom"),
            None,
        ]
        findings = [self.finding(pr_number=1485), self.finding(pr_number=1490, head_sha="sha-b")]

        with (
            mock.patch.object(factory_review_reconcile.time, "sleep"),
            self.assertRaisesRegex(
                factory_review_reconcile.FactoryReviewReconcileError, "#1485: boom"
            ),
        ):
            factory_review_reconcile.apply_findings(client, findings, threshold_hours=3)

        # The second PR still got its label + comment despite the first's
        # write failure -- the aggregated error is raised only after the
        # whole batch has been attempted.
        client.add_flag_labels.assert_has_calls([mock.call(1485), mock.call(1490)])
        client.post_comment.assert_called_once()

    def test_a_read_error_from_the_inherited_get_client_is_caught_too(self) -> None:
        # issue_comments() raises the base client's error type, not this
        # module's own -- both must be caught by the same isolation.
        client = self.still_due_client()
        client.pull_request.side_effect = lambda number, _heads={
            1485: "sha-stale",
            1490: "sha-b",
        }: {"state": "open", "head": {"sha": _heads[number]}}
        client.issue_comments.side_effect = [
            factory_review_reconcile.factory_review.FactoryReviewError("read boom"),
            [],
        ]
        findings = [self.finding(pr_number=1485), self.finding(pr_number=1490, head_sha="sha-b")]

        with (
            mock.patch.object(factory_review_reconcile.time, "sleep"),
            self.assertRaisesRegex(
                factory_review_reconcile.FactoryReviewReconcileError, "#1485: read boom"
            ),
        ):
            factory_review_reconcile.apply_findings(client, findings, threshold_hours=3)

        client.add_flag_labels.assert_called_once_with(1490)

    def test_paces_between_findings_but_not_after_the_last_one(self) -> None:
        client = self.still_due_client()
        findings = [self.finding(pr_number=1485), self.finding(pr_number=1490, head_sha="sha-b")]

        with mock.patch.object(factory_review_reconcile.time, "sleep") as sleep:
            factory_review_reconcile.apply_findings(client, findings, threshold_hours=3)

        sleep.assert_called_once_with(factory_review_reconcile.WRITE_PACE_SECONDS)


def http_error(code: int, *, headers: dict[str, str] | None = None) -> "factory_review_reconcile.urllib.error.HTTPError":
    from email.message import Message

    hdrs = Message()
    for key, value in (headers or {}).items():
        hdrs[key] = value
    return factory_review_reconcile.urllib.error.HTTPError(
        "https://api.github.com/x", code, "err", hdrs, mock.Mock(read=lambda: b"{}")
    )


class RetryAfterSecondsTests(unittest.TestCase):
    def test_reads_a_present_header(self) -> None:
        self.assertEqual(factory_review_reconcile._retry_after_seconds(http_error(429, headers={"Retry-After": "5"})), 5.0)

    def test_none_when_the_header_is_absent(self) -> None:
        self.assertIsNone(factory_review_reconcile._retry_after_seconds(http_error(429)))

    def test_none_when_the_header_is_not_a_number(self) -> None:
        self.assertIsNone(
            factory_review_reconcile._retry_after_seconds(
                http_error(429, headers={"Retry-After": "not-a-number"})
            )
        )


class GitHubClientWriteRetryTests(unittest.TestCase):
    def test_429_retries_after_the_retry_after_header(self) -> None:
        client = factory_review_reconcile.GitHubClient("fairchild/workspaces", "token")
        responses = iter([http_error(429, headers={"Retry-After": "0"}), mock.MagicMock()])

        def urlopen(*args, **kwargs):
            response = next(responses)
            if isinstance(response, BaseException):
                raise response
            return mock.MagicMock(__enter__=mock.Mock(return_value=None), __exit__=mock.Mock(return_value=False))

        with (
            mock.patch.object(factory_review_reconcile.urllib.request, "urlopen", side_effect=urlopen),
            mock.patch.object(factory_review_reconcile.time, "sleep") as sleep,
        ):
            client.write("POST", "/repos/fairchild/workspaces/issues/1/labels", {"labels": ["agent"]})

        sleep.assert_called_once_with(0.0)

    def test_a_5xx_fails_immediately_without_retrying(self) -> None:
        # A 5xx is ambiguous -- the mutation may have already landed -- so
        # this must not retry blind into a possible duplicate.
        client = factory_review_reconcile.GitHubClient("fairchild/workspaces", "token")

        with (
            mock.patch.object(
                factory_review_reconcile.urllib.request,
                "urlopen",
                side_effect=http_error(502),
            ) as urlopen,
            self.assertRaises(factory_review_reconcile.FactoryReviewReconcileError),
        ):
            client.write("POST", "/repos/fairchild/workspaces/issues/1/comments", {"body": "x"})

        self.assertEqual(urlopen.call_count, 1)

    def test_a_dropped_connection_fails_immediately_without_retrying(self) -> None:
        client = factory_review_reconcile.GitHubClient("fairchild/workspaces", "token")

        with (
            mock.patch.object(
                factory_review_reconcile.urllib.request,
                "urlopen",
                side_effect=factory_review_reconcile.urllib.error.URLError("dropped"),
            ) as urlopen,
            self.assertRaises(factory_review_reconcile.FactoryReviewReconcileError),
        ):
            client.write("POST", "/repos/fairchild/workspaces/issues/1/comments", {"body": "x"})

        self.assertEqual(urlopen.call_count, 1)


class LoadFactoryReviewReuseTests(unittest.TestCase):
    def test_a_second_load_returns_the_same_module_object(self) -> None:
        first = factory_review_reconcile.factory_review
        second = factory_review_reconcile._load_factory_review()

        self.assertIs(first, second)
        # The identity that matters in practice: a decision from one load
        # must still isinstance-check against the other's class.
        decision = first.ReviewDecision("review", "route", "april")
        self.assertIsInstance(decision, second.ReviewDecision)


class ResolveThresholdHoursTests(unittest.TestCase):
    def args(self, *, threshold_hours=None):
        return argparse.Namespace(threshold_hours=threshold_hours)

    def test_rejects_nan_from_the_cli_flag(self) -> None:
        with self.assertRaisesRegex(
            factory_review_reconcile.FactoryReviewReconcileError, "positive"
        ):
            factory_review_reconcile.resolve_threshold_hours(self.args(threshold_hours=float("nan")))

    def test_rejects_infinity_from_the_cli_flag(self) -> None:
        with self.assertRaisesRegex(
            factory_review_reconcile.FactoryReviewReconcileError, "positive"
        ):
            factory_review_reconcile.resolve_threshold_hours(self.args(threshold_hours=float("inf")))

    def test_rejects_nan_from_the_environment_variable(self) -> None:
        with (
            mock.patch.dict(
                factory_review_reconcile.os.environ,
                {"FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS": "nan"},
            ),
            self.assertRaisesRegex(
                factory_review_reconcile.FactoryReviewReconcileError, "positive"
            ),
        ):
            factory_review_reconcile.resolve_threshold_hours(self.args())

    def test_rejects_infinity_from_the_environment_variable(self) -> None:
        with (
            mock.patch.dict(
                factory_review_reconcile.os.environ,
                {"FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS": "inf"},
            ),
            self.assertRaisesRegex(
                factory_review_reconcile.FactoryReviewReconcileError, "positive"
            ),
        ):
            factory_review_reconcile.resolve_threshold_hours(self.args())

    def test_accepts_a_normal_positive_value(self) -> None:
        self.assertEqual(
            factory_review_reconcile.resolve_threshold_hours(self.args(threshold_hours=6.5)), 6.5
        )


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
            "?head_sha=sha-abc&per_page=100"
        )


class CliFixtureTests(unittest.TestCase):
    def test_basic_fixture_flags_the_stale_pr_and_the_unread_draft(self) -> None:
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
        # #1496 is a draft nobody has read yet, which is due its one review.
        # It used to be skipped for being a draft at all.
        self.assertIn("[stale] #1496: due for april", result.stdout)
        self.assertIn("Dry run: 2 finding(s); no writes.", result.stdout)

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
        self.assertIn("--threshold-hours must be a positive, finite number", result.stderr)


if __name__ == "__main__":
    unittest.main()
