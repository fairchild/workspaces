#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Give April one model turn to answer a blocking review on her own PR (#1125).

Before this lane, a CHANGES_REQUESTED review whose objection was to the diff
itself had exactly one answer: an escalation naming the owner, because the
runtime's `advance_pr` capability was unreachable from the factory's event
loop. This lane is the reachable path. `admit` re-derives from live state
whether the event is one April may answer, `preflight` re-checks it just
before the model runs, and `resolve` guarantees the outcome is visible --
either the revision marker the reviewer can re-review, or an escalation
naming the owner.

The escalation guarantee is what makes deferring safe on the other side:
`factory-review-response.py` posts nothing when this lane takes a review, so
every decline here that follows such a defer carries `escalate=true` and
resolve speaks in its place. A review this lane touches never ends in silence.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import urllib.parse
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CONTRIBUTOR_SCRIPTS = (
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
)
if str(CONTRIBUTOR_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(CONTRIBUTOR_SCRIPTS))

from evidence import extract_requested_evidence  # noqa: E402
from patch_policy import sensitive_agent_patch_paths  # noqa: E402


def _load_sibling(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    # dataclasses' `_is_type` looks the defining module up in sys.modules, so
    # it must be registered before exec_module runs the class body.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The response lane is the module this one extends, not a neighbour it
# resembles: review selection, blocker inventory, marker reading, the
# escalation text, and the owner-action label all come from there. Two
# opinions about which review is standing, or about what the owner has to do,
# would show up as a PR that both lanes think the other one answered.
response = _load_sibling("factory_review_response_for_revise", "factory-review-response.py")
factory_implement = response.factory_implement
factory_review = response.factory_review

REVISE_WORKFLOW = "factory-revise.yml"
REVIEW_WORKFLOW = "factory-review.yml"
# The step whose success means a model turn was actually spent. Read off the
# step, not the job: a job that skipped the turn because preflight declined
# still concludes success, and would otherwise consume a day's budget.
REVISION_STEP_NAME_BY_JOB = {"revise": "Run April revision turn"}
DEFAULT_DAILY_REVISE_CAP = 4
CONTRIBUTOR_BOT = response.RESPONDER_BOT
REVISE_OUTCOMES = ("pushed", "body-only", "needs-owner")


class FactoryReviseError(RuntimeError):
    """Raised when a revision turn cannot be admitted or resolved safely."""


def warn(message: str) -> None:
    """A visible failure notice, not a line buried in a green run's log."""
    print(f"::warning::Factory revise: {message}")
    print(f"Factory revise: {message}", file=sys.stderr)


@dataclass(frozen=True)
class AdmissionDecision:
    """Whether April takes this review, and who speaks if she does not.

    `escalate` is the defer contract: True whenever the response lane would
    have stayed silent on this event, so resolve has to say something.
    """

    action: str
    reason: str
    escalate: bool = False


class GitHubClient(response.GitHubClient):
    def pull_request_files(self, number: int) -> list[dict[str, Any]]:
        files: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = list(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/pulls/{number}/files"
                    f"?per_page=100&page={page}",
                )
            )
            files.extend(dict(item) for item in batch)
            if len(batch) < 100:
                return files
            page += 1

    def workflow_runs_on(self, workflow: str, day: str) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        page = 1
        while True:
            query = urllib.parse.urlencode({"created": day, "per_page": 100, "page": page})
            payload = dict(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/actions/workflows/{workflow}/runs?{query}",
                )
            )
            batch = list(payload.get("workflow_runs") or [])
            runs.extend(dict(run) for run in batch)
            if len(batch) < 100:
                return runs
            page += 1

    def workflow_run_jobs(self, run_id: int) -> list[dict[str, Any]]:
        payload = dict(
            self.request("GET", f"/repos/{self.repository}/actions/runs/{run_id}/jobs")
        )
        return [dict(job) for job in payload.get("jobs") or []]

    def dispatch_workflow(self, workflow: str, ref: str, inputs: dict[str, str]) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/actions/workflows/{workflow}/dispatches",
            {"ref": ref, "inputs": inputs},
        )


def head_repository(pull_request: dict[str, Any]) -> str:
    head = pull_request.get("head") or {}
    repo = head.get("repo") or {} if isinstance(head, dict) else {}
    return str(repo.get("full_name") or "") if isinstance(repo, dict) else ""


