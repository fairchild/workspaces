#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Daily reconciliation for the Factory counterpart-review lane.

`factory-review.yml` (signal) is edge-triggered on `pull_request` events and
succeeds independently of whether `factory-review-execute.yml` (the
`workflow_run`-triggered job that actually posts a counterpart review) ever
follows it. GitHub's `workflow_run` delivery is not guaranteed same-run: a PR
observed live on 2026-08-31 had its signal succeed four times over an hour
while the Executor produced zero runs — anywhere in the repo — for roughly
seven hours (#1507). The PR merged inside that gap with no bot review, and
nothing noticed.

This sweep re-derives, for every open pull request, exactly the admission
check the Executor's own `admit` job makes (`evaluate_review`, imported
rather than re-implemented — a second opinion about routing is the one thing
a reconciliation pass must not have). When a PR is currently due for a
counterpart review *and* has been due for longer than the threshold, that is
the symptom worth flagging — regardless of whether the cause was a
`workflow_run` gap, an exhausted daily cap, or a crash loop that never
reached the review step. Detection only: this never dispatches a review or
touches the Executor's own budget: `agent` + `needs-human` is the marker the
lane pairs with an idempotent comment (a repeat sweep never reposts the same
head's diagnosis) so the PR surfaces for the owner without anything acting
on their behalf.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_THRESHOLD_HOURS = 3
RECONCILE_MARKER = "<!-- factory-review-reconcile:head={head_sha} -->"
# GITHUB_TOKEN-authored comments post under this identity. Matching the
# marker only against this author, not "any comment on the PR", is what
# keeps the idempotency check from being a self-suppression switch anyone
# who can comment could pull.
RECONCILE_COMMENT_AUTHOR = "github-actions[bot]"
FLAG_LABELS = ("agent", "needs-human")
API_ATTEMPTS = 3
# A pause between each finding's writes, in line with GitHub's own guidance
# to space mutating requests roughly a second apart rather than firing a
# burst that trips the ~80/minute secondary rate limit.
WRITE_PACE_SECONDS = 1.1


def _load_factory_review():
    """The Executor's own admission logic, loaded by path.

    Routing (which reviewer, whether this head already has a verdict) must
    stay single-sourced with `factory-review.py` — duplicating
    `evaluate_review` here would let this reconciliation pass and the
    Executor's admission drift into disagreeing about what "due for review"
    means.

    Reuses an already-loaded module rather than re-execing over it: a second
    `exec_module` mints a second, distinct `ReviewDecision` class under the
    same `sys.modules` name, so a `StaleReview` built from the first load's
    decision would fail `isinstance` against the second. Harmless within a
    single `uv run --script` process (this only runs once, at import time),
    but this module and the test file that loads it by the same path can
    both end up in one interpreter.
    """
    name = "factory_review_for_reconcile"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / "factory-review.py")
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review = _load_factory_review()


class FactoryReviewReconcileError(RuntimeError):
    """Raised when the reconciliation sweep cannot be planned or applied safely."""


def _retry_after_seconds(error: urllib.error.HTTPError) -> float | None:
    raw = error.headers.get("Retry-After") if error.headers else None
    if raw is None:
        return None
    try:
        return max(0.0, float(raw))
    except ValueError:
        return None


