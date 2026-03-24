#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Synchronize execution-state labels for planned contributor issues."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[4]
GITHUB_API_TIMEOUT = 30
STALE_CLAIM_HOURS = 24

WORK_STATE_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 30, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        comments(last: 20) {
          nodes {
            id
            body
            createdAt
            author { login }
            authorAssociation
            reactionGroups {
              content
              users(first: 20) {
                nodes { login }
              }
            }
          }
        }
      }
    }
    issues(first: 80, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        url
        body
        labels(first: 20) {
          nodes { name }
        }
        comments(last: 20) {
          nodes {
            body
            createdAt
            author { login }
            authorAssociation
          }
        }
        assignees(first: 5) {
          nodes { login }
        }
      }
    }
    pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        body
      }
    }
  }
}
"""

TASK_ISSUE_MARKER_RE = re.compile(
    r"<!-- peter-planner:discussion=(?P<number>\d+);issue=(?P<slug>[a-z0-9-]+) -->"
)
PETER_PLANNED_MARKER_RE = re.compile(
    r"<!-- peter-planner:discussion=(?P<number>\d+);status=planned -->"
)
CLAIM_MARKER_RE = re.compile(
    r"<!-- contributor:issue=(?P<number>\d+);status=(?P<status>[a-z_]+);agent=(?P<agent>[a-z0-9-]+);branch=(?P<branch>[^>\n]+) -->"
)
CLOSING_REFERENCE_RE = re.compile(
    r"(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(?P<number>\d+)\b"
)

AGENT_READY_LABEL = "agent:ready"
AGENT_READY_LABEL_COLOR = "5319e7"
AGENT_READY_LABEL_DESCRIPTION = "Execution-approved and ready for an automated contributor to claim"
AGENT_CLAIM_LABEL = "agent:claimed"
AGENT_CLAIM_LABEL_COLOR = "1d76db"
AGENT_CLAIM_LABEL_DESCRIPTION = "Currently being executed by an automated contributor"
AGENT_REVIEW_LABEL = "agent:review"
AGENT_REVIEW_LABEL_COLOR = "fbca04"
AGENT_REVIEW_LABEL_DESCRIPTION = "PR opened, awaiting review"
TRUSTED_AUTHOR_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
TRUSTED_AUTOMATION_LOGINS = {
    "april-clearwater[bot]",
    "claude[bot]",
    "github-actions[bot]",
    "plat-ironwood[bot]",
    "workspace-agents",
    "workspace-agents[bot]",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def log(message: str) -> None:
    print(f"[sync-execution-state] {message}", file=sys.stderr)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"error: required environment variable {name} is not set", file=sys.stderr)
        raise SystemExit(1)
    return value


def run_checked(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=cwd,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        command = " ".join(cmd)
        print(f"error: command timed out after {exc.timeout}s: {command}", file=sys.stderr)
        raise SystemExit(1) from exc
    if result.returncode != 0:
        command = " ".join(cmd)
        print(f"error: command failed: {command}", file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        raise SystemExit(result.returncode or 1)
    return result


def repo_owner_name(env: dict[str, str]) -> tuple[str, str]:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
        return owner, name

    result = run_checked(
        ["gh", "repo", "view", "--json", "owner,name"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    data = json.loads(result.stdout)
    return data["owner"]["login"], data["name"]


def fetch_work_state(owner: str, name: str, env: dict[str, str]) -> dict[str, list[dict[str, object]]]:
    result = run_checked(
        [
            "gh",
            "api",
            "graphql",
            "-f",
            f"query={WORK_STATE_QUERY}",
            "-f",
            f"owner={owner}",
            "-f",
            f"name={name}",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    data = json.loads(result.stdout)
    repository = data.get("data", {}).get("repository", {})
    return {
        "discussions": repository.get("discussions", {}).get("nodes", []),
        "issues": repository.get("issues", {}).get("nodes", []),
        "pull_requests": repository.get("pullRequests", {}).get("nodes", []),
    }


def fetch_issue_state_map(env: dict[str, str]) -> dict[int, str]:
    result = run_checked(
        [
            "gh",
            "issue",
            "list",
            "--state",
            "all",
            "--limit",
            "200",
            "--json",
            "number,state",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    return {
        int(item["number"]): str(item["state"])
        for item in json.loads(result.stdout)
    }


def issue_label_names(issue: dict[str, object]) -> set[str]:
    labels = issue.get("labels", {})
    nodes = labels.get("nodes", []) if isinstance(labels, dict) else []
    return {
        str(label.get("name", "")).strip()
        for label in nodes
        if isinstance(label, dict) and str(label.get("name", "")).strip()
    }


def _parse_timestamp(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _normalize_login(login: str) -> str:
    return login.removesuffix("[bot]").strip().casefold()


def trusted_automation_logins() -> set[str]:
    return {login.casefold() for login in TRUSTED_AUTOMATION_LOGINS}


def trusted_comment_author(
    comment: dict[str, object],
    *,
    trusted_logins: set[str] | None = None,
) -> bool:
    if trusted_logins is None:
        trusted_logins = trusted_automation_logins()

    author_association = str(comment.get("authorAssociation", "")).upper()
    if author_association in TRUSTED_AUTHOR_ASSOCIATIONS:
        return True

    author = comment.get("author")
    login = ""
    if isinstance(author, dict):
        login = str(author.get("login", "")).casefold()
    elif isinstance(author, str):
        login = author.casefold()
    return bool(login and login in trusted_logins)


def markdown_section(body: str, heading: str) -> str:
    pattern = rf"(?ms)^## {re.escape(heading)}\n(.*?)(?=^## |\n---\n|\Z)"
    match = re.search(pattern, body)
    if not match:
        return ""
    return match.group(1).strip()


def extract_issue_discussion_number(body: str) -> int | None:
    match = TASK_ISSUE_MARKER_RE.search(body)
    if not match:
        return None
    return int(match.group("number"))


def extract_blocked_by(body: str) -> list[int]:
    blocked_section = markdown_section(body, "Blocked By")
    blocked = [int(number) for number in re.findall(r"#(\d+)", blocked_section)]
    return list(dict.fromkeys(blocked))


def latest_issue_claim(
    issue_number: int,
    comments: dict[str, object],
    *,
    trusted_logins: set[str] | None = None,
) -> dict[str, str] | None:
    nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
    claims: list[dict[str, str]] = []
    for comment in nodes:
        if not isinstance(comment, dict):
            continue
        if not trusted_comment_author(comment, trusted_logins=trusted_logins):
            continue
        match = CLAIM_MARKER_RE.search(str(comment.get("body", "")))
        if not match or int(match.group("number")) != issue_number:
            continue
        claims.append(
            {
                "agent": match.group("agent"),
                "branch": match.group("branch").strip(),
                "status": match.group("status"),
                "createdAt": str(comment.get("createdAt", "")),
            }
        )
    if not claims:
        return None
    return max(claims, key=lambda item: item.get("createdAt", ""))


def claim_is_stale(
    claim: dict[str, str] | None,
    *,
    has_open_pr: bool,
    now: datetime | None = None,
) -> bool:
    if claim is None or has_open_pr:
        return False
    if now is None:
        now = datetime.now(timezone.utc)
    created_at = _parse_timestamp(claim.get("createdAt", ""))
    if created_at is None:
        return False
    return now - created_at >= timedelta(hours=STALE_CLAIM_HOURS)


def extract_pr_issue_reference(body: str) -> int | None:
    match = CLOSING_REFERENCE_RE.search(body)
    if not match:
        return None
    return int(match.group("number"))


def latest_planned_comment(
    discussion: dict[str, object] | None,
    discussion_number: int,
    *,
    trusted_logins: set[str] | None = None,
) -> dict[str, object] | None:
    if discussion is None:
        return None
    comments = discussion.get("comments", {})
    nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
    planned: list[dict[str, object]] = []
    for comment in nodes:
        if not isinstance(comment, dict):
            continue
        if not trusted_comment_author(comment, trusted_logins=trusted_logins):
            continue
        match = PETER_PLANNED_MARKER_RE.search(str(comment.get("body", "")))
        if match and int(match.group("number")) == discussion_number:
            planned.append(comment)
    if not planned:
        return None
    return max(planned, key=lambda item: str(item.get("createdAt", "")))


def planned_comment_has_owner_approval(
    comment: dict[str, object] | None,
    owner_login: str,
) -> bool:
    if comment is None:
        return False
    owner = _normalize_login(owner_login)
    for reaction_group in comment.get("reactionGroups", []) or []:
        if not isinstance(reaction_group, dict):
            continue
        if reaction_group.get("content") != "THUMBS_UP":
            continue
        users = reaction_group.get("users", {})
        nodes = users.get("nodes", []) if isinstance(users, dict) else []
        if any(
            _normalize_login(str(user.get("login", ""))) == owner
            for user in nodes
            if isinstance(user, dict)
        ):
            return True
    return False


def fetch_existing_labels(env: dict[str, str]) -> set[str]:
    result = run_checked(
        ["gh", "label", "list", "--limit", "200", "--json", "name"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    return {item["name"] for item in json.loads(result.stdout)}


def ensure_label(existing: set[str], env: dict[str, str], name: str, color: str, description: str) -> None:
    if name in existing:
        return
    run_checked(
        [
            "gh",
            "label",
            "create",
            name,
            "--color",
            color,
            "--description",
            description,
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    existing.add(name)


def desired_execution_labels(
    issue: dict[str, object],
    *,
    discussions: dict[int, dict[str, object]],
    issue_states: dict[int, str],
    open_pr_issue_numbers: set[int],
    owner_login: str,
    now: datetime,
) -> tuple[set[str], str]:
    labels: set[str] = set()
    trusted_logins = trusted_automation_logins()
    issue_number = int(issue["number"])
    body = str(issue.get("body", ""))
    discussion_number = extract_issue_discussion_number(body)
    if discussion_number is None:
        return labels, "missing Peter marker"

    discussion = discussions.get(discussion_number)
    planned_comment = latest_planned_comment(
        discussion,
        discussion_number,
        trusted_logins=trusted_logins,
    )
    if not planned_comment_has_owner_approval(planned_comment, owner_login):
        return labels, "discussion not execution-approved"

    blocked_by = extract_blocked_by(body)
    blockers = [
        blocker
        for blocker in blocked_by
        if issue_states.get(blocker, "OPEN").upper() != "CLOSED"
    ]
    if blockers:
        return labels, f"blocked by {', '.join(f'#{number}' for number in blockers)}"

    has_open_pr = issue_number in open_pr_issue_numbers
    if has_open_pr:
        labels.add(AGENT_REVIEW_LABEL)
        return labels, "open PR, awaiting review"

    latest_claim = latest_issue_claim(
        issue_number,
        issue.get("comments", {}),
        trusted_logins=trusted_logins,
    )
    if latest_claim is not None and not claim_is_stale(latest_claim, has_open_pr=False, now=now):
        labels.add(AGENT_CLAIM_LABEL)
        return labels, f"actively claimed by {latest_claim['agent']}"

    labels.add(AGENT_READY_LABEL)
    return labels, "execution-approved and ready"


def sync_issue_labels(
    issue_number: int,
    current_labels: set[str],
    desired_labels: set[str],
    *,
    dry_run: bool,
    env: dict[str, str],
) -> bool:
    managed = {AGENT_READY_LABEL, AGENT_CLAIM_LABEL, AGENT_REVIEW_LABEL}
    add_labels = sorted(desired_labels - current_labels)
    remove_labels = sorted((current_labels & managed) - desired_labels)
    if not add_labels and not remove_labels:
        return False

    cmd = ["gh", "issue", "edit", str(issue_number)]
    for label in add_labels:
        cmd.extend(["--add-label", label])
    for label in remove_labels:
        cmd.extend(["--remove-label", label])

    if dry_run:
        log(
            f"Dry run issue #{issue_number}: add={add_labels or ['-']} "
            f"remove={remove_labels or ['-']}"
        )
        return True

    run_checked(cmd, timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    return True


def issue_bot_assignees(issue: dict[str, object]) -> list[str]:
    assignees = issue.get("assignees", {})
    nodes = assignees.get("nodes", []) if isinstance(assignees, dict) else []
    return [
        str(node.get("login", ""))
        for node in nodes
        if isinstance(node, dict) and str(node.get("login", "")).endswith("[bot]")
    ]


def unassign_issue(
    issue_number: int,
    login: str,
    *,
    dry_run: bool,
    env: dict[str, str],
) -> None:
    if dry_run:
        log(f"Dry run: would unassign {login} from #{issue_number}")
        return
    run_checked(
        ["gh", "issue", "edit", str(issue_number), "--remove-assignee", login],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    log(f"Unassigned {login} from #{issue_number} (stale claim)")


def main() -> int:
    args = parse_args()
    require_env("GH_TOKEN")
    env = dict(os.environ)
    owner, name = repo_owner_name(env)
    work_state = fetch_work_state(owner, name, env)
    issue_states = fetch_issue_state_map(env)
    now = datetime.now(timezone.utc)

    existing_labels = fetch_existing_labels(env)
    ensure_label(existing_labels, env, AGENT_READY_LABEL, AGENT_READY_LABEL_COLOR, AGENT_READY_LABEL_DESCRIPTION)
    ensure_label(existing_labels, env, AGENT_CLAIM_LABEL, AGENT_CLAIM_LABEL_COLOR, AGENT_CLAIM_LABEL_DESCRIPTION)
    ensure_label(existing_labels, env, AGENT_REVIEW_LABEL, AGENT_REVIEW_LABEL_COLOR, AGENT_REVIEW_LABEL_DESCRIPTION)

    discussions = {
        int(discussion["number"]): discussion
        for discussion in work_state["discussions"]
        if discussion.get("number") is not None
    }
    open_pr_issue_numbers = {
        issue_number
        for pull_request in work_state["pull_requests"]
        for issue_number in [extract_pr_issue_reference(str(pull_request.get("body", "")))]
        if issue_number is not None
    }

    updated = 0
    for issue in work_state["issues"]:
        current_labels = issue_label_names(issue)
        if "agent:task" not in current_labels:
            continue
        desired_labels, reason = desired_execution_labels(
            issue,
            discussions=discussions,
            issue_states=issue_states,
            open_pr_issue_numbers=open_pr_issue_numbers,
            owner_login=owner,
            now=now,
        )
        changed = sync_issue_labels(
            int(issue["number"]),
            current_labels,
            desired_labels,
            dry_run=args.dry_run,
            env=env,
        )
        if changed:
            updated += 1
            log(
                f"Issue #{issue['number']} -> {sorted(desired_labels) or ['-']} "
                f"({reason})"
            )
        if AGENT_CLAIM_LABEL not in desired_labels and AGENT_REVIEW_LABEL not in desired_labels:
            for assignee in issue_bot_assignees(issue):
                unassign_issue(int(issue["number"]), assignee, dry_run=args.dry_run, env=env)

    log(f"Execution-state sync complete; updated {updated} issue(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
