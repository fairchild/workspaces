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
# The contributor revision loop (#1125) is the missing capability behind every
# "the diff itself must change" escalation. Naming it keeps the escalation
# honest about what the factory cannot yet do, rather than implying judgment.
REVISION_LOOP_ISSUE = "#1125"


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
    for review in sorted(reviews, key=lambda item: str(item.get("submitted_at") or "")):
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


def evaluate_response(
    pull_request: dict[str, Any],
    review: dict[str, Any] | None,
    *,
    repository_owner: str,
    already_responded: bool,
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
        # check_suite event). Escalating anyway is the fail-safe direction --
        # a needless ask costs the owner a glance; a false "you are not
        # needed" costs a parked PR, which is the failure this lane exists to
        # remove.
        blockers.append(
            Blocker(
                key="revision-required",
                owner_required=True,
                detail=(
                    "**A change to the diff was requested.** Nothing the owner can "
                    "act on in this PR's machine-readable state (evidence entries, "
                    "blocking labels) accounts for the review, so the requested "
                    "change is to the code "
                    f"or prose itself. The factory has no contributor revision loop "
                    f"yet ({REVISION_LOOP_ISSUE}): push the revision, or re-release "
                    "the linked issue with the review's feedback folded into it."
                ),
            )
        )
    return ResponseDecision("respond", "review needs a factory response", tuple(blockers))


def response_marker(review_id: int) -> str:
    return f"{RESPONSE_MARKER_PREFIX}{review_id} -->"


def is_response_comment(comment: dict[str, Any], review_id: int) -> bool:
    """True only for a response this lane actually posted for `review_id`.

    Author-bound and position-bound. A substring search over every comment
    body would let anyone silence the lane by quoting the marker back --
    exactly the false-suppression class #1364 closed for the owner-comment
    responder, whose quote/code reader is reused here. The marker must be the
    last line that renders outside blockquotes, fences, and indented blocks.
    """
    author = str((comment.get("user") or {}).get("login") or "")
    if author.casefold() != RESPONDER_BOT.casefold():
        return False
    visible = factory_responder._unquoted_visible_lines(str(comment.get("body") or ""))
    return bool(visible) and visible[-1].strip() == response_marker(review_id)


def has_response_for_review(comments: list[dict[str, Any]], review_id: int) -> bool:
    return any(is_response_comment(comment, review_id) for comment in comments)


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
    lines += [
        "",
        "Once that lands, ask for a fresh counterpart review (`Factory Review` → run "
        "for this PR number) and the loop picks it back up. This PR is waiting on the "
        "owner, not stranded.",
    ]
    lines += ["", response_marker(int(review.get("id") or 0))]
    return "\n".join(lines) + "\n"


def write_output(name: str, value: str) -> None:
    factory_implement.write_output(name, value)


def respond(
    client: GitHubClient,
    pr_number: int,
    review_id: int | None,
    repository_owner: str,
) -> None:
    pull_request = client.pull_request(pr_number)
    reviews = client.pull_request_reviews(pr_number)
    comments = client.comments(pr_number)
    answered = {
        int(review.get("id") or 0)
        for review in standing_reviews(reviews, repository_owner)
        if has_response_for_review(comments, int(review.get("id") or 0))
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
    )
    print(f"Factory review response for #{pr_number}: {decision.action} ({decision.reason})")
    write_output("pr_number", str(pr_number))
    write_output("responded", "true" if decision.action == "respond" else "false")
    write_output("owner_required", "true" if decision.owner_required else "false")
    write_output(
        "blockers",
        ",".join(blocker.key for blocker in decision.blockers),
    )
    if decision.action != "respond":
        return
    assert review is not None
    client.comment(
        pr_number,
        response_comment(decision, review, repository_owner=repository_owner),
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
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except FactoryReviewResponseError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