class GitHubClient(factory_review.GitHubClient):
    """Adds the list/write calls reconciliation needs to the review lane's
    read-only GET client — `pull_request`/`pull_request_files`/
    `pull_request_reviews`/`workflow_runs_on` are inherited unchanged, so a
    fetched PR is shaped exactly the way `evaluate_review` expects it."""

    def open_pull_requests(self) -> list[dict[str, Any]]:
        pulls: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = self.request(
                f"/repos/{self.repository}/pulls?state=open&per_page=100&page={page}"
            )
            pulls.extend(dict(item) for item in batch)
            if len(batch) < 100:
                return pulls
            page += 1

    def workflow_runs_for_head(self, workflow: str, head_sha: str) -> list[dict[str, Any]]:
        # 100, not the default 20: a head with more dispatches against it than
        # that (retries, reruns, an unrelated flood) would otherwise let a
        # genuinely successful signal fall off the page and read as "never
        # ran" (silent false negative — the PR this sweep most needs to catch
        # never gets flagged).
        payload = dict(
            self.request(
                f"/repos/{self.repository}/actions/workflows/{workflow}/runs"
                f"?head_sha={head_sha}&per_page=100"
            )
        )
        return [dict(run) for run in payload.get("workflow_runs") or []]

    def issue_comments(self, number: int) -> list[dict[str, Any]]:
        return self._paginated(f"/repos/{self.repository}/issues/{number}/comments")

    def write(self, method: str, path: str, payload: dict[str, Any]) -> None:
        """POST with a retry policy scoped to what is actually safe to retry.

        A 429 means GitHub rejected the request before doing anything with
        it — retrying (after any `Retry-After` it names) cannot double-apply
        a write. A 5xx or a dropped connection is ambiguous: the mutation may
        have already landed server-side with the response lost in transit,
        so retrying it risks a second, real comment or a second label call
        under a fresh idempotency check that has nothing to compare against
        yet. Those surface immediately instead — the caller's per-finding
        isolation lets the run continue, and tomorrow's sweep retries safely
        because by then the marker check has something to find.
        """
        data = json.dumps(payload).encode("utf-8")
        for attempt in range(1, API_ATTEMPTS + 1):
            request = urllib.request.Request(
                f"{self.api_url}{path}",
                data=data,
                headers={
                    "Accept": "application/vnd.github+json",
                    "Authorization": f"Bearer {self.token}",
                    "Content-Type": "application/json",
                    "User-Agent": "workspaces-factory-review-reconcile",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
                method=method,
            )
            try:
                with urllib.request.urlopen(request, timeout=30):
                    return
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")
                if error.code == 429 and attempt < API_ATTEMPTS:
                    # `or` would treat a genuine `Retry-After: 0` as absent
                    # and fall through to the exponential backoff instead.
                    retry_after = _retry_after_seconds(error)
                    time.sleep(retry_after if retry_after is not None else 2**attempt)
                    continue
                raise FactoryReviewReconcileError(
                    f"GitHub API {method} {path} failed with HTTP {error.code}: {detail}"
                ) from error
            except urllib.error.URLError as error:
                raise FactoryReviewReconcileError(
                    f"GitHub API {method} {path} failed: {error.reason}"
                ) from error

    def add_flag_labels(self, number: int) -> None:
        self.write(
            "POST",
            f"/repos/{self.repository}/issues/{number}/labels",
            {"labels": list(FLAG_LABELS)},
        )

    def post_comment(self, number: int, body: str) -> None:
        self.write(
            "POST",
            f"/repos/{self.repository}/issues/{number}/comments",
            {"body": body},
        )


@dataclass(frozen=True)
class StaleReview:
    pr_number: int
    reviewer: str
    head_sha: str
    signal_completed_at: str
    age_hours: float


def runs_associated_with_pull_request(
    runs: list[dict[str, Any]], pr_number: int
) -> list[dict[str, Any]]:
    """Drops a run GitHub explicitly ties to a *different* PR; keeps
    everything else.

    `head_sha` identifies a commit, not a PR — two open PRs can point at the
    same commit (a rebase, a duplicate branch), and a run genuinely
    triggered for one would otherwise read as evidence for the other. Each
    `pull_request`-triggered run carries its own `pull_requests` array
    naming which PR(s) it belongs to; a run naming some *other* PR is
    excluded outright. A run with an empty array — cross-repo/fork-triggered
    runs, where GitHub gives no association at all — is ambiguous rather
    than wrong, so it stays, on the same best-effort basis `head_sha` alone
    already was.
    """
    kept: list[dict[str, Any]] = []
    for run in runs:
        associated_numbers = {
            int(pr["number"])
            for pr in run.get("pull_requests") or []
            if isinstance(pr, dict) and "number" in pr
        }
        if not associated_numbers or pr_number in associated_numbers:
            kept.append(run)
    return kept


def latest_successful_run_completion(runs: list[dict[str, Any]]) -> str | None:
    """The most recent `updated_at` among runs that finished successfully.

    `updated_at` rather than a dedicated completion timestamp: for the
    single-job, few-seconds-long "signal" workflow this is close enough at an
    hours-scale threshold, and every run object carries it without a second
    per-run jobs call.
    """
    completions = [
        str(run["updated_at"])
        for run in runs
        if str(run.get("status") or "") == "completed"
        and str(run.get("conclusion") or "") == "success"
        and run.get("updated_at")
    ]
    return max(completions) if completions else None


def evaluate_pull_request(
    pull_request: dict[str, Any],
    files: list[dict[str, Any]],
    reviews: list[dict[str, Any]],
    signal_runs: list[dict[str, Any]],
    *,
    now: datetime,
    threshold_hours: float,
) -> StaleReview | None:
    decision = factory_review.evaluate_review(pull_request, files, reviews, force=False)
    if decision.action != "review":
        return None
    signal_completed_at = latest_successful_run_completion(signal_runs)
    if signal_completed_at is None:
        # The signal itself hasn't succeeded for this head yet — new push,
        # still building, or a signal-side failure distinct from what this
        # sweep exists to catch. Not stale; nothing to flag yet.
        return None
    completed = datetime.fromisoformat(signal_completed_at.replace("Z", "+00:00"))
    age_hours = (now - completed).total_seconds() / 3600
    if age_hours < threshold_hours:
        return None
    head_sha = str((pull_request.get("head") or {}).get("sha") or "")
    return StaleReview(
        pr_number=int(pull_request["number"]),
        reviewer=decision.reviewer,
        head_sha=head_sha,
        signal_completed_at=signal_completed_at,
        age_hours=age_hours,
    )


def already_flagged(comments: list[dict[str, Any]], head_sha: str) -> bool:
    marker = RECONCILE_MARKER.format(head_sha=head_sha)
    return any(
        marker in str(comment.get("body") or "")
        for comment in comments
        # Scoped to the sweep's own posting identity: matching any commenter
        # would let the PR's own author (or anyone who can comment) suppress
        # the flag for a head by simply pasting the marker text, and the
        # workflow would exit clean having silently skipped both the label
        # and the real diagnosis.
        if str((comment.get("user") or {}).get("login") or "").casefold()
        == RECONCILE_COMMENT_AUTHOR.casefold()
    )


def comment_body(finding: StaleReview, threshold_hours: float) -> str:
    marker = RECONCILE_MARKER.format(head_sha=finding.head_sha)
    return (
        f"{marker}\n"
        f"Factory Review's signal succeeded for this head "
        f"({finding.signal_completed_at}, {finding.age_hours:.1f}h ago — over the "
        f"{threshold_hours:g}h threshold) but no counterpart review from "
        f"`{factory_review.REVIEWER_BOTS[finding.reviewer]}` has landed since.\n\n"
        "This is the symptom `factory-review-reconcile.py` watches for "
        "(#1507): the Executor lane can silently fail to follow the signal "
        "— a `workflow_run` delivery gap, a crash loop, or an exhausted "
        "daily cap. The owner can force a review through the same path that "
        "bypasses both Factory kill switches:\n\n"
        f"```\ngh workflow run \"Factory Review\" -f pr_number={finding.pr_number}\n```"
    )


def find_stale_reviews(
    client: GitHubClient,
    pull_requests: list[dict[str, Any]],
    *,
    now: datetime,
    threshold_hours: float,
) -> list[StaleReview]:
    """Fetches per-PR state cheapest-check-first: a PR without exactly one
    `author:*` label, or one `evaluate_review` already calls settled (no
    route, already reviewed, self-review, draft), never reaches the
    `workflow_runs_for_head` call — most open PRs at any moment fall into one
    of those buckets, and each is an Actions API request this sweep would
    otherwise make once a day for every open PR regardless of relevance."""
    findings: list[StaleReview] = []
    for pull_request in pull_requests:
        if factory_review.author_label(pull_request) is None:
            continue
        number = int(pull_request["number"])
        try:
            files = client.pull_request_files(number)
            reviews = client.pull_request_reviews(number)
            if (
                factory_review.evaluate_review(pull_request, files, reviews, force=False).action
                != "review"
            ):
                continue
            head_sha = str((pull_request.get("head") or {}).get("sha") or "")
            signal_runs = runs_associated_with_pull_request(
                client.workflow_runs_for_head("factory-review.yml", head_sha), number
            )
        except (FactoryReviewReconcileError, factory_review.FactoryReviewError) as error:
            # A read failure here loses only today's chance to flag this one
            # PR, not every PR already scanned — the daily cadence retries it
            # tomorrow, so degrading gracefully beats aborting the batch.
            print(f"[read-failed] #{number}: {error}", file=sys.stderr)
            continue
        finding = evaluate_pull_request(
            pull_request, files, reviews, signal_runs, now=now, threshold_hours=threshold_hours
        )
        if finding is not None:
            findings.append(finding)
    return findings


def print_findings(findings: list[StaleReview]) -> None:
    if not findings:
        print("[reconcile] no stale reviews found")
        return
    for finding in findings:
        print(
            f"[stale] #{finding.pr_number}: due for {finding.reviewer} since "
            f"{finding.signal_completed_at} ({finding.age_hours:.1f}h ago)"
        )


def still_due(client: GitHubClient, finding: StaleReview) -> bool:
    """Re-checks a finding against live state right before writing.

    Findings are computed in one pass over every open PR, then applied in a
    second pass afterward — during which the PR this finding names can have
    moved on: closed, merged, pushed to a new head, or actually reviewed
    while a sibling PR was still being scanned. Re-fetching only what
    changed (the PR itself and its reviews, not files — routing does not
    change without an author-label edit) is cheap next to writing a stale
    diagnosis onto a PR the owner already resolved.
    """
    pull_request = client.pull_request(finding.pr_number)
    if str(pull_request.get("state") or "").casefold() != "open":
        return False
    head_sha = str((pull_request.get("head") or {}).get("sha") or "")
    if head_sha != finding.head_sha:
        return False
    reviews = client.pull_request_reviews(finding.pr_number)
    return not factory_review.reviewed_head(
        reviews, reviewer=finding.reviewer, head_sha=finding.head_sha
    )


def apply_findings(
    client: GitHubClient, findings: list[StaleReview], threshold_hours: float
) -> None:
    """Continues past a single PR's failure rather than aborting the rest of
    the run: one flaky read or write must not silence every other stale PR
    this sweep already found. Every failure is still raised at the end,
    once, so the run fails loudly and CI/cron surfaces it. Paced a beat
    between PRs so a large batch of findings never bursts past GitHub's
    secondary rate limit on mutating requests."""
    failures: list[tuple[int, str]] = []
    for index, finding in enumerate(findings):
        try:
            if not still_due(client, finding):
                print(f"[skip] #{finding.pr_number}: no longer due for review")
                continue
            comments = client.issue_comments(finding.pr_number)
            if already_flagged(comments, finding.head_sha):
                print(f"[skip] #{finding.pr_number}: already flagged for head {finding.head_sha}")
                continue
            client.add_flag_labels(finding.pr_number)
            client.post_comment(finding.pr_number, comment_body(finding, threshold_hours))
        except (FactoryReviewReconcileError, factory_review.FactoryReviewError) as error:
            failures.append((finding.pr_number, str(error)))
            print(f"[failed] #{finding.pr_number}: {error}", file=sys.stderr)
            continue
        finally:
            if index < len(findings) - 1:
                time.sleep(WRITE_PACE_SECONDS)
        print(f"[flagged] #{finding.pr_number}")
    if failures:
        rendered = "; ".join(f"#{number}: {detail}" for number, detail in failures)
        raise FactoryReviewReconcileError(f"persistent per-PR flag failures: {rendered}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="plan only (the default)")
    mode.add_argument(
        "--apply", action="store_true", help="apply the needs-human label and post the comment"
    )
    parser.add_argument(
        "--threshold-hours",
        type=float,
        default=None,
        help="how long a PR may be due for review before it is flagged "
        "(default: $FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS or 3)",
    )
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        help="read checked-in state instead of querying GitHub",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.fixtures_dir is not None and args.apply:
        raise FactoryReviewReconcileError("--fixtures-dir cannot be combined with --apply")


def resolve_threshold_hours(args: argparse.Namespace) -> float:
    if args.threshold_hours is not None:
        if not math.isfinite(args.threshold_hours) or args.threshold_hours <= 0:
            raise FactoryReviewReconcileError("--threshold-hours must be a positive, finite number")
        return args.threshold_hours
    raw = os.environ.get("FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS", "").strip()
    if not raw:
        return DEFAULT_THRESHOLD_HOURS
    try:
        value = float(raw)
    except ValueError as error:
        raise FactoryReviewReconcileError(
            f"FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS must be a positive, finite number, got {raw!r}"
        ) from error
    # `<= 0` alone lets `nan` (every comparison false) and `inf` (compares
    # true, then flags a 30-minute-old signal or disables every finding)
    # both through — both are non-finite, so `math.isfinite` catches what a
    # bare positivity check cannot.
    if not math.isfinite(value) or value <= 0:
        raise FactoryReviewReconcileError(
            "FACTORY_REVIEW_RECONCILE_THRESHOLD_HOURS must be a positive, finite number"
        )
    return value


def load_fixture_findings(fixtures_dir: Path, threshold_hours: float) -> list[StaleReview]:
    if not fixtures_dir.is_dir():
        raise FactoryReviewReconcileError(f"fixture pack not found: {fixtures_dir}")
    state_path = fixtures_dir / "state.json"
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FactoryReviewReconcileError(f"missing required file: {state_path}") from error
    except json.JSONDecodeError as error:
        raise FactoryReviewReconcileError(f"invalid JSON in {state_path}: {error}") from error
    now = datetime.fromisoformat(str(payload["now"]).replace("Z", "+00:00"))
    findings: list[StaleReview] = []
    for entry in payload["pull_requests"]:
        finding = evaluate_pull_request(
            entry["pull_request"],
            entry.get("files", []),
            entry.get("reviews", []),
            entry.get("signal_runs", []),
            now=now,
            threshold_hours=threshold_hours,
        )
        if finding is not None:
            findings.append(finding)
    return findings


def main() -> int:
    args = parse_args()
    validate_args(args)
    threshold_hours = resolve_threshold_hours(args)

    if args.fixtures_dir is not None:
        findings = load_fixture_findings(args.fixtures_dir, threshold_hours)
        print_findings(findings)
        print(f"Dry run: {len(findings)} finding(s); no writes.")
        return 0

    repository = factory_review.require_env("GITHUB_REPOSITORY")
    token = factory_review.require_env("GH_TOKEN")
    client = GitHubClient(repository, token)
    now = datetime.now(UTC)
    findings = find_stale_reviews(
        client, client.open_pull_requests(), now=now, threshold_hours=threshold_hours
    )
    print_findings(findings)
    if args.apply:
        apply_findings(client, findings, threshold_hours)
    else:
        print(f"Dry run: {len(findings)} finding(s); no writes.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FactoryReviewReconcileError, factory_review.FactoryReviewError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