def head_sha(pull_request: dict[str, Any]) -> str:
    head = pull_request.get("head") or {}
    return str(head.get("sha") or "") if isinstance(head, dict) else ""


def head_branch(pull_request: dict[str, Any]) -> str:
    head = pull_request.get("head") or {}
    return str(head.get("ref") or "") if isinstance(head, dict) else ""


def review_by_id(reviews: list[dict[str, Any]], review_id: int) -> dict[str, Any] | None:
    return next(
        (
            review
            for review in reviews
            if isinstance(review, dict) and int(review.get("id") or 0) == review_id
        ),
        None,
    )


def revision_was_posted(jobs: list[dict[str, Any]]) -> bool:
    """Whether a run of this lane actually spent a model turn.

    The counterpart of factory-review.py's `review_was_posted`, against this
    lane's job and step names.
    """
    for job in jobs:
        if not isinstance(job, dict):
            continue
        expected_step = REVISION_STEP_NAME_BY_JOB.get(str(job.get("name") or ""))
        if expected_step is None:
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            if (
                str(step.get("name") or "") == expected_step
                and str(step.get("conclusion") or "").casefold() == "success"
            ):
                return True
    return False


def parse_daily_cap(value: str | None) -> int:
    raw = (value or str(DEFAULT_DAILY_REVISE_CAP)).strip()
    try:
        cap = int(raw)
    except ValueError as error:
        raise FactoryReviseError(
            f"FACTORY_REVISE_DAILY_CAP must be a positive integer, got {raw!r}"
        ) from error
    if cap <= 0:
        raise FactoryReviseError("FACTORY_REVISE_DAILY_CAP must be a positive integer")
    return cap


def parse_runaway_cap(value: str | None, daily_cap: int) -> int:
    raw = (value or "").strip()
    if not raw:
        return daily_cap * factory_review.RUNAWAY_CAP_MULTIPLIER
    try:
        cap = int(raw)
    except ValueError as error:
        raise FactoryReviseError(
            f"FACTORY_REVISE_RUNAWAY_CAP must be a positive integer, got {raw!r}"
        ) from error
    if cap <= 0:
        raise FactoryReviseError("FACTORY_REVISE_RUNAWAY_CAP must be a positive integer")
    return cap


def budget_decline_reason(
    client: GitHubClient,
    daily_cap: int,
    runaway_cap: int,
    current_run_id: str,
    current_run_attempt: int,
) -> str | None:
    """Why today's budget refuses another turn, or None when it allows one.

    A reason rather than an exception: cap exhaustion is one of the declines
    the response lane already deferred on, so it has to reach resolve as an
    escalation instead of killing the job.
    """
    day = datetime.now(UTC).date().isoformat()
    runs = client.workflow_runs_on(REVISE_WORKFLOW, day)

    # A crash loop never posts a revision, so the budget below never sees it;
    # this ceiling on raw attempts is what stops it retrying forever (#1179).
    raw_attempts = factory_review.count_daily_run_attempts(
        runs, current_run_id, current_run_attempt
    )
    print(f"Factory revise raw attempt count: {raw_attempts}/{runaway_cap}")
    if raw_attempts > runaway_cap:
        return (
            f"the daily runaway guard of {runaway_cap} run attempts is exceeded "
            f"({raw_attempts} attempts today) -- possible crash loop"
        )

    # Not filtered by the run's overall conclusion: a sibling job (telemetry,
    # evidence) failing must not erase a revision the model actually made.
    posted_by_run = {
        str(run["id"]): revision_was_posted(client.workflow_run_jobs(run["id"]))
        for run in runs
        if isinstance(run, dict) and run.get("id") is not None
    }
    budget = factory_review.count_daily_review_budget(runs, posted_by_run, current_run_id)
    print(f"Factory revise execution budget: {budget}/{daily_cap}")
    if budget > daily_cap:
        return (
            f"the daily revision cap of {daily_cap} is exceeded ({budget} posted or "
            "in-flight turns today)"
        )
    return None


def linked_issue_evidence_contract(
    client: GitHubClient, linked_issue: int
) -> list[str]:
    return extract_requested_evidence(str(client.issue(linked_issue).get("body") or ""))


