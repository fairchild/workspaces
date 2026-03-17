#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run a contributor agent from a prompt file."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


CLAUDE_TASK = (
    "Check what needs attention: open PRs to review, then your own open PRs "
    "or claimed issues to advance, then execution-approved issues to pick up, "
    "then discussions to participate in or propose. Output your response "
    "using YAML frontmatter as specified in your prompt."
)
CLAUDE_TASK_CLI = (
    "You are running as an automated contributor. FIRST check if any PRs "
    "need your follow-up review (you reviewed but didn't approve, and new "
    "commits were pushed since). Then review other open PRs, then continue "
    "your own open PRs or claimed issues, then claim an execution-approved "
    "ready issue if one exists, then participate in discussions — comment on "
    "an existing one or propose a new idea. CRITICAL: Your final output MUST "
    "be valid YAML frontmatter exactly as specified in your prompt — start "
    "with `---` on the very first line, then metadata fields, then closing "
    "`---`, then your markdown body. Do NOT write any text before the "
    "opening `---`."
)
REPO_ROOT = Path(__file__).resolve().parents[4]
SKILL_ROOT = Path(__file__).resolve().parents[1]
GH_DISCUSS_SCRIPT = REPO_ROOT / ".agents" / "skills" / "gh-discuss" / "scripts" / "gh-discuss.py"
VALIDATOR_SCRIPT = SKILL_ROOT / "scripts" / "validate-agent-output.py"

# Timeouts (seconds) — every external call must declare its budget
GITHUB_API_TIMEOUT = 30
CLAUDE_TIMEOUT = 300
VALIDATION_TIMEOUT = 30
ENGAGEMENT_RECENT_HOURS = 72
LOW_COMMENT_THRESHOLD = 1
STALE_CLAIM_HOURS = 24


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt-file", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--mode", choices=["cli", "print"], default="cli")
    parser.add_argument("--message", type=str, default="",
                        help="Directed task — overrides periodic priority order")
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    print(f"error: required environment variable {name} is not set", file=sys.stderr)
    sys.exit(1)


def normalize_provider_env(env: dict[str, str]) -> dict[str, str]:
    normalized = dict(env)
    if not normalized.get("OPENAI_API_KEY"):
        fallback = normalized.get("GITHUB_CODESPACES_OPENAI_API_KEY", "").strip()
        if fallback:
            normalized["OPENAI_API_KEY"] = fallback
    return normalized


def log(message: str) -> None:
    print(f"[run-contributor] {message}", file=sys.stderr)


