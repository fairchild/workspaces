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
blocks the PR, and posts exactly one response per review -- either "the
factory clears these itself" or "this needs @owner because X", naming the
gesture. Escalation is the default: a blocker the factory cannot prove it
will clear is always escalated explicitly, never parked in silence.

Deterministic by construction -- no model, no tools, no untrusted text
reaching an executor. It only reads PR state the factory already writes
(labels, the structured evidence block, review history).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
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

APRIL_ATTRIBUTION = "*April Clearwater, Application Lead*\n\n"
RESPONSE_MARKER_PREFIX = "<!-- factory-review-response review-id:"
CHANGES_REQUESTED = "CHANGES_REQUESTED"
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


def blocking_review(
    reviews: list[dict[str, Any]],
    repository_owner: str,
    review_id: int | None,
) -> dict[str, Any] | None:
    """The trusted CHANGES_REQUESTED review this lane should answer.

    A reviewer's later review supersedes their earlier one, so only each
    trusted reviewer's most recent review counts -- answering a verdict the
    reviewer has already replaced would re-park a PR that moved on.
    """
    trusted = trusted_reviewers(repository_owner)
    latest_by_reviewer: dict[str, dict[str, Any]] = {}
    for review in reviews:
        login = str((review.get("user") or {}).get("login") or "").casefold()
        if login not in trusted:
            continue
        if str(review.get("state") or "").upper() == "COMMENTED":
            # A comment-only review never changes a reviewer's standing
            # verdict on GitHub, so it must not displace one here either.
            continue
        latest_by_reviewer[login] = review
    blocking = [
        review
        for review in latest_by_reviewer.values()
        if str(review.get("state") or "").upper() == CHANGES_REQUESTED
    ]
    if review_id is not None:
        return next(
            (review for review in blocking if int(review.get("id") or 0) == review_id),
            None,
        )
    blocking.sort(key=lambda review: str(review.get("submitted_at") or ""))
    return blocking[-1] if blocking else None


def evidence_entries(body: str) -> list[dict[str, Any]]:
    metadata = _extract_evidence_metadata(body)
    if not isinstance(metadata, dict):
        return []
    entries = metadata.get("entries")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _entry_label(entry: dict[str, Any]) -> str:
    index = entry.get("index")
    item = str(entry.get("item") or "").strip()
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


def label_blockers(labels: set[str], entries: list[dict[str, Any]]) -> list[Blocker]:
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
        if label == BLOCKED_EVIDENCE_LABEL and entries:
            # Already accounted for entry-by-entry above, where the gesture can
            # name the specific evidence lines rather than the label alone.
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
    blockers = evidence_blockers(entries) + label_blockers(labels, entries)
    if not blockers:
        # Nothing in the machine-readable state explains the objection --
        # almost always a change to the diff itself. Defaulting to escalation
        # here is the whole point: an unexplained objection must surface as an
        # explicit owner ask, not as silence. A review that objects to *both*
        # a self-clearing blocker and the diff still reads as self-clearing on
        # this turn; it converges on the next one, because once the blocker
        # clears and the counterpart re-reviews, the standing objection has
        # nothing left to explain it and lands here.
        blockers.append(
            Blocker(
                key="revision-required",
                owner_required=True,
                detail=(
                    "**A change to the diff was requested.** Nothing in this PR's "
                    "machine-readable state (evidence entries, blocking labels) "
                    "accounts for the review, so the requested change is to the code "
                    f"or prose itself. The factory has no contributor revision loop "
                    f"yet ({REVISION_LOOP_ISSUE}): push the revision, or re-release "
                    "the linked issue with the review's feedback folded into it."
                ),
            )
        )
    return ResponseDecision("respond", "review needs a factory response", tuple(blockers))


def response_marker(review_id: int) -> str:
    return f"{RESPONSE_MARKER_PREFIX}{review_id} -->"


def has_response_for_review(comments: list[dict[str, Any]], review_id: int) -> bool:
    marker = response_marker(review_id)
    return any(marker in str(comment.get("body") or "") for comment in comments)


def response_comment(
    decision: ResponseDecision,
    review: dict[str, Any],
    *,
    repository_owner: str,
) -> str:
    reviewer = str((review.get("user") or {}).get("login") or "a reviewer")
    review_url = str(review.get("html_url") or "").strip()
    reference = f"[requested changes]({review_url})" if review_url else "requested changes"
    owner_lines = [b.detail for b in decision.blockers if b.owner_required]
    factory_lines = [b.detail for b in decision.blockers if not b.owner_required]

    lines = [APRIL_ATTRIBUTION.rstrip("\n"), ""]
    lines.append(f"Read @{reviewer}'s {reference}.")
    lines.append("")
    if owner_lines:
        lines.append(f"**This needs @{repository_owner}** — the factory cannot clear it:")
        lines.append("")
        lines += [f"- {line}" for line in owner_lines]
        if factory_lines:
            lines += ["", "Clearing on its own, no action needed:", ""]
            lines += [f"- {line}" for line in factory_lines]
        lines += [
            "",
            "Once those gestures land, ask for a fresh counterpart review "
            "(`Factory Review` → run for this PR number) and the loop picks it back up.",
        ]
    else:
        lines.append(
            "**No owner action needed** — every blocking item here clears without you:"
        )
        lines.append("")
        lines += [f"- {line}" for line in factory_lines]
        lines += [
            "",
            "The factory will ask for a fresh counterpart review once they land. If your "
            "review asked for more than that, say so on this PR — the next standing "
            f"review with nothing left to explain it escalates to @{repository_owner}.",
        ]
    lines += ["", response_marker(int(review["id"]))]
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
    review = blocking_review(reviews, repository_owner, review_id)
    already_responded = review is not None and has_response_for_review(
        client.comments(pr_number), int(review.get("id") or 0)
    )
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
