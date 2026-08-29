#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for April's revision turn (#1125).

Intent: prove the lane can never strand a PR the response lane deferred on.
Every admission decline downstream of that defer escalates, every turn that
does not land escalates, and the two claims the lane makes about state -- "a
revision answers this review" and "the owner is the blocking party" -- are
only ever written when they are true.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-revise.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-revise.yml"
REPO_VARIABLES_MANIFEST = REPO_ROOT / "config" / "github" / "repo-variables.json"

REPOSITORY = "fairchild/workspaces"
OWNER = "fairchild"
PLAT = "workspace-agents[bot]"
APRIL = "april-clearwater[bot]"
RUN_URL = "https://github.com/fairchild/workspaces/actions/runs/42"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


revise = load_module("factory_revise_under_test", SCRIPT_PATH)
response = revise.response
# The job/permission splitter the sibling workflow contract tests already use:
# one opinion about what a job block is, so a `permissions:` assertion here
# cannot disagree with the same assertion there.
parse_jobs = load_module(
    "factory_workflow_parsing_for_revise", TESTS_DIR / "test_factory_workflows.py"
).parse_jobs


def pull_request(
    *,
    author: str = APRIL,
    state: str = "open",
    draft: bool = False,
    labels: tuple[str, ...] = ("author:april",),
    body: str = "Closes #1000\n",
    head_repo: str = REPOSITORY,
    head_ref: str = "codex/april-clearwater-issue-1000-fix",
    head_sha: str = "aaaa1111",
) -> dict[str, object]:
    return {
        "number": 1377,
        "state": state,
        "draft": draft,
        "user": {"login": author},
        "labels": [{"name": name} for name in labels],
        "body": body,
        "head": {
            "ref": head_ref,
            "sha": head_sha,
            "repo": {"full_name": head_repo},
        },
    }


def review(
    *,
    login: str = PLAT,
    state: str = "CHANGES_REQUESTED",
    submitted_at: str = "2026-08-27T04:00:00Z",
    review_id: int = 900,
) -> dict[str, object]:
    return {
        "id": review_id,
        "state": state,
        "submitted_at": submitted_at,
        "user": {"login": login},
        "html_url": (
            f"https://github.com/fairchild/workspaces/pull/1377#pullrequestreview-{review_id}"
        ),
    }


def april_comment(body: str) -> dict[str, object]:
    return {"user": {"login": APRIL}, "body": body}


def revision_comment(review_id: int) -> dict[str, object]:
    return april_comment(f"revised\n\n{response.revision_marker(review_id)}")


def issue(*, evidence: bool = True) -> dict[str, object]:
    body = "Make the thing work.\n"
    if evidence:
        body += "\n## Requested Evidence\n- `swift test` passes\n"
    return {"number": 1000, "body": body}


def workflow_run(
    run_id: int,
    *,
    status: str = "completed",
    run_attempt: int = 1,
) -> dict[str, object]:
    return {"id": run_id, "status": status, "run_attempt": run_attempt}


def revise_job(*, conclusion: str = "success") -> dict[str, object]:
    return {
        "name": "revise",
        "steps": [
            {"name": "Run April revision turn", "conclusion": conclusion},
        ],
    }


class FakeClient:
    """Minimal stand-in for the GitHub client: records what was written."""

    def __init__(
        self,
        pr: dict[str, object],
        reviews: list[dict[str, object]],
        comments: list[dict[str, object]] | None = None,
        *,
        files: list[str] | None = None,
        linked_issue: dict[str, object] | None = None,
        runs: list[dict[str, object]] | None = None,
        jobs: dict[int, list[dict[str, object]]] | None = None,
    ) -> None:
        self.repository = REPOSITORY
        self._pr = pr
        self._reviews = reviews
        self._comments = list(comments or [])
        self._files = list(files or ["Sources/Feature.swift"])
        self._issue = linked_issue if linked_issue is not None else issue()
        self._runs = list(runs or [])
        self._jobs = dict(jobs or {})
        self.posted: list[str] = []
        self.added: list[str] = []
        self.removed: list[str] = []
        self.ensured: list[str] = []
        self.dispatched: list[tuple[str, str, dict[str, str]]] = []
        self.dispatch_failure = False

    def pull_request(self, number: int) -> dict[str, object]:
        return self._pr

    def pull_request_reviews(self, number: int) -> list[dict[str, object]]:
        return self._reviews

    def pull_request_files(self, number: int) -> list[dict[str, object]]:
        return [{"filename": path} for path in self._files]

    def comments(self, number: int) -> list[dict[str, object]]:
        return self._comments

    def comment(self, number: int, body: str) -> None:
        self.posted.append(body)
        self._comments.append(april_comment(body))

    def issue(self, number: int) -> dict[str, object]:
        return self._issue

    def timeline(self, number: int) -> list[dict[str, object]]:
        return []

    def ensure_label(self, name: str, color: str, description: str) -> bool:
        self.ensured.append(name)
        return True

    def add_label(self, number: int, name: str) -> None:
        self.added.append(name)
        self._pr["labels"] = [*self._pr["labels"], {"name": name}]

    def remove_label(self, number: int, name: str) -> None:
        self.removed.append(name)

    def workflow_runs_on(self, workflow: str, day: str) -> list[dict[str, object]]:
        return self._runs

    def workflow_run_jobs(self, run_id: int) -> list[dict[str, object]]:
        return self._jobs.get(run_id, [])

    def dispatch_workflow(self, workflow: str, ref: str, inputs: dict[str, str]) -> None:
        if self.dispatch_failure:
            raise revise.factory_implement.FactoryImplementError("HTTP 403")
        self.dispatched.append((workflow, ref, dict(inputs)))