def run_checked(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            cmd,
            input=input,
            capture_output=True,
            text=True,
            env=env,
            cwd=cwd,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        command = " ".join(cmd)
        print(f"error: command timed out after {exc.timeout}s: {command}", file=sys.stderr)
        sys.exit(1)
    if result.returncode != 0:
        command = " ".join(cmd)
        print(f"error: command failed: {command}", file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        sys.exit(result.returncode or 1)
    return result


def run_optional(
    cmd: list[str],
    *,
    timeout: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    default: str,
) -> str:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=env,
            cwd=cwd,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return default
    if result.returncode != 0:
        return default
    return result.stdout


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


def extract_persona(prompt_file: Path) -> str:
    """Extract persona name from the prompt file heading."""
    try:
        for line in prompt_file.read_text().splitlines():
            if line.startswith("# "):
                return line[2:].split("—")[0].split("–")[0].strip()
    except OSError:
        pass
    return ""


HISTORY_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title
        reviews(last: 20) {
          nodes { body author { login } submittedAt }
        }
        comments(last: 20) {
          nodes { body author { login } createdAt }
        }
      }
    }
    issues(first: 10, orderBy: {field: UPDATED_AT, direction: DESC}, states: [OPEN]) {
      nodes {
        number title
        comments(last: 20) {
          nodes { body author { login } createdAt }
        }
      }
    }
    discussions(first: 20, states: OPEN) {
      nodes {
        number title body createdAt
        comments(last: 10) {
          nodes { body author { login } createdAt }
        }
      }
    }
  }
}
"""


def _has_persona(text: str, markers: list[str]) -> bool:
    return any(m in text for m in markers)


def _find_agent_threads(data: dict, markers: list[str]) -> list[dict]:
    """Find threads where the agent acted, returning the last action + replies."""
    threads: list[dict] = []
    repo = data.get("data", {}).get("repository", {})

    for pr in repo.get("pullRequests", {}).get("nodes", []):
        items: list[dict] = []
        for r in pr.get("reviews", {}).get("nodes", []):
            items.append({
                "body": r.get("body", ""),
                "author": (r.get("author") or {}).get("login", ""),
                "time": r.get("submittedAt", ""),
            })
        for c in pr.get("comments", {}).get("nodes", []):
            items.append({
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "time": c.get("createdAt", ""),
            })
        items.sort(key=lambda x: x["time"])
        agent_indices = [i for i, x in enumerate(items) if _has_persona(x["body"], markers)]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "PR",
            "number": pr["number"],
            "title": pr["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    for issue in repo.get("issues", {}).get("nodes", []):
        items = [
            {
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "time": c.get("createdAt", ""),
            }
            for c in issue.get("comments", {}).get("nodes", [])
        ]
        agent_indices = [i for i, x in enumerate(items) if _has_persona(x["body"], markers)]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "Issue",
            "number": issue["number"],
            "title": issue["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    for disc in repo.get("discussions", {}).get("nodes", []):
        disc_body = disc.get("body", "")
        items = [
            {
                "body": c.get("body", ""),
                "author": (c.get("author") or {}).get("login", ""),
                "time": c.get("createdAt", ""),
            }
            for c in disc.get("comments", {}).get("nodes", [])
        ]
        if _has_persona(disc_body, markers):
            threads.append({
                "kind": "Discussion (proposed)",
                "number": disc["number"],
                "title": disc["title"],
                "agent_item": {
                    "body": disc_body,
                    "author": "",
                    "time": disc.get("createdAt", ""),
                },
                "replies": items,
            })
            continue
        agent_indices = [i for i, x in enumerate(items) if _has_persona(x["body"], markers)]
        if not agent_indices:
            continue
        last = agent_indices[-1]
        threads.append({
            "kind": "Discussion",
            "number": disc["number"],
            "title": disc["title"],
            "agent_item": items[last],
            "replies": items[last + 1:],
        })

    threads.sort(key=lambda t: t["agent_item"]["time"], reverse=True)
    return threads


def _format_thread(t: dict) -> str:
    """Format a single agent activity thread."""
    excerpt = t["agent_item"]["body"][:500].replace("\n", "\n    ")
    lines = [
        f"  {t['kind']} #{t['number']} — {t['title']}",
        f"    You wrote ({t['agent_item']['time']}):",
        f"    {excerpt}",
    ]
    if t["replies"]:
        lines.append("    Replies since:")
        for r in t["replies"][:5]:
            r_text = r["body"][:300].replace("\n", "\n      ")
            lines.append(f"    - {r['author']} ({r['time']}): {r_text}")
    else:
        lines.append("    No replies yet.")
    return "\n".join(lines)


def gather_agent_history(
    persona: str, owner: str, name: str, env: dict[str, str],
) -> str:
    """Find the agent's most recent actions and any replies since."""
    if not persona:
        return ""

    log(f"Gathering recent history for {persona}")
    raw = run_optional(
        [
            "gh", "api", "graphql",
            "-f", f"query={HISTORY_QUERY}",
            "-f", f"owner={owner}",
            "-f", f"name={name}",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="{}",
    )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ""

    markers = [f"*{persona}", f"*Proposed by {persona}"]
    threads = _find_agent_threads(data, markers)
    if not threads:
        return ""

    formatted = "\n\n".join(_format_thread(t) for t in threads[:3])
    return (
        f"Your last actions as {persona} and what happened since:\n\n"
        f"{formatted}"
    )


def gather_backlog_state() -> str:
    lines: list[str] = []
    for path in sorted((REPO_ROOT / "backlog").glob("*.md")):
        status = "unknown"
        try:
            for line in path.read_text().splitlines():
                if line.startswith("status:"):
                    status = line.split(":", 1)[1].strip() or "unknown"
                    break
        except OSError:
            continue
        lines.append(f"{path.name}: {status}")
    return "\n".join(lines)


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
        comments(last: 20) {
          nodes {
            id
            body
            createdAt
            author { login }
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
            state
            submittedAt
          }
        }
        comments(last: 20) {
          nodes {
            author { login }
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
AGENT_READY_LABEL = "agent:ready"
AGENT_READY_LABEL_COLOR = "5319e7"
AGENT_READY_LABEL_DESCRIPTION = "Execution-approved and ready for an automated contributor to claim"
AGENT_CLAIM_LABEL = "agent:claimed"
AGENT_CLAIM_LABEL_COLOR = "1d76db"
AGENT_CLAIM_LABEL_DESCRIPTION = "Currently being executed by an automated contributor"
AGENT_MERGEABLE_LABEL = "agent:mergeable"
AGENT_MERGEABLE_LABEL_COLOR = "0e8a16"
AGENT_MERGEABLE_LABEL_DESCRIPTION = "Agent-approved, ready for owner merge"


def persona_slug(persona: str) -> str:
    base = persona.split(",", 1)[0].strip().casefold()
    slug = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return slug or "agent"


def short_persona_name(persona: str) -> str:
    return persona.split(",", 1)[0].strip() or persona.strip()


def issue_label_names(issue: dict[str, object]) -> set[str]:
    labels = issue.get("labels", {})
    nodes = labels.get("nodes", []) if isinstance(labels, dict) else []
    return {
        str(label.get("name", "")).strip()
        for label in nodes
        if isinstance(label, dict) and str(label.get("name", "")).strip()
    }


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


def extract_execution_priority(body: str) -> int | None:
    match = EXECUTION_PRIORITY_RE.search(markdown_section(body, "Execution"))
    if not match:
        return None
    return int(match.group("priority"))


def extract_blocked_by(body: str) -> list[int]:
    blocked_section = markdown_section(body, "Blocked By")
    blocked = [int(number) for number in re.findall(r"#(\d+)", blocked_section)]
    return list(dict.fromkeys(blocked))


def extract_requested_evidence(body: str) -> list[str]:
    evidence_section = markdown_section(body, "Requested Evidence")
    return [
        line[2:].strip()
        for line in evidence_section.splitlines()
        if line.strip().startswith("- ") and line[2:].strip().lower() != "none"
    ]


def latest_issue_claim(issue_number: int, comments: dict[str, object]) -> dict[str, str] | None:
    nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
    claims: list[dict[str, str]] = []
    for comment in nodes:
        if not isinstance(comment, dict):
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


def extract_pr_issue_reference(body: str) -> tuple[int | None, str | None]:
    marker = PR_MARKER_RE.search(body)
    if marker:
        return int(marker.group("number")), marker.group("agent")
    close_ref = CLOSING_REFERENCE_RE.search(body)
    if close_ref:
        return int(close_ref.group("number")), None
    return None, None


def latest_planned_comment(
    discussion: dict[str, object] | None,
    discussion_number: int,
) -> dict[str, object] | None:
    if discussion is None:
        return None
    comments = discussion.get("comments", {})
    nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
    planned: list[dict[str, object]] = []
    for comment in nodes:
        if not isinstance(comment, dict):
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
) -> tuple[bool, str]:
    if discussion_number is None:
        return False, "missing Peter planner marker"
    if discussion is None:
        return False, f"linked discussion #{discussion_number} not found"
    planned_comment = latest_planned_comment(discussion, discussion_number)
    if planned_comment is None:
        return False, f"discussion #{discussion_number} has no Peter summary comment yet"
    if planned_comment_has_owner_approval(planned_comment, owner_login):
        return True, f"owner reacted 👍 on Peter summary comment in discussion #{discussion_number}"
    return False, f"awaiting owner 👍 on Peter summary comment in discussion #{discussion_number}"


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


def find_prs_awaiting_rereview(
    pull_requests: list[dict[str, object]],
    bot_login: str,
) -> str:
    """Find open PRs where this agent reviewed but didn't approve and new commits exist."""
    awaiting: list[str] = []

    for pr in pull_requests:
        reviews = (pr.get("reviews") or {}).get("nodes", [])
        agent_reviews = [
            review
            for review in reviews
            if _normalize_login((review.get("author") or {}).get("login", "")) == _normalize_login(bot_login)
        ]
        if not agent_reviews:
            continue

        latest_agent_review = max(agent_reviews, key=lambda review: review.get("submittedAt", ""))
        if latest_agent_review.get("state") == "APPROVED":
            continue

        commits = (pr.get("commits") or {}).get("nodes", [])
        if not commits:
            continue
        latest_commit_date = commits[0].get("commit", {}).get("committedDate", "")
        review_date = latest_agent_review.get("submittedAt", "")

        if latest_commit_date > review_date:
            awaiting.append(
                f"  PR #{pr['number']} — {pr['title']}\n"
                f"    Your review: {latest_agent_review['state']} at {review_date}\n"
                f"    Latest commit: {latest_commit_date} (pushed AFTER your review)"
            )

    if not awaiting:
        return ""

    return (
        "PRIORITY — PRs awaiting your re-review (you reviewed but didn't approve, "
        "and the author has pushed new commits since):\n\n"
        + "\n\n".join(awaiting)
    )


def detect_bot_login(env: dict[str, str]) -> str:
    """Detect the bot login from GH_APP_SLUG env var or GH_TOKEN /user endpoint."""
    app_slug = env.get("GH_APP_SLUG", "").strip()
    if app_slug:
        return f"{app_slug}[bot]"
    # Fallback: try /user (works for PATs)
    login = run_optional(
        ["gh", "api", "/user", "--jq", ".login"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    ).strip()
    return login


def _parse_timestamp(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _normalize_login(login: str) -> str:
    return login.removesuffix("[bot]").strip().casefold()


def _extract_proposed_persona(body: str) -> str:
    match = re.search(r"\*Proposed by ([^*\n]+)\*", body)
    if not match:
        return ""
    return match.group(1).split(",", 1)[0].strip()


def _is_idea_discussion(title: str) -> bool:
    return "[idea]" in title.casefold()


def format_open_discussions(discussions: list[dict[str, object]]) -> str:
    lines: list[str] = []
    for disc in discussions:
        comments = disc.get("comments", {})
        comment_nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
        comment_count = comments.get("totalCount", len(comment_nodes)) if isinstance(comments, dict) else 0
        category = disc.get("category", {})
        category_name = category.get("name", "Unknown") if isinstance(category, dict) else "Unknown"
        line = (
            f"#{disc.get('number')} [{category_name}] {disc.get('title')} "
            f"({comment_count} comments)"
        )
        previews: list[str] = []
        for comment in comment_nodes[:2]:
            author = (comment.get("author") or {}).get("login", "unknown")
            body = str(comment.get("body", "")).replace("\n", " ")[:200]
            previews.append(f"  -> {author}: {body}")
        if previews:
            line = f"{line}\n" + "\n".join(previews)
        lines.append(line)
    return "\n".join(lines)


def find_discussions_needing_engagement(
    discussions: list[dict[str, object]],
    *,
    owner_login: str,
    persona: str,
    now: datetime | None = None,
) -> list[dict[str, object]]:
    if now is None:
        now = datetime.now(timezone.utc)

    owner = _normalize_login(owner_login)
    current_persona = persona.casefold()
    candidates: list[dict[str, object]] = []

    for disc in discussions:
        title = str(disc.get("title", ""))
        if not _is_idea_discussion(title):
            continue

        body = str(disc.get("body", ""))
        comments = disc.get("comments", {})
        comment_nodes = comments.get("nodes", []) if isinstance(comments, dict) else []
        comment_count = comments.get("totalCount", len(comment_nodes)) if isinstance(comments, dict) else 0
        proposed_by = _extract_proposed_persona(body)
        created_at = _parse_timestamp(str(disc.get("createdAt", "")))
        age = now - created_at if created_at is not None else None
        owner_replied = any(
            _normalize_login((comment.get("author") or {}).get("login", "")) == owner
            for comment in comment_nodes
        )
        other_agent_recent = bool(
            proposed_by
            and proposed_by.casefold() != current_persona
            and age is not None
            and age <= timedelta(hours=ENGAGEMENT_RECENT_HOURS)
        )

        reasons: list[str] = []
        if other_agent_recent:
            age_hours = max(1, int(age.total_seconds() // 3600)) if age is not None else ENGAGEMENT_RECENT_HOURS
            reasons.append(f"{proposed_by} opened this {age_hours}h ago")
        if comment_count == 0:
            reasons.append("0 comments")
        elif comment_count <= LOW_COMMENT_THRESHOLD:
            reasons.append("only 1 comment")
        if not owner_replied:
            reasons.append("no owner reply yet")

        if not reasons:
            continue

        if other_agent_recent:
            priority = 0
        elif comment_count <= LOW_COMMENT_THRESHOLD:
            priority = 1
        else:
            priority = 2

        sort_timestamp = created_at.timestamp() if created_at is not None else 0.0
        candidates.append(
            {
                "number": disc.get("number"),
                "title": title,
                "proposed_by": proposed_by,
                "comment_count": comment_count,
                "owner_replied": owner_replied,
                "reasons": reasons,
                "priority": priority,
                "sort_timestamp": sort_timestamp,
            }
        )

    candidates.sort(
        key=lambda item: (
            int(item["priority"]),
            int(item["comment_count"]),
            -float(item["sort_timestamp"]),
        )
    )
    return candidates


def format_engagement_candidates(candidates: list[dict[str, object]]) -> str:
    if not candidates:
        return ""

    lines = ["PRIORITY — discussions needing engagement before new proposals:\n"]
    for candidate in candidates[:5]:
        reasons = ", ".join(str(reason) for reason in candidate["reasons"])
        lines.append(
            f"  Discussion #{candidate['number']} — {candidate['title']}\n"
            f"    Reasons: {reasons}"
        )
    return "\n".join(lines)


def build_engagement_retry_message(candidate: dict[str, object]) -> str:
    reasons = ", ".join(str(reason) for reason in candidate["reasons"])
    return (
        "Do not propose a new discussion. Comment on the existing discussion "
        f"#{candidate['number']} instead and help move that thread forward. "
        f"It needs engagement because: {reasons}. Respond to the existing thesis, "
        "refine the scope, or ask one concrete question that advances the thread."
    )


def format_issue_list_for_context(issues: list[dict[str, object]]) -> str:
    payload = [
        {
            "number": issue.get("number"),
            "title": issue.get("title"),
            "labels": sorted(issue_label_names(issue)),
            "url": issue.get("url"),
        }
        for issue in issues
    ]
    return json.dumps(payload, indent=2, ensure_ascii=False)


def format_pr_list_for_context(pull_requests: list[dict[str, object]]) -> str:
    payload = [
        {
            "number": pr.get("number"),
            "title": pr.get("title"),
            "author": (pr.get("author") or {}).get("login", ""),
            "isDraft": pr.get("isDraft"),
            "reviewDecision": pr.get("reviewDecision"),
            "headRefName": pr.get("headRefName"),
            "url": pr.get("url"),
        }
        for pr in pull_requests
    ]
    return json.dumps(payload, indent=2, ensure_ascii=False)


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


def summarize_requested_evidence(requested_evidence: list[str]) -> str:
    if not requested_evidence:
        return "Follow the repo evidence bar for the touched surfaces."
    preview = requested_evidence[:2]
    suffix = " ..." if len(requested_evidence) > 2 else ""
    return "; ".join(preview) + suffix


def classify_execution_work(
    issues: list[dict[str, object]],
    pull_requests: list[dict[str, object]],
    discussions: list[dict[str, object]],
    issue_states: dict[int, str],
    *,
    owner_login: str,
    persona: str,
    bot_login: str,
) -> dict[str, list[dict[str, object]]]:
    current_agent = persona_slug(persona)
    normalized_bot = _normalize_login(bot_login)
    issue_pr_map: dict[int, list[dict[str, object]]] = {}
    for pr in pull_requests:
        issue_number, marker_agent = extract_pr_issue_reference(str(pr.get("body", "")))
        if issue_number is None:
            continue
        author_login = str((pr.get("author") or {}).get("login", ""))
        issue_pr_map.setdefault(issue_number, []).append(
            {
                "number": pr.get("number"),
                "title": pr.get("title"),
                "url": pr.get("url"),
                "author_login": author_login,
                "reviewDecision": pr.get("reviewDecision"),
                "headRefName": pr.get("headRefName"),
                "agent": marker_agent or (current_agent if _normalize_login(author_login) == normalized_bot else ""),
            }
        )

    own_open_prs: list[dict[str, object]] = []
    claimed_issues: list[dict[str, object]] = []
    ready_issues: list[dict[str, object]] = []

    for issue in issues:
        labels = issue_label_names(issue)
        if AGENT_CLAIM_LABEL not in labels and AGENT_READY_LABEL not in labels and "agent:task" not in labels:
            continue
        if "agent:task" not in labels:
            continue

        issue_number = int(issue["number"])
        body = str(issue.get("body", ""))
        discussion_number = extract_issue_discussion_number(body)
        priority = extract_execution_priority(body)
        blocked_by = extract_blocked_by(body)
        requested_evidence = extract_requested_evidence(body)
        blockers = [
            blocker
            for blocker in blocked_by
            if issue_states.get(blocker, "OPEN").upper() != "CLOSED"
        ]
        latest_claim = latest_issue_claim(issue_number, issue.get("comments", {}))
        claim_agent = latest_claim.get("agent") if latest_claim else None
        linked_prs = issue_pr_map.get(issue_number, [])
        stale_claim = claim_is_stale(latest_claim, has_open_pr=bool(linked_prs))
        if stale_claim:
            latest_claim = None
            claim_agent = None
        own_pr = next(
            (
                pr
                for pr in linked_prs
                if pr["agent"] == current_agent
                or (
                    not pr["agent"]
                    and _normalize_login(str(pr["author_login"])) == normalized_bot
                )
            ),
            None,
        )

        item = {
            "issue_number": issue_number,
            "title": issue.get("title"),
            "url": issue.get("url"),
            "discussion_number": discussion_number,
            "priority": priority,
            "blocked_by": blocked_by,
            "requested_evidence": requested_evidence,
            "approval_reason": (
                f"{AGENT_READY_LABEL} label present"
                if AGENT_READY_LABEL in labels
                else f"waiting for {AGENT_READY_LABEL} label"
            ),
            "claim_branch": latest_claim.get("branch") if latest_claim else "",
            "claim_agent": claim_agent or "",
        }

        if own_pr is not None:
            own_open_prs.append(
                {
                    **item,
                    "pr_number": own_pr["number"],
                    "pr_title": own_pr["title"],
                    "pr_url": own_pr["url"],
                    "pr_branch": own_pr["headRefName"],
                    "review_decision": own_pr["reviewDecision"] or "REVIEW_REQUIRED",
                }
            )
            continue

        if latest_claim is not None and claim_agent == current_agent:
            claimed_issues.append(item)
            continue

        if AGENT_READY_LABEL not in labels or blockers or linked_prs:
            continue
        if latest_claim is not None and claim_agent and claim_agent != current_agent:
            continue
        if AGENT_CLAIM_LABEL in labels and latest_claim is None:
            continue

        ready_issues.append(item)

    def sort_key(item: dict[str, object]) -> tuple[int, int]:
        priority = int(item["priority"]) if item.get("priority") is not None else 9999
        return priority, int(item["issue_number"])

    own_open_prs.sort(key=sort_key)
    claimed_issues.sort(key=sort_key)
    ready_issues.sort(key=sort_key)
    return {
        "own_open_prs": own_open_prs,
        "claimed_issues": claimed_issues,
        "ready_issues": ready_issues,
    }


def format_own_open_prs(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — your open PRs to advance after reviews:\n"]
    for item in items[:5]:
        lines.append(
            f"  PR #{item['pr_number']} — {item['pr_title']}\n"
            f"    Issue: #{item['issue_number']} | Review decision: {item['review_decision']} | Branch: {item['pr_branch']}"
        )
    return "\n".join(lines)


def format_claimed_issues(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — issues you already claimed and should keep moving:\n"]
    for item in items[:5]:
        priority = item.get("priority")
        priority_text = f"Priority {priority}" if priority is not None else "Priority unrecorded"
        lines.append(
            f"  Issue #{item['issue_number']} — {item['title']}\n"
            f"    {priority_text} | Branch: {item['claim_branch'] or 'not recorded'}\n"
            f"    Requested evidence: {summarize_requested_evidence(list(item['requested_evidence']))}"
        )
    return "\n".join(lines)


def format_ready_issues(items: list[dict[str, object]]) -> str:
    if not items:
        return ""
    lines = ["PRIORITY — execution-approved issues ready to claim if no PR work is waiting:\n"]
    for item in items[:5]:
        priority = item.get("priority")
        priority_text = f"Priority {priority}" if priority is not None else "Priority unrecorded"
        discussion = (
            f"discussion #{item['discussion_number']}"
            if item.get("discussion_number") is not None
            else "linked discussion unavailable"
        )
        lines.append(
            f"  Issue #{item['issue_number']} — {item['title']}\n"
            f"    {priority_text} | Approval: {item['approval_reason']} | From {discussion}\n"
            f"    Requested evidence: {summarize_requested_evidence(list(item['requested_evidence']))}"
        )
    return "\n".join(lines)


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


def maybe_block_new_proposal(
    validated_json: str,
    engagement_candidates: list[dict[str, object]],
) -> dict[str, object] | None:
    data = json.loads(validated_json)
    if data.get("action") != "propose" or not engagement_candidates:
        return None
    return engagement_candidates[0]


def gather_context(
    env: dict[str, str],
    persona: str = "",
    bot_login: str = "",
) -> tuple[str, list[dict[str, object]]]:
    log("Gathering context")
    owner, name = repo_owner_name(env)

    recent_commits = run_checked(
        ["git", "log", "--oneline", "--since=2 weeks ago"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    ).stdout.rstrip()

    work_state = fetch_work_state(owner, name, env)
    discussion_nodes = work_state["discussions"]
    discussions = format_open_discussions(discussion_nodes)
    engagement_candidates = find_discussions_needing_engagement(
        discussion_nodes,
        owner_login=owner,
        persona=persona,
    )
    engagement_summary = format_engagement_candidates(engagement_candidates)
    open_issues = format_issue_list_for_context(work_state["issues"])
    open_prs = format_pr_list_for_context(work_state["pull_requests"])

    backlog_state = gather_backlog_state()
    history = gather_agent_history(persona, owner, name, env)
    issue_states = fetch_issue_state_map(env)
    execution_state = classify_execution_work(
        work_state["issues"],
        work_state["pull_requests"],
        discussion_nodes,
        issue_states,
        owner_login=owner,
        persona=persona,
        bot_login=bot_login,
    )
    pending_reviews = find_prs_awaiting_rereview(work_state["pull_requests"], bot_login) if bot_login else ""
    own_open_prs = format_own_open_prs(execution_state["own_open_prs"])
    claimed_issues = format_claimed_issues(execution_state["claimed_issues"])
    ready_issues = format_ready_issues(execution_state["ready_issues"])

    sections = []
    if pending_reviews:
        sections.append(pending_reviews)
    if own_open_prs:
        sections.append(own_open_prs)
    if claimed_issues:
        sections.append(claimed_issues)
    if ready_issues:
        sections.append(ready_issues)
    if engagement_summary:
        sections.append(engagement_summary)
    sections.extend([
        f"Recent commits (last 2 weeks):\n{recent_commits}",
        f"Open discussions:\n{discussions}",
        f"Open issues:\n{open_issues}",
        f"Open PRs:\n{open_prs}",
        f"Backlog state:\n{backlog_state}",
    ])
    if history:
        sections.append(history)
    return "\n\n".join(sections), engagement_candidates


def run_claude(
    prompt_file: Path, context: str, env: dict[str, str],
    *, mode: str = "cli", message: str = "",
) -> str:
    log(f"Running Claude Code with {prompt_file} (mode={mode})")
    if message:
        log(f"Directed task: {message[:80]}")
        task = (
            f"DIRECTED TASK (highest priority — do this instead of your normal priority "
            f"order): {message}\n\n"
            f"CRITICAL: Your final output MUST be valid YAML frontmatter exactly as "
            f"specified in your prompt — start with `---` on the very first line, then "
            f"metadata fields, then closing `---`, then your markdown body. Do NOT write "
            f"any text before the opening `---`."
        )
    else:
        task = CLAUDE_TASK_CLI if mode == "cli" else CLAUDE_TASK
    cmd = [
        "npx",
        "--yes",
        "@anthropic-ai/claude-code",
        "--print",
        "--system-prompt",
        prompt_file.read_text(),
        "--append-system-prompt",
        context,
    ]
    timeout = CLAUDE_TIMEOUT
    if mode == "cli":
        cmd.extend([
            "--permission-mode", "bypassPermissions",
            "--tools",
            "Read,Grep,Glob,Edit,Write,MultiEdit,Bash(git:*),Bash(gh:*),Bash(uv:*),Bash(swift:*),Bash(mise:*),Bash(./scripts/*),Bash(xcodebuild:*)",
            "--max-budget-usd", "2.50",
        ])
        timeout = 1200
    cmd.append(task)
    return run_checked(cmd, timeout=timeout, cwd=REPO_ROOT, env=env).stdout


def validate_output(raw_output: str, env: dict[str, str]) -> tuple[int, str | None, str]:
    log("Validating agent output")
    try:
        result = subprocess.run(
            ["uv", "run", str(VALIDATOR_SCRIPT), "--check-dedup"],
            input=raw_output,
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO_ROOT,
            timeout=VALIDATION_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print("error: validation timed out", file=sys.stderr)
        return 1, None, "validation timed out"
    if result.returncode == 0:
        return 0, result.stdout, result.stderr
    error_text = result.stderr.strip()
    if error_text:
        print(error_text, file=sys.stderr)
    return result.returncode, None, error_text


def build_body(data: dict[str, object]) -> str:
    persona = str(data.get("persona", ""))
    body = str(data.get("body", ""))
    if data["action"] == "propose":
        return f"*Proposed by {persona}*\n\n{body}"
    return f"*{persona}*\n\n{body}"


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


def slugify(value: str, *, max_length: int = 48) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not slug:
        return "task"
    return slug[:max_length].rstrip("-") or "task"


def branch_name_for_issue(persona: str, issue_number: int, issue_title: str) -> str:
    return f"codex/{persona_slug(persona)}-issue-{issue_number}-{slugify(issue_title)}"


def ensure_label_exists(env: dict[str, str], name: str, color: str, description: str) -> None:
    labels = run_optional(
        ["gh", "label", "list", "--limit", "200", "--json", "name"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="[]",
    )
    try:
        existing = {item["name"] for item in json.loads(labels)}
    except json.JSONDecodeError:
        existing = set()
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


def ensure_claim_label(env: dict[str, str]) -> None:
    ensure_label_exists(env, AGENT_CLAIM_LABEL, AGENT_CLAIM_LABEL_COLOR, AGENT_CLAIM_LABEL_DESCRIPTION)


def issue_label_presence(issue: dict[str, object]) -> set[str]:
    return issue_label_names(issue)


def claim_marker(issue_number: int, persona: str, branch: str) -> str:
    return (
        f"<!-- contributor:issue={issue_number};status=claimed;"
        f"agent={persona_slug(persona)};branch={branch} -->"
    )


def compose_claim_comment(issue_number: int, persona: str, branch: str) -> str:
    return (
        f"*{persona}*\n\n"
        f"Claiming this issue for execution on `{branch}`.\n\n"
        f"{claim_marker(issue_number, persona, branch)}"
    )


def pr_marker(issue_number: int, persona: str) -> str:
    return f"<!-- contributor:issue={issue_number};agent={persona_slug(persona)} -->"


def compose_pr_body(
    issue_number: int,
    persona: str,
    summary_body: str,
) -> str:
    return (
        f"*{persona}*\n\n"
        f"{summary_body.strip()}\n\n"
        f"Closes #{issue_number}\n\n"
        f"{pr_marker(issue_number, persona)}"
    )


def compose_pr_update_comment(persona: str, summary_body: str) -> str:
    return f"*{persona}*\n\n{summary_body.strip()}"


def set_git_identity(env: dict[str, str], persona: str, bot_login: str) -> None:
    user_name = bot_login or short_persona_name(persona)
    user_email = f"{persona_slug(persona)}@users.noreply.github.com"
    run_checked(["git", "config", "user.name", user_name], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    run_checked(["git", "config", "user.email", user_email], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)


def working_tree_dirty(env: dict[str, str]) -> bool:
    status = run_optional(
        ["git", "status", "--porcelain"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    return bool(status.strip())


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
    latest_claim = latest_issue_claim(issue_number, issue.get("comments", {}))
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


def ensure_issue_claimed(
    issue_number: int,
    persona: str,
    branch: str,
    latest_claim: dict[str, str] | None,
    current_labels: set[str],
    env: dict[str, str],
    bot_login: str = "",
) -> None:
    if latest_claim is not None and latest_claim.get("agent") == persona_slug(persona) and latest_claim.get("branch") == branch:
        return
    ensure_claim_label(env)
    cmd = ["gh", "issue", "edit", str(issue_number), "--add-label", AGENT_CLAIM_LABEL]
    if AGENT_READY_LABEL in current_labels:
        cmd.extend(["--remove-label", AGENT_READY_LABEL])
    run_checked(cmd, timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
    run_checked(
        ["gh", "issue", "comment", str(issue_number), "--body", compose_claim_comment(issue_number, persona, branch)],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
    )
    if bot_login:
        run_checked(
            ["gh", "issue", "edit", str(issue_number), "--add-assignee", bot_login],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )


def _update_mergeable_label(pr_number: int, verdict: str, env: dict[str, str]) -> None:
    """Add agent:mergeable on approve, remove on request_changes."""
    if verdict not in ("approve", "approve_with_followups", "request_changes"):
        return
    pr_body = run_optional(
        ["gh", "pr", "view", str(pr_number), "--json", "body", "--jq", ".body"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    linked_issue, _ = extract_pr_issue_reference(pr_body)
    if linked_issue is None:
        return
    if verdict in ("approve", "approve_with_followups"):
        ensure_label_exists(env, AGENT_MERGEABLE_LABEL, AGENT_MERGEABLE_LABEL_COLOR, AGENT_MERGEABLE_LABEL_DESCRIPTION)
        run_checked(
            ["gh", "issue", "edit", str(linked_issue), "--add-label", AGENT_MERGEABLE_LABEL],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
    else:
        run_optional(
            ["gh", "issue", "edit", str(linked_issue), "--remove-label", AGENT_MERGEABLE_LABEL],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
            default="",
        )


def route_action(validated_json: str, dry_run: bool, env: dict[str, str]) -> int:
    data = json.loads(validated_json)
    action = data["action"]

    if dry_run:
        log(f"Dry run; action={action}")
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0

    log(f"Routing action {action}")
    body = build_body(data) if action != "execute_issue" else ""

    if action == "propose":
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "create",
                str(data["title"]),
                "--body",
                body,
                "--category",
                "General",
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    if action == "comment":
        run_checked(
            [
                "uv",
                "run",
                str(GH_DISCUSS_SCRIPT),
                "update",
                str(data["discussion_number"]),
                body,
            ],
            timeout=GITHUB_API_TIMEOUT,
            cwd=REPO_ROOT,
            env=env,
        )
        return 0

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(body)
        body_file = handle.name

    try:
        if action == "review_pr":
            verdict = str(data.get("verdict", "")).lower()
            review_flag = {
                "approve": "--approve",
                "approve_with_followups": "--approve",
                "request_changes": "--request-changes",
            }.get(verdict, "--comment")
            run_checked(
                [
                    "gh",
                    "pr",
                    "review",
                    str(data["pr_number"]),
                    review_flag,
                    "--body-file",
                    body_file,
                ],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
            _update_mergeable_label(int(data["pr_number"]), verdict, env)
            return 0
        if action == "execute_issue":
            persona = str(data.get("persona", ""))
            bot_login = detect_bot_login(env)
            issue_number = int(data["issue_number"])
            state = find_issue_execution_state(
                issue_number,
                env,
                persona=persona,
                bot_login=bot_login,
            )
            if state is None:
                print(f"error: issue #{issue_number} is not available for execution", file=sys.stderr)
                return 1

            own_pr = state.get("own_pr")
            other_pr = state.get("other_pr")
            if own_pr is None and not bool(state.get("approved")):
                print(
                    f"error: issue #{issue_number} is not execution-approved ({state.get('approval_reason')})",
                    file=sys.stderr,
                )
                return 1
            if own_pr is None and state.get("blockers"):
                print(
                    f"error: issue #{issue_number} is still blocked by {state['blockers']}",
                    file=sys.stderr,
                )
                return 1
            if other_pr is not None:
                print(
                    f"error: issue #{issue_number} already has open PR #{other_pr['number']} by another agent",
                    file=sys.stderr,
                )
                return 1

            latest_claim = state.get("latest_claim")
            if (
                own_pr is None
                and latest_claim is not None
                and latest_claim.get("agent")
                and latest_claim.get("agent") != persona_slug(persona)
            ):
                print(
                    f"error: issue #{issue_number} is already claimed by {latest_claim['agent']}",
                    file=sys.stderr,
                )
                return 1

            branch = current_branch(env)
            if own_pr is not None:
                expected_branch = str(own_pr.get("headRefName", ""))
                if branch != expected_branch:
                    print(
                        f"error: issue #{issue_number} already has PR #{own_pr['number']} on "
                        f"branch '{expected_branch}'. Check out that branch before editing.",
                        file=sys.stderr,
                    )
                    return 1
            else:
                default = default_branch(env)
                if branch in {"HEAD", "", default, "main", "master"}:
                    branch = branch_name_for_issue(
                        persona,
                        issue_number,
                        str(state["issue"].get("title", f"issue-{issue_number}")),
                    )
                    run_checked(
                        ["git", "checkout", "-b", branch],
                        timeout=GITHUB_API_TIMEOUT,
                        cwd=REPO_ROOT,
                        env=env,
                    )
                ensure_issue_claimed(
                    issue_number,
                    persona,
                    branch,
                    latest_claim if isinstance(latest_claim, dict) else None,
                    issue_label_presence(state["issue"]),
                    env,
                    bot_login=bot_login or "",
                )

            if not working_tree_dirty(env):
                print(
                    f"error: execute_issue selected for #{issue_number} but no file changes were made",
                    file=sys.stderr,
                )
                return 1

            set_git_identity(env, persona, bot_login)
            run_checked(["git", "add", "-A"], timeout=GITHUB_API_TIMEOUT, cwd=REPO_ROOT, env=env)
            run_checked(
                ["git", "commit", "-m", str(data["commit_message"]).strip()],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
            run_checked(
                ["git", "push", "--set-upstream", "origin", branch],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )

            summary_body = str(data.get("body", "")).strip()
            if own_pr is not None:
                run_checked(
                    [
                        "gh",
                        "pr",
                        "comment",
                        str(own_pr["number"]),
                        "--body",
                        compose_pr_update_comment(persona, summary_body),
                    ],
                    timeout=GITHUB_API_TIMEOUT,
                    cwd=REPO_ROOT,
                    env=env,
                )
                return 0

            pr_body = compose_pr_body(issue_number, persona, summary_body)
            run_checked(
                [
                    "gh",
                    "pr",
                    "create",
                    "--base",
                    default_branch(env),
                    "--head",
                    branch,
                    "--title",
                    str(data["pr_title"]).strip(),
                    "--body",
                    pr_body,
                ],
                timeout=GITHUB_API_TIMEOUT,
                cwd=REPO_ROOT,
                env=env,
            )
            return 0
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass

    print(f"error: unknown action: {action}", file=sys.stderr)
    return 1


def main() -> int:
    args = parse_args()
    prompt_file = args.prompt_file.resolve()
    if not prompt_file.is_file():
        print(f"error: prompt file not found: {prompt_file}", file=sys.stderr)
        return 1

    require_env("CLAUDE_CODE_OAUTH_TOKEN")
    require_env("GH_TOKEN")
    env = normalize_provider_env(dict(os.environ))

    persona = extract_persona(prompt_file)
    bot_login = detect_bot_login(env)
    if bot_login:
        log(f"Authenticated as {bot_login}")
    context, engagement_candidates = gather_context(env, persona=persona, bot_login=bot_login)
    raw_output = run_claude(prompt_file, context, env, mode=args.mode, message=args.message)
    exit_code, validated_json, error_text = validate_output(raw_output, env)

    if exit_code == 2 and error_text.startswith("duplicate:"):
        log("Skipping duplicate proposal")
        return 0
    if exit_code != 0 or validated_json is None:
        print("--- Raw output ---", file=sys.stderr)
        print(raw_output, file=sys.stderr)
        return 1

    if not args.message:
        blocked_candidate = maybe_block_new_proposal(validated_json, engagement_candidates)
        if blocked_candidate is not None:
            log(
                "Blocking new proposal because existing discussions need engagement: "
                f"#{blocked_candidate['number']}"
            )
            retry_message = build_engagement_retry_message(blocked_candidate)
            raw_output = run_claude(
                prompt_file,
                context,
                env,
                mode=args.mode,
                message=retry_message,
            )
            exit_code, validated_json, error_text = validate_output(raw_output, env)
            if exit_code != 0 or validated_json is None:
                print("--- Raw output ---", file=sys.stderr)
                print(raw_output, file=sys.stderr)
                return 1
            if json.loads(validated_json).get("action") == "propose":
                print(
                    "error: contributor proposed a new idea despite engagement policy",
                    file=sys.stderr,
                )
                print("--- Raw output ---", file=sys.stderr)
                print(raw_output, file=sys.stderr)
                return 1

    result = route_action(validated_json, args.dry_run, env)
    if result == 0:
        log("Completed successfully")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