def evaluate_admission(
    pull_request: dict[str, Any],
    response_decision: response.ResponseDecision,
    *,
    repository: str,
    sensitive_paths: list[str],
    linked_issue: int | None,
    evidence_contract: bool,
    budget_reason: str | None,
) -> AdmissionDecision:
    """Whether this event earns a revision turn, from live state only.

    The order is the defer boundary. Everything above `response_decision` is
    scope the response lane never deferred on -- it skipped, or the lane's own
    `if:` refused the event -- so declining there is silence nobody is waiting
    on. Everything below it ran only because the response lane deferred, so
    those declines escalate.
    """
    author = str((pull_request.get("user") or {}).get("login") or "")
    if author.casefold() != CONTRIBUTOR_BOT.casefold():
        return AdmissionDecision(
            "decline", f"pull request is authored by {author or 'nobody'}, not April"
        )
    if head_repository(pull_request) != repository:
        return AdmissionDecision("decline", "pull request head is not on this repository")
    if not head_branch(pull_request) or not head_sha(pull_request):
        return AdmissionDecision("decline", "pull request has no head branch or SHA")
    if response_decision.action == "skip":
        return AdmissionDecision("decline", response_decision.reason)
    if response_decision.action == "respond":
        # The response lane speaks for itself on every respond outcome, the
        # attempt ceiling included: it never deferred that state, and the two
        # lanes racing marker-dedupe from different concurrency groups would
        # let both posts through. One writer per state.
        return AdmissionDecision(
            "decline",
            f"the response lane escalates this review ({response_decision.reason})",
        )
    if linked_issue is None:
        return AdmissionDecision(
            "decline",
            "the PR body has no closing reference, so there is no issue contract to "
            "revise against",
            escalate=True,
        )
    if not evidence_contract:
        return AdmissionDecision(
            "decline",
            f"issue #{linked_issue} has no `## Requested Evidence` contract, and the "
            "contributor runtime refuses to execute without one",
            escalate=True,
        )
    if sensitive_paths:
        # Unconditional -- the `privileged-agent-patch` label sanctions a diff
        # existing, not this lane re-running the branch's own validator and
        # prompt files with a branch-writing token. Declining every
        # sensitive-path diff is what makes the admitted branch's `.agents/`
        # and `.github/` content provably main's (or the owner's): an
        # unprivileged April patch cannot touch them at creation, and a
        # privileged one never reaches this lane.
        listed = ", ".join(f"`{response._quotable(path)}`" for path in sensitive_paths[:5])
        return AdmissionDecision(
            "decline",
            f"the diff touches privileged paths ({listed}); that revision turn "
            "is the owner's, whatever labels the PR carries",
            escalate=True,
        )
    if budget_reason is not None:
        return AdmissionDecision("decline", budget_reason, escalate=True)
    return AdmissionDecision("revise", "April may answer this review with a revision")


def revision_blocked_blocker(reason: str, run_url: str) -> response.Blocker:
    """The owner ask for a turn the lane took and did not land."""
    return response.Blocker(
        key="revision-turn-incomplete",
        owner_required=True,
        detail=(
            "**April's revision turn did not land.** The revision lane took this "
            f"review and stopped: {reason}. The change to the diff is still unmade. "
            f"Run: {run_url}. Gesture: push the revision, or clear what that reason "
            "names and re-run `Factory Revise` for this PR — a manual dispatch is "
            "a recovery run and may retake an already-escalated review."
        ),
    )


def needs_owner_blocker(comment_posted: bool, run_url: str) -> response.Blocker:
    """The owner ask when April herself concluded the review is theirs."""
    where = (
        "Her reasoning is in her comment above."
        if comment_posted
        else f"Her comment could not be posted; the run log carries it: {run_url}."
    )
    return response.Blocker(
        key="revision-needs-owner",
        owner_required=True,
        detail=(
            "**April read the review and determined it needs you.** "
            f"{where} The revision lane stops here by her own call."
        ),
    )


