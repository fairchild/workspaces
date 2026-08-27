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

from evidence import extract_requested_evidence  # noqa: E402
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

# Identity GitHub assigns as `github.actor` when a workflow_dispatch call is
# made with the default GITHUB_TOKEN from inside another Actions run — this is
# how the Monitor's standing-queue sweep (scripts/factory-sweep.py) re-fires
# factory-implement.yml. Trusting this trigger actor does not widen who can
# get code executed: verify_release_actor still requires the issue timeline's
# most recent `ready` label event to be actor-attributed to the repository
# owner, and only the owner can make that event exist. The sweep only ever
# re-evaluates standing admitted state; it never applies `ready` itself.
FACTORY_SWEEP_ACTOR = "github-actions[bot]"

# The App identity the claim and rollback steps mutate labels with. A `ready`
# event attributed to it is factory bookkeeping -- the claim's removal, or
# rollback's restore after a failed run -- rather than a release or a
# revocation. Identity alone is not treated as proof of either: see
# owner_release_event, which requires the surrounding events to have the shape
# a real claim-then-rollback leaves behind.
FACTORY_LABEL_ACTORS = frozenset({"april-clearwater[bot]"})

# Negative admission outcomes split on whether a retry can ever succeed.
# Terminal declines strip `ready` so the release cannot refire a run the
# factory will always refuse; transient deferrals keep `ready` because the
# blocking condition (WIP capacity, daily budget) clears on its own and the
# Owner's release stays valid. Admission only ever removes `ready` — applying
# it remains Owner-only, matching the janitor's release-gate invariant.
TERMINAL_DECLINES = frozenset({"privileged", "no_evidence_contract"})
TRANSIENT_DEFERRALS = frozenset({"wip", "budget"})

