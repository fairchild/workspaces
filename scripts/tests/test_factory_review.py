#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory counterpart-review admission."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review.yml"
EXECUTOR_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review = load_module("factory_review", SCRIPT_PATH)


class FactoryReviewTests(unittest.TestCase):
    def pull_request(
        self,
        *,
        label: str = "author:codex",
        draft: bool = False,
        head_sha: str = "abc123",
    ):
        return {
            "state": "open",
            "draft": draft,
            "labels": [{"name": label}],
            "head": {"sha": head_sha},
        }

    def test_fixed_persona_pairs_route_to_counterpart(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        self.assertEqual(factory_review.counterpart_reviewer("author:april", files), "plat")
        self.assertEqual(factory_review.counterpart_reviewer("author:plat", files), "april")

    def test_generalist_authors_route_by_file_majority(self) -> None:
        application_files = [
            {"filename": "Sources/Feature.swift"},
            {"filename": "Tests/FeatureTests.swift"},
            {"filename": ".github/workflows/ci.yml"},
        ]
        platform_files = [
            {"filename": ".github/workflows/ci.yml"},
            {"filename": "infra/worker/index.ts"},
            {"filename": "scripts/helper.py"},
        ]

        for label in ("author:claude-code", "author:codex", "author:fable-orchestrator"):
            with self.subTest(label=label):
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, application_files),
                    "april",
                )
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, platform_files),
                    "plat",
                )

    def test_app_cannot_review_its_own_mislabeled_pull_request(self) -> None:
        pull_request = {
            **self.pull_request(label="author:codex"),
            "user": {"login": "april-clearwater[bot]"},
        }

        decision = factory_review.evaluate_review(
            pull_request,
            [{"filename": "Sources/Feature.swift"}],
            [],
            force=False,
        )

        self.assertEqual(decision.action, "skip")
        self.assertIn("cannot review its own", decision.reason)

    def test_linked_issue_is_derived_from_closing_reference(self) -> None:
        self.assertEqual(
            factory_review.linked_issue_number({"body": "Summary\n\nCloses #1091"}),
            1091,
        )
        self.assertIsNone(factory_review.linked_issue_number({"body": "Related to #1091"}))

    def test_automatic_review_deduplicates_reviewer_and_head_sha(self) -> None:
        reviews = [
            {
                "user": {"login": "april-clearwater[bot]"},
                "commit_id": "abc123",
                "state": "APPROVED",
            }
        ]
        pull_request = self.pull_request()
        files = [{"filename": "Sources/Feature.swift"}]

        automatic = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=False,
        )
        requested = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=True,
        )

        self.assertEqual(automatic.action, "skip")
        self.assertEqual(requested.action, "review")
        self.assertEqual(requested.reviewer, "april")

    def test_raw_attempt_count_includes_reruns_and_current_attempt(self) -> None:
        runs = [
            {"id": 100, "run_attempt": 2},
            {"id": 101, "run_attempt": 1},
        ]
        self.assertEqual(factory_review.count_daily_run_attempts(runs, "101"), 3)
        self.assertEqual(factory_review.count_daily_run_attempts(runs, "102", 3), 6)

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "positive integer"):
            factory_review.parse_daily_cap("0")

        api_client = factory_review.GitHubClient("fairchild/workspaces", "token")
        with mock.patch.object(
            api_client,
            "request",
            return_value={"workflow_runs": runs},
        ):
            self.assertEqual(
                api_client.workflow_runs_on("factory-review-execute.yml", "2026-07-14"),
                runs,
            )

    def test_review_was_posted_requires_the_specific_review_step_to_succeed(self) -> None:
        def job(name: str, step_name: str, step_conclusion: str, job_conclusion: str = "success"):
            return {
                "name": name,
                "conclusion": job_conclusion,
                "steps": [{"name": step_name, "conclusion": step_conclusion}],
            }

        self.assertTrue(
            factory_review.review_was_posted(
                [job("april", "Run April counterpart review", "success")]
            )
        )
        self.assertFalse(
            factory_review.review_was_posted(
                [job("april", "Run April counterpart review", "skipped")]
            ),
            "a job that trivially succeeded because the review step was skipped "
            "(dedup, or head changed after admission) did not post a review",
        )
        self.assertFalse(
            factory_review.review_was_posted(
                [job("plat", "Run Plat counterpart review", "failure", job_conclusion="failure")]
            ),
            "a crashed reviewer step did not post a review",
        )
        self.assertFalse(
            factory_review.review_was_posted([{"name": "admit", "conclusion": "success", "steps": []}]),
            "admission alone is not a posted review",
        )

    def test_review_step_counts_once_regardless_of_retries_inside_it(self) -> None:
        """#1179: run-contributor.py retries a review once in-process on a
        transient failure before `route_action` ever posts anything, so at
        most one `gh pr review` call happens per step. Confirms the budget
        accounting this depends on: it is derived entirely from the step's
        own final conclusion and `run_attempt` (a *workflow*-level GitHub
        Actions rerun), neither of which reflects retries that happened
        inside a single step's process -- so an in-process retry cannot be
        observed here at all, let alone counted twice.
        """
        run = {"id": 1, "run_attempt": 1, "status": "completed", "conclusion": "success"}
        # Same shape regardless of whether the review step needed a retry
        # internally to reach this success -- factory-review.py has no
        # visibility into that and does not need any to count correctly.
        jobs = [
            {
                "name": "april",
                "conclusion": "success",
                "steps": [{"name": "Run April counterpart review", "conclusion": "success"}],
            }
        ]

        self.assertTrue(factory_review.review_was_posted(jobs))
        budget = factory_review.count_daily_review_budget(
            [run], {"1": True}, current_run_id="1"
        )
        self.assertEqual(budget, 1, "a retried-then-posted review claims exactly one budget slot")

    def test_daily_cap_counts_only_successful_reviews_not_failed_attempts(self) -> None:
        """Retries and crash-loop failures must not inflate the review budget."""
        runs = [
            {"id": 1, "run_attempt": 1, "status": "completed", "conclusion": "success"},
            {"id": 2, "run_attempt": 5, "status": "completed", "conclusion": "failure"},
            {"id": 3, "run_attempt": 1, "status": "completed", "conclusion": "success"},
        ]

        def jobs_for(run_id: int) -> list[dict[str, object]]:
            posted = {1: True, 2: False, 3: True}
            conclusion = "success" if posted[run_id] else "failure"
            return [
                {
                    "name": "april",
                    "conclusion": conclusion,
                    "steps": [{"name": "Run April counterpart review", "conclusion": conclusion}],
                }
            ]

        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.side_effect = lambda run_id: jobs_for(run_id)

        # Two reviews were posted (runs 1 and 3); run 2 failed after five
        # attempts and posted nothing, so it does not count toward the cap.
        # The current attempt ("4") reserves the third and final slot.
        factory_review.authorize_execution(
            client, daily_cap=3, runaway_cap=30, current_run_id="4", current_run_attempt=1
        )

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "daily review cap of 2"):
            factory_review.authorize_execution(
                client, daily_cap=2, runaway_cap=30, current_run_id="5", current_run_attempt=1
            )

    def test_sibling_job_failure_does_not_erase_a_posted_review(self) -> None:
        """A telemetry-job failure must not zero out a review the reviewer job posted.

        The run's overall conclusion is 'failure' (telemetry failed), but the
        april job's own review step succeeded -- that must still count.
        """
        runs = [{"id": 1, "run_attempt": 1, "status": "completed", "conclusion": "failure"}]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.return_value = [
            {
                "name": "april",
                "conclusion": "success",
                "steps": [{"name": "Run April counterpart review", "conclusion": "success"}],
            },
            {"name": "telemetry", "conclusion": "failure", "steps": []},
        ]

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "daily review cap of 1"):
            factory_review.authorize_execution(
                client, daily_cap=1, runaway_cap=30, current_run_id="2", current_run_attempt=1
            )

    def test_in_flight_runs_hold_a_provisional_claim_against_the_cap(self) -> None:
        """Concurrent triggers across different PRs must not all bypass the cap.

        None of them show as a posted review yet, so without a provisional
        hold on still-running executions, a burst could admit far more than
        `daily_cap` concurrent reviews before any of them resolve.
        """
        runs = [{"id": 10, "status": "in_progress", "conclusion": None}]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.return_value = []

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "daily review cap of 1"):
            factory_review.authorize_execution(
                client, daily_cap=1, runaway_cap=30, current_run_id="20", current_run_attempt=1
            )

    def test_a_failed_run_releases_its_claim_once_concluded(self) -> None:
        """A run that finishes without posting a review frees its reservation."""
        runs = [{"id": 10, "status": "completed", "conclusion": "failure"}]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.return_value = []

        factory_review.authorize_execution(
            client, daily_cap=1, runaway_cap=30, current_run_id="20", current_run_attempt=1
        )

    def test_runaway_guard_trips_on_raw_attempts_even_with_no_successful_reviews(
        self,
    ) -> None:
        """A pure crash loop must still be stopped even though nothing succeeded."""
        runs = [{"id": 1, "run_attempt": 40, "status": "completed", "conclusion": "failure"}]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.return_value = [{"name": "april", "conclusion": "failure"}]

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "runaway guard"):
            factory_review.authorize_execution(
                client, daily_cap=12, runaway_cap=36, current_run_id="1", current_run_attempt=41
            )

    def test_runaway_cap_defaults_to_a_multiple_of_the_daily_cap(self) -> None:
        self.assertEqual(factory_review.parse_runaway_cap(None, 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("", 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("100", 12), 100)
        with self.assertRaisesRegex(factory_review.FactoryReviewError, "positive integer"):
            factory_review.parse_runaway_cap("0", 12)

    def test_human_or_draft_pull_request_does_not_enter_review_lane(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        human = self.pull_request(label="quality")
        draft = self.pull_request(draft=True)

        self.assertEqual(
            factory_review.evaluate_review(human, files, [], force=False).action,
            "skip",
        )
        self.assertEqual(
            factory_review.evaluate_review(draft, files, [], force=False).action,
            "skip",
        )

    def test_workflow_uses_isolated_apps_kill_switches_and_no_review_trigger(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        executor = EXECUTOR_PATH.read_text(encoding="utf-8")

        self.assertIn("types: [opened, ready_for_review, synchronize]", workflow)
        self.assertNotIn("pull_request_review:", workflow)
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", workflow)
        self.assertIn("vars.FACTORY_REVIEW_ENABLED == 'true'", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("workflow_run:", executor)
        self.assertIn("secrets.APRIL_APP_ID", executor)
        self.assertIn("secrets.APRIL_PRIVATE_KEY", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_APP_ID", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_PRIVATE_KEY", executor)
        self.assertIn("GH_APP_SLUG: april-clearwater", executor)
        self.assertIn("GH_APP_SLUG: workspace-agents", executor)
        self.assertIn("mentioned you in PR #${PR_NUMBER}", executor)
        self.assertIn("ref: ${{ needs.admit.outputs.head_sha }}", executor)
        self.assertIn("--expected-head", executor)
        self.assertIn("FACTORY_EXPECTED_PR_HEAD_SHA", executor)
        self.assertIn("FACTORY_REVIEW_DAILY_CAP", executor)
        self.assertIn("FACTORY_REVIEW_RUNAWAY_CAP", executor)
        self.assertIn("factory-review.py --authorize", executor)


if __name__ == "__main__":
    unittest.main()
