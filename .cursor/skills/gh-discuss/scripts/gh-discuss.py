#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Multi-agent coordination via GitHub Discussions.

Usage:
    gh-discuss.py dashboard
    gh-discuss.py list [--unclaimed] [--decisions]
    gh-discuss.py create TITLE [--body BODY] [--priority P] [--decision]
    gh-discuss.py claim NUMBER
    gh-discuss.py update NUMBER MESSAGE
    gh-discuss.py complete NUMBER [--pr PR]
    gh-discuss.py abandon NUMBER
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Repo / category discovery (auto-detected, cached per session)
# ---------------------------------------------------------------------------

def _cache_path(repo_slug: str) -> Path:
    h = hashlib.md5(repo_slug.encode()).hexdigest()[:8]
    return Path(tempfile.gettempdir()) / f"gh-discuss-{h}.json"


def _gh_json(args: list[str]) -> Any:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"error: gh {' '.join(args)}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def _graphql(query: str, **variables: str) -> dict:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        cmd.extend(["-f", f"{k}={v}"])
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"error: graphql: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    data = json.loads(result.stdout)
    if "errors" in data:
        print(f"error: graphql: {data['errors'][0]['message']}", file=sys.stderr)
        sys.exit(1)
    return data


def repo_info() -> dict:
    """Return {id, owner, name, slug, categories} for current repo. Cached in /tmp."""
    info = _gh_json(["repo", "view", "--json", "owner,name,id"])
    owner = info["owner"]["login"]
    name = info["name"]
    slug = f"{owner}/{name}"
    cache = _cache_path(slug)

    if cache.exists():
        cached = json.loads(cache.read_text())
        if cached.get("slug") == slug:
            return cached

    data = _graphql("""
    {
      repository(owner: "%s", name: "%s") {
        discussionCategories(first: 20) {
          nodes { id name slug }
        }
      }
    }
    """ % (owner, name))

    repo = data["data"]["repository"]
    categories = {c["slug"]: c["id"] for c in repo["discussionCategories"]["nodes"]}
    cat_names = {c["name"]: c["id"] for c in repo["discussionCategories"]["nodes"]}

    result = {
        "id": info["id"],
        "owner": owner,
        "name": name,
        "slug": slug,
        "categories": categories,
        "category_names": cat_names,
    }
    cache.write_text(json.dumps(result))
    return result


