"""GitHub API calls, GraphQL queries, and state fetching."""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

from _helpers import (
    AGENT_READY_LABEL,
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    _normalize_login,
    _parse_timestamp,
    issue_label_presence,
    markdown_section,
    persona_slug,
    run_checked,
    run_optional,
)
from evidence import (
    extract_requested_evidence,
    validate_evidence_accounting,
)

STALE_CLAIM_HOURS = 24

HISTORY_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title
        reviews(last: 20) {
          nodes { body author { login } authorAssociation submittedAt }
        }
        comments(last: 20) {
          nodes { body author { login } authorAssociation createdAt }
        }
      }
    }
    issues(first: 10, orderBy: {field: UPDATED_AT, direction: DESC}, states: [OPEN]) {
      nodes {
        number title
        comments(last: 20) {
          nodes { body author { login } authorAssociation createdAt }
        }
      }
    }
    discussions(first: 20, states: OPEN) {
      nodes {
        number title body createdAt author { login } authorAssociation
        comments(last: 10) {
          nodes { body author { login } authorAssociation createdAt }
        }
      }
    }
  }
}
"""

WORK_STATE_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 30, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        id
        number
        title
        body
        createdAt
        updatedAt
        category { name }
        author { login }
        authorAssociation
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
          totalCount
        }
      }
    }
    issues(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        url
        body
        state
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
      }
    }
    pullRequests(first: 30, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        url
        body
        isDraft
        reviewDecision
        headRefName
        author { login }
        commits(last: 1) {
          nodes {
            commit { committedDate }
          }
        }
        reviews(last: 50) {
          nodes {
            author { login }
            authorAssociation
            body
            state
            submittedAt
          }
        }
        comments(last: 20) {
          nodes {
            author { login }
            authorAssociation
            body
            createdAt
          }
        }
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
PR_MARKER_RE = re.compile(
    r"<!-- contributor:issue=(?P<number>\d+);agent=(?P<agent>[a-z0-9-]+) -->"
)
CLOSING_REFERENCE_RE = re.compile(
    r"(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(?P<number>\d+)\b"
)
EXECUTION_PRIORITY_RE = re.compile(r"(?m)^- Priority:\s*(?P<priority>\d+)\s*$")
TRUSTED_AUTHOR_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
TRUSTED_AUTOMATION_LOGINS = {
    "april-clearwater[bot]",
    "claude[bot]",
    "github-actions[bot]",
    "plat-ironwood[bot]",
    "workspace-agents",
    "workspace-agents[bot]",
}


def trusted_automation_logins(env: dict[str, str] | None = None) -> set[str]:
    logins = {login.casefold() for login in TRUSTED_AUTOMATION_LOGINS}
    if env is None:
        return logins

    app_slug = env.get("GH_APP_SLUG", "").strip()
    if not app_slug:
        return logins

    logins.add(app_slug.casefold())
    logins.add(f"{app_slug}[bot]".casefold())
    return logins


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


def extract_issue_discussion_number(body: str) -> int | None:
    match = TASK_ISSUE_MARKER_RE.search(body)
    if not match:
        return None
    return int(match.group("number"))


def extract_execution_priority(body: str) -> int | None:
    match = EXECUTION_PRIORITY_RE.search(markdown_section(body, "Execution"))
    if not match:
        return None
    return int(match.group("priority"))


def extract_blocked_by(body: str) -> list[int]:
    blocked_section = markdown_section(body, "Blocked By")
    blocked = [int(number) for number in re.findall(r"#(\d+)", blocked_section)]
    return list(dict.fromkeys(blocked))


def extract_pr_issue_reference(body: str) -> tuple[int | None, str | None]:
    marker = PR_MARKER_RE.search(body)
    if marker:
        return int(marker.group("number")), marker.group("agent")
    close_ref = CLOSING_REFERENCE_RE.search(body)
    if close_ref:
        return int(close_ref.group("number")), None
    return None, None


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


def discussion_execution_status(
    discussion: dict[str, object] | None,
    discussion_number: int | None,
    owner_login: str,
    *,
    trusted_logins: set[str] | None = None,
) -> tuple[bool, str]:
    if discussion_number is None:
        return False, "missing Peter planner marker"
    if discussion is None:
        return False, f"linked discussion #{discussion_number} not found"
    planned_comment = latest_planned_comment(
        discussion,
        discussion_number,
        trusted_logins=trusted_logins,
    )
    if planned_comment is None:
        return False, f"discussion #{discussion_number} has no Peter summary comment yet"
    if planned_comment_has_owner_approval(planned_comment, owner_login):
        return True, f"owner reacted \U0001f44d on Peter summary comment in discussion #{discussion_number}"
    return False, f"awaiting owner \U0001f44d on Peter summary comment in discussion #{discussion_number}"


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


def detect_bot_login(env: dict[str, str]) -> str:
    app_slug = env.get("GH_APP_SLUG", "").strip()
    if app_slug:
        return f"{app_slug}[bot]"
    login = run_optional(
        ["gh", "api", "/user", "--jq", ".login"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    ).strip()
    return login


def default_branch(env: dict[str, str]) -> str:
    branch = run_optional(
        ["gh", "repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="main",
    ).strip()
    return branch or "main"


def current_branch(env: dict[str, str]) -> str:
    return run_optional(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="HEAD",
    ).strip() or "HEAD"


def fetch_work_state(owner: str, name: str, env: dict[str, str]) -> dict[str, list[dict[str, object]]]:
    raw = run_optional(
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
        default="{}",
    )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {"discussions": [], "issues": [], "pull_requests": []}
    repository = data.get("data", {}).get("repository", {})
    return {
        "discussions": repository.get("discussions", {}).get("nodes", []),
        "issues": repository.get("issues", {}).get("nodes", []),
        "pull_requests": repository.get("pullRequests", {}).get("nodes", []),
    }


def fetch_issue_state_map(env: dict[str, str]) -> dict[int, str]:
    raw = run_optional(
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
        default="[]",
    )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return {int(item["number"]): str(item["state"]) for item in data}


def find_issue_execution_state(
    issue_number: int,
    env: dict[str, str],
    *,
    persona: str,
    bot_login: str,
) -> dict[str, object] | None:
    owner, name = repo_owner_name(env)
    work_state = fetch_work_state(owner, name, env)
    issue_states = fetch_issue_state_map(env)
    issue = next((item for item in work_state["issues"] if int(item["number"]) == issue_number), None)
    if issue is None:
        return None

    current_agent = persona_slug(persona)
    normalized_bot = _normalize_login(bot_login)
    trusted_logins = trusted_automation_logins(env)
    if bot_login:
        trusted_logins.add(bot_login.casefold())
    labels = issue_label_presence(issue)
    linked_prs: list[dict[str, object]] = []
    for pr in work_state["pull_requests"]:
        linked_issue, marker_agent = extract_pr_issue_reference(str(pr.get("body", "")))
        if linked_issue != issue_number:
            continue
        author_login = str((pr.get("author") or {}).get("login", ""))
        linked_prs.append(
            {
                "number": pr.get("number"),
                "title": pr.get("title"),
                "url": pr.get("url"),
                "headRefName": pr.get("headRefName"),
                "reviewDecision": pr.get("reviewDecision"),
                "author_login": author_login,
                "agent": marker_agent or (current_agent if _normalize_login(author_login) == normalized_bot else ""),
            }
        )

    own_pr = next(
        (
            pr
            for pr in linked_prs
            if pr["agent"] == current_agent
            or (not pr["agent"] and _normalize_login(str(pr["author_login"])) == normalized_bot)
        ),
        None,
    )
    other_pr = next((pr for pr in linked_prs if pr is not own_pr), None)
    blocked_by = extract_blocked_by(str(issue.get("body", "")))
    blockers = [
        blocker
        for blocker in blocked_by
        if issue_states.get(blocker, "OPEN").upper() != "CLOSED"
    ]
    latest_claim = latest_issue_claim(
        issue_number,
        issue.get("comments", {}),
        trusted_logins=trusted_logins,
    )
    stale_claim = claim_is_stale(latest_claim, has_open_pr=bool(linked_prs))
    if stale_claim:
        latest_claim = None

    return {
        "issue": issue,
        "approved": AGENT_READY_LABEL in labels,
        "approval_reason": (
            f"{AGENT_READY_LABEL} label present"
            if AGENT_READY_LABEL in labels
            else f"issue #{issue_number} is missing {AGENT_READY_LABEL}"
        ),
        "blockers": blockers,
        "requested_evidence": extract_requested_evidence(str(issue.get("body", ""))),
        "latest_claim": latest_claim,
        "stale_claim": stale_claim,
        "own_pr": own_pr,
        "other_pr": other_pr,
    }


def find_pr_review_state(pr_number: int, env: dict[str, str]) -> dict[str, object] | None:
    owner, name = repo_owner_name(env)
    work_state = fetch_work_state(owner, name, env)
    pr = next((item for item in work_state["pull_requests"] if int(item["number"]) == pr_number), None)
    if pr is None:
        return None

    issue_number, _ = extract_pr_issue_reference(str(pr.get("body", "")))
    issue = None
    requested_evidence: list[str] = []
    if issue_number is not None:
        issue = next((item for item in work_state["issues"] if int(item["number"]) == issue_number), None)
        if issue is not None:
            requested_evidence = extract_requested_evidence(str(issue.get("body", "")))

    accounting, errors = validate_evidence_accounting(str(pr.get("body", "")), requested_evidence)
    return {
        "pr": pr,
        "issue_number": issue_number,
        "issue": issue,
        "requested_evidence": requested_evidence,
        "evidence_accounting": accounting,
        "evidence_errors": errors,
    }
