#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory counterpart-review admission."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review.yml"
EXECUTOR_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"
READINESS_PATH = REPO_ROOT / "scripts" / "pr-readiness.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review = load_module("factory_review", SCRIPT_PATH)


class FactoryReviewTests(unittest.TestCase):
    REPOSITORY = "fairchild/workspaces"

    def pull_request(
        self,
        *,
        label: str | None = "author:codex",
        labels: tuple[str, ...] | None = None,
        draft: bool = False,
        head_sha: str = "abc123",
        head_repository: str | None = None,
    ):
        if labels is None:
            labels = () if label is None else (label,)
        return {
            "state": "open",
            "draft": draft,
            "labels": [{"name": name} for name in labels],
            "head": {
                "sha": head_sha,
                "repo": {"full_name": head_repository or self.REPOSITORY},
            },
            "base": {"repo": {"full_name": self.REPOSITORY}},
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

        for label in ("author:claude-code", "author:codex", "author:fable-orchestrator", None):
            with self.subTest(label=label):
                pull_request = self.pull_request(label=label)
                self.assertEqual(
                    factory_review.route_reviewer(pull_request, application_files),
                    "april",
                )
                self.assertEqual(
                    factory_review.route_reviewer(pull_request, platform_files),
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

        self.assertIn("possible crash loop", self.guard_failure(client, daily_cap=12))
        self.assertNotIn("budget exhaustion", self.guard_failure(client, daily_cap=12))

    def guard_failure(
        self,
        client,
        *,
        daily_cap: int = 12,
        runaway_cap: int = 36,
        current_run_id: str = "1",
        current_run_attempt: int = 41,
    ) -> str:
        """The message `authorize_execution` dies with, asserting that it dies."""
        with self.assertRaises(factory_review.FactoryReviewError) as raised:
            with contextlib.redirect_stdout(io.StringIO()):
                factory_review.authorize_execution(
                    client,
                    daily_cap=daily_cap,
                    runaway_cap=runaway_cap,
                    current_run_id=current_run_id,
                    current_run_attempt=current_run_attempt,
                )
        return str(raised.exception)

    def cap_exhausted_morning(self):
        """Run 33382299160's day, replayed: 36 runs, 12 of which posted a review.

        Verified against the live run list for 2026-08-31 (42 runs, all
        `run_attempt` 1) and the admit logs either side of the crossover: run
        33382111323 printed `36/36` and `budget: 13/12` and failed with the
        daily review cap; 33382299160 printed `37/36` and failed with
        "possible crash loop", never reaching the budget line.
        """
        posted = list(range(1, 13))
        refused = list(range(13, 37))
        runs = [
            {"id": run_id, "run_attempt": 1, "status": "completed", "conclusion": "success"}
            for run_id in posted
        ] + [
            {"id": run_id, "run_attempt": 1, "status": "completed", "conclusion": "failure"}
            for run_id in refused
        ]
        review_step = [
            {
                "name": "april",
                "conclusion": "success",
                "steps": [{"name": "Run April counterpart review", "conclusion": "success"}],
            }
        ]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.side_effect = lambda run_id: (
            review_step if run_id in posted else []
        )
        return client

    def test_a_cap_exhausted_day_of_refusals_does_not_report_a_crash_loop(self) -> None:
        """#1271, specimen #1487: the morning of 2026-08-31, under this code.

        Twelve reviews posted, then every later trigger refused at the admit
        gate -- 25 free no-ops that walked the raw counter past 36 on their
        own. Under the old code this raised "possible crash loop" while
        nothing was looping, and on the 2026-08-08 instance of the same
        sequence two agents spent a diagnosis on the wrong ceiling. The guard
        still fires (the ceiling is unchanged); it now says why.
        """
        message = self.guard_failure(
            self.cap_exhausted_morning(), current_run_id="33382299160", current_run_attempt=1
        )

        self.assertNotIn("possible crash loop", message)
        self.assertIn("budget exhaustion, not a crash loop", message)
        self.assertIn("37 run attempts", message)
        self.assertIn("daily review cap of 12 is exhausted (13 posted or in-flight today)", message)
        self.assertIn("25 attempts refused since", message)
        self.assertIn("reset at 00:00Z UTC", message)

    def test_the_cap_exhausted_failure_logs_both_counters(self) -> None:
        """The budget line is the reader's evidence, so it must survive the guard.

        Run 33382299160's log stopped after `raw attempt count: 37/36`: the
        old ordering raised before the budget was ever computed, so the one
        number that explained the failure never printed.
        """
        buffer = io.StringIO()
        with self.assertRaises(factory_review.FactoryReviewError):
            with contextlib.redirect_stdout(buffer):
                factory_review.authorize_execution(
                    self.cap_exhausted_morning(),
                    daily_cap=12,
                    runaway_cap=36,
                    current_run_id="33382299160",
                    current_run_attempt=1,
                )

        self.assertIn("Factory review raw attempt count: 37/36", buffer.getvalue())
        self.assertIn("Factory review execution budget: 13/12", buffer.getvalue())

    def test_a_crash_loop_after_a_productive_morning_is_still_a_crash_loop(self) -> None:
        """The discriminator is the budget, not "did anything post today".

        Three reviews posted, then a genuine loop of 34 attempts posting
        nothing. A loop's runs conclude without posting, so they release their
        budget claim -- the budget stays well under cap, and the ceiling is
        again the only thing that can stop it. Keying the message off "some
        review was posted today" would have mislabelled this as backpressure.
        """
        runs = [
            {"id": 1, "run_attempt": 1, "status": "completed", "conclusion": "success"},
            {"id": 2, "run_attempt": 1, "status": "completed", "conclusion": "success"},
            {"id": 3, "run_attempt": 1, "status": "completed", "conclusion": "success"},
            {"id": 4, "run_attempt": 34, "status": "completed", "conclusion": "failure"},
        ]
        review_step = [
            {
                "name": "april",
                "conclusion": "success",
                "steps": [{"name": "Run April counterpart review", "conclusion": "success"}],
            }
        ]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.side_effect = lambda run_id: (
            review_step if run_id in (1, 2, 3) else []
        )

        message = self.guard_failure(client, current_run_id="5", current_run_attempt=1)

        self.assertIn("possible crash loop", message)
        self.assertNotIn("budget exhaustion", message)

    def test_neither_ceiling_moved_and_the_runaway_check_still_goes_first(self) -> None:
        """#1271 asks for a message, not a threshold or an ordering change.

        At exactly the cap the guard stays silent (the comparison is still
        strict), and one attempt later -- with the budget also over -- it is
        the runaway ceiling that raises, not the budget check, because a crash
        loop must be stopped whatever the budget says.
        """
        client = self.cap_exhausted_morning()

        at_the_ceiling = self.guard_failure(
            client, runaway_cap=37, current_run_id="33382299160", current_run_attempt=1
        )
        self.assertIn("daily review cap of 12 is exceeded", at_the_ceiling)
        self.assertNotIn("runaway guard", at_the_ceiling)

        one_over = self.guard_failure(
            client, runaway_cap=36, current_run_id="33382299160", current_run_attempt=1
        )
        self.assertTrue(
            one_over.startswith("daily runaway guard of 36 run attempts is exceeded"),
            one_over,
        )

    def test_the_runaway_message_names_the_condition_that_caused_it(self) -> None:
        """#1271's acceptance, at the message seam itself."""
        crash_loop = factory_review.runaway_guard_reason(
            raw_attempts=37,
            runaway_cap=36,
            budget=1,
            daily_cap=12,
            unproductive_attempts=37,
            lane_noun="review",
        )
        backpressure = factory_review.runaway_guard_reason(
            raw_attempts=37,
            runaway_cap=36,
            budget=13,
            daily_cap=12,
            unproductive_attempts=25,
            lane_noun="review",
        )

        self.assertEqual(
            crash_loop,
            "daily runaway guard of 36 run attempts is exceeded "
            "(37 run attempts) -- possible crash loop",
        )
        self.assertIn("budget exhaustion, not a crash loop", backpressure)
        self.assertNotIn("possible crash loop", backpressure)

    def test_productive_and_unproductive_attempts_account_for_every_attempt(self) -> None:
        runs = [
            {"id": 1, "run_attempt": 1},
            {"id": 2, "run_attempt": 3},
            {"id": 3, "run_attempt": 1},
        ]
        posted = {"1": True, "2": False, "3": False}

        raw = factory_review.count_daily_run_attempts(runs, "4", 2)
        unproductive = factory_review.count_unproductive_attempts(runs, posted, "4", 2)

        self.assertEqual(raw, 7)
        self.assertEqual(unproductive, 6, "run 1's single posting attempt is the only productive one")
        self.assertEqual(
            factory_review.count_unproductive_attempts(runs, {}, "", 1),
            factory_review.count_daily_run_attempts(runs, "", 1),
            "a day that posted nothing has no productive attempts",
        )

    def test_runaway_cap_defaults_to_a_multiple_of_the_daily_cap(self) -> None:
        self.assertEqual(factory_review.parse_runaway_cap(None, 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("", 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("100", 12), 100)
        with self.assertRaisesRegex(factory_review.FactoryReviewError, "positive integer"):
            factory_review.parse_runaway_cap("0", 12)

    FILES = [{"filename": "Sources/Feature.swift"}]

    def decide(self, pull_request, reviews=(), *, force=False):
        return factory_review.evaluate_review(
            pull_request, self.FILES, list(reviews), force=force
        )

    def april_review(self, *, head: str = "abc123", state: str = "APPROVED"):
        return {
            "user": {"login": "april-clearwater[bot]"},
            "commit_id": head,
            "state": state,
        }

    def test_an_unlabelled_pull_request_is_reviewed(self) -> None:
        """The failure this default reverses: no author label used to mean no review,
        and nothing on the pull request said so."""
        decision = self.decide(self.pull_request(label=None))

        self.assertEqual(decision.action, "review")
        self.assertEqual(decision.reviewer, "april")

    def test_a_label_that_is_not_an_author_label_does_not_suppress_review(self) -> None:
        self.assertEqual(self.decide(self.pull_request(label="quality")).action, "review")

    def test_the_skip_review_label_suppresses_review(self) -> None:
        decision = self.decide(self.pull_request(labels=("author:codex", "skip-review")))

        self.assertEqual(decision.action, "skip")
        self.assertIn("skip-review", decision.reason)

    def test_a_fork_pull_request_is_not_reviewed(self) -> None:
        """A review reads the diff and writes under a reviewer app's token, so an
        unvouched fork is refused rather than admitted by default."""
        decision = self.decide(self.pull_request(head_repository="stranger/workspaces"))

        self.assertEqual(decision.action, "skip")
        self.assertIn("not on this repository", decision.reason)

    def test_a_vouched_fork_pull_request_is_reviewed(self) -> None:
        decision = self.decide(
            self.pull_request(
                labels=("author:codex", "safe-to-review-fork"),
                head_repository="stranger/workspaces",
            )
        )

        self.assertEqual(decision.action, "review")

    def test_an_author_label_cannot_vouch_for_a_fork(self) -> None:
        """The label a stranger cannot apply is the one that admits them."""
        self.assertEqual(
            self.decide(
                self.pull_request(label="author:claude-code", head_repository="stranger/workspaces")
            ).action,
            "skip",
        )

    def test_the_sweep_and_the_lane_share_one_admission_definition(self) -> None:
        """Both ask `admitted_for_review`; a gate written twice is a gate that drifts."""
        fork = self.pull_request(head_repository="stranger/workspaces")
        vouched = self.pull_request(
            labels=("safe-to-review-fork",), head_repository="stranger/workspaces"
        )

        self.assertFalse(factory_review.admitted_for_review(fork))
        self.assertTrue(factory_review.admitted_for_review(vouched))
        self.assertTrue(factory_review.admitted_for_review(self.pull_request()))
        self.assertEqual(self.decide(fork).action, "skip")

    def test_a_pull_request_with_no_known_provenance_is_refused(self) -> None:
        self.assertEqual(self.decide({"state": "open", "labels": []}).action, "skip")

    def test_a_draft_is_reviewed_once_and_then_left_alone(self) -> None:
        draft = self.pull_request(draft=True)
        first = self.decide(draft)

        self.assertEqual(first.action, "review")

        pushed = self.pull_request(draft=True, head_sha="def456")
        self.assertEqual(
            self.decide(pushed, [self.april_review()]).action,
            "skip",
        )

    def test_marking_a_draft_ready_restores_the_per_push_cadence(self) -> None:
        ready = self.pull_request(draft=False, head_sha="def456")

        self.assertEqual(self.decide(ready, [self.april_review()]).action, "review")

    def test_a_comment_only_review_does_not_quiet_a_draft(self) -> None:
        pushed = self.pull_request(draft=True, head_sha="def456")
        commented = [self.april_review(state="COMMENTED")]

        self.assertEqual(self.decide(pushed, commented).action, "review")

    def test_a_closed_pull_request_is_never_reviewed(self) -> None:
        closed = {**self.pull_request(), "state": "closed"}

        self.assertEqual(self.decide(closed).action, "skip")

    READY_BODY = (
        "## Summary\n\nA change.\n\n"
        "## Evidence Status\n- [complete] CI green -- proof\n\n"
        "## Validation\n- 12 passed\n\n"
        "## Mergeability\n"
        "- Surface: infra — the factory review lane\n"
        "- User-facing behavior changed: No\n"
        "- Non-happy paths considered: covered by tests\n"
        "- Residual risk or follow-up: None\n"
    )

    def ready_pull_request(self, *, body: str | None = None, labels=("author:april",)):
        return {
            "state": "open",
            "labels": [{"name": name} for name in labels],
            "user": {"login": "april-clearwater[bot]"},
            "head": {"sha": "headsha", "repo": {"full_name": self.REPOSITORY}},
            "base": {"repo": {"full_name": self.REPOSITORY}},
            "body": self.READY_BODY if body is None else body,
        }

    def stale_reviews(
        self,
        *,
        state: str = "CHANGES_REQUESTED",
        head: str = "headsha",
        submitted_at: str = "2026-08-27T02:00:00Z",
    ) -> list[dict[str, object]]:
        return [
            {
                "user": {"login": "workspace-agents[bot]"},
                "commit_id": head,
                "state": state,
                "submitted_at": submitted_at,
            }
        ]

    def refreshable(self, pull_request, reviews, files=()) -> bool:
        return factory_review.stale_review_refreshable(
            pull_request,
            [{"filename": name} for name in files],
            reviews,
            reviewer="plat",
            head_sha="headsha",
        )

    def test_a_standing_rejection_refreshes_once_readiness_passes(self) -> None:
        # #1102, then #1377: the objection was to the PR body, the fix moves no
        # commit, so dismiss_stale_reviews_on_push never fires and the reviewer
        # never re-runs.
        self.assertTrue(self.refreshable(self.ready_pull_request(), self.stale_reviews()))

    def test_a_body_that_still_fails_readiness_does_not_refresh(self) -> None:
        # The whole point of sharing pr-readiness.py: an edit is not evidence
        # the objection was addressed, and could as easily have added a blocker.
        cases = {
            "no Mergeability": self.READY_BODY.replace("## Mergeability", "## Notes"),
            "evidence still blocked": self.READY_BODY.replace(
                "- [complete] CI green -- proof", "- [blocked] CI green -- waiting"
            ),
            "evidence still pending": self.READY_BODY.replace(
                "- [complete] CI green -- proof", "- [pending-ci] CI green -- waiting"
            ),
            "blank Mergeability field": self.READY_BODY.replace(
                "- Residual risk or follow-up: None", "- Residual risk or follow-up: TBD"
            ),
            "merge-stop instruction": self.READY_BODY + "\nDo not merge until Friday.\n",
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                self.assertFalse(
                    self.refreshable(self.ready_pull_request(body=body), self.stale_reviews())
                )
        # A blocking label the body cannot show is caught for the same reason.
        self.assertFalse(
            self.refreshable(
                self.ready_pull_request(labels=("author:april", "blocked:secrets")),
                self.stale_reviews(),
            )
        )

    def test_no_standing_rejection_means_nothing_to_refresh(self) -> None:
        ready = self.ready_pull_request()
        # Approved on this head.
        self.assertFalse(self.refreshable(ready, self.stale_reviews(state="APPROVED")))
        # Rejected, but on an older head -- a push already superseded it.
        self.assertFalse(self.refreshable(ready, self.stale_reviews(head="older")))
        # Dismissed, pending, or absent entirely.
        self.assertFalse(self.refreshable(ready, self.stale_reviews(state="DISMISSED")))
        self.assertFalse(self.refreshable(ready, self.stale_reviews(state="PENDING")))
        self.assertFalse(self.refreshable(ready, []))
        # A review with no commit id cannot be matched to this head.
        self.assertFalse(self.refreshable(ready, self.stale_reviews(head="")))

    def test_a_later_approval_supersedes_the_rejection_on_the_same_head(self) -> None:
        reviews = self.stale_reviews() + self.stale_reviews(
            state="APPROVED", submitted_at="2026-08-27T02:30:00Z"
        )
        self.assertFalse(self.refreshable(self.ready_pull_request(), reviews))

    def test_a_comment_only_review_does_not_displace_the_standing_verdict(self) -> None:
        reviews = self.stale_reviews() + self.stale_reviews(
            state="COMMENTED", submitted_at="2026-08-27T02:30:00Z"
        )
        self.assertTrue(self.refreshable(self.ready_pull_request(), reviews))

    def test_the_refresh_gate_is_the_merge_gate_not_a_second_opinion(self) -> None:
        # If these ever diverge, a PR could be re-reviewed into an approval it
        # cannot merge on, or stay parked while it is provably ready.
        self.assertIs(
            factory_review.pr_readiness.evaluate,
            sys.modules["pr_readiness_for_review"].evaluate,
        )
        readiness = READINESS_PATH.read_text(encoding="utf-8")
        self.assertIn("def evaluate(", readiness)

    def test_refresh_only_bypasses_the_already_reviewed_skip(self) -> None:
        pull_request = self.ready_pull_request()
        reviews = self.stale_reviews()
        self.assertEqual(
            factory_review.evaluate_review(pull_request, [], reviews, force=False).action,
            "skip",
        )
        self.assertEqual(
            factory_review.evaluate_review(
                pull_request, [], reviews, force=False, stale_refresh=True
            ).action,
            "review",
        )
        # Every other skip still holds -- refresh is not a bypass.
        for name, mutation in (
            ("closed", {"state": "closed"}),
            ("draft", {"draft": True}),
            ("no author label", {"labels": []}),
            ("two author labels", {"labels": [{"name": "author:april"}, {"name": "author:plat"}]}),
        ):
            with self.subTest(case=name):
                self.assertEqual(
                    factory_review.evaluate_review(
                        {**pull_request, **mutation}, [], reviews,
                        force=False, stale_refresh=True,
                    ).action,
                    "skip",
                )

    def test_the_review_signal_workflow_is_unchanged_by_this_lane(self) -> None:
        # The re-review request comes from the trusted Evidence Verify lane, not
        # from a global `pull_request: edited` subscription: a job skipped by
        # `if:` still reports success, so subscribing would start a trusted
        # executor run -- and a failed artifact download -- on every body edit
        # in the repository, poisoning the runaway cap.
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("types: [opened, ready_for_review, synchronize]", workflow)
        self.assertNotIn("edited", workflow)

    def test_only_the_owner_or_the_factory_may_dispatch_a_review(self) -> None:
        executor = EXECUTOR_PATH.read_text(encoding="utf-8")
        self.assertIn('if [ "$RUN_ACTOR" = "$REPOSITORY_OWNER" ]; then', executor)
        self.assertIn('elif [ "$RUN_ACTOR" = "github-actions[bot]" ]; then', executor)
        self.assertIn("Only the repository owner or the factory may re-request review.", executor)
        # The owner's dispatch forces; the factory's only requests.
        owner_branch = executor.split('if [ "$RUN_ACTOR" = "$REPOSITORY_OWNER" ]; then', 1)[1]
        self.assertTrue(
            owner_branch.lstrip().startswith("FORCE_REVIEW=true"),
            "owner dispatch must still force an unconditional review",
        )
        factory_branch = executor.split('elif [ "$RUN_ACTOR" = "github-actions[bot]" ]; then', 1)[1]
        self.assertTrue(factory_branch.lstrip().startswith("REFRESH_STALE=true"))
        # Re-derived in admission and again in each reviewer's preflight.
        self.assertEqual(executor.count("ARGS+=(--refresh-stale-review)"), 3)

    def test_only_owner_dispatch_bypasses_the_kill_switches(self) -> None:
        executor = EXECUTOR_PATH.read_text(encoding="utf-8")
        gate = executor.split("runs-on:", 1)[0]
        self.assertIn(
            "github.event.workflow_run.actor.login == github.repository_owner", gate
        )
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", gate)
        self.assertIn("vars.FACTORY_REVIEW_ENABLED == 'true'", gate)

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
