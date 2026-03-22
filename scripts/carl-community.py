#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Carl Community — community commentator for the Workspaces project.

Gathers project activity (discussions, issues, PRs, CI runs, git log),
scores it for significance, generates color commentary via a single
Claude API call, and posts to a running GitHub Discussion thread.

Usage:
    carl-community.py                         # gather, generate, post
    carl-community.py --dry-run               # gather, generate, print (no post)
    carl-community.py --dry-run --json        # same, structured output
    carl-community.py --fixtures-dir DIR      # replay from fixture data
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen


REPO_ROOT = Path(__file__).resolve().parents[1]
PERSONA_PATH = (
    REPO_ROOT
    / ".agents"
    / "skills"
    / "carl-community"
    / "references"
    / "carl-community.md"
)
WATERMARK_RE = re.compile(
    r"<!-- carl-community:timestamp=(?P<ts>[0-9T:.+Z-]+) -->"
)
THREAD_TITLE = "[community] Carl's Commentary"
PREFERRED_CATEGORY = "show-and-tell"
FALLBACK_CATEGORY = "general"
FAILURE_CONCLUSIONS = {"failure", "timed_out", "startup_failure", "action_required"}
FIXTURE_REQUIRED_FILES = (
    "repo.json",
    "discussions.json",
    "issues.json",
    "prs.json",
    "runs.json",
    "git-log.txt",
)

# Activity scoring weights
SCORE_PR_MERGED = 5
SCORE_PR_OPENED = 3
SCORE_ISSUE_OPENED = 3
SCORE_ISSUE_CLOSED = 3
SCORE_DISCUSSION_COMMENT = 1
SCORE_DISCUSSION_NEW = 2
SCORE_CI_FAILURE = 2
SCORE_COMMIT = 1


class CarlError(RuntimeError):
    """Raised when the script cannot complete."""


@dataclass(frozen=True)
class RepoInfo:
    owner: str
    name: str
    repository_id: str = ""
    category_ids: dict[str, str] = field(default_factory=dict)


@dataclass
class ActivityData:
    repo: RepoInfo
    thread: dict[str, Any] | None  # the commentary discussion node
    thread_comments: list[dict[str, Any]]
    discussions: list[dict[str, Any]]
    issues: list[dict[str, Any]]
    prs: list[dict[str, Any]]
    runs: list[dict[str, Any]]
    git_log: str
    watermark: datetime


# ---------------------------------------------------------------------------
# Helpers (same patterns as ops-report.py)
# ---------------------------------------------------------------------------


def log(message: str) -> None:
    print(f"[carl-community] {message}", file=sys.stderr)


def run_checked(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd, capture_output=True, text=True, cwd=cwd, env=env, input=input,
    )
    if result.returncode != 0:
        command = " ".join(cmd)
        raise CarlError(
            f"command failed ({command}): "
            f"{(result.stderr or result.stdout).strip() or 'unknown error'}"
        )
    return result


def load_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise CarlError(f"missing required file: {path}") from error
    except json.JSONDecodeError as error:
        raise CarlError(f"invalid JSON in {path}: {error}") from error


def graphql(query: str, env: dict[str, str], **variables: Any) -> dict[str, Any]:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        if isinstance(value, bool):
            cmd.extend(["-f", f"{key}={'true' if value else 'false'}"])
        elif isinstance(value, int):
            cmd.extend(["-F", f"{key}={value}"])
        else:
            cmd.extend(["-f", f"{key}={value}"])
    result = run_checked(cmd, cwd=REPO_ROOT, env=env)
    data = json.loads(result.stdout)
    if "errors" in data:
        raise CarlError(f"graphql error: {data['errors']}")
    return data


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    elif re.search(r"[+-]\d{4}$", normalized):
        normalized = normalized[:-5] + normalized[-5:-2] + ":" + normalized[-2:]
    return datetime.fromisoformat(normalized)


def now_utc() -> datetime:
    return datetime.now(tz=UTC)


# ---------------------------------------------------------------------------
# Repo info
# ---------------------------------------------------------------------------


