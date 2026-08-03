#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Level-triggered sweep for the standing Agent Factory ready queue.

`factory-implement.yml` only fires on the `ready` label *event*
(edge-triggered). Nothing previously reconciled standing state, so an admitted
issue could sit `ready` indefinitely if the labeling event was missed, raced,
or preceded automation being enabled. This sweep runs from the daily
factory-monitor cron and re-dispatches `factory-implement.yml`
(`workflow_dispatch`) for the oldest open `ready`+`agent`+`task` issues that
have no open linked pull request, up to whatever headroom remains under
`FACTORY_IMPLEMENT_DAILY_CAP` for today.

Admission stays Owner-only: this sweep never applies `ready` itself, and
`factory-implement.py`'s claim step independently re-verifies — from the
issue's own timeline — that the most recent `ready` label event was actually
applied by the repository owner before doing any work. The sweep only
re-fires standing admitted state. The sweep also pre-filters candidates on
that same owner-actor and content-staleness checks before dispatching,
purely as a budget guard: a non-owner label-capable collaborator relabeling
old issues, or a non-owner editing an issue's title/body after the owner
released it, can't burn the day's FACTORY_IMPLEMENT_DAILY_CAP on runs that
claim would defer anyway — worse, repeatedly, since a deferred issue stays
`ready` for the next sweep to re-pick.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent


def _load_factory_implement():
    name = "factory_implement_for_sweep"
    spec = importlib.util.spec_from_file_location(
        name, SCRIPT_DIR / "factory-implement.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    # dataclasses' `_is_type` looks the defining module up in sys.modules, so
    # it must be registered before exec_module runs the class body.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Reused rather than duplicated: daily-cap counting is budget/security-critical
# and must stay single-sourced with the claim/authorize steps it also gates.
factory_implement = _load_factory_implement()


class FactorySweepError(RuntimeError):
    """Raised when the sweep cannot be planned or dispatched safely."""


@dataclass(frozen=True)
class SweepPlan:
    dispatch: tuple[int, ...]
    skipped_over_cap: tuple[int, ...]
    daily_run_count: int
    daily_cap: int


class GitHubClient(factory_implement.GitHubClient):
    def open_ready_agent_issues(self) -> list[dict[str, Any]]:
        # Paginated: a single per_page=100 request would silently cap the
        # standing queue at 100 issues, permanently starving anything older
        # sitting past that point — exactly the kind of silent stall #1148
        # exists to fix.
        labels = "ready,agent,task"
        issues: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = self.request(
                "GET",
                f"/repos/{self.repository}/issues"
                f"?state=open&labels={labels}&sort=created&direction=asc"
                f"&per_page=100&page={page}",
            )
            issues.extend(dict(item) for item in batch if "pull_request" not in item)
            if len(batch) < 100:
                return issues
            page += 1

    def has_open_linked_pull(
        self, issue_number: int, *, events: list[dict[str, Any]] | None = None
    ) -> bool:
        for event in events if events is not None else self.timeline(issue_number):
            if str(event.get("event", "")) != "cross-referenced":
                continue
            source = event.get("source") or {}
            source_issue = source.get("issue") if isinstance(source, dict) else None
            if not isinstance(source_issue, dict) or "pull_request" not in source_issue:
                continue
            if str(source_issue.get("state", "")).casefold() == "open":
                return True
        return False

    def dispatch_factory_implement(self, issue_number: int, ref: str) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/actions/workflows/factory-implement.yml/dispatches",
            {"ref": ref, "inputs": {"issue_number": str(issue_number)}},
        )


def eligible_issue_numbers(
    client: GitHubClient,
    repository_owner: str,
    *,
    candidates: list[dict[str, Any]] | None = None,
) -> list[int]:
    """Oldest-first open ready+agent+task issues genuinely owner-admitted,
    with no open linked PR.

    The owner-admission and content-staleness checks here are a budget
    guard, not the security boundary: without them, anyone who can apply
    labels or edit an already-released issue could get the sweep to burn the
    whole day's FACTORY_IMPLEMENT_DAILY_CAP on issues that claim() will defer
    anyway — and, worse, keep burning it every day after, since a deferred
    issue stays `ready` for the next sweep to pick up again. Pre-filtering
    them out here means they consume no slot at all. factory-implement.py's
    claim() independently re-derives and enforces the same checks before any
    work happens, so a bug here can waste sweep dispatches but never grant
    unauthorized execution.
    """
    issues = candidates if candidates is not None else client.open_ready_agent_issues()
    numbers: list[int] = []
    for issue in issues:
        number = int(issue["number"])
        events = client.timeline(number)
        ready_event = factory_implement.latest_ready_event(events)
        if ready_event is None:
            continue
        ready_actor = str((ready_event.get("actor") or {}).get("login") or "")
        if not ready_actor or ready_actor.casefold() != repository_owner.casefold():
            continue
        if client.has_open_linked_pull(number, events=events):
            continue
        hostile_editor = factory_implement.latest_non_owner_editor(
            client.user_content_edits_since(number, str(ready_event["created_at"])),
            repository_owner,
        )
        if hostile_editor is not None:
            continue
        numbers.append(number)
    return numbers