def revision_attestation_comment(review: dict[str, Any] | None, review_id: int) -> str:
    """The lane's attestation that a validated revision answered this review.

    Deterministic and deliberately thin -- every word is the lane's own, so no
    model prose can forge or fence-hide the marker, and it is only ever posted
    after resolve has verified the outcome it attests to (a push the head
    carries, or a body fix the readiness gate accepts).
    """
    url = str((review or {}).get("html_url") or "").strip()
    reference = f"[requested changes]({url})" if url else "requested changes"
    lines = [
        response.APRIL_ATTRIBUTION.rstrip("\n"),
        "",
        f"Revision turn complete for {response.reviewer_name(review or {})}'s "
        f"{reference} — the diff and the PR body are the answer; April's own "
        "reply above has the detail when one landed.",
        "",
        response.revision_marker(review_id),
    ]
    return "\n".join(lines) + "\n"


def attest_revision(
    client: GitHubClient,
    pr_number: int,
    review_id: int,
) -> bool:
    """Post the marker for a validated turn, unless one is already there."""
    comments = client.comments(pr_number)
    if response.has_revision_for_review(comments, review_id):
        return False
    review = review_by_id(client.pull_request_reviews(pr_number), review_id)
    client.comment(pr_number, revision_attestation_comment(review, review_id))
    print(f"Factory revise attested the revision on #{pr_number} for review {review_id}")
    return True


def request_fresh_review(
    actions_client: GitHubClient,
    pr_number: int,
    default_branch: str,
) -> bool:
    """Ask the review lane to look again after a body-only revision.

    A body-only turn moves no commit, so `synchronize` never fires and the
    standing rejection has nothing to clear it (#1379, the same shape the
    Evidence Verify lane hit). Dispatching is a request, not a grant:
    factory-review.py re-derives from live PR state whether the rejection is
    actually refreshable.
    """
    try:
        actions_client.dispatch_workflow(
            REVIEW_WORKFLOW, default_branch, {"pr_number": str(pr_number)}
        )
    except factory_implement.FactoryImplementError as error:
        warn(f"could not request a fresh counterpart review for #{pr_number}: {error}")
        return False
    print(f"Factory revise requested a fresh counterpart review for #{pr_number}")
    return True


def force_escalate(
    client: GitHubClient,
    pr_number: int,
    review_id: int,
    repository_owner: str,
    *,
    reason: str,
    run_url: str,
    blocker: response.Blocker | None = None,
) -> bool:
    """Say what the failed turn could not. True when a comment was posted.

    Re-derived from live state rather than from what the caller believed:
    between the turn starting and this running, the reviewer may have
    approved, the owner may have pushed the fix, or the response lane may
    have escalated already. Silence is correct in exactly those cases and
    nowhere else.
    """
    pull_request = client.pull_request(pr_number)
    reviews = client.pull_request_reviews(pr_number)
    comments = client.comments(pr_number)
    review = response.blocking_review(reviews, repository_owner, review_id)
    already_responded = review is not None and response.has_response_for_review(
        comments, int(review.get("id") or 0)
    )
    decision = response.evaluate_response(
        pull_request,
        review,
        repository_owner=repository_owner,
        already_responded=already_responded,
        revise_enabled=True,
        revision_in_flight=(
            review is not None
            and response.has_revision_for_review(comments, int(review.get("id") or 0))
        ),
        revision_attempts=response.count_revision_attempts(comments),
    )
    labels = factory_implement.label_names(pull_request)
    if decision.action not in {"respond", "defer"}:
        # Still level-triggered: an escalation already standing for this
        # review keeps its marker, even though this run adds nothing.
        if review is not None and already_responded:
            response.apply_owner_action(client, pr_number, labels)
        print(
            f"Factory revise escalation for #{pr_number} review {review_id}: "
            f"not needed ({decision.reason})"
        )
        return False
    assert review is not None
    escalation = response.ResponseDecision(
        "respond",
        "the revision turn did not land",
        decision.blockers + (blocker or revision_blocked_blocker(reason, run_url),),
    )
    labelled = response.apply_owner_action(client, pr_number, labels)
    client.comment(
        pr_number,
        response.response_comment(
            escalation, review, repository_owner=repository_owner, labelled=labelled
        ),
    )
    print(
        f"Factory revise escalated #{pr_number} for review {review_id}: {reason}"
    )
    return True


