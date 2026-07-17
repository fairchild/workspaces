#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claim and recover Agent Factory implementation dispatches.

The workflow-facing CLI keeps issue admission, WIP enforcement, and lifecycle
mutations deterministic before the contributor runtime receives credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


CONTRIBUTOR_SCRIPTS = (
    Path(__file__).resolve().parents[1]
    / ".agents"
    / "skills"
    / "cofounder-contributor"
    / "scripts"
)
if str(CONTRIBUTOR_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(CONTRIBUTOR_SCRIPTS))

from patch_policy import (  # noqa: E402
    issue_body_path_candidates,
    issue_scope_digest,
    sensitive_agent_patch_paths,
)


FACTORY_WIP_CAP = 2
DEFAULT_DAILY_IMPLEMENT_CAP = 6
PRIVILEGED_PATCH_LABEL = "privileged-agent-patch"
API_ATTEMPTS = 3
API_BACKOFF_SECONDS = 1.0
APRIL_ATTRIBUTION = "*April Clearwater, Application Lead*\n\n"

# Negative admission outcomes split on whether a retry can ever succeed.
# Terminal declines strip `ready` so the release cannot refire a run the
# factory will always refuse; transient deferrals keep `ready` because the
# blocking condition (WIP capacity, daily budget) clears on its own and the
# Owner's release stays valid. Admission only ever removes `ready` — applying
# it remains Owner-only, matching the janitor's release-gate invariant.
TERMINAL_DECLINES = frozenset({"privileged"})
TRANSIENT_DEFERRALS = frozenset({"wip", "budget"})

# Admission comments speak as the pipeline stage, not as a contributor
# persona: no contributor ran, so persona attribution would misattribute.
PRIVILEGED_COMMENT = (
    "Factory admission: declined — this issue indicates privileged-path scope "
    "and requires the orchestrator lane. Removing `ready`; the factory cannot "
    "take this issue."
)
WIP_COMMENT = (
    f"Factory admission: deferred — the {FACTORY_WIP_CAP}-issue factory WIP "
    "cap is full; leaving this issue ready."
)
BUDGET_COMMENT_MARKER = "<!-- factory-implement-budget-skip -->"


class FactoryImplementError(RuntimeError):
    """Raised when a dispatch cannot be evaluated or mutated safely."""


@dataclass(frozen=True)
class ClaimDecision:
    action: str
    reason: str


class GitHubClient:
    def __init__(self, repository: str, token: str) -> None:
        if len(repository.split("/", 1)) != 2:
            raise FactoryImplementError("GITHUB_REPOSITORY must be set to owner/name")
        self.repository = repository
        self.token = token
        self.api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        body = b""
        for attempt in range(1, API_ATTEMPTS + 1):
            data = None if payload is None else json.dumps(payload).encode("utf-8")
            request = urllib.request.Request(
                f"{self.api_url}{path}",
                data=data,
                headers={
                    "Accept": "application/vnd.github+json",
                    "Authorization": f"Bearer {self.token}",
                    "Content-Type": "application/json",
                    "User-Agent": "workspaces-factory-implement",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
                method=method,
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    body = response.read()
                break
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")
                transient = error.code == 429 or 500 <= error.code < 600
                if not transient or attempt == API_ATTEMPTS:
                    raise FactoryImplementError(
                        f"GitHub API {method} {path} failed with HTTP "
                        f"{error.code}: {detail}"
                    ) from error
            except urllib.error.URLError as error:
                if attempt == API_ATTEMPTS:
                    raise FactoryImplementError(
                        f"GitHub API {method} {path} failed: {error.reason}"
                    ) from error
            delay = API_BACKOFF_SECONDS * (2 ** (attempt - 1))
            print(
                f"Retrying GitHub API {method} {path} after {delay:.1f}s",
                file=sys.stderr,
            )
            time.sleep(delay)
        if not body:
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError as error:
            raise FactoryImplementError(
                f"GitHub API {method} {path} returned invalid JSON"
            ) from error

    def issue(self, number: int) -> dict[str, Any]:
        return dict(self.request("GET", f"/repos/{self.repository}/issues/{number}"))

    def comments(self, number: int) -> list[dict[str, Any]]:
        comments: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = list(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/issues/{number}/comments"
                    f"?per_page=100&page={page}",
                )
            )
            comments.extend(dict(comment) for comment in batch)
            if len(batch) < 100:
                return comments
            page += 1

    def timeline(self, number: int) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = list(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/issues/{number}/timeline"
                    f"?per_page=100&page={page}",
                )
            )
            events.extend(dict(event) for event in batch)
            if len(batch) < 100:
                return events
            page += 1

    def claimed_issues(self) -> list[dict[str, Any]]:
        labels = urllib.parse.quote("agent,task,claimed")
        items = self.request(
            "GET",
            f"/repos/{self.repository}/issues?state=open&labels={labels}&per_page=100",
        )
        return [dict(item) for item in items if "pull_request" not in item]

    def update_issue(self, number: int, payload: dict[str, Any]) -> None:
        self.request("PATCH", f"/repos/{self.repository}/issues/{number}", payload)

    def add_assignees(self, number: int, assignees: list[str]) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/issues/{number}/assignees",
            {"assignees": assignees},
        )

    def remove_assignees(self, number: int, assignees: list[str]) -> None:
        self.request(
            "DELETE",
            f"/repos/{self.repository}/issues/{number}/assignees",
            {"assignees": assignees},
        )

    def comment(self, number: int, body: str) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/issues/{number}/comments",
            {"body": body},
        )

    def workflow_runs_on(self, workflow: str, day: str) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        page = 1
        while True:
            query = urllib.parse.urlencode(
                {"created": day, "per_page": 100, "page": page}
            )
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