def repo_info(env: dict[str, str]) -> RepoInfo:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
    else:
        result = run_checked(
            ["gh", "repo", "view", "--json", "owner,name"], cwd=REPO_ROOT, env=env,
        )
        data = json.loads(result.stdout)
        owner, name = data["owner"]["login"], data["name"]

    query = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 20) {
      nodes { id slug name }
    }
  }
}
"""
    data = graphql(query, env, owner=owner, name=name)
    repo = data["data"]["repository"]
    category_ids = {
        node["slug"].lower(): node["id"]
        for node in repo["discussionCategories"]["nodes"]
    }
    return RepoInfo(
        owner=owner,
        name=name,
        repository_id=repo["id"],
        category_ids=category_ids,
    )


# ---------------------------------------------------------------------------
# Thread management
# ---------------------------------------------------------------------------


def find_commentary_thread(
    repo: RepoInfo, env: dict[str, str],
) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    """Search for the Carl Community discussion thread. Returns (thread, comments)."""
    query = """
query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    discussions(first: 50, after: $after, states: OPEN) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        number
        url
        title
        category { slug }
        comments(last: 10) {
          nodes {
            id
            body
            createdAt
            author { login }
          }
        }
      }
    }
  }
}
"""
    cursor: str | None = None
    while True:
        data = graphql(query, env, owner=repo.owner, name=repo.name, after=cursor)
        page = data["data"]["repository"]["discussions"]
        for disc in page["nodes"]:
            if disc["title"].strip().lower() == THREAD_TITLE.lower():
                comments = disc.get("comments", {}).get("nodes", [])
                return disc, comments
        if not page["pageInfo"]["hasNextPage"]:
            return None, []
        cursor = page["pageInfo"]["endCursor"]


def create_commentary_thread(repo: RepoInfo, env: dict[str, str]) -> dict[str, Any]:
    """Create the Carl Community discussion thread."""
    cat_id = repo.category_ids.get(PREFERRED_CATEGORY)
    if not cat_id:
        cat_id = repo.category_ids.get(FALLBACK_CATEGORY)
    if not cat_id:
        raise CarlError(
            f"No '{PREFERRED_CATEGORY}' or '{FALLBACK_CATEGORY}' discussion category found"
        )

    mutation = """
mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {
    repositoryId: $repoId
    categoryId: $catId
    title: $title
    body: $body
  }) {
    discussion { id number url title }
  }
}
"""
    body = (
        "Carl Community's running commentary on the Workspaces project.\n\n"
        "Each comment below is a snapshot of recent project activity — "
        "what shipped, what's in progress, and what's coming up."
    )
    data = graphql(
        mutation, env,
        repoId=repo.repository_id,
        catId=cat_id,
        title=THREAD_TITLE,
        body=body,
    )
    return data["data"]["createDiscussion"]["discussion"]


def find_or_create_thread(
    repo: RepoInfo, env: dict[str, str],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Find existing thread or create one. Returns (thread, comments)."""
    thread, comments = find_commentary_thread(repo, env)
    if thread:
        log(f"Found thread #{thread['number']}: {thread['url']}")
        return thread, comments
    log("No existing thread found — creating one")
    thread = create_commentary_thread(repo, env)
    log(f"Created thread #{thread['number']}: {thread['url']}")
    return thread, []


# ---------------------------------------------------------------------------
# Watermark
# ---------------------------------------------------------------------------


def extract_watermark(comments: list[dict[str, Any]]) -> datetime:
    """Find the timestamp of Carl's last post from the marker comment."""
    for comment in reversed(comments):
        body = comment.get("body", "")
        match = WATERMARK_RE.search(body)
        if match:
            ts = parse_datetime(match.group("ts"))
            if ts:
                log(f"Watermark from last post: {ts.isoformat()}")
                return ts
    default = now_utc() - timedelta(hours=24)
    log(f"No previous post found — using 24h default: {default.isoformat()}")
    return default


# ---------------------------------------------------------------------------
# Data gathering
# ---------------------------------------------------------------------------


def fetch_discussions(repo: RepoInfo, env: dict[str, str]) -> list[dict[str, Any]]:
    query = """
query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    discussions(first: 50, after: $after, states: OPEN) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id number url title createdAt updatedAt
        category { name slug }
        author { login }
        comments(first: 50) {
          nodes {
            id body createdAt
            author { login }
          }
        }
      }
    }
  }
}
"""
    discussions: list[dict[str, Any]] = []
    cursor: str | None = None
    while True:
        data = graphql(query, env, owner=repo.owner, name=repo.name, after=cursor)
        page = data["data"]["repository"]["discussions"]
        discussions.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            return discussions
        cursor = page["pageInfo"]["endCursor"]


def fetch_issues(env: dict[str, str]) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh", "issue", "list", "--state", "all", "--limit", "200",
            "--json",
            "number,title,state,createdAt,updatedAt,closedAt,labels,milestone,assignees",
        ],
        cwd=REPO_ROOT, env=env,
    )
    return json.loads(result.stdout)


