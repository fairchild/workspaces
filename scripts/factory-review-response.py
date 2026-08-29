#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Give the factory a response turn when a counterpart review requests changes.

Owner involvement is soft breakage (#1378): before this lane, a
CHANGES_REQUESTED review on a factory-authored PR simply stopped the loop and
the owner became the default advancing party, indistinguishable from a
stranded PR. This lane reads the blocking review, inventories what actually
blocks the PR, and posts exactly one response per review naming what the
owner has to do. Every response is an escalation: the lane cannot read the
review's prose, so it can never prove an objection is fully covered by
something that clears on its own, and claiming otherwise would recreate the
silent park it exists to remove. Blockers it does expect to clear are still
listed, as context under the ask.

Deterministic by construction -- no model, no tools, no untrusted text
reaching an executor. It only reads PR state the factory already writes
(labels, the structured evidence block, review history).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CONTRIBUTOR_SCRIPTS = (
    REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
)
if str(CONTRIBUTOR_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(CONTRIBUTOR_SCRIPTS))

from evidence import _extract_evidence_metadata  # noqa: E402


def _load_sibling(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    # dataclasses' `_is_type` looks the defining module up in sys.modules, so
    # it must be registered before exec_module runs the class body.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Reused rather than duplicated: reviewer routing and the GitHub client are
# security-relevant and must stay single-sourced with the lanes they mirror.
factory_implement = _load_sibling(
    "factory_implement_for_review_response", "factory-implement.py"
)
factory_review = _load_sibling(
    "factory_review_for_review_response", "factory-review.py"
)
# Quote/code handling is the #1364 lesson: a marker inside a blockquote, a
# fence, or an indented block is text a human wrote *about* the factory, not a
# marker the factory wrote. Reuse that reader instead of a substring search.
factory_responder = _load_sibling(
    "factory_responder_for_review_response", "factory-responder-payload.py"
)

APRIL_ATTRIBUTION = "*April Clearwater, Application Lead*\n\n"
RESPONDER_BOT = "april-clearwater[bot]"
RESPONSE_MARKER_PREFIX = "<!-- factory-review-response review-id:"
# The revision lane's own marker (`factory-revise.yml`). This module never
# writes one; it reads them to tell "April is answering that review with a
# diff" apart from "nobody is moving", which are the same picture otherwise.
REVISION_MARKER_PREFIX = "<!-- factory-revision review-id:"
RESPONSE_MARKER_RE = re.compile(
    rf"^{re.escape(RESPONSE_MARKER_PREFIX)}(?P<id>\d+) -->$"
)
REVISION_MARKER_RE = re.compile(
    rf"^{re.escape(REVISION_MARKER_PREFIX)}(?P<id>\d+) -->$"
)
# Revision turns the factory will spend on one pull request before the owner
# is the only party left who can move it. Two: the second turn is where a
# model answers what the first one misread, and a third has nothing new to
# read -- the reviewer's objection has not changed and neither has the code
# the model can see.
REVISION_ATTEMPT_CEILING = 2
REVISION_LANE_SWITCH = "FACTORY_REVISE_ENABLED"
# Evidence item text is PR-controlled. It is quoted back so the escalation
# names the line the owner has to edit, so it is neutralized first: HTML
# comment delimiters would let PR text seed a marker inside April's own
# comment, and an unbounded item would let it dominate the response.
ITEM_QUOTE_LIMIT = 160
CHANGES_REQUESTED = "CHANGES_REQUESTED"
# States that neither block nor replace a reviewer's standing verdict.
NON_SUPERSEDING_REVIEW_STATES = frozenset({"COMMENTED", "PENDING", "DISMISSED"})
BLOCKED_EVIDENCE_LABEL = "blocked:evidence"
NEEDS_HUMAN_LABEL = "needs-human"
# Machine-managed, and the counterpart to `needs-human`: the factory applies
# this when it determines the owner is the blocking party and removes it when
# that stops being true. `needs-human` stays what a person applies to say the
# same thing; the factory never touches that one. A PR waiting on the owner
# used to look exactly like a stranded one -- red, unmoving, CHANGES_REQUESTED
# -- so the state is now written down where a glance and a query can both see
# it (#1381).
OWNER_ACTION_LABEL = "owner-action"
OWNER_ACTION_COLOR = "d93f0b"
OWNER_ACTION_DESCRIPTION = (
    "The factory determined the owner is the blocking party; see its comment "
    "for the gesture"
)
# The contributor revision loop (#1125) is the missing capability behind every
# "the diff itself must change" escalation. Naming it keeps the escalation
# honest about what the factory cannot yet do, rather than implying judgment.
REVISION_LOOP_ISSUE = "#1125"


def warn(message: str) -> None:
    """A visible failure notice, not a line buried in a green run's log."""
    print(f"::warning::Factory review response: {message}")
    print(f"Factory review response: {message}", file=sys.stderr)


class FactoryReviewResponseError(RuntimeError):
    """Raised when a review response cannot be evaluated or posted safely."""


@dataclass(frozen=True)
class Blocker:
    """One thing standing between this PR and merge.

    `owner_required` is the whole verdict: False only when the factory can
    point at the lane that clears this blocker without a human gesture.
    """

    key: str
    owner_required: bool
    detail: str


@dataclass(frozen=True)
class ResponseDecision:
    action: str
    reason: str
    blockers: tuple[Blocker, ...] = ()

    @property
    def owner_required(self) -> bool:
        return any(blocker.owner_required for blocker in self.blockers)


class GitHubClient(factory_implement.GitHubClient):
    def label_exists(self, name: str) -> bool | None:
        """True/False, or None when the answer could not be established.

        A 404 is a real answer; anything else is the lookup failing, and
        treating that as "missing" would turn a transient error into a
        pointless create attempt.
        """
        try:
            self.request("GET", f"/repos/{self.repository}/labels/{name}")
            return True
        except factory_implement.FactoryImplementError as error:
            return False if " 404: " in str(error) else None

    def ensure_label(self, name: str, color: str, description: str) -> bool:
        exists = self.label_exists(name)
        if exists is True:
            return True
        if exists is None:
            return False
        try:
            self.request(
                "POST",
                f"/repos/{self.repository}/labels",
                {"name": name, "color": color, "description": description},
            )
            return True
        except factory_implement.FactoryImplementError as error:
            # Losing a create race is success; the label is there either way.
            # Re-reading rather than assuming keeps a real failure a failure.
            if self.label_exists(name) is True:
                return True
            warn(f"could not create the `{name}` label: {error}")
            return False

    def add_label(self, number: int, name: str) -> None:
        self.request(
            "POST", f"/repos/{self.repository}/issues/{number}/labels", {"labels": [name]}
        )

    def remove_label(self, number: int, name: str) -> None:
        self.request(
            "DELETE", f"/repos/{self.repository}/issues/{number}/labels/{name}"
        )

    def pull_request(self, number: int) -> dict[str, Any]:
        return dict(self.request("GET", f"/repos/{self.repository}/pulls/{number}"))

    def pull_request_reviews(self, number: int) -> list[dict[str, Any]]:
        reviews: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = list(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/pulls/{number}/reviews"
                    f"?per_page=100&page={page}",
                )
            )
            reviews.extend(dict(review) for review in batch)
            if len(batch) < 100:
                return reviews
            page += 1


def require_automation_switches(global_switch: str, stage_switch: str) -> None:
    if global_switch.casefold() != "true" or stage_switch.casefold() != "true":
        raise FactoryReviewResponseError(
            "Factory review response is disabled by AGENT_AUTOMATIONS_ENABLED "
            "or FACTORY_REVIEW_RESPONSE_ENABLED"
        )


def trusted_reviewers(repository_owner: str) -> set[str]:
    """Logins whose CHANGES_REQUESTED earns a factory response turn.

    The counterpart reviewer bots and the owner. A drive-by review from any
    other account is not factory lineage, so it does not spend a response.
    """
    return {bot.casefold() for bot in factory_review.REVIEWER_BOTS.values()} | {
        repository_owner.casefold()
    }


def standing_reviews(
    reviews: list[dict[str, Any]],
    repository_owner: str,
) -> list[dict[str, Any]]:
    """Trusted CHANGES_REQUESTED verdicts that still stand, oldest first.

    A reviewer's later review supersedes their earlier one, so only each
    trusted reviewer's most recent submitted, non-`COMMENTED` review counts --
    answering a verdict the reviewer already replaced would re-park a PR that
    moved on. `PENDING` reviews have not been submitted (GitHub leaves their
    `submitted_at` null) and `DISMISSED` ones no longer block, so neither can
    stand or supersede.
    """
    trusted = trusted_reviewers(repository_owner)
    latest_by_reviewer: dict[str, dict[str, Any]] = {}
    # Sorted by submitted_at rather than read in list order: which verdict is
    # "latest" decides whether it still stands, so it comes from the
    # timestamps, not from pagination.
    records = [review for review in reviews if isinstance(review, dict)]
    for review in sorted(records, key=lambda item: str(item.get("submitted_at") or "")):
        login = str((review.get("user") or {}).get("login") or "").casefold()
        if login not in trusted:
            continue
        state = str(review.get("state") or "").upper()
        if state in NON_SUPERSEDING_REVIEW_STATES:
            continue
        latest_by_reviewer[login] = review
    return [
        review
        for review in latest_by_reviewer.values()
        if str(review.get("state") or "").upper() == CHANGES_REQUESTED
    ]


def blocking_review(
    reviews: list[dict[str, Any]],
    repository_owner: str,
    review_id: int | None,
    *,
    answered: Callable[[int], bool] = lambda _: False,
) -> dict[str, Any] | None:
    """The review this run should answer.

    With an explicit id (the webhook path), only that review qualifies, and
    only while it still stands. Without one (manual recovery), the newest
    review that has no response yet -- not simply the newest -- so a second
    reviewer's standing verdict cannot be permanently shadowed by an
    already-answered newer one.
    """
    standing = sorted(
        standing_reviews(reviews, repository_owner),
        key=lambda item: str(item.get("submitted_at") or ""),
    )
    if review_id is not None:
        return next(
            (review for review in standing if int(review.get("id") or 0) == review_id),
            None,
        )
    unanswered = [
        review for review in standing if not answered(int(review.get("id") or 0))
    ]
    return unanswered[-1] if unanswered else None


RECOGNIZED_REVIEW_STATES = frozenset(
    {CHANGES_REQUESTED, "APPROVED", "COMMENTED", "PENDING", "DISMISSED"}
)


def reviews_are_conclusive(
    reviews: list[dict[str, Any]],
    repository_owner: str,
) -> bool:
    """Whether the review list is complete enough to prove nobody is blocking.

    Absence of a standing rejection is only meaningful if every trusted
    reviewer's record could actually be read. A review with no login, no
    timestamp, or a state this code does not recognise might be the blocking
    one, so an incomplete list means "cannot prove unblocked" rather than
    "unblocked" -- the difference between leaving a marker up one cycle too
    long and telling the owner they are free when they are not.
    """
    trusted = trusted_reviewers(repository_owner)
    for review in reviews:
        if not isinstance(review, dict):
            return False
        login = str((review.get("user") or {}).get("login") or "")
        if not login:
            return False
        if login.casefold() not in trusted:
            continue
        if str(review.get("state") or "").upper() not in RECOGNIZED_REVIEW_STATES:
            return False
        if not str(review.get("submitted_at") or ""):
            # PENDING reviews legitimately have none; anything else is a
            # record this code cannot order, so it cannot be superseded.
            if str(review.get("state") or "").upper() != "PENDING":
                return False
    return True


def evidence_entries(body: str) -> list[dict[str, Any]]:
    metadata = _extract_evidence_metadata(body)
    if not isinstance(metadata, dict):
        return []
    entries = metadata.get("entries")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _quotable(text: str) -> str:
    """PR-controlled text, safe to place inside April's own comment.

    HTML comment delimiters come out first: leaving them in would let a PR
    body seed a response marker inside the very comment the marker is meant
    to identify. Backticks and newlines go too, so a quoted item cannot break
    out of the line it sits on, and the result is bounded.
    """
    flattened = " ".join(
        text.replace("<!--", "").replace("-->", "").replace("`", "").split()
    )
    if len(flattened) <= ITEM_QUOTE_LIMIT:
        return flattened
    return flattened[: ITEM_QUOTE_LIMIT - 1].rstrip() + "…"


def _entry_label(entry: dict[str, Any]) -> str:
    index = entry.get("index")
    item = _quotable(str(entry.get("item") or ""))
    return f"item {index} (\"{item}\")" if item else f"item {index}"


def evidence_blockers(entries: list[dict[str, Any]]) -> list[Blocker]:
    blocked = [
        entry for entry in entries if str(entry.get("status") or "").strip() == "blocked"
    ]
    pending = [
        entry
        for entry in entries
        if str(entry.get("status") or "").strip() == "pending-ci"
    ]
    blockers: list[Blocker] = []
    if blocked:
        listed = "; ".join(_entry_label(entry) for entry in blocked)
        blockers.append(
            Blocker(
                key="evidence-attestation",
                owner_required=True,
                detail=(
                    f"**Owner evidence attestation.** Requested evidence {listed} "
                    "cannot be reconciled mechanically. Gesture: in this PR body's "
                    "`## Evidence Status` list, rewrite each of those lines as "
                    "`- [complete] <item> -- <how you verified it>`, then remove the "
                    f"`{BLOCKED_EVIDENCE_LABEL}` label. The readiness gate and the "
                    "linked issue's state follow from those two edits."
                ),
            )
        )
    if pending:
        listed = "; ".join(_entry_label(entry) for entry in pending)
        blockers.append(
            Blocker(
                key="evidence-pending-ci",
                owner_required=False,
                detail=(
                    f"Requested evidence {listed} completes when the named checks "
                    "finish on this head — `factory-evidence-verify.yml` writes the "
                    f"entry and drops `{BLOCKED_EVIDENCE_LABEL}` on its own."
                ),
            )
        )
    return blockers


def label_blockers(labels: set[str], *, evidence_accounted: bool) -> list[Blocker]:
    blockers: list[Blocker] = []
    if NEEDS_HUMAN_LABEL in labels:
        blockers.append(
            Blocker(
                key="needs-human",
                owner_required=True,
                detail=(
                    f"**`{NEEDS_HUMAN_LABEL}` is applied.** Someone has already marked "
                    "this as needing human intervention; the factory does not clear "
                    "that label."
                ),
            )
        )
    for label in sorted(label for label in labels if label.startswith("blocked:")):
        if label == BLOCKED_EVIDENCE_LABEL and evidence_accounted:
            # Already accounted for entry-by-entry above, where the gesture can
            # name the specific evidence lines rather than the label alone. A
            # label left behind with nothing pending or blocked to explain it is
            # its own blocker -- the readiness gate fails on the label alone.
            continue
        blockers.append(
            Blocker(
                key=f"label:{label}",
                owner_required=True,
                detail=(
                    f"**`{label}` is applied.** The readiness gate fails while any "
                    "`blocked:` label is present. Gesture: resolve what the label "
                    "names, then remove it."
                ),
            )
        )
    return blockers


def revision_lane_covers(pull_request: dict[str, Any]) -> bool:
    """Whether the revision lane's v1 admission scope includes this PR.

    Deferring to a lane that will decline is how a PR gets stranded, so this
    is the one admission condition the response side has to know about. The
    revision lane checks out and pushes the head branch, which it will only do
    for a branch the factory itself wrote -- April's own pull requests.
    """
    author = str((pull_request.get("user") or {}).get("login") or "")
    return author.casefold() == RESPONDER_BOT.casefold()


def revision_required_blocker(reason: str) -> Blocker:
    """The diff has to change and the revision lane is not the one changing it."""
    return Blocker(
        key="revision-required",
        owner_required=True,
        detail=(
            "**A change to the diff was requested.** Nothing the owner can act on "
            "in this PR's machine-readable state (evidence entries, blocking "
            "labels) accounts for the review, so the requested change is to the "
            "code or prose itself. The contributor revision loop "
            f"({REVISION_LOOP_ISSUE}) can take that turn, but {reason}. Gesture: "
            "push the revision, or re-release the linked issue with the review's "
            "feedback folded into it."
        ),
    )


def revision_exhausted_blocker(attempts: int) -> Blocker:
    return Blocker(
        key="revision-attempts-exhausted",
        owner_required=True,
        detail=(
            f"**The revision loop has spent its {REVISION_ATTEMPT_CEILING} turns on "
            f"this PR** ({attempts} reviews answered with a revision) and a reviewer "
            "is still blocking. Another model turn reads the same code against the "
            "same objection, so the loop stops here. Gesture: push the revision, or "
            "re-release the linked issue with the review's feedback folded into it."
        ),
    )


def evaluate_response(
    pull_request: dict[str, Any],
    review: dict[str, Any] | None,
    *,
    repository_owner: str,
    already_responded: bool,
    revise_enabled: bool = False,
    revision_in_flight: bool = False,
    revision_attempts: int = 0,
) -> ResponseDecision:
    if str(pull_request.get("state") or "").casefold() != "open":
        return ResponseDecision("skip", "pull request is not open")
    if bool(pull_request.get("draft")):
        return ResponseDecision("skip", "pull request is a draft")
    if factory_review.author_label(pull_request) is None:
        return ResponseDecision(
            "skip", "pull request does not carry exactly one author label"
        )
    if review is None:
        return ResponseDecision(
            "skip", "no standing changes-requested review from a trusted reviewer"
        )
    if already_responded:
        return ResponseDecision("skip", "this review already has a factory response")

    labels = factory_implement.label_names(pull_request)
    entries = evidence_entries(str(pull_request.get("body") or ""))
    evidence = evidence_blockers(entries)
    blockers = evidence + label_blockers(labels, evidence_accounted=bool(evidence))
    if not any(blocker.owner_required for blocker in blockers):
        # Nothing owner-required explains the objection, so the requested
        # change is to the diff itself. A self-clearing blocker is not proof
        # the review is covered: the lane never reads the review's prose, and
        # a `pending-ci` entry can also sit forever (the named check may not
        # exist, may fail, or the verifier may be off or already past its last
        # check_suite event). Whoever takes the turn from here, somebody does
        # -- a needless ask costs the owner a glance; a false "you are not
        # needed" costs a parked PR, which is the failure this lane exists to
        # remove.
        if not revise_enabled:
            blockers.append(
                revision_required_blocker(f"`{REVISION_LANE_SWITCH}` is off")
            )
        elif not revision_lane_covers(pull_request):
            blockers.append(
                revision_required_blocker(
                    f"it revises only pull requests `{RESPONDER_BOT}` authored"
                )
            )
        elif revision_in_flight:
            return ResponseDecision(
                "skip", "a revision turn already answered this review"
            )
        elif revision_attempts >= REVISION_ATTEMPT_CEILING:
            blockers.append(revision_exhausted_blocker(revision_attempts))
        else:
            # The revision lane runs off this same event and owns the turn
            # from here. Every decline path over there ends in either a
            # revision marker or an owner escalation, so a defer cannot
            # strand the PR -- it moves who answers, not whether anyone does.
            return ResponseDecision(
                "defer", "the revision lane owns this turn", tuple(blockers)
            )
    return ResponseDecision("respond", "review needs a factory response", tuple(blockers))


def response_marker(review_id: int) -> str:
    return f"{RESPONSE_MARKER_PREFIX}{review_id} -->"


def revision_marker(review_id: int) -> str:
    return f"{REVISION_MARKER_PREFIX}{review_id} -->"


def marked_review_id(comment: dict[str, Any], pattern: re.Pattern[str]) -> int | None:
    """The review id in a factory marker on this comment, or None.

    Author-bound and position-bound. A substring search over every comment
    body would let anyone silence the lane by quoting the marker back --
    exactly the false-suppression class #1364 closed for the owner-comment
    responder, whose quote/code reader is reused here. The marker must be the
    last line that renders outside blockquotes, fences, and indented blocks.
    """
    author = str((comment.get("user") or {}).get("login") or "")
    if author.casefold() != RESPONDER_BOT.casefold():
        return None
    visible = factory_responder._unquoted_visible_lines(str(comment.get("body") or ""))
    if not visible:
        return None
    match = pattern.match(visible[-1].strip())
    return int(match.group("id")) if match else None


def is_response_comment(comment: dict[str, Any], review_id: int) -> bool:
    """True only for a response this lane actually posted for `review_id`."""
    return marked_review_id(comment, RESPONSE_MARKER_RE) == review_id


def has_response_for_review(comments: list[dict[str, Any]], review_id: int) -> bool:
    return any(is_response_comment(comment, review_id) for comment in comments)


def has_revision_for_review(comments: list[dict[str, Any]], review_id: int) -> bool:
    """Whether April already answered `review_id` with a revision turn."""
    return any(
        marked_review_id(comment, REVISION_MARKER_RE) == review_id
        for comment in comments
    )


def count_revision_attempts(comments: list[dict[str, Any]]) -> int:
    """How many distinct reviews April has answered with a revision here.

    Distinct review ids, not comments: the revision lane repairs a missing
    marker by posting one itself, and a turn counted twice would spend the
    ceiling on a single answer.
    """
    return len(
        {
            review_id
            for comment in comments
            if (review_id := marked_review_id(comment, REVISION_MARKER_RE)) is not None
        }
    )


def reviewer_name(review: dict[str, Any]) -> str:
    """The reviewer as plain text, never as an `@` mention.

    Mention triage watches comment bodies for agent slugs. It already excludes
    bot senders, so April mentioning a reviewer bot would not dispatch
    anything today -- but writing the slug at all leaves a trigger surface for
    a future gate to widen onto, and the reviewer gains nothing from the ping.
    """
    login = str((review.get("user") or {}).get("login") or "").strip()
    if not login:
        return "the reviewer"
    return login.removesuffix("[bot]")


def response_comment(
    decision: ResponseDecision,
    review: dict[str, Any],
    *,
    repository_owner: str,
    labelled: bool = True,
) -> str:
    review_url = str(review.get("html_url") or "").strip()
    reference = f"[requested changes]({review_url})" if review_url else "requested changes"
    owner_lines = [b.detail for b in decision.blockers if b.owner_required]
    self_clearing = [b.detail for b in decision.blockers if not b.owner_required]

    lines = [APRIL_ATTRIBUTION.rstrip("\n"), ""]
    lines.append(f"Read {reviewer_name(review)}'s {reference}.")
    lines += ["", f"**This needs @{repository_owner}** — the factory cannot clear it:", ""]
    lines += [f"- {line}" for line in owner_lines]
    if self_clearing:
        lines += ["", "Already moving without you, for context:", ""]
        lines += [f"- {line}" for line in self_clearing]
    closing = (
        "Once that lands, ask for a fresh counterpart review (`Factory Review` → run "
        "for this PR number) and the loop picks it back up."
    )
    if labelled:
        closing += (
            f" `{OWNER_ACTION_LABEL}` stays on this PR until a reviewer stops blocking "
            "it, so it reads as waiting on the owner rather than stranded — here and "
            "in the Factory Digest."
        )
    else:
        closing += (
            f" The `{OWNER_ACTION_LABEL}` label could not be applied, so this PR will "
            "not show up as waiting on you until it is — the workflow run says why."
        )
    lines += ["", closing]
    lines += ["", response_marker(int(review.get("id") or 0))]
    return "\n".join(lines) + "\n"


def label_applied_by_factory(
    events: list[dict[str, Any]],
    label: str,
    factory_logins: set[str],
) -> bool:
    """Whether the most recent application of `label` was the factory's own.

    The factory removes only what it applied. A person applying `owner-action`
    by hand is making a statement, not leaving machine state, and the factory
    has no business withdrawing it.
    """
    applications = [
        event
        for event in events
        if str(event.get("event", "")).casefold() == "labeled"
        and str((event.get("label") or {}).get("name", "")) == label
    ]
    if not applications:
        return False
    # Ordered by timestamp rather than list position: GitHub's timeline reads
    # chronologically today but documents no sort contract, and getting this
    # backwards would remove a label a person applied.
    latest = max(
        applications,
        key=lambda event: (str(event.get("created_at") or ""), int(event.get("id") or 0)),
    )
    actor = latest.get("actor") or {}
    login = str(actor.get("login", "")) if isinstance(actor, dict) else ""
    return bool(login) and login.casefold() in factory_logins


def factory_label_logins() -> set[str]:
    """Identities whose label application counts as the factory's own."""
    return {bot.casefold() for bot in factory_review.REVIEWER_BOTS.values()} | {
        RESPONDER_BOT.casefold()
    }


def apply_owner_action(client: GitHubClient, pr_number: int, labels: set[str]) -> bool:
    """Ensure the marker is on the PR. True when it is, by whatever route.

    Level-triggered on purpose: called whenever a standing rejection has a
    factory response, not only when a new comment is posted, so a transient
    failure or a label someone removed by hand is repaired on the next event
    rather than leaving the PR silently unmarked.
    """
    if OWNER_ACTION_LABEL in labels:
        return True
    if not client.ensure_label(
        OWNER_ACTION_LABEL, OWNER_ACTION_COLOR, OWNER_ACTION_DESCRIPTION
    ):
        return False
    try:
        client.add_label(pr_number, OWNER_ACTION_LABEL)
    except factory_implement.FactoryImplementError as error:
        warn(f"could not apply `{OWNER_ACTION_LABEL}` to #{pr_number}: {error}")
        return False
    print(f"Factory review response applied {OWNER_ACTION_LABEL} to #{pr_number}")
    return True


def clear_owner_action(client: GitHubClient, pr_number: int, labels: set[str]) -> bool:
    """Withdraw the factory's own owner-action label. True if it removed one."""
    if OWNER_ACTION_LABEL not in labels:
        return False
    if not label_applied_by_factory(
        client.timeline(pr_number), OWNER_ACTION_LABEL, factory_label_logins()
    ):
        print(
            f"Factory review response: {OWNER_ACTION_LABEL} on #{pr_number} was not "
            "machine-applied; leaving it"
        )
        return False
    try:
        client.remove_label(pr_number, OWNER_ACTION_LABEL)
    except factory_implement.FactoryImplementError as error:
        warn(f"could not clear `{OWNER_ACTION_LABEL}` on #{pr_number}: {error}")
        return False
    print(f"Factory review response cleared {OWNER_ACTION_LABEL} from #{pr_number}")
    return True


def write_output(name: str, value: str) -> None:
    factory_implement.write_output(name, value)


def respond(
    client: GitHubClient,
    pr_number: int,
    review_id: int | None,
    repository_owner: str,
    *,
    revise_enabled: bool = False,
) -> None:
    pull_request = client.pull_request(pr_number)
    reviews = client.pull_request_reviews(pr_number)
    comments = client.comments(pr_number)
    standing = standing_reviews(reviews, repository_owner)
    # Escalation markers only, deliberately: this set decides both which
    # review still needs answering and whether the owner-action marker below
    # belongs on the PR. A revision-answered review is in flight, not waiting
    # on the owner, so counting its marker here would label a moving PR.
    answered = {
        int(item.get("id") or 0)
        for item in standing
        if has_response_for_review(comments, int(item.get("id") or 0))
    }
    review = blocking_review(
        reviews,
        repository_owner,
        review_id,
        answered=lambda candidate: candidate in answered,
    )
    already_responded = review is not None and int(review.get("id") or 0) in answered
    decision = evaluate_response(
        pull_request,
        review,
        repository_owner=repository_owner,
        already_responded=already_responded,
        revise_enabled=revise_enabled,
        revision_in_flight=(
            review is not None
            and has_revision_for_review(comments, int(review.get("id") or 0))
        ),
        revision_attempts=count_revision_attempts(comments),
    )
    print(f"Factory review response for #{pr_number}: {decision.action} ({decision.reason})")
    labels = factory_implement.label_names(pull_request)
    open_pr = str(pull_request.get("state") or "").casefold() == "open"
    cleared = False
    labelled = OWNER_ACTION_LABEL in labels
    if open_pr:
        # The marker tracks whether ANY trusted reviewer is blocking, not
        # whether this run had something to answer. Reading it off `review`
        # would clear the marker the moment one reviewer approved while
        # another's rejection still stood -- and on the webhook path `review`
        # is filtered to the triggering review, so an approval always looks
        # like "nothing blocking".
        if not standing:
            if reviews_are_conclusive(reviews, repository_owner):
                cleared = clear_owner_action(client, pr_number, labels)
                labelled = labelled and not cleared
            elif labelled:
                print(
                    f"Factory review response: review data for #{pr_number} is "
                    f"incomplete; leaving {OWNER_ACTION_LABEL} in place"
                )
        elif answered == {int(item.get("id") or 0) for item in standing}:
            # Every standing rejection already has its response, so the marker
            # belongs on the PR whether or not this run posts anything. This
            # is what repairs a failed application or a hand-removed label.
            labelled = apply_owner_action(client, pr_number, labels)
    if decision.action == "respond" and decision.owner_required:
        assert review is not None
        labelled = apply_owner_action(client, pr_number, labels)
    write_output("pr_number", str(pr_number))
    write_output("responded", "true" if decision.action == "respond" else "false")
    write_output("owner_required", "true" if decision.owner_required else "false")
    write_output("owner_action_applied", "true" if labelled else "false")
    write_output("owner_action_cleared", "true" if cleared else "false")
    write_output(
        "blockers",
        ",".join(blocker.key for blocker in decision.blockers),
    )
    # Read by nothing in this lane's own workflow: they are how an operator
    # reading a deferred run's summary can see which review was handed on.
    write_output("revise_eligible", "true" if decision.action == "defer" else "false")
    write_output(
        "review_id", str(int(review.get("id") or 0)) if review is not None else ""
    )
    if decision.action != "respond":
        return
    assert review is not None
    client.comment(
        pr_number,
        response_comment(
            decision, review, repository_owner=repository_owner, labelled=labelled
        ),
    )
    print(
        f"Factory review response posted on #{pr_number} for review "
        f"{review.get('id')}: owner_required={decision.owner_required}"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument(
        "--review-id",
        type=int,
        default=None,
        help="Answer this specific review; omit to answer the standing one.",
    )
    return parser.parse_args(argv)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryReviewResponseError(f"{name} is required")
    return value


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    require_automation_switches(
        os.environ.get("AGENT_AUTOMATIONS_ENABLED", ""),
        os.environ.get("FACTORY_REVIEW_RESPONSE_ENABLED", ""),
    )
    client = GitHubClient(
        require_env("GITHUB_REPOSITORY"),
        require_env("GH_TOKEN"),
    )
    respond(
        client,
        args.pr,
        args.review_id,
        require_env("FACTORY_REPOSITORY_OWNER"),
        revise_enabled=os.environ.get(REVISION_LANE_SWITCH, "").casefold() == "true",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except FactoryReviewResponseError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