class QuietTest(unittest.TestCase):
    def setUp(self) -> None:
        handle = tempfile.NamedTemporaryFile("w", delete=False)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        patcher = mock.patch.dict(os.environ, {"GITHUB_OUTPUT": handle.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        buffer = io.StringIO()
        redirect = contextlib.redirect_stdout(buffer)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def run_admit(
        self,
        client: FakeClient,
        *,
        review_id: int | None = 900,
        daily_cap: int = 4,
        runaway_cap: int = 12,
        recovery: bool = False,
    ) -> tuple[revise.AdmissionDecision, dict[str, str]]:
        outputs: dict[str, str] = {}
        with mock.patch.object(
            revise, "write_output", lambda name, value: outputs.__setitem__(name, value)
        ):
            decision = revise.admit(
                client,
                client,
                1377,
                review_id,
                OWNER,
                daily_cap=daily_cap,
                runaway_cap=runaway_cap,
                current_run_id="7",
                current_run_attempt=1,
                recovery=recovery,
            )
        return decision, outputs


class AdmissionScopeTests(QuietTest):
    """Declines above the defer boundary: the response lane already spoke, or
    the event never reached it, so silence here strands nothing."""

    def assert_silent_decline(self, client: FakeClient) -> revise.AdmissionDecision:
        decision, outputs = self.run_admit(client)
        self.assertEqual(decision.action, "decline")
        self.assertFalse(decision.escalate)
        self.assertEqual(outputs["matched"], "false")
        self.assertEqual(outputs["escalate"], "false")
        return decision

    def test_an_april_authored_open_pr_with_a_blocking_review_is_admitted(self) -> None:
        client = FakeClient(pull_request(), [review()])
        decision, outputs = self.run_admit(client)
        self.assertEqual(decision.action, "revise")
        self.assertEqual(outputs["matched"], "true")
        self.assertEqual(outputs["review_id"], "900")
        self.assertEqual(outputs["head_sha"], "aaaa1111")
        self.assertEqual(outputs["pr_branch"], "codex/april-clearwater-issue-1000-fix")
        self.assertEqual(outputs["linked_issue"], "1000")

    def test_a_pull_request_april_did_not_author_is_refused(self) -> None:
        # v1 scope: the lane pushes to the head branch, so it only takes
        # branches the factory itself wrote.
        for author in (OWNER, PLAT, "workspaces-factory[bot]"):
            with self.subTest(author=author):
                self.assert_silent_decline(
                    FakeClient(pull_request(author=author), [review()])
                )

    def test_a_fork_head_is_refused(self) -> None:
        self.assert_silent_decline(
            FakeClient(pull_request(head_repo="someone/workspaces"), [review()])
        )

    def test_closed_draft_and_unlabelled_pull_requests_are_refused(self) -> None:
        for name, pr in (
            ("closed", pull_request(state="closed")),
            ("draft", pull_request(draft=True)),
            ("no author label", pull_request(labels=())),
            ("two author labels", pull_request(labels=("author:april", "author:plat"))),
        ):
            with self.subTest(case=name):
                self.assert_silent_decline(FakeClient(pr, [review()]))

    def test_a_superseded_or_dismissed_review_is_refused(self) -> None:
        for name, reviews in (
            (
                "approved since",
                [
                    review(review_id=900, submitted_at="2026-08-27T01:00:00Z"),
                    review(
                        review_id=901,
                        state="APPROVED",
                        submitted_at="2026-08-27T02:00:00Z",
                    ),
                ],
            ),
            ("dismissed", [review(state="DISMISSED")]),
            ("untrusted reviewer", [review(login="drive-by")]),
        ):
            with self.subTest(case=name):
                self.assert_silent_decline(FakeClient(pull_request(), reviews))

    def test_a_review_already_answered_by_a_revision_is_refused(self) -> None:
        # The turn is in flight (or landed); a second one would answer the
        # same objection against the same code.
        self.assert_silent_decline(
            FakeClient(pull_request(), [review()], [revision_comment(900)])
        )

    def test_a_review_the_response_lane_escalated_is_refused(self) -> None:
        self.assert_silent_decline(
            FakeClient(
                pull_request(),
                [review()],
                [april_comment(f"asked\n\n{response.response_marker(900)}")],
            )
        )

    def test_an_owner_required_blocker_is_left_to_the_response_lane(self) -> None:
        # `blocked:evidence` is an owner attestation; no revision clears it,
        # and the response lane posts its own escalation naming the gesture.
        self.assert_silent_decline(
            FakeClient(
                pull_request(labels=("author:april", "blocked:evidence")), [review()]
            )
        )


class AdmissionEscalationTests(QuietTest):
    """Declines below the defer boundary: the response lane posted nothing, so
    resolve has to."""

    def assert_escalating_decline(self, client: FakeClient) -> revise.AdmissionDecision:
        decision, outputs = self.run_admit(client)
        self.assertEqual(decision.action, "decline")
        self.assertTrue(decision.escalate, decision.reason)
        self.assertEqual(outputs["matched"], "false")
        self.assertEqual(outputs["escalate"], "true")
        self.assertEqual(outputs["decline_reason"], decision.reason)
        self.assertTrue(outputs["review_id"])
        return decision

    def test_the_attempt_ceiling_declines_without_a_second_writer(self) -> None:
        # The response lane never defers at the ceiling -- it escalates on its
        # own path -- and the two lanes race from different concurrency groups,
        # so a second escalation here would dodge the marker dedupe. One
        # writer per state.
        comments = [
            revision_comment(800),
            revision_comment(850),
        ]
        decision, outputs = self.run_admit(
            FakeClient(pull_request(), [review()], comments)
        )
        self.assertEqual(decision.action, "decline")
        self.assertFalse(decision.escalate)
        self.assertEqual(outputs["escalate"], "false")
        self.assertIn("escalates", decision.reason)

    def test_the_ceiling_counts_distinct_reviews_not_repeated_markers(self) -> None:
        # The lane repairs a missing marker by posting one itself; counting
        # comments would spend the ceiling on a single answered review.
        client = FakeClient(
            pull_request(),
            [review()],
            [revision_comment(800), revision_comment(800), revision_comment(800)],
        )
        decision, _ = self.run_admit(client)
        self.assertEqual(decision.action, "revise")

    def test_a_privileged_path_escalates(self) -> None:
        decision = self.assert_escalating_decline(
            FakeClient(
                pull_request(),
                [review()],
                files=["Sources/Feature.swift", ".github/workflows/ci.yml"],
            )
        )
        self.assertIn(".github/workflows/ci.yml", decision.reason)

    def test_the_privileged_patch_label_earns_no_exemption(self) -> None:
        # The label sanctions a diff existing; it does not sanction this lane
        # re-running the branch's own validator and prompt files with a
        # branch-writing token. Declining unconditionally is what keeps an
        # admitted branch's `.agents/` and `.github/` content provably main's.
        decision = self.assert_escalating_decline(
            FakeClient(
                pull_request(
                    labels=("author:april", "privileged-agent-patch")
                ),
                [review()],
                files=[".github/workflows/ci.yml"],
            )
        )
        self.assertIn("owner's", decision.reason)

    def test_recovery_retakes_an_escalated_review(self) -> None:
        # The escalation's own gesture is "clear the cause and re-run Factory
        # Revise"; a rerun refused by that escalation's marker would make the
        # instruction a lie. Owner-only by the workflow's dispatch admission.
        escalated = [april_comment(f"asked\n\n{response.response_marker(900)}")]
        without, _ = self.run_admit(FakeClient(pull_request(), [review()], escalated))
        self.assertEqual(without.action, "decline")
        decision, _ = self.run_admit(
            FakeClient(pull_request(), [review()], escalated), recovery=True
        )
        self.assertEqual(decision.action, "revise")

    def test_recovery_falls_back_to_the_newest_standing_review(self) -> None:
        # Dispatch path with every standing rejection already answered: the
        # unanswered-first pick returns nothing, and recovery exists exactly
        # to retake an answered one.
        escalated = [april_comment(f"asked\n\n{response.response_marker(900)}")]
        decision, outputs = self.run_admit(
            FakeClient(pull_request(), [review()], escalated),
            review_id=None,
            recovery=True,
        )
        self.assertEqual(decision.action, "revise")
        self.assertEqual(outputs["review_id"], "900")

    def test_a_missing_evidence_contract_escalates(self) -> None:
        decision = self.assert_escalating_decline(
            FakeClient(
                pull_request(), [review()], linked_issue=issue(evidence=False)
            )
        )
        self.assertIn("Requested Evidence", decision.reason)

    def test_a_pull_request_with_no_linked_issue_escalates(self) -> None:
        decision = self.assert_escalating_decline(
            FakeClient(pull_request(body="No closing reference here.\n"), [review()])
        )
        self.assertIn("closing reference", decision.reason)

    def test_an_exhausted_daily_cap_escalates(self) -> None:
        client = FakeClient(
            pull_request(),
            [review()],
            runs=[workflow_run(run_id) for run_id in range(100, 105)],
            jobs={run_id: [revise_job()] for run_id in range(100, 105)},
        )
        decision = self.assert_escalating_decline(client)
        self.assertIn("daily revision cap", decision.reason)

    def test_the_runaway_guard_escalates_on_raw_attempts(self) -> None:
        # A crash loop never posts a revision, so the budget below never sees
        # it; the raw-attempt ceiling is what stops it retrying forever.
        client = FakeClient(
            pull_request(),
            [review()],
            runs=[workflow_run(100, run_attempt=13)],
            jobs={100: [revise_job(conclusion="failure")]},
        )
        decision = self.assert_escalating_decline(client)
        self.assertIn("runaway guard", decision.reason)


class BudgetTests(unittest.TestCase):
    def test_a_spent_turn_is_read_off_the_step_not_the_job(self) -> None:
        # A job whose preflight declined still concludes success, and must not
        # consume a day's budget.
        self.assertTrue(revise.revision_was_posted([revise_job()]))
        self.assertFalse(revise.revision_was_posted([revise_job(conclusion="skipped")]))
        self.assertFalse(
            revise.revision_was_posted(
                [{"name": "resolve", "steps": [{"name": "Resolve", "conclusion": "success"}]}]
            )
        )

    def test_the_step_name_matches_the_workflow(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        for job, step in revise.REVISION_STEP_NAME_BY_JOB.items():
            with self.subTest(job=job):
                self.assertIn(f"name: {step}", workflow)

    def budget(self, runs, jobs, *, daily_cap=4, runaway_cap=12) -> str | None:
        client = FakeClient(pull_request(), [review()], runs=runs, jobs=jobs)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            return revise.budget_decline_reason(client, daily_cap, runaway_cap, "7", 1)

    def test_a_crashed_run_releases_its_claim(self) -> None:
        crashed = [workflow_run(run_id) for run_id in range(100, 110)]
        jobs = {run_id: [revise_job(conclusion="failure")] for run_id in range(100, 110)}
        self.assertIsNone(self.budget(crashed, jobs))

    def test_an_in_flight_run_holds_a_provisional_claim(self) -> None:
        # A burst of concurrent triggers must not all be admitted before any
        # of them resolve, since none would yet show as a posted revision.
        in_flight = [
            workflow_run(run_id, status="in_progress") for run_id in range(100, 105)
        ]
        reason = self.budget(in_flight, {})
        assert reason is not None
        self.assertIn("daily revision cap", reason)

    def test_a_posted_turn_holds_its_claim_permanently(self) -> None:
        posted = [workflow_run(run_id) for run_id in range(100, 104)]
        jobs = {run_id: [revise_job()] for run_id in range(100, 104)}
        reason = self.budget(posted, jobs)
        assert reason is not None
        self.assertIn("daily revision cap of 4", reason)

    def test_the_default_cap_is_four(self) -> None:
        self.assertEqual(revise.parse_daily_cap(None), 4)
        self.assertEqual(revise.parse_daily_cap("6"), 6)
        for bad in ("0", "-1", "many"):
            with self.subTest(value=bad):
                with self.assertRaises(revise.FactoryReviseError):
                    revise.parse_daily_cap(bad)
        self.assertEqual(revise.parse_runaway_cap(None, 4), 12)


class PreflightTests(QuietTest):
    def run_preflight(self, client: FakeClient, expected_head: str = "aaaa1111") -> bool:
        with mock.patch.object(revise, "write_output", lambda name, value: None):
            return revise.preflight(client, 1377, 900, expected_head, OWNER)

    def test_an_unchanged_head_with_a_standing_review_still_matches(self) -> None:
        self.assertTrue(self.run_preflight(FakeClient(pull_request(), [review()])))

    def test_a_head_that_moved_after_admission_declines(self) -> None:
        self.assertFalse(
            self.run_preflight(FakeClient(pull_request(), [review()]), "bbbb2222")
        )

    def test_a_review_that_stopped_standing_declines(self) -> None:
        self.assertFalse(
            self.run_preflight(FakeClient(pull_request(), [review(state="APPROVED")]))
        )


class ResolveTests(QuietTest):
    def resolve(
        self,
        client: FakeClient,
        *,
        revise_result: str = "success",
        revision_outcome: str = "pushed",
        comment_posted: str = "true",
        head_after: str = "bbbb2222",
        reason: str = "",
        review_id: int | None = 900,
    ) -> dict[str, str]:
        outputs: dict[str, str] = {}
        with mock.patch.object(
            revise, "write_output", lambda name, value: outputs.__setitem__(name, value)
        ):
            revise.resolve(
                client,
                client,
                1377,
                review_id,
                OWNER,
                head_after=head_after,
                revise_result=revise_result,
                revision_outcome=revision_outcome,
                comment_posted=comment_posted,
                reason=reason,
                run_url=RUN_URL,
                default_branch="main",
            )
        return outputs

    def pushed_pr(self) -> dict[str, object]:
        return pull_request(head_sha="bbbb2222")

    def test_a_validated_push_is_attested(self) -> None:
        # The marker is resolve's attestation, written only after the live
        # head confirms the push -- whether or not April's reply landed.
        client = FakeClient(self.pushed_pr(), [review()])
        outputs = self.resolve(client, comment_posted="false")
        self.assertEqual(len(client.posted), 1)
        self.assertTrue(response.has_revision_for_review(client._comments, 900))
        self.assertEqual(outputs["revision_attested"], "true")
        self.assertEqual(outputs["escalated"], "false")
        self.assertEqual(client.dispatched, [])

    def test_attestation_is_idempotent(self) -> None:
        client = FakeClient(self.pushed_pr(), [review()], [revision_comment(900)])
        outputs = self.resolve(client)
        self.assertEqual(client.posted, [])
        self.assertEqual(outputs["revision_attested"], "false")
        self.assertEqual(outputs["escalated"], "false")

    def test_the_attestation_carries_no_model_text(self) -> None:
        client = FakeClient(self.pushed_pr(), [review()])
        self.resolve(client)
        attestation = client.posted[0]
        self.assertIn(response.revision_marker(900), attestation)
        # Every word is the lane's own; the last visible line is the marker.
        self.assertEqual(
            [line for line in attestation.splitlines() if line.strip()][-1],
            response.revision_marker(900),
        )

    def _readiness(self, ok: bool) -> mock._patch:
        verdict = mock.Mock()
        verdict.ok = ok
        return mock.patch.object(
            revise.factory_review.pr_readiness,
            "evaluate",
            return_value=verdict,
        )

    def test_a_ready_body_only_turn_is_attested_and_re_reviewed(self) -> None:
        # No commit moved, so `synchronize` never fires and the standing
        # rejection has nothing to clear it (#1379).
        client = FakeClient(pull_request(), [review()])
        with self._readiness(ok=True):
            outputs = self.resolve(client, revision_outcome="body-only")
        self.assertEqual(
            client.dispatched, [("factory-review.yml", "main", {"pr_number": "1377"})]
        )
        self.assertTrue(response.has_revision_for_review(client._comments, 900))
        self.assertEqual(outputs["review_dispatched"], "true")
        self.assertEqual(outputs["escalated"], "false")

    def test_a_body_only_turn_that_fails_readiness_escalates_unattested(self) -> None:
        # The dispatch it would send is one the review lane declines exactly
        # when readiness fails -- attesting there would leave a marked park:
        # marker up, refresh never comes, response lane skips forever.
        client = FakeClient(pull_request(), [review()])
        with self._readiness(ok=False):
            outputs = self.resolve(client, revision_outcome="body-only")
        self.assertEqual(client.dispatched, [])
        self.assertFalse(response.has_revision_for_review(client._comments, 900))
        self.assertEqual(outputs["escalated"], "true")
        self.assertIn("readiness gate", client.posted[0])

    def test_a_body_only_turn_whose_review_stopped_standing_is_quiet(self) -> None:
        client = FakeClient(pull_request(), [review(state="DISMISSED")])
        with self._readiness(ok=True):
            outputs = self.resolve(client, revision_outcome="body-only")
        self.assertEqual(client.posted, [])
        self.assertEqual(client.dispatched, [])
        self.assertEqual(outputs["escalated"], "false")

    def test_a_failed_dispatch_escalates(self) -> None:
        client = FakeClient(pull_request(), [review()])
        client.dispatch_failure = True
        with self._readiness(ok=True):
            outputs = self.resolve(client, revision_outcome="body-only")
        self.assertEqual(outputs["review_dispatched"], "false")
        self.assertEqual(outputs["escalated"], "true")

    def test_a_push_the_branch_does_not_carry_escalates(self) -> None:
        # The attestation binds to the exact head the turn exported: a
        # force-push back to the admitted head, or on past it, both fail the
        # equality. Writing the marker anyway would tell the reviewer a
        # revision exists to look at, which is the one claim this lane must
        # never get wrong.
        client = FakeClient(pull_request(head_sha="aaaa1111"), [review()])
        outputs = self.resolve(client, comment_posted="false")
        self.assertEqual(outputs["escalated"], "true")
        self.assertFalse(response.has_revision_for_review(client._comments, 900))
        self.assertIn("does not carry", client.posted[0])

    def test_a_push_with_no_exported_head_escalates(self) -> None:
        client = FakeClient(self.pushed_pr(), [review()])
        outputs = self.resolve(client, head_after="")
        self.assertEqual(outputs["escalated"], "true")
        self.assertFalse(response.has_revision_for_review(client._comments, 900))
        self.assertIn("exported no head", client.posted[0])

    def test_an_attested_owner_rejection_marks_waiting_on_the_owner(self) -> None:
        # A counterpart bot re-reviews automatically; the owner does not.
        client = FakeClient(self.pushed_pr(), [review(login=OWNER)])
        outputs = self.resolve(client)
        self.assertEqual(outputs["revision_attested"], "true")
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])

    def test_an_attested_bot_rejection_adds_no_label(self) -> None:
        client = FakeClient(self.pushed_pr(), [review()])
        self.resolve(client)
        self.assertEqual(client.added, [])

    def test_missing_id_derivation_prefers_the_unanswered_review(self) -> None:
        # Newest-standing alone would dedupe against the answered rejection
        # and leave the unanswered one silent.
        answered = review(review_id=950, login=OWNER, submitted_at="2026-08-28T00:00:00Z")
        unanswered = review(review_id=900, submitted_at="2026-08-27T00:00:00Z")
        client = FakeClient(
            pull_request(),
            [unanswered, answered],
            [april_comment(f"asked\n\n{response.response_marker(950)}")],
        )
        outputs = self.resolve(
            client, review_id=None, revise_result="failure", revision_outcome=""
        )
        self.assertEqual(outputs["escalated"], "true")
        self.assertTrue(response.has_response_for_review(client._comments, 900))

    def test_needs_owner_always_gets_the_deterministic_escalation(self) -> None:
        # April's reasoning comment carries no machinery, so the escalation
        # marker and the label are always this step's to write.
        client = FakeClient(
            pull_request(),
            [review()],
            [april_comment("this needs you — my reasoning above")],
        )
        outputs = self.resolve(client, revision_outcome="needs-owner")
        self.assertEqual(len(client.posted), 1)
        self.assertIn("her comment above", client.posted[0].casefold())
        self.assertTrue(response.has_response_for_review(client._comments, 900))
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])
        self.assertEqual(outputs["escalated"], "true")

    def test_needs_owner_with_a_lost_comment_still_says_why(self) -> None:
        # Her reason is gone; the verdict is not. A label with nothing
        # explaining it is the stranded-looking PR #1381 closed.
        client = FakeClient(pull_request(), [review()])
        outputs = self.resolve(
            client, revision_outcome="needs-owner", comment_posted="false"
        )
        self.assertEqual(len(client.posted), 1)
        self.assertIn("could not be posted", client.posted[0])
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])
        self.assertEqual(outputs["escalated"], "true")

    def test_a_missing_review_id_resolves_the_standing_review(self) -> None:
        # An admission crash on the manual-dispatch path names no review; the
        # standing rejection is the one the dispatch was about.
        client = FakeClient(pull_request(), [review()])
        outputs = self.resolve(
            client, review_id=None, revise_result="failure", revision_outcome=""
        )
        self.assertEqual(outputs["escalated"], "true")
        self.assertTrue(response.has_response_for_review(client._comments, 900))

    def test_a_missing_review_id_with_nothing_standing_is_quiet(self) -> None:
        client = FakeClient(pull_request(), [review(state="APPROVED")])
        outputs = self.resolve(
            client, review_id=None, revise_result="failure", revision_outcome=""
        )
        self.assertEqual(client.posted, [])
        self.assertEqual(outputs["escalated"], "false")

    def test_a_failed_turn_escalates_and_names_the_run(self) -> None:
        client = FakeClient(pull_request(), [review()])
        outputs = self.resolve(client, revise_result="failure", revision_outcome="")
        self.assertEqual(outputs["escalated"], "true")
        self.assertEqual(len(client.posted), 1)
        posted = client.posted[0]
        self.assertIn(f"This needs @{OWNER}", posted)
        self.assertIn(RUN_URL, posted)
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])
        self.assertTrue(
            response.has_response_for_review(client._comments, 900),
            "the escalation must still end with its own marker",
        )

    def test_a_preflight_decline_says_the_head_moved_rather_than_crashed(self) -> None:
        # The job concludes success with no outcome when re-validation
        # declined; saying "the turn ended success" would read as a bug.
        client = FakeClient(pull_request(), [review()])
        self.resolve(client, revise_result="success", revision_outcome="")
        self.assertIn("head moved after admission", client.posted[0])

    def test_a_declined_admission_escalates_with_its_own_reason(self) -> None:
        client = FakeClient(pull_request(), [review()])
        self.resolve(
            client,
            revise_result="skipped",
            revision_outcome="",
            reason="the daily revision cap of 4 is exceeded",
        )
        self.assertIn("daily revision cap of 4", client.posted[0])

    def test_a_failed_turn_does_not_double_post_over_a_standing_escalation(self) -> None:
        client = FakeClient(
            pull_request(),
            [review()],
            [april_comment(f"already asked\n\n{response.response_marker(900)}")],
        )
        outputs = self.resolve(client, revise_result="failure", revision_outcome="")
        self.assertEqual(client.posted, [])
        self.assertEqual(outputs["escalated"], "false")
        # Still level-triggered: the marker is repaired even with nothing new
        # to say.
        self.assertEqual(client.added, [response.OWNER_ACTION_LABEL])

    def test_a_failed_turn_stays_quiet_when_the_review_stopped_standing(self) -> None:
        # The owner pushed the fix, or the reviewer approved, while the turn
        # was running. Nobody is waiting; an escalation would be wrong.
        client = FakeClient(pull_request(), [review(state="APPROVED")])
        outputs = self.resolve(client, revise_result="failure", revision_outcome="")
        self.assertEqual(client.posted, [])
        self.assertEqual(client.added, [])
        self.assertEqual(outputs["escalated"], "false")

    def test_a_failed_turn_stays_quiet_when_the_revision_actually_landed(self) -> None:
        # The reply and its marker are on the PR; a later job (telemetry,
        # evidence) failing does not unmake the revision.
        client = FakeClient(pull_request(), [review()], [revision_comment(900)])
        outputs = self.resolve(client, revise_result="failure", revision_outcome="")
        self.assertEqual(client.posted, [])
        self.assertEqual(outputs["escalated"], "false")


class WorkflowContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.jobs = parse_jobs(self.workflow)
        self.gate = self.workflow.split("runs-on:", 1)[0]

    def test_every_entry_path_is_gated_by_both_kill_switches(self) -> None:
        # M3 norm: a lane that spends a model turn and writes to a branch does
        # not get a dispatch bypass, unlike Review and Monitor.
        self.assertEqual(self.gate.count("vars.AGENT_AUTOMATIONS_ENABLED == 'true'"), 2)
        self.assertEqual(self.gate.count("vars.FACTORY_REVISE_ENABLED == 'true'"), 2)

    def test_manual_dispatch_is_owner_only(self) -> None:
        self.assertIn("github.actor == github.repository_owner", self.gate)
        self.assertIn("github.triggering_actor == github.repository_owner", self.gate)

    def test_a_third_party_rerun_cannot_replay_a_trusted_review(self) -> None:
        self.assertIn("github.triggering_actor == github.actor", self.gate)

    def test_only_same_repository_heads_reach_the_credentialed_lane(self) -> None:
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            self.gate,
        )

    def test_only_april_authored_pull_requests_spin_a_runner(self) -> None:
        self.assertIn(
            f"github.event.pull_request.user.login == '{APRIL}'", self.gate
        )

    def test_only_a_changes_requested_review_from_a_trusted_reviewer_admits(self) -> None:
        self.assertIn("github.event.review.state == 'changes_requested'", self.gate)
        self.assertIn("types: [submitted]", self.workflow)
        self.assertIn("github.event.review.user.login == github.repository_owner", self.gate)
        for bot in sorted(response.factory_review.REVIEWER_BOTS.values()):
            self.assertIn(f"github.event.review.user.login == '{bot}'", self.gate)

    def test_serialized_per_pull_request(self) -> None:
        self.assertIn("group: factory-revise-", self.workflow)
        self.assertIn("cancel-in-progress: false", self.workflow)

    def test_scripts_run_from_the_trusted_default_branch(self) -> None:
        for job in ("admit", "revise", "resolve"):
            with self.subTest(job=job):
                self.assertIn(
                    "ref: ${{ github.event.repository.default_branch }}", self.jobs[job]
                )
        self.assertNotIn("ref: ${{ needs.admit.outputs.head_sha }}", self.workflow)

    def test_only_the_revise_job_can_write_to_a_branch(self) -> None:
        self.assertIn("permission-contents: write", self.jobs["revise"])
        for job in ("admit", "resolve"):
            with self.subTest(job=job):
                self.assertNotIn("permission-contents: write", self.jobs[job])

    def test_the_token_that_labels_a_pull_request_can_write_to_one(self) -> None:
        # For a GitHub App the permission follows the target, and a pull
        # request is not an issue even when the endpoint says /issues/ (#1412).
        self.assertIn("permission-pull-requests: write", self.jobs["resolve"])
        self.assertIn("permission-issues: write", self.jobs["resolve"])
        self.assertNotIn("permission-pull-requests: read", self.workflow)

    def test_only_the_resolve_job_may_dispatch_a_workflow(self) -> None:
        self.assertIn("actions: write", self.jobs["resolve"])
        for job in ("admit", "revise", "telemetry"):
            with self.subTest(job=job):
                self.assertNotIn("actions: write", self.jobs[job])

    def test_the_model_job_stays_read_only_and_telemetry_writes(self) -> None:
        self.assertIn("FACTORY_TELEMETRY_LANE: revise", self.jobs["revise"])
        self.assertIn("factory-revise-telemetry", self.jobs["revise"])
        self.assertIn("contents: write", self.jobs["telemetry"])
        self.assertIn("scripts/factory-cost-append.py", self.jobs["telemetry"])

    def test_the_revision_turn_carries_the_frozen_contract(self) -> None:
        revise_job_text = self.jobs["revise"]
        self.assertIn(
            "@${REPOSITORY_OWNER} requested changes on your PR #${PR_NUMBER}",
            revise_job_text,
        )
        self.assertIn(
            "FACTORY_REVISION_REVIEW_ID: ${{ needs.admit.outputs.review_id }}",
            revise_job_text,
        )
        self.assertIn(
            "FACTORY_EXPECTED_PR_HEAD_SHA: ${{ needs.admit.outputs.head_sha }}",
            revise_job_text,
        )
        self.assertIn('FACTORY_REQUIRE_EXPLICIT_EVIDENCE: "true"', revise_job_text)
        self.assertIn('FACTORY_VISUAL_EVIDENCE_AVAILABLE: "false"', revise_job_text)
        self.assertIn("GH_APP_SLUG: april-clearwater", revise_job_text)
        self.assertIn("secrets.CLAUDE_CODE_OAUTH_TOKEN", revise_job_text)
        self.assertIn("timeout-minutes: 30", revise_job_text)

    def test_resolve_runs_on_an_escalating_decline_and_on_a_crash(self) -> None:
        # The response lane deferred on this same event, so a run that ends
        # without this job is the silent park the arrangement exists to
        # remove -- including when admission itself never finished.
        resolve_job = self.jobs["resolve"]
        self.assertIn("always()", resolve_job)
        self.assertIn("needs.admit.outputs.escalate == 'true'", resolve_job)
        self.assertIn("needs.admit.result == 'failure'", resolve_job)
        # ...which means the review id cannot come only from admission.
        self.assertIn("github.event.review.id", resolve_job)

    def test_the_evidence_lane_is_reused_unchanged(self) -> None:
        self.assertIn("uses: ./.github/workflows/_evidence.yml", self.jobs["evidence"])

    def test_evidence_runs_only_for_a_pushed_outcome(self) -> None:
        # A body-only turn moved no code and a needs-owner turn moved nothing
        # at all; spending a macOS lane on an unchanged head would rewrite
        # evidence for a revision that does not exist.
        self.assertIn(
            "needs.revise.outputs.revision_outcome == 'pushed'",
            self.jobs["evidence"],
        )

    def test_resolve_binds_the_attestation_to_the_exported_head(self) -> None:
        self.assertIn(
            "HEAD_AFTER: ${{ needs.revise.outputs.pr_head_sha }}",
            self.jobs["resolve"],
        )

    def test_manual_dispatch_is_a_recovery_run(self) -> None:
        for job in ("admit", "revise"):
            self.assertIn(
                "FACTORY_REVISE_RECOVERY: "
                "${{ github.event_name == 'workflow_dispatch' }}",
                self.jobs[job],
            )
        self.assertIn("upload_text_evidence: true", self.jobs["evidence"])
        self.assertIn("needs_screenshot_evidence: false", self.jobs["evidence"])
        self.assertIn("secrets.EVIDENCE_UPLOAD_TOKEN", self.jobs["evidence"])

    def test_actions_are_sha_pinned(self) -> None:
        refs = re.findall(r"uses:\s+(?!\./)(\S+)@(\S+)", self.workflow)
        self.assertTrue(refs)
        for action, ref in refs:
            self.assertRegex(ref, r"^[0-9a-f]{40}$", f"{action} is not SHA-pinned")

    def test_the_kill_switch_is_in_the_repo_variable_manifest(self) -> None:
        """The manifest tracks kill switches, and only kill switches.

        Both directions are enforced elsewhere and pull opposite ways: a
        workflow gating on an unlisted `vars.FACTORY_*_ENABLED` fails
        test_factory_workflows.py, and a manifest entry with no live repo
        variable fails `scripts/check-repo-variables.py` in the drift lane.
        A daily cap has a workflow default and is only ever set when someone
        wants to override it, so listing one would red the drift lane for a
        variable that is working as intended -- which is why neither
        `FACTORY_IMPLEMENT_DAILY_CAP` nor `FACTORY_REVIEW_DAILY_CAP` is there.
        """
        manifest = json.loads(REPO_VARIABLES_MANIFEST.read_text(encoding="utf-8"))
        self.assertIn(response.REVISION_LANE_SWITCH, manifest)
        self.assertEqual(
            [name for name in manifest if name.endswith("_DAILY_CAP")],
            [],
            "daily caps are workflow defaults, not manifest-tracked variables",
        )
        self.assertIn(
            "FACTORY_REVISE_DAILY_CAP", WORKFLOW_PATH.read_text(encoding="utf-8")
        )

    def test_the_response_lane_is_told_whether_this_one_is_armed(self) -> None:
        # On the event path only. A manual dispatch of the response lane
        # creates no revise event, so it must read the switch as off and
        # escalate deterministically rather than defer into silence.
        response_workflow = (
            WORKFLOW_PATH.parent / "factory-review-response.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            f"{response.REVISION_LANE_SWITCH}: "
            "${{ github.event_name == 'pull_request_review' && "
            f"vars.{response.REVISION_LANE_SWITCH} || 'false' }}}}",
            response_workflow,
        )


if __name__ == "__main__":
    unittest.main()