def label_names(issue: dict[str, Any]) -> set[str]:
    return {
        str(label.get("name", ""))
        for label in issue.get("labels", []) or []
        if isinstance(label, dict)
    }


def privileged_scope(issue: dict[str, Any]) -> bool:
    if PRIVILEGED_PATCH_LABEL in label_names(issue):
        return True
    issue_text = "\n".join(
        (str(issue.get("title") or ""), str(issue.get("body") or ""))
    )
    candidates = issue_body_path_candidates(issue_text)
    return bool(sensitive_agent_patch_paths(candidates))


def evaluate_claim(
    issue: dict[str, Any],
    claimed_count: int,
    *,
    daily_run_count: int = 0,
    daily_cap: int = DEFAULT_DAILY_IMPLEMENT_CAP,
) -> ClaimDecision:
    labels = label_names(issue)
    if str(issue.get("state", "")).casefold() != "open":
        return ClaimDecision("skip", "issue is not open")
    missing = {"agent", "task", "ready"} - labels
    if missing:
        return ClaimDecision("skip", f"issue is missing labels: {', '.join(sorted(missing))}")
    conflicting = {"claimed", "review"} & labels
    if conflicting:
        return ClaimDecision(
            "skip",
            f"issue has conflicting labels: {', '.join(sorted(conflicting))}",
        )
    if privileged_scope(issue):
        return ClaimDecision("privileged", "issue indicates privileged-path scope")
    if daily_run_count > daily_cap:
        return ClaimDecision(
            "budget",
            f"daily implementation cap of {daily_cap} is exceeded ({daily_run_count} runs)",
        )
    if claimed_count >= FACTORY_WIP_CAP:
        return ClaimDecision("wip", f"factory WIP cap of {FACTORY_WIP_CAP} is full")
    return ClaimDecision("claim", "issue is eligible for unattended implementation")


def claim_payload(issue: dict[str, Any]) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"ready", "claimed"}) | {"claimed"})
    return {"labels": labels}


def rollback_payload(issue: dict[str, Any]) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"claimed", "ready"}) | {"ready"})
    return {"labels": labels}


def decline_payload(issue: dict[str, Any]) -> dict[str, Any]:
    return {"labels": sorted(label_names(issue) - {"ready"})}


def sync_claim_assignee(
    client: GitHubClient,
    issue_number: int,
    assignee: str,
    *,
    add: bool,
) -> None:
    # Best-effort visibility only: GitHub rejects agent-account assignment from
    # App installation tokens, and claim state lives in the label + bot comment.
    try:
        if add:
            client.add_assignees(issue_number, [assignee])
        else:
            client.remove_assignees(issue_number, [assignee])
    except FactoryImplementError as error:
        verb = "assignment" if add else "unassignment"
        print(
            f"Factory implement {verb} of {assignee} on #{issue_number} skipped: {error}",
            file=sys.stderr,
        )


def comment_once(
    client: GitHubClient,
    issue_number: int,
    body: str,
    *,
    dedupe_key: str | None = None,
) -> None:
    identity = dedupe_key or body
    if any(
        identity in str(comment.get("body", ""))
        for comment in client.comments(issue_number)
    ):
        return
    client.comment(issue_number, body)


def budget_skip_comment(daily_run_count: int, daily_cap: int) -> str:
    return (
        BUDGET_COMMENT_MARKER
        + "\n"
        + "Factory admission: deferred — "
        + f"{daily_run_count} implementation runs have started today, above the "
        + f"configured daily cap of {daily_cap}; leaving this issue ready. "
        + "The workflow log records the skip."
    )


def parse_daily_cap(value: str | None) -> int:
    raw = (value or str(DEFAULT_DAILY_IMPLEMENT_CAP)).strip()
    try:
        cap = int(raw)
    except ValueError as error:
        raise FactoryImplementError(
            f"FACTORY_IMPLEMENT_DAILY_CAP must be a positive integer, got {raw!r}"
        ) from error
    if cap <= 0:
        raise FactoryImplementError("FACTORY_IMPLEMENT_DAILY_CAP must be a positive integer")
    return cap