def admit(
    client: GitHubClient,
    actions_client: GitHubClient,
    pr_number: int,
    review_id: int | None,
    repository_owner: str,
    *,
    daily_cap: int,
    runaway_cap: int,
    current_run_id: str,
    current_run_attempt: int,
    recovery: bool = False,
) -> AdmissionDecision:
    pull_request = client.pull_request(pr_number)
    reviews = client.pull_request_reviews(pr_number)
    comments = client.comments(pr_number)
    review = response.blocking_review(reviews, repository_owner, review_id)
    resolved_review_id = int(review.get("id") or 0) if review is not None else review_id
    response_decision = response.evaluate_response(
        pull_request,
        review,
        repository_owner=repository_owner,
        # A recovery dispatch exists to retake a review this lane already
        # escalated -- the escalation told the owner to clear the cause and
        # re-run, so the standing response marker must not refuse the rerun.
        already_responded=(
            not recovery
            and review is not None
            and response.has_response_for_review(comments, int(review.get("id") or 0))
        ),
        revise_enabled=True,
        revision_in_flight=(
            review is not None
            and response.has_revision_for_review(comments, int(review.get("id") or 0))
        ),
        revision_attempts=response.count_revision_attempts(comments),
    )
    linked_issue = factory_review.linked_issue_number(pull_request)
    # The reads below cost an API call each, so they only happen once the
    # cheap state has already agreed this event is a candidate. The sensitive
    # check runs regardless of `privileged-agent-patch` -- see
    # evaluate_admission for why the label earns no exemption here.
    sensitive_paths: list[str] = []
    evidence_contract = False
    budget_reason: str | None = None
    if response_decision.action == "defer":
        changed = client.pull_request_files(pr_number)
        sensitive_paths = sensitive_agent_patch_paths(
            [str(item.get("filename") or "") for item in changed]
        )
        if linked_issue is not None:
            evidence_contract = bool(
                linked_issue_evidence_contract(client, linked_issue)
            )
        budget_reason = budget_decline_reason(
            actions_client, daily_cap, runaway_cap, current_run_id, current_run_attempt
        )
    decision = evaluate_admission(
        pull_request,
        response_decision,
        repository=client.repository,
        sensitive_paths=sensitive_paths,
        linked_issue=linked_issue,
        evidence_contract=evidence_contract,
        budget_reason=budget_reason,
    )
    print(
        f"Factory revise admission for #{pr_number}: {decision.action} "
        f"({decision.reason}); escalate={decision.escalate}"
    )
    write_output("matched", "true" if decision.action == "revise" else "false")
    write_output("escalate", "true" if decision.escalate else "false")
    write_output("decline_reason", decision.reason if decision.action != "revise" else "")
    write_output("pr_number", str(pr_number))
    write_output("review_id", str(resolved_review_id or ""))
    write_output("head_sha", head_sha(pull_request))
    write_output("pr_branch", head_branch(pull_request))
    write_output("linked_issue", str(linked_issue or ""))
    return decision


def preflight(
    client: GitHubClient,
    pr_number: int,
    review_id: int,
    expected_head: str,
    repository_owner: str,
    *,
    recovery: bool = False,
) -> bool:
    """Re-verify the admitted conditions with the model one step away.

    Admission ran on a runner with no credentials and no branch; between then
    and now the head can move, the reviewer can approve, and the response lane
    can escalate. Re-deriving here is what keeps a turn from being spent on a
    review that stopped needing one.
    """
    pull_request = client.pull_request(pr_number)
    reviews = client.pull_request_reviews(pr_number)
    comments = client.comments(pr_number)
    review = response.blocking_review(reviews, repository_owner, review_id)
    response_decision = response.evaluate_response(
        pull_request,
        review,
        repository_owner=repository_owner,
        already_responded=(
            not recovery
            and review is not None
            and response.has_response_for_review(comments, review_id)
        ),
        revise_enabled=True,
        revision_in_flight=response.has_revision_for_review(comments, review_id),
        revision_attempts=response.count_revision_attempts(comments),
    )
    decision = evaluate_admission(
        pull_request,
        response_decision,
        repository=client.repository,
        sensitive_paths=[],
        linked_issue=factory_review.linked_issue_number(pull_request),
        evidence_contract=True,
        budget_reason=None,
    )
    live_head = head_sha(pull_request)
    if decision.action == "revise" and expected_head and expected_head != live_head:
        decision = AdmissionDecision(
            "decline", "pull request head changed after admission"
        )
    print(
        f"Factory revise preflight for #{pr_number}: {decision.action} ({decision.reason})"
    )
    write_output("matched", "true" if decision.action == "revise" else "false")
    write_output("head_sha", live_head)
    return decision.action == "revise"