def agent_id() -> str:
    """Derive agent name from git worktree directory."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip()).name
    return "unknown-agent"


def current_branch() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def comment_header() -> str:
    return f"**Agent**: `{agent_id()}` | **Branch**: `{current_branch()}`"


# ---------------------------------------------------------------------------
# Category helpers
# ---------------------------------------------------------------------------

def get_category_id(info: dict, name: str) -> str:
    """Get category ID by name or slug, case-insensitive."""
    for key in [name, name.lower()]:
        if key in info["categories"]:
            return info["categories"][key]
    for cat_name, cat_id in info["category_names"].items():
        if cat_name.lower() == name.lower():
            return cat_id
    print(f"error: category '{name}' not found. Available: {list(info['category_names'].keys())}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_dashboard(args: argparse.Namespace) -> None:
    info = repo_info()
    owner, name = info["owner"], info["name"]

    data = _graphql("""
    {
      repository(owner: "%s", name: "%s") {
        general: discussions(first: 30, states: OPEN, categoryId: "%s") {
          nodes { number title }
        }
        qa: discussions(first: 30, states: OPEN, categoryId: "%s") {
          nodes { number title isAnswered }
        }
      }
    }
    """ % (owner, name,
           get_category_id(info, "General"),
           get_category_id(info, "Q&A")))

    repo = data["data"]["repository"]
    tasks = repo["general"]["nodes"]
    decisions = repo["qa"]["nodes"]

    unclaimed = [t for t in tasks if "[claimed:" not in t["title"]]
    claimed = [t for t in tasks if "[claimed:" in t["title"]]
    unanswered = [d for d in decisions if not d.get("isAnswered")]
    answered = [d for d in decisions if d.get("isAnswered")]

    print(f"=== Dashboard ({info['slug']}) ===\n")

    print(f"Open Tasks: {len(tasks)}  (unclaimed: {len(unclaimed)}, claimed: {len(claimed)})")
    for t in unclaimed:
        print(f"  #{t['number']}  {t['title']}")
    for t in claimed:
        print(f"  #{t['number']}  {t['title']}")

    print(f"\nPending Decisions: {len(unanswered)}  (answered: {len(answered)})")
    for d in unanswered:
        print(f"  #{d['number']}  {d['title']}")
    for d in answered:
        print(f"  #{d['number']}  {d['title']}  [ANSWERED]")

    print()


def cmd_list(args: argparse.Namespace) -> None:
    info = repo_info()
    owner, name = info["owner"], info["name"]

    if args.decisions:
        cat_id = get_category_id(info, "Q&A")
    else:
        cat_id = get_category_id(info, "General")

    data = _graphql("""
    {
      repository(owner: "%s", name: "%s") {
        discussions(first: 50, states: OPEN, categoryId: "%s") {
          nodes {
            number title body
            author { login }
            comments { totalCount }
            createdAt
            isAnswered
          }
        }
      }
    }
    """ % (owner, name, cat_id))

    discussions = data["data"]["repository"]["discussions"]["nodes"]

    if args.unclaimed:
        discussions = [d for d in discussions if "[claimed:" not in d["title"]]

    if args.decisions:
        discussions = [d for d in discussions if not d.get("isAnswered")]

    if args.json_output:
        print(json.dumps(discussions, indent=2))
        return

    for d in discussions:
        comments = d["comments"]["totalCount"]
        print(f"#{d['number']}  {d['title']}  ({comments} comments)")


def cmd_create(args: argparse.Namespace) -> None:
    info = repo_info()

    if args.decision:
        cat_id = get_category_id(info, "Q&A")
        prefix = "[decision]"
    else:
        cat_id = get_category_id(info, "General")
        prefix = "[task]"

    title = f"{prefix} {args.title}"
    body_parts = [comment_header(), ""]

    if args.from_backlog:
        backlog_path = Path(args.from_backlog)
        if backlog_path.exists():
            raw = backlog_path.read_text()
            # Extract title from first markdown heading
            for line in raw.splitlines():
                if line.startswith("# "):
                    title = f"{prefix} {line[2:].strip()}"
                    break
            body_parts.append(f"*Synced from `{args.from_backlog}`*\n\n---\n")
            body_parts.append(raw[:3000])
        else:
            print(f"warning: {args.from_backlog} not found, creating without backlog content", file=sys.stderr)

    if args.body:
        body_parts.append(args.body)

    body = "\n".join(body_parts)

    data = _graphql(
        """
        mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
          createDiscussion(input: {
            repositoryId: $repoId
            categoryId: $catId
            title: $title
            body: $body
          }) {
            discussion { id number url }
          }
        }
        """,
        repoId=info["id"],
        catId=cat_id,
        title=title,
        body=body,
    )

    disc = data["data"]["createDiscussion"]["discussion"]
    print(f"Created #{disc['number']}: {title}")
    print(f"  {disc['url']}")


def _get_discussion(info: dict, number: int) -> dict:
    data = _graphql("""
    {
      repository(owner: "%s", name: "%s") {
        discussion(number: %d) {
          id number title body closed
          category { name }
          author { login }
          comments(first: 50) {
            nodes { id body author { login } createdAt }
          }
        }
      }
    }
    """ % (info["owner"], info["name"], number))
    disc = data["data"]["repository"]["discussion"]
    if not disc:
        print(f"error: discussion #{number} not found", file=sys.stderr)
        sys.exit(1)
    return disc


def cmd_claim(args: argparse.Namespace) -> None:
    info = repo_info()
    disc = _get_discussion(info, args.number)
    agent = agent_id()

    if "[claimed:" in disc["title"]:
        match = re.search(r"\[claimed:([^\]]+)\]", disc["title"])
        if match:
            claimer = match.group(1)
            if claimer == agent:
                print(f"Already claimed by you ({agent})")
                return
            print(f"error: already claimed by {claimer}", file=sys.stderr)
            sys.exit(1)

    # Post claim comment
    body = f"{comment_header()}\n\nClaiming this task."
    _graphql(
        """
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }
        """,
        discId=disc["id"],
        body=body,
    )

    # Update title to mark as claimed
    new_title = disc["title"].replace("[task]", f"[task][claimed:{agent}]")
    _graphql(
        """
        mutation($discId: ID!, $title: String!) {
          updateDiscussion(input: {
            discussionId: $discId
            title: $title
          }) {
            discussion { id title }
          }
        }
        """,
        discId=disc["id"],
        title=new_title,
    )

    # Verify claim — re-read to check for race condition
    updated = _get_discussion(info, args.number)
    if f"[claimed:{agent}]" not in updated["title"]:
        print(f"warning: claim may have been overwritten by another agent", file=sys.stderr)
        sys.exit(1)

    print(f"Claimed #{args.number}: {new_title}")


def cmd_update(args: argparse.Namespace) -> None:
    info = repo_info()
    disc = _get_discussion(info, args.number)

    body = f"{comment_header()}\n\n{args.message}"
    _graphql(
        """
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }
        """,
        discId=disc["id"],
        body=body,
    )
    print(f"Updated #{args.number}")


def cmd_complete(args: argparse.Namespace) -> None:
    info = repo_info()
    disc = _get_discussion(info, args.number)

    parts = [comment_header(), "", "Task completed."]
    if args.pr:
        parts.append(f"\nPR: #{args.pr}")
    body = "\n".join(parts)

    _graphql(
        """
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }
        """,
        discId=disc["id"],
        body=body,
    )

    _graphql(
        """
        mutation($discId: ID!) {
          closeDiscussion(input: {
            discussionId: $discId
            reason: RESOLVED
          }) {
            discussion { id closed }
          }
        }
        """,
        discId=disc["id"],
    )
    print(f"Completed #{args.number}")


def cmd_abandon(args: argparse.Namespace) -> None:
    info = repo_info()
    disc = _get_discussion(info, args.number)

    body = f"{comment_header()}\n\nAbandoning this task — available for others."
    _graphql(
        """
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }
        """,
        discId=disc["id"],
        body=body,
    )

    new_title = re.sub(r"\[claimed:[^\]]+\]", "", disc["title"])
    _graphql(
        """
        mutation($discId: ID!, $title: String!) {
          updateDiscussion(input: {
            discussionId: $discId
            title: $title
          }) {
            discussion { id title }
          }
        }
        """,
        discId=disc["id"],
        title=new_title,
    )

    print(f"Abandoned #{args.number}: {new_title}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Multi-agent coordination via GitHub Discussions",
        prog="gh-discuss.py",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("dashboard", help="Show current coordination state")

    p_list = sub.add_parser("list", help="List open discussions")
    p_list.add_argument("--unclaimed", action="store_true", help="Only unclaimed tasks")
    p_list.add_argument("--decisions", action="store_true", help="Show pending decisions instead of tasks")
    p_list.add_argument("--json", dest="json_output", action="store_true", help="JSON output")

    p_create = sub.add_parser("create", help="Create a task or decision")
    p_create.add_argument("title", nargs="?", default="", help="Discussion title")
    p_create.add_argument("--body", "-b", help="Discussion body")
    p_create.add_argument("--priority", "-p", choices=["p0", "p1", "p2"], help="Priority tag in title")
    p_create.add_argument("--decision", "-d", action="store_true", help="Create as Q&A decision")
    p_create.add_argument("--from-backlog", help="Path to backlog file to sync")

    p_claim = sub.add_parser("claim", help="Claim a task")
    p_claim.add_argument("number", type=int, help="Discussion number")

    p_update = sub.add_parser("update", help="Post a progress update")
    p_update.add_argument("number", type=int, help="Discussion number")
    p_update.add_argument("message", help="Progress message")

    p_complete = sub.add_parser("complete", help="Complete a task")
    p_complete.add_argument("number", type=int, help="Discussion number")
    p_complete.add_argument("--pr", type=int, help="PR number to link")

    p_abandon = sub.add_parser("abandon", help="Abandon a claimed task")
    p_abandon.add_argument("number", type=int, help="Discussion number")

    args = parser.parse_args()
    commands = {
        "dashboard": cmd_dashboard,
        "list": cmd_list,
        "create": cmd_create,
        "claim": cmd_claim,
        "update": cmd_update,
        "complete": cmd_complete,
        "abandon": cmd_abandon,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