def is_factory_implement_dispatch(
    run: dict[str, Any],
    repository_owner: str = "",
) -> bool:
    actor = str((run.get("actor") or {}).get("login") or "")
    actor_matches = not repository_owner or actor.casefold() == repository_owner.casefold()
    return actor_matches and (
        str(run.get("event", "")) == "workflow_dispatch"
        or str(run.get("display_title", "")).startswith("Factory Implement ready #")
    )


def count_daily_runs(
    runs: list[dict[str, Any]],
    current_run_id: str,
    current_run_attempt: int = 1,
    repository_owner: str = "",
) -> int:
    attempts_by_run = {
        str(run["id"]): max(1, int(run.get("run_attempt") or 1))
        for run in runs
        if isinstance(run, dict)
        and run.get("id") is not None
        and is_factory_implement_dispatch(run, repository_owner)
    }
    if current_run_id:
        attempts_by_run[current_run_id] = max(
            attempts_by_run.get(current_run_id, 0),
            current_run_attempt,
        )
    return sum(attempts_by_run.values())


def require_automation_switches(global_switch: str, stage_switch: str) -> None:
    if global_switch.casefold() != "true" or stage_switch.casefold() != "true":
        raise FactoryImplementError(
            "Factory implementation is disabled by AGENT_AUTOMATIONS_ENABLED "
            "or FACTORY_IMPLEMENT_ENABLED"
        )


def latest_ready_actor(events: list[dict[str, Any]]) -> str | None:
    for event in reversed(events):
        if str(event.get("event", "")).casefold() != "labeled":
            continue
        if str((event.get("label") or {}).get("name", "")).casefold() != "ready":
            continue
        return str((event.get("actor") or {}).get("login") or "") or None
    return None


def verify_release_actor(
    events: list[dict[str, Any]],
    trigger_actor: str,
    repository_owner: str,
) -> str:
    owner = repository_owner.strip()
    if not owner:
        raise FactoryImplementError("FACTORY_REPOSITORY_OWNER is required")
    if trigger_actor.casefold() != owner.casefold():
        raise FactoryImplementError(
            f"Factory implementation trigger actor {trigger_actor!r} is not repository owner"
        )
    ready_actor = latest_ready_actor(events)
    if ready_actor is None:
        raise FactoryImplementError("issue timeline has no ready label event")
    if ready_actor.casefold() != owner.casefold():
        raise FactoryImplementError(
            f"most recent ready label actor {ready_actor!r} is not repository owner"
        )
    return ready_actor


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    else:
        print(f"{name}={value}")


def slugify(value: str, *, max_length: int = 48) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    return (slug[:max_length].rstrip("-") or "task")


def claim_branch(issue: dict[str, Any]) -> str:
    number = int(issue["number"])
    title = slugify(str(issue.get("title") or f"issue-{number}"))
    return f"codex/april-clearwater-issue-{number}-{title}"


def claim_comment(issue: dict[str, Any], run_url: str) -> str:
    number = int(issue["number"])
    branch = claim_branch(issue)
    marker = (
        f"<!-- contributor:issue={number};status=claimed;"
        f"agent=april-clearwater;branch={branch} -->"
    )
    return (
        "*April Clearwater, Application Lead*\n\n"
        f"Claiming this issue for execution on `{branch}`.\n\n"
        f"Workflow run: {run_url}\n\n{marker}"
    )


def latest_factory_claim_run(
    comments: list[dict[str, Any]],
    trusted_author: str,
) -> str | None:
    prefix = "Workflow run: "
    for comment in reversed(comments):
        author = str((comment.get("user") or {}).get("login") or "")
        if author.casefold() != trusted_author.casefold():
            continue
        body = str(comment.get("body") or "")
        if "agent=april-clearwater;branch=" not in body:
            continue
        line = next((line for line in body.splitlines() if line.startswith(prefix)), "")
        return line.removeprefix(prefix).strip() or None
    return None