def resolve(
    client: GitHubClient,
    actions_client: GitHubClient,
    pr_number: int,
    review_id: int | None,
    repository_owner: str,
    *,
    head_before: str,
    revise_result: str,
    revision_outcome: str,
    comment_posted: str,
    reason: str,
    run_url: str,
    default_branch: str,
) -> None:
    """Make the turn's outcome visible, whatever the outcome was.

    Every marker this lane writes is written here, after the outcome it
    attests to is validated against live state -- a push the head actually
    carries, or a body fix the readiness gate accepts. The runtime's own
    comments carry no markers at all, so nothing the model wrote can stand in
    for an attestation.
    """
    if review_id is None:
        # Admission crashed before resolving one (the manual-dispatch path has
        # no review in its event). The standing rejection is the review the
        # dispatch was about; none standing means nobody is waiting.
        standing = response.blocking_review(
            client.pull_request_reviews(pr_number), repository_owner, None
        )
        if standing is None:
            print(
                f"Factory revise resolve for #{pr_number}: no standing blocking "
                "review; nothing to resolve"
            )
            write_output("escalated", "false")
            return
        review_id = int(standing.get("id") or 0)
    outcome = revision_outcome.strip()
    succeeded = revise_result.strip().casefold() == "success" and outcome in REVISE_OUTCOMES
    attested = False
    dispatched = False
    escalated = False
    if succeeded and outcome == "pushed":
        live_head = head_sha(client.pull_request(pr_number))
        if head_before and live_head == head_before:
            # The turn reported a push the branch does not carry. Attesting
            # anyway would tell the reviewer a revision exists to look at,
            # which is the one claim this lane must never get wrong.
            succeeded = False
            reason = "the turn reported a push the branch head does not carry"
        else:
            attested = attest_revision(client, pr_number, review_id)
    elif succeeded and outcome == "body-only":
        # A body-only turn re-enters review through a dispatch the review lane
        # is free to decline -- and it declines exactly when readiness still
        # fails. Attesting and dispatching in that state would leave a marked
        # park: the marker says "answered", the refresh never comes, and the
        # response lane skips forever. So the readiness gate is checked here,
        # with the review lane's own evaluator, before the marker exists.
        pull_request = client.pull_request(pr_number)
        standing = response.blocking_review(
            client.pull_request_reviews(pr_number), repository_owner, review_id
        )
        if standing is None:
            print(
                f"Factory revise resolve for #{pr_number}: review {review_id} no "
                "longer stands; the state resolved itself"
            )
        else:
            paths = [
                str(item.get("filename") or "")
                for item in client.pull_request_files(pr_number)
            ]
            if factory_review.pr_readiness.evaluate(pull_request, paths).ok:
                # Dispatch before attesting: the marker attests "answered and
                # re-entering review", and posting it first would trip the
                # in-flight guard on the very escalation a failed dispatch
                # needs to make.
                dispatched = request_fresh_review(
                    actions_client, pr_number, default_branch
                )
                if dispatched:
                    attested = attest_revision(client, pr_number, review_id)
                else:
                    escalated = force_escalate(
                        client,
                        pr_number,
                        review_id,
                        repository_owner,
                        reason=(
                            "the body revision landed but the fresh-review "
                            "request could not be dispatched"
                        ),
                        run_url=run_url,
                    )
            else:
                escalated = force_escalate(
                    client,
                    pr_number,
                    review_id,
                    repository_owner,
                    reason=(
                        "the turn rewrote the PR body but the readiness gate "
                        "still fails, so a fresh review would decline to run"
                    ),
                    run_url=run_url,
                )
    elif succeeded and outcome == "needs-owner":
        # April's call, the lane's voice: her reasoning comment (when it
        # landed) carries no machinery, so the deterministic escalation and
        # the label are always this step's to write.
        escalated = force_escalate(
            client,
            pr_number,
            review_id,
            repository_owner,
            reason="April determined this review needs the owner",
            run_url=run_url,
            blocker=needs_owner_blocker(
                comment_posted.strip().casefold() == "true", run_url
            ),
        )
    if not succeeded:
        # A job that concluded success with no outcome is the preflight
        # declining after admission, which is a different thing to say than a
        # crash -- and the one the owner is most likely to have caused.
        if revise_result.strip().casefold() == "success":
            fallback = (
                "re-validation declined the turn just before the model ran (the "
                "head moved after admission, or the review stopped standing)"
            )
        else:
            fallback = f"the turn ended `{revise_result.strip() or 'unknown'}`"
        escalated = force_escalate(
            client,
            pr_number,
            review_id,
            repository_owner,
            reason=reason.strip() or fallback,
            run_url=run_url,
        )
    write_output("revision_attested", "true" if attested else "false")
    write_output("review_dispatched", "true" if dispatched else "false")
    write_output("escalated", "true" if escalated else "false")