# Admission comments speak as the pipeline stage, not as a contributor
# persona: no contributor ran, so persona attribution would misattribute.
PRIVILEGED_COMMENT = (
    "Factory admission: declined — this issue indicates privileged-path scope "
    "and requires the orchestrator lane. Removing `ready`; the factory cannot "
    "take this issue."
)
NO_EVIDENCE_CONTRACT_COMMENT = (
    "Factory admission: declined — this issue has no `## Requested Evidence` "
    "section with at least one item, and the contributor runtime refuses to "
    "execute without one. Removing `ready`; add the section and re-release.\n\n"
    "Each bullet states one thing that must be true for the change to be "
    "believed, for example:\n\n"
    "```markdown\n"
    "## Requested Evidence\n"
    "- `swift test --filter WorkspaceStoreTests` passes\n"
    "- CI: `Lint, Test, Build` green on the PR head\n"
    "```"
)
TERMINAL_DECLINE_COMMENTS = {
    "privileged": PRIVILEGED_COMMENT,
    "no_evidence_contract": NO_EVIDENCE_CONTRACT_COMMENT,
}
WIP_COMMENT = (
    f"Factory admission: deferred — the {FACTORY_WIP_CAP}-issue factory WIP "
    "cap is full; leaving this issue ready."
)
BUDGET_COMMENT_MARKER = "<!-- factory-implement-budget-skip -->"
# No trailing "-->": stale_scope_marker() below scopes each marker to its
# release cycle's ready timestamp, so a fresh hostile edit after a later
# owner re-release gets its own comment instead of being deduped against an
# earlier, now-superseded warning.
STALE_SCOPE_COMMENT_MARKER = "<!-- factory-implement-stale-scope"


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

    def graphql(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            "https://api.github.com/graphql",
            data=json.dumps({"query": query, "variables": variables}).encode("utf-8"),
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "workspaces-factory-implement",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise FactoryImplementError(
                f"GitHub GraphQL HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise FactoryImplementError(
                f"GitHub GraphQL request failed: {error.reason}"
            ) from error
        except json.JSONDecodeError as error:
            raise FactoryImplementError("GitHub GraphQL returned invalid JSON") from error
        if payload.get("errors"):
            messages = "; ".join(str(item.get("message", item)) for item in payload["errors"])
            raise FactoryImplementError(f"GitHub GraphQL error: {messages}")
        return payload

    def user_content_edits_since(self, issue_number: int, since: str) -> list[dict[str, Any]]:
        """All content edits at-or-after `since`, newest first.

        REST's issue Timeline API has no event for body/title edits (only
        `renamed` for titles) — userContentEdits is the only GitHub API that
        exposes who last touched an issue's actual content, which is what
        binds admission to the content the owner actually reviewed.
        userContentEdits' natural connection order is newest-first (verified
        live against this repo's own GraphQL API — the opposite of most
        GitHub connections), so `first`/`after` is what pages forward from
        the most recent edit toward the oldest; `last`/`before` would instead
        walk toward *older* edits from an already-oldest starting point. A
        single `first: 50` page isn't enough on its own: a hostile edit can
        sit behind 50 even-newer (e.g. owner) edits, so this keeps paging
        forward until it finds an edit strictly before `since` — nothing
        further in the (still-descending) connection could be relevant
        either — or history is exhausted.

        `since`/`editedAt` comparisons use `<` as the exclusion boundary, not
        `<=`: GitHub timestamps are second-precision, so an edit landing in
        the same second as `since` must count as at-or-after it, not before.
        """
        owner, name = self.repository.split("/", 1)
        query = """
query FactoryImplementIssueEdits(
  $owner: String!, $name: String!, $number: Int!, $after: String
) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      userContentEdits(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { editor { login } editedAt }
      }
    }
  }
}
"""
        relevant: list[dict[str, Any]] = []
        after: str | None = None
        while True:
            payload = self.graphql(
                query,
                {"owner": owner, "name": name, "number": issue_number, "after": after},
            )
            repository = (payload.get("data") or {}).get("repository")
            if repository is None:
                raise FactoryImplementError(f"repository {self.repository} was not found")
            issue = repository.get("issue")
            if issue is None:
                raise FactoryImplementError(
                    f"issue #{issue_number} was not found via GraphQL"
                )
            connection = issue.get("userContentEdits")
            if connection is None:
                # A genuinely empty edit history is a non-null connection
                # with nodes: [] per GitHub's schema — null here means the
                # query didn't resolve as expected, not "no edits".
                raise FactoryImplementError(
                    f"issue #{issue_number} userContentEdits was null"
                )
            nodes = connection.get("nodes")
            if nodes is None:
                raise FactoryImplementError(
                    f"issue #{issue_number} userContentEdits.nodes was null"
                )
            crossed_boundary = False
            for node in nodes:  # newest-first within the page
                edited_at = str(node.get("editedAt") or "")
                if edited_at and edited_at < since:
                    crossed_boundary = True
                    break
                relevant.append(dict(node))
            page_info = connection.get("pageInfo") or {}
            if crossed_boundary or not page_info.get("hasNextPage"):
                return relevant
            after = page_info.get("endCursor")

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
    if not extract_requested_evidence(str(issue.get("body") or "")):
        # The contributor runtime refuses to execute without an explicit
        # contract (FACTORY_REQUIRE_EXPLICIT_EVIDENCE, set on every factory
        # run). Catching it here instead costs one API read; catching it there
        # costs a claim, a branch name, an isolated scratch, and a model
        # invocation, and leaves the issue `claimed` until rollback.
        return ClaimDecision(
            "no_evidence_contract",
            "issue has no Requested Evidence contract",
        )
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


def stale_scope_marker(ready_created_at: str) -> str:
    return f"{STALE_SCOPE_COMMENT_MARKER}:{ready_created_at} -->"


def stale_scope_comment(editor: str, ready_created_at: str) -> str:
    return (
        stale_scope_marker(ready_created_at)
        + "\n"
        + "Factory admission: deferred — this issue's title or body was edited "
        + f"by @{editor} after the owner's most recent `ready` release; leaving "
        + "this issue ready pending a fresh review. Re-apply `ready` after "
        + "confirming the current content is still what should ship."
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
    trusted_actors = (
        {repository_owner.casefold(), FACTORY_SWEEP_ACTOR.casefold()}
        if repository_owner
        else set()
    )
    actor_matches = not repository_owner or actor.casefold() in trusted_actors
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


def latest_ready_event(events: list[dict[str, Any]]) -> dict[str, Any] | None:
    for event in reversed(events):
        if str(event.get("event", "")).casefold() != "labeled":
            continue
        if str((event.get("label") or {}).get("name", "")).casefold() != "ready":
            continue
        return event
    return None


def ready_label_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Every `ready` add and removal, oldest first.

    Sorted by `created_at` rather than trusting the timeline's order: the
    REST timeline reads chronologically today but GitHub documents no sort
    guarantee, and offset pagination is not a snapshot. This sequence decides
    admission, so its order comes from the timestamps.
    """
    relevant = [
        event
        for event in events
        if str(event.get("event", "")).casefold() in {"labeled", "unlabeled"}
        and str((event.get("label") or {}).get("name", "")).casefold() == "ready"
    ]
    return sorted(
        relevant,
        key=lambda event: (str(event.get("created_at") or ""), int(event.get("id") or 0)),
    )


def owner_release_event(
    events: list[dict[str, Any]],
    repository_owner: str,
) -> dict[str, Any] | None:
    """The owner `ready` release this issue's current admission rests on.

    Walks `ready` adds and removals newest-first and accepts only the exact
    shape a real factory retry leaves behind: an owner release, the claim's
    own factory-attributed removal, and rollback's factory-attributed restore.
    Anything else terminates the walk and returns None.

    Both halves of that shape matter. Skipping the restore is what stops a
    failed run from locking the issue's front door -- before this, the newest
    `ready` event on a retried issue was bot-attributed, so every later firing,
    including the documented owner `workflow_dispatch` recovery, was refused
    until a human cycled the label. Requiring the removal underneath it is what
    keeps identity from standing in for provenance: the factory's App token is
    held by several lanes, and a `ready` applied by one of them on an issue
    that was never claimed is not a restore of anything.

    A removal by anyone else is a revocation and ends the lineage, so an owner
    who withdraws `ready` mid-claim cannot have that release replayed by the
    retry that follows.

    Returning the owner's own event, not the restore, keeps the
    content-staleness boundary honest: `ready` comes back minutes to hours
    later, and the content the owner reviewed is the content as of their
    release.
    """
    owner = repository_owner.casefold()
    factory = {actor.casefold() for actor in FACTORY_LABEL_ACTORS}
    # Set after stepping over a factory restore: the only thing that may sit
    # underneath one is the claim removal it is undoing.
    awaiting_claim_removal = False
    for event in reversed(ready_label_events(events)):
        action = str(event.get("event", "")).casefold()
        actor = str((event.get("actor") or {}).get("login") or "").casefold()
        factory_actor = actor in factory
        if action == "labeled" and actor == owner:
            return None if awaiting_claim_removal else event
        if action == "labeled" and factory_actor:
            awaiting_claim_removal = True
            continue
        if action == "unlabeled" and factory_actor:
            awaiting_claim_removal = False
            continue
        return None
    return None


def latest_non_owner_editor(
    edits: list[dict[str, Any]],
    repository_owner: str,
) -> str | None:
    """The most recent non-owner editor among `edits`.

    `edits` is expected already bounded to "at or after the release point"
    and ordered newest-first, both by the caller (see
    GitHubClient.user_content_edits_since) — so the first non-owner match
    found here is the most recent one. Returns None when every edit belongs
    to the owner (or there are none) — an edit with a missing/deleted editor
    is treated as untrusted, since it can't be verified as the owner.
    """
    owner = repository_owner.casefold()
    for edit in edits:
        editor = edit.get("editor") or {}
        login = str(editor.get("login") or "") if isinstance(editor, dict) else ""
        if login.casefold() == owner:
            continue
        return login or "an unidentified editor"
    return None


def verify_release_actor(
    events: list[dict[str, Any]],
    trigger_actor: str,
    repository_owner: str,
) -> str:
    owner = repository_owner.strip()
    if not owner:
        raise FactoryImplementError("FACTORY_REPOSITORY_OWNER is required")
    # The trigger actor may be the owner (manual dispatch or the `ready` label
    # event itself) or the Monitor sweep's automation identity. Either way,
    # admission is decided below by the immutable ready-label timeline event,
    # never by who happened to trigger this particular run.
    trusted_triggers = {owner.casefold(), FACTORY_SWEEP_ACTOR.casefold()}
    if trigger_actor.casefold() not in trusted_triggers:
        raise FactoryImplementError(
            f"Factory implementation trigger actor {trigger_actor!r} is not "
            "repository owner or the factory sweep"
        )
    if latest_ready_event(events) is None:
        raise FactoryImplementError("issue timeline has no ready label event")
    release = owner_release_event(events, owner)
    if release is None:
        blocking = str((latest_ready_event(events).get("actor") or {}).get("login") or "")
        raise FactoryImplementError(
            f"most recent ready label actor {blocking!r} is not repository owner"
        )
    return str((release.get("actor") or {}).get("login") or "")


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
    events = client.timeline(issue_number)
    verified_actor = verify_release_actor(events, trigger_actor, repository_owner)

    # The owner reviewed and approved *content*, not just a label. A sweep can
    # re-fire this issue long after that review, so a non-owner editing the
    # title/body in between (issue authors and collaborators can both do
    # this) must not ride the earlier owner approval — REST's issue timeline
    # has no event for body/title edits, so userContentEdits is the only way
    # to see who touched the content and when.
    ready_event = owner_release_event(events, repository_owner)
    if ready_event is None:
        # Unreachable: verify_release_actor above already raised unless an
        # owner release exists in these same `events`.
        raise FactoryImplementError("issue timeline has no owner ready release")
    hostile_editor = latest_non_owner_editor(
        client.user_content_edits_since(
            issue_number,
            # `events` comes from client.timeline(), a REST call — REST uses
            # snake_case (created_at), unlike the GraphQL createdAt this file
            # otherwise doesn't use. Verified against a live timeline response.
            str(ready_event["created_at"]),
        ),
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
    decision = (
        ClaimDecision("stale_scope", f"content edited by {hostile_editor} after release")
        if hostile_editor is not None
        else evaluate_claim(
            issue,
            claimed_count,
            daily_run_count=daily_run_count,
            daily_cap=daily_cap,
        )
    )
    print(f"Factory implement decision for #{issue_number}: {decision.action} ({decision.reason})")
    write_output("issue_number", str(issue_number))
    write_output("matched", "false")
    write_output("issue_scope_digest", issue_scope_digest(issue))
    write_output("verified_actor", verified_actor)
    if decision.action in TERMINAL_DECLINES:
        comment_once(client, issue_number, TERMINAL_DECLINE_COMMENTS[decision.action])
        client.update_issue(issue_number, decline_payload(issue))
        return
    if decision.action == "stale_scope":
        ready_created_at = str(ready_event["created_at"])
        comment_once(
            client,
            issue_number,
            stale_scope_comment(hostile_editor, ready_created_at),
            dedupe_key=stale_scope_marker(ready_created_at),
        )
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