def fetch_prs(env: dict[str, str]) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh", "pr", "list", "--state", "all", "--limit", "200",
            "--json",
            "number,title,state,createdAt,updatedAt,mergedAt,url,author,reviewDecision",
        ],
        cwd=REPO_ROOT, env=env,
    )
    return json.loads(result.stdout)


def fetch_runs(env: dict[str, str]) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh", "run", "list", "--limit", "100",
            "--json",
            "conclusion,createdAt,displayTitle,name,status,url,workflowName",
        ],
        cwd=REPO_ROOT, env=env,
    )
    return json.loads(result.stdout)


def fetch_git_log(since: datetime) -> str:
    result = subprocess.run(
        [
            "git", "log", "--oneline",
            f"--since={since.isoformat()}",
            "--format=%h %s (%an)",
        ],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


# ---------------------------------------------------------------------------
# Activity scoring
# ---------------------------------------------------------------------------


def score_activity(data: ActivityData) -> int:
    since = data.watermark
    score = 0

    # PRs
    for pr in data.prs:
        merged_at = parse_datetime(pr.get("mergedAt"))
        if merged_at and merged_at > since:
            score += SCORE_PR_MERGED
        elif parse_datetime(pr.get("createdAt", "")) and parse_datetime(pr["createdAt"]) > since:
            score += SCORE_PR_OPENED

    # Issues
    for issue in data.issues:
        created = parse_datetime(issue.get("createdAt"))
        closed = parse_datetime(issue.get("closedAt"))
        if created and created > since:
            score += SCORE_ISSUE_OPENED
        elif closed and closed > since:
            score += SCORE_ISSUE_CLOSED

    # Discussions (exclude the Carl thread itself)
    thread_id = data.thread["id"] if data.thread else None
    for disc in data.discussions:
        if disc.get("id") == thread_id:
            continue
        disc_created = parse_datetime(disc.get("createdAt"))
        if disc_created and disc_created > since:
            score += SCORE_DISCUSSION_NEW
        for comment in disc.get("comments", {}).get("nodes", []):
            comment_created = parse_datetime(comment.get("createdAt"))
            if comment_created and comment_created > since:
                score += SCORE_DISCUSSION_COMMENT

    # CI failures
    for run in data.runs:
        run_created = parse_datetime(run.get("createdAt"))
        conclusion = (run.get("conclusion") or "").lower()
        if run_created and run_created > since and conclusion in FAILURE_CONCLUSIONS:
            score += SCORE_CI_FAILURE

    # Commits
    if data.git_log:
        score += data.git_log.count("\n") + 1

    return score


# ---------------------------------------------------------------------------
# Prompt building
# ---------------------------------------------------------------------------


def summarize_prs(prs: list[dict[str, Any]], since: datetime) -> str:
    merged = []
    opened = []
    for pr in prs:
        merged_at = parse_datetime(pr.get("mergedAt"))
        created_at = parse_datetime(pr.get("createdAt"))
        author = pr.get("author", {}).get("login", "unknown") if isinstance(pr.get("author"), dict) else "unknown"
        title = pr.get("title", "")
        number = pr.get("number", "?")
        if merged_at and merged_at > since:
            merged.append(f"- #{number} {title} (by {author})")
        elif created_at and created_at > since:
            opened.append(f"- #{number} {title} (by {author})")

    parts = []
    if merged:
        parts.append("**Merged PRs:**\n" + "\n".join(merged))
    if opened:
        parts.append("**Opened PRs:**\n" + "\n".join(opened))
    return "\n\n".join(parts) if parts else "No PR activity."


def summarize_issues(issues: list[dict[str, Any]], since: datetime) -> str:
    opened = []
    closed = []
    for issue in issues:
        created = parse_datetime(issue.get("createdAt"))
        closed_at = parse_datetime(issue.get("closedAt"))
        title = issue.get("title", "")
        number = issue.get("number", "?")
        if created and created > since:
            opened.append(f"- #{number} {title}")
        elif closed_at and closed_at > since:
            closed.append(f"- #{number} {title}")

    parts = []
    if opened:
        parts.append("**Opened:**\n" + "\n".join(opened))
    if closed:
        parts.append("**Closed:**\n" + "\n".join(closed))
    return "\n\n".join(parts) if parts else "No issue activity."


def summarize_runs(runs: list[dict[str, Any]], since: datetime) -> str:
    failures = []
    total = 0
    for run in runs:
        created = parse_datetime(run.get("createdAt"))
        if not created or created <= since:
            continue
        total += 1
        conclusion = (run.get("conclusion") or "").lower()
        if conclusion in FAILURE_CONCLUSIONS:
            name = run.get("workflowName") or run.get("name", "?")
            failures.append(f"- {name}: {conclusion}")

    if total == 0:
        return "No CI runs."
    if failures:
        return f"{total} runs total, {len(failures)} failures:\n" + "\n".join(failures)
    return f"{total} runs, all passing."


def summarize_discussions(
    discussions: list[dict[str, Any]], since: datetime, thread_id: str | None,
) -> str:
    items = []
    for disc in discussions:
        if disc.get("id") == thread_id:
            continue
        title = disc.get("title", "")
        number = disc.get("number", "?")
        new_comments = 0
        for comment in disc.get("comments", {}).get("nodes", []):
            comment_created = parse_datetime(comment.get("createdAt"))
            if comment_created and comment_created > since:
                new_comments += 1
        disc_created = parse_datetime(disc.get("createdAt"))
        is_new = disc_created and disc_created > since
        if is_new or new_comments > 0:
            label = "NEW" if is_new else f"+{new_comments} comments"
            items.append(f"- #{number} {title} ({label})")

    return "\n".join(items) if items else "No discussion activity."


def build_prompt(data: ActivityData) -> tuple[str, str]:
    """Build (system_message, user_message) for the Claude call."""
    persona = PERSONA_PATH.read_text(encoding="utf-8")

    thread_id = data.thread["id"] if data.thread else None
    since = data.watermark

    # Find last Carl post for continuity
    last_post = ""
    for comment in reversed(data.thread_comments):
        if WATERMARK_RE.search(comment.get("body", "")):
            body = comment["body"]
            # Strip the marker
            body = WATERMARK_RE.sub("", body).strip()
            last_post = body[-400:] if len(body) > 400 else body
            break

    user_msg = f"""Activity since {since.strftime('%Y-%m-%d %H:%M UTC')}:

## Pull Requests
{summarize_prs(data.prs, since)}

## Issues
{summarize_issues(data.issues, since)}

## CI Runs
{summarize_runs(data.runs, since)}

## Discussion Activity
{summarize_discussions(data.discussions, since, thread_id)}

## Recent Commits
{data.git_log or "No commits."}

## Your Previous Post (avoid repeating these observations)
{last_post or "This is your first post!"}

Write your commentary post now. Output only the markdown body, no preamble."""

    return persona, user_msg


# ---------------------------------------------------------------------------
# Claude API call
# ---------------------------------------------------------------------------


def call_claude(
    system: str, user: str, *, model: str, api_key: str,
) -> str:
    """Call the Anthropic Messages API via urllib (no SDK dependency)."""
    payload = json.dumps({
        "model": model,
        "max_tokens": 1024,
        "temperature": 0.7,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }).encode()

    req = Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )

    try:
        with urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        raise CarlError(f"Claude API call failed: {e}") from e

    for block in data.get("content", []):
        if block.get("type") == "text":
            return block["text"]

    raise CarlError(f"No text content in API response: {data}")