def write_output(name: str, value: str) -> None:
    factory_implement.write_output(name, value)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    admit_parser = subparsers.add_parser("admit")
    admit_parser.add_argument("--pr", type=int, required=True)
    admit_parser.add_argument("--review-id", type=int, default=None)

    preflight_parser = subparsers.add_parser("preflight")
    preflight_parser.add_argument("--pr", type=int, required=True)
    preflight_parser.add_argument("--review-id", type=int, required=True)
    preflight_parser.add_argument("--expected-head", default="")

    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("--pr", type=int, required=True)
    resolve_parser.add_argument(
        "--review-id",
        type=int,
        default=None,
        help="Omit when admission crashed before naming one; resolve derives "
        "the standing blocking review.",
    )
    resolve_parser.add_argument("--head-before", default="")
    resolve_parser.add_argument("--revise-result", default="")
    resolve_parser.add_argument("--revision-outcome", default="")
    resolve_parser.add_argument("--comment-posted", default="")
    resolve_parser.add_argument(
        "--reason",
        default="",
        help="Why the turn did not happen, when admission declined it.",
    )
    return parser.parse_args(argv)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryReviseError(f"{name} is required")
    return value


def require_automation_switches(global_switch: str, stage_switch: str) -> None:
    if global_switch.casefold() != "true" or stage_switch.casefold() != "true":
        raise FactoryReviseError(
            "Factory revise is disabled by AGENT_AUTOMATIONS_ENABLED or "
            "FACTORY_REVISE_ENABLED"
        )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    require_automation_switches(
        os.environ.get("AGENT_AUTOMATIONS_ENABLED", ""),
        os.environ.get(response.REVISION_LANE_SWITCH, ""),
    )
    repository = require_env("GITHUB_REPOSITORY")
    repository_owner = require_env("FACTORY_REPOSITORY_OWNER")
    client = GitHubClient(repository, require_env("GH_TOKEN"))
    recovery = os.environ.get("FACTORY_REVISE_RECOVERY", "").casefold() == "true"
    if args.command == "admit":
        daily_cap = parse_daily_cap(os.environ.get("FACTORY_REVISE_DAILY_CAP"))
        admit(
            client,
            GitHubClient(repository, require_env("FACTORY_ACTIONS_TOKEN")),
            args.pr,
            args.review_id,
            repository_owner,
            daily_cap=daily_cap,
            runaway_cap=parse_runaway_cap(
                os.environ.get("FACTORY_REVISE_RUNAWAY_CAP"), daily_cap
            ),
            current_run_id=require_env("GITHUB_RUN_ID"),
            current_run_attempt=int(require_env("GITHUB_RUN_ATTEMPT")),
            recovery=recovery,
        )
    elif args.command == "preflight":
        preflight(
            client,
            args.pr,
            args.review_id,
            args.expected_head,
            repository_owner,
            recovery=recovery,
        )
    elif args.command == "resolve":
        resolve(
            client,
            GitHubClient(repository, require_env("FACTORY_ACTIONS_TOKEN")),
            args.pr,
            args.review_id,
            repository_owner,
            head_before=args.head_before,
            revise_result=args.revise_result,
            revision_outcome=args.revision_outcome,
            comment_posted=args.comment_posted,
            reason=args.reason,
            run_url=require_env("RUN_URL"),
            default_branch=os.environ.get("FACTORY_DEFAULT_BRANCH", "main").strip()
            or "main",
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except FactoryReviseError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