def plan_sweep(eligible: list[int], daily_run_count: int, daily_cap: int) -> SweepPlan:
    headroom = max(0, daily_cap - daily_run_count)
    return SweepPlan(
        dispatch=tuple(eligible[:headroom]),
        skipped_over_cap=tuple(eligible[headroom:]),
        daily_run_count=daily_run_count,
        daily_cap=daily_cap,
    )


def print_plan(plan: SweepPlan) -> None:
    print(
        f"Factory sweep budget: {plan.daily_run_count}/{plan.daily_cap} "
        "implementation runs today"
    )
    if plan.dispatch:
        rendered = ", ".join(f"#{number}" for number in plan.dispatch)
        print(f"[dispatch] {rendered}")
    else:
        print("[dispatch] none eligible or no budget remaining")
    if plan.skipped_over_cap:
        rendered = ", ".join(f"#{number}" for number in plan.skipped_over_cap)
        print(f"[skip] over daily cap, retrying on a future sweep: {rendered}")


def apply_plan(client: GitHubClient, plan: SweepPlan, ref: str) -> None:
    failures: list[tuple[int, str]] = []
    for number in plan.dispatch:
        try:
            client.dispatch_factory_implement(number, ref)
        except factory_implement.FactoryImplementError as error:
            failures.append((number, str(error)))
            print(f"[failed] #{number}: {error}", file=sys.stderr)
            continue
        print(f"[dispatched] #{number}")
    if failures:
        rendered = "; ".join(f"#{number}: {detail}" for number, detail in failures)
        raise FactorySweepError(f"persistent per-issue dispatch failures: {rendered}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="plan only (the default)")
    mode.add_argument(
        "--apply", action="store_true", help="dispatch factory-implement.yml for the plan"
    )
    parser.add_argument("--ref", default="main", help="git ref to dispatch against")
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        help="read checked-in state instead of querying GitHub",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.fixtures_dir is not None and args.apply:
        raise FactorySweepError("--fixtures-dir cannot be combined with --apply")


def load_fixture_plan(fixtures_dir: Path) -> SweepPlan:
    if not fixtures_dir.is_dir():
        raise FactorySweepError(f"fixture pack not found: {fixtures_dir}")
    state_path = fixtures_dir / "state.json"
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FactorySweepError(f"missing required file: {state_path}") from error
    except json.JSONDecodeError as error:
        raise FactorySweepError(f"invalid JSON in {state_path}: {error}") from error
    eligible = [
        int(issue["number"])
        for issue in payload["issues"]
        if not issue.get("has_open_linked_pull")
    ]
    return plan_sweep(
        eligible,
        int(payload.get("daily_run_count", 0)),
        int(payload.get("daily_cap", factory_implement.DEFAULT_DAILY_IMPLEMENT_CAP)),
    )


def main() -> int:
    args = parse_args()
    validate_args(args)
    if args.fixtures_dir is not None:
        plan = load_fixture_plan(args.fixtures_dir)
        print_plan(plan)
        print(f"Dry run: {len(plan.dispatch)} dispatch(es) planned; no writes.")
        return 0

    repository = factory_implement.require_env("GITHUB_REPOSITORY")
    token = factory_implement.require_env("GH_TOKEN")
    daily_cap = factory_implement.parse_daily_cap(
        os.environ.get("FACTORY_IMPLEMENT_DAILY_CAP")
    )
    client = GitHubClient(repository, token)
    owner = repository.split("/", 1)[0]
    day = datetime.now(UTC).date().isoformat()
    daily_run_count = factory_implement.count_daily_runs(
        client.workflow_runs_on("factory-implement.yml", day),
        current_run_id="",
        current_run_attempt=1,
        repository_owner=owner,
    )
    plan = plan_sweep(eligible_issue_numbers(client, owner), daily_run_count, daily_cap)
    print_plan(plan)
    if args.apply:
        apply_plan(client, plan, args.ref)
        print(f"Dispatched {len(plan.dispatch)} implementation run(s).")
    else:
        print(f"Dry run: {len(plan.dispatch)} dispatch(es) planned; no writes.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FactorySweepError, factory_implement.FactoryImplementError) as error:
        # main() calls into factory_implement (require_env, parse_daily_cap,
        # and every GitHubClient/GraphQL call the sweep makes), any of which
        # can raise its own error type — both need the same clean exit here
        # rather than one of them escaping as a raw traceback.
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