# ---------------------------------------------------------------------------
# Post comment
# ---------------------------------------------------------------------------


def post_comment(discussion_id: str, body: str, env: dict[str, str]) -> None:
    mutation = """
mutation($discId: ID!, $body: String!) {
  addDiscussionComment(input: {
    discussionId: $discId
    body: $body
  }) {
    comment { id }
  }
}
"""
    graphql(mutation, env, discId=discussion_id, body=body)


# ---------------------------------------------------------------------------
# Fixture support
# ---------------------------------------------------------------------------


def load_fixture_inputs(fixtures_dir: Path, repo: RepoInfo | None = None) -> ActivityData:
    if not fixtures_dir.is_dir():
        raise CarlError(f"fixture directory not found: {fixtures_dir}")

    missing = [f for f in FIXTURE_REQUIRED_FILES if not (fixtures_dir / f).is_file()]
    # thread.json is optional (first-run scenario)
    if missing:
        raise CarlError(f"fixture pack missing files: {', '.join(missing)}")

    repo_payload = load_json_file(fixtures_dir / "repo.json")
    if repo is None:
        repo = RepoInfo(
            owner=repo_payload.get("owner", "test"),
            name=repo_payload.get("name", "test"),
            repository_id=repo_payload.get("repository_id", ""),
            category_ids=repo_payload.get("category_ids", {}),
        )

    thread = None
    thread_comments: list[dict[str, Any]] = []
    thread_path = fixtures_dir / "thread.json"
    if thread_path.is_file():
        thread_data = load_json_file(thread_path)
        thread = thread_data.get("discussion")
        thread_comments = thread_data.get("comments", [])

    git_log = ""
    git_log_path = fixtures_dir / "git-log.txt"
    if git_log_path.is_file():
        git_log = git_log_path.read_text(encoding="utf-8").strip()

    watermark = extract_watermark(thread_comments)

    return ActivityData(
        repo=repo,
        thread=thread,
        thread_comments=thread_comments,
        discussions=load_json_file(fixtures_dir / "discussions.json"),
        issues=load_json_file(fixtures_dir / "issues.json"),
        prs=load_json_file(fixtures_dir / "prs.json"),
        runs=load_json_file(fixtures_dir / "runs.json"),
        git_log=git_log,
        watermark=watermark,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate commentary without posting")
    parser.add_argument("--fixtures-dir", type=Path,
                        help="Load data from fixture pack instead of live GitHub")
    parser.add_argument("--model", default="claude-sonnet-4-20250514",
                        help="Claude model for commentary generation")
    parser.add_argument("--threshold", type=int, default=5,
                        help="Minimum activity score to post (default: 5)")
    parser.add_argument("--json", action="store_true", dest="json_output",
                        help="Output structured JSON")
    return parser.parse_args()


def output_result(
    result: dict[str, Any], *, json_output: bool,
) -> None:
    if json_output:
        print(json.dumps(result, indent=2))
    else:
        if result.get("posted") or result.get("dry_run"):
            print(result.get("commentary", ""))
        elif result.get("skipped_reason"):
            log(result["skipped_reason"])


def main() -> None:
    args = parse_args()
    env = {**os.environ}

    if args.fixtures_dir:
        fixture_path = args.fixtures_dir
        if not fixture_path.is_absolute():
            fixture_path = (REPO_ROOT / fixture_path).resolve()
        log(f"Loading fixture data from {fixture_path}")
        data = load_fixture_inputs(fixture_path)
    else:
        log("Fetching live data from GitHub")
        repo = repo_info(env)
        thread, comments = find_or_create_thread(repo, env)
        watermark = extract_watermark(comments)

        log("Gathering activity data...")
        data = ActivityData(
            repo=repo,
            thread=thread,
            thread_comments=comments,
            discussions=fetch_discussions(repo, env),
            issues=fetch_issues(env),
            prs=fetch_prs(env),
            runs=fetch_runs(env),
            git_log=fetch_git_log(watermark),
            watermark=watermark,
        )

    score = score_activity(data)
    log(f"Activity score: {score} (threshold: {args.threshold})")

    thread_url = data.thread.get("url", "") if data.thread else ""

    if score < args.threshold:
        result = {
            "posted": False,
            "commentary": "",
            "thread_url": thread_url,
            "activity_score": score,
            "skipped_reason": f"Below activity threshold (score: {score}, threshold: {args.threshold})",
        }
        output_result(result, json_output=args.json_output)
        return

    # Build prompt and generate commentary
    system_msg, user_msg = build_prompt(data)

    if args.fixtures_dir or args.dry_run:
        # Fixture mode or dry-run: show the prompt, skip API and posting
        log("Dry-run — showing prompt instead of calling API")
        commentary = f"[DRY RUN — PROMPT BELOW]\n\n{user_msg}"
        result = {
            "posted": False,
            "dry_run": True,
            "commentary": commentary,
            "thread_url": thread_url,
            "activity_score": score,
            "skipped_reason": None,
        }
        output_result(result, json_output=args.json_output)
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        raise CarlError("ANTHROPIC_API_KEY environment variable is required")
    log(f"Calling Claude ({args.model})...")
    commentary = call_claude(system_msg, user_msg, model=args.model, api_key=api_key)

    # Append watermark and post
    timestamp = now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")
    body = f"{commentary}\n\n<!-- carl-community:timestamp={timestamp} -->"

    if not data.thread:
        raise CarlError("No thread available for posting")

    log(f"Posting to thread #{data.thread['number']}...")
    post_comment(data.thread["id"], body, env)
    log("Posted successfully")

    result = {
        "posted": True,
        "commentary": commentary,
        "thread_url": thread_url,
        "activity_score": score,
        "skipped_reason": None,
    }
    output_result(result, json_output=args.json_output)


if __name__ == "__main__":
    try:
        main()
    except CarlError as e:
        log(f"error: {e}")
        sys.exit(1)