def claim(
    client: GitHubClient,
    actions_client: GitHubClient,
    issue_number: int,
    run_url: str,
    assignee: str,
    trigger_actor: str,
    repository_owner: str,
    global_switch: str,
    stage_switch: str,
    daily_cap: int,
    current_run_id: str,
    current_run_attempt: int,
) -> None:
    require_automation_switches(global_switch, stage_switch)
    issue = client.issue(issue_number)
    verified_actor = verify_release_actor(
        client.timeline(issue_number),
        trigger_actor,
        repository_owner,
    )
    claimed_count = len(client.claimed_issues())
    day = datetime.now(UTC).date().isoformat()
    daily_run_count = count_daily_runs(
        actions_client.workflow_runs_on("factory-implement.yml", day),
        current_run_id,
        current_run_attempt,
        repository_owner,
    )
    decision = evaluate_claim(
        issue,
        claimed_count,
        daily_run_count=daily_run_count,
        daily_cap=daily_cap,
    )
    print(f"Factory implement decision for #{issue_number}: {decision.action} ({decision.reason})")
    write_output("issue_number", str(issue_number))
    write_output("matched", "false")
    write_output("issue_scope_digest", issue_scope_digest(issue))
    write_output("verified_actor", verified_actor)
    if decision.action in TERMINAL_DECLINES:
        comment_once(client, issue_number, PRIVILEGED_COMMENT)
        client.update_issue(issue_number, decline_payload(issue))
        return
    if decision.action in TRANSIENT_DEFERRALS:
        if decision.action == "wip":
            comment_once(client, issue_number, WIP_COMMENT)
        else:
            comment_once(
                client,
                issue_number,
                budget_skip_comment(daily_run_count, daily_cap),
                dedupe_key=BUDGET_COMMENT_MARKER,
            )
        return
    if decision.action == "skip":
        return

    client.comment(issue_number, claim_comment(issue, run_url))
    client.update_issue(issue_number, claim_payload(issue))
    sync_claim_assignee(client, issue_number, assignee, add=True)
    write_output("matched", "true")


def authorize_execution(
    actions_client: GitHubClient,
    daily_cap: int,
    current_run_id: str,
    current_run_attempt: int,
    global_switch: str,
    stage_switch: str,
    repository_owner: str,
) -> None:
    require_automation_switches(global_switch, stage_switch)
    day = datetime.now(UTC).date().isoformat()
    daily_run_count = count_daily_runs(
        actions_client.workflow_runs_on("factory-implement.yml", day),
        current_run_id,
        current_run_attempt,
        repository_owner,
    )
    print(f"Factory implement execution budget: {daily_run_count}/{daily_cap}")
    if daily_run_count > daily_cap:
        raise FactoryImplementError(
            f"daily implementation cap of {daily_cap} is exceeded "
            f"({daily_run_count} run attempts)"
        )


def rollback(
    client: GitHubClient,
    issue_number: int,
    run_url: str,
    assignee: str,
) -> None:
    issue = client.issue(issue_number)
    if "claimed" not in label_names(issue):
        print(f"Factory implement rollback for #{issue_number}: claim is no longer active")
        return
    if latest_factory_claim_run(client.comments(issue_number), assignee) != run_url:
        print(f"Factory implement rollback for #{issue_number}: claim belongs to another run")
        return
    client.update_issue(issue_number, rollback_payload(issue))
    sync_claim_assignee(client, issue_number, assignee, add=False)
    comment_once(
        client,
        issue_number,
        APRIL_ATTRIBUTION
        + f"Factory implementation run failed and restored ready: {run_url}",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("claim", "rollback"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--issue", type=int, required=True)
        subparser.add_argument("--run-url", required=True)
    subparsers.add_parser("authorize")
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryImplementError(f"{name} is required")
    return value


def main() -> int:
    args = parse_args()
    repository = require_env("GITHUB_REPOSITORY")
    daily_cap = parse_daily_cap(os.environ.get("FACTORY_IMPLEMENT_DAILY_CAP"))
    current_run_id = os.environ.get("GITHUB_RUN_ID", "").strip()
    current_run_attempt = int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    global_switch = os.environ.get("AGENT_AUTOMATIONS_ENABLED", "")
    stage_switch = os.environ.get("FACTORY_IMPLEMENT_ENABLED", "")
    if args.command == "authorize":
        authorize_execution(
            GitHubClient(repository, require_env("FACTORY_ACTIONS_TOKEN")),
            daily_cap,
            current_run_id,
            current_run_attempt,
            global_switch,
            stage_switch,
            require_env("FACTORY_REPOSITORY_OWNER"),
        )
        return 0

    client = GitHubClient(repository, require_env("GH_TOKEN"))
    if args.command == "claim":
        assignee = require_env("FACTORY_CLAIM_ASSIGNEE")
        actions_client = GitHubClient(
            repository,
            require_env("FACTORY_ACTIONS_TOKEN"),
        )
        claim(
            client,
            actions_client,
            args.issue,
            args.run_url,
            assignee,
            require_env("FACTORY_TRIGGER_ACTOR"),
            require_env("FACTORY_REPOSITORY_OWNER"),
            global_switch,
            stage_switch,
            daily_cap,
            current_run_id,
            current_run_attempt,
        )
    elif args.command == "rollback":
        assignee = require_env("FACTORY_CLAIM_ASSIGNEE")
        rollback(client, args.issue, args.run_url, assignee)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FactoryImplementError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
