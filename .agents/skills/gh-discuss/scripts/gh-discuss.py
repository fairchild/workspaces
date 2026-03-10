#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Multi-agent coordination via GitHub Discussions.

Usage:
    gh-discuss.py setup
    gh-discuss.py verify
    gh-discuss.py dashboard
    gh-discuss.py list [--unclaimed] [--decisions]
    gh-discuss.py create TITLE [--body BODY] [--priority P] [--decision] [--category CAT]
    gh-discuss.py claim NUMBER
    gh-discuss.py update NUMBER MESSAGE
    gh-discuss.py complete NUMBER [--pr PR]
    gh-discuss.py abandon NUMBER

Authentication:
    By default, uses the gh CLI's personal auth. To post as a GitHub App bot,
    configure credentials at ~/.config/gh-discuss/ (see 'setup' command).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# GitHub App authentication (optional — falls back to personal gh auth)
# ---------------------------------------------------------------------------

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _generate_jwt(app_id: str, key_path: str) -> str:
    """Generate a GitHub App JWT using openssl for RS256 signing."""
    now = int(time.time())
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = _b64url(json.dumps({
        "iat": now - 60,
        "exp": now + (10 * 60),
        "iss": int(app_id),
    }).encode())
    signing_input = f"{header}.{payload}"

    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
        input=signing_input.encode(),
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"error: JWT signing failed: {result.stderr.decode().strip()}", file=sys.stderr)
        sys.exit(1)

    signature = _b64url(result.stdout)
    return f"{signing_input}.{signature}"


def _get_installation_token(app_id: str, installation_id: str, key_path: str) -> str:
    """Exchange a JWT for a GitHub App installation access token.

    Uses urllib directly because gh CLI sets 'Authorization: token ...'
    but GitHub App JWTs require 'Authorization: Bearer ...'.
    """
    from urllib.request import Request, urlopen

    jwt_token = _generate_jwt(app_id, key_path)
    req = Request(
        f"https://api.github.com/app/installations/{installation_id}/access_tokens",
        method="POST",
        headers={
            "Authorization": f"Bearer {jwt_token}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urlopen(req) as resp:
            data = json.loads(resp.read())
            return data["token"]
    except Exception as e:
        print(f"error: installation token exchange failed: {e}", file=sys.stderr)
        sys.exit(1)


def _resolve_app_credentials() -> tuple[str, str, str] | None:
    """Resolve GitHub App credentials from env vars or ~/.config/gh-discuss/.

    Returns (app_id, installation_id, private_key_path) or None.
    """
    config_dir = Path.home() / ".config" / "gh-discuss"

    app_id = os.environ.get("GH_DISCUSS_APP_ID")
    if not app_id and (config_dir / "app-id").exists():
        app_id = (config_dir / "app-id").read_text().strip()

    installation_id = os.environ.get("GH_DISCUSS_INSTALLATION_ID")
    if not installation_id and (config_dir / "installation-id").exists():
        installation_id = (config_dir / "installation-id").read_text().strip()

    key_path = os.environ.get("GH_DISCUSS_PRIVATE_KEY_PATH")
    if not key_path and (config_dir / "app.pem").exists():
        key_path = str(config_dir / "app.pem")

    if app_id and installation_id and key_path:
        if not Path(key_path).exists():
            print(f"error: private key not found: {key_path}", file=sys.stderr)
            sys.exit(1)
        return app_id, installation_id, key_path

    return None


def _auth_env() -> dict[str, str] | None:
    """Build subprocess env with app token, or None for default gh auth."""
    creds = _resolve_app_credentials()
    if creds is None:
        print("note: no app credentials found, posting as personal account", file=sys.stderr)
        return None
    app_id, installation_id, key_path = creds
    token = _get_installation_token(app_id, installation_id, key_path)
    return {**os.environ, "GH_TOKEN": token}


# ---------------------------------------------------------------------------
# Repo / category discovery (auto-detected, cached per session)
# ---------------------------------------------------------------------------

def _cache_path(repo_slug: str) -> Path:
    h = hashlib.md5(repo_slug.encode()).hexdigest()[:8]
    return Path(tempfile.gettempdir()) / f"gh-discuss-{h}.json"


def _gh_json(args: list[str], env: dict[str, str] | None = None) -> Any:
    result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        print(f"error: gh {' '.join(args)}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def _graphql(query: str, env: dict[str, str] | None = None, **variables: str) -> dict:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        cmd.extend(["-f", f"{k}={v}"])
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        print(f"error: graphql: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    data = json.loads(result.stdout)
    if "errors" in data:
        print(f"error: graphql: {data['errors'][0]['message']}", file=sys.stderr)
        sys.exit(1)
    return data


def repo_info(env: dict[str, str] | None = None) -> dict:
    """Return {id, owner, name, slug, categories} for current repo. Cached in /tmp."""
    info = _gh_json(["repo", "view", "--json", "owner,name,id"], env=env)
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
    """ % (owner, name), env=env)

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

def cmd_dashboard(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
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
           get_category_id(info, "Q&A")), env=auth)

    repo = data["data"]["repository"]
    tasks = repo["general"]["nodes"]
    decisions = repo["qa"]["nodes"]

    ideas = [t for t in tasks if "[idea]" in t["title"]]
    non_ideas = [t for t in tasks if "[idea]" not in t["title"]]
    unclaimed = [t for t in non_ideas if "[claimed:" not in t["title"]]
    claimed = [t for t in non_ideas if "[claimed:" in t["title"]]
    unanswered = [d for d in decisions if not d.get("isAnswered")]
    answered = [d for d in decisions if d.get("isAnswered")]

    print(f"=== Dashboard ({info['slug']}) ===\n")

    print(f"Open Tasks: {len(non_ideas)}  (unclaimed: {len(unclaimed)}, claimed: {len(claimed)})")
    for t in unclaimed:
        print(f"  #{t['number']}  {t['title']}")
    for t in claimed:
        print(f"  #{t['number']}  {t['title']}")

    if ideas:
        print(f"\nIdeas: {len(ideas)}")
        for t in ideas:
            print(f"  #{t['number']}  {t['title']}")

    print(f"\nPending Decisions: {len(unanswered)}  (answered: {len(answered)})")
    for d in unanswered:
        print(f"  #{d['number']}  {d['title']}")
    for d in answered:
        print(f"  #{d['number']}  {d['title']}  [ANSWERED]")

    print()


def cmd_list(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
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
    """ % (owner, name, cat_id), env=auth)

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


def cmd_create(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)

    if args.category:
        cat_id = get_category_id(info, args.category)
        prefix = ""  # caller controls prefix in title
    elif args.decision:
        cat_id = get_category_id(info, "Q&A")
        prefix = "[decision]"
    else:
        cat_id = get_category_id(info, "General")
        prefix = "[task]"

    if prefix:
        raw_title = re.sub(r"^\[(?:task|decision|idea)\]\s*", "", args.title)
        title = f"{prefix} {raw_title}"
    else:
        title = args.title  # caller controls full title (--category mode)
    body_parts = [comment_header(), ""]

    if args.from_backlog:
        backlog_path = Path(args.from_backlog)
        if backlog_path.exists():
            raw = backlog_path.read_text()
            # Extract title from first markdown heading
            for line in raw.splitlines():
                if line.startswith("# "):
                    heading = re.sub(r"^\[(?:task|decision)\]\s*", "", line[2:].strip())
                    title = f"{prefix} {heading}"
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
        env=auth,
        repoId=info["id"],
        catId=cat_id,
        title=title,
        body=body,
    )

    disc = data["data"]["createDiscussion"]["discussion"]
    print(f"Created #{disc['number']}: {title}")
    print(f"  {disc['url']}")


def _get_discussion(info: dict, number: int, env: dict[str, str] | None = None) -> dict:
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
    """ % (info["owner"], info["name"], number), env=env)
    disc = data["data"]["repository"]["discussion"]
    if not disc:
        print(f"error: discussion #{number} not found", file=sys.stderr)
        sys.exit(1)
    return disc


def cmd_claim(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
    disc = _get_discussion(info, args.number, env=auth)
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
        env=auth,
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
        env=auth,
        discId=disc["id"],
        title=new_title,
    )

    # Verify claim — re-read to check for race condition
    updated = _get_discussion(info, args.number, env=auth)
    if f"[claimed:{agent}]" not in updated["title"]:
        print(f"warning: claim may have been overwritten by another agent", file=sys.stderr)
        sys.exit(1)

    print(f"Claimed #{args.number}: {new_title}")


def cmd_update(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
    disc = _get_discussion(info, args.number, env=auth)

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
        env=auth,
        discId=disc["id"],
        body=body,
    )
    print(f"Updated #{args.number}")


def cmd_complete(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
    disc = _get_discussion(info, args.number, env=auth)

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
        env=auth,
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
        env=auth,
        discId=disc["id"],
    )
    print(f"Completed #{args.number}")


def cmd_abandon(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    info = repo_info(env=auth)
    disc = _get_discussion(info, args.number, env=auth)

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
        env=auth,
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
        env=auth,
        discId=disc["id"],
        title=new_title,
    )

    print(f"Abandoned #{args.number}: {new_title}")


def cmd_setup(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    """Validate GitHub App credentials and print authenticated identity."""
    creds = _resolve_app_credentials()
    if creds is None:
        config_dir = Path.home() / ".config" / "gh-discuss"
        print("No GitHub App credentials found.\n")
        print("To set up, create a GitHub App and store credentials:")
        print(f"  mkdir -p {config_dir}")
        print(f"  echo 'YOUR_APP_ID' > {config_dir}/app-id")
        print(f"  echo 'YOUR_INSTALLATION_ID' > {config_dir}/installation-id")
        print(f"  cp ~/Downloads/your-app.pem {config_dir}/app.pem")
        print(f"  chmod 600 {config_dir}/app.pem")
        print("\nOr use env vars: GH_DISCUSS_APP_ID, GH_DISCUSS_INSTALLATION_ID, GH_DISCUSS_PRIVATE_KEY_PATH")
        sys.exit(1)

    app_id, installation_id, key_path = creds
    print(f"App ID: {app_id}")
    print(f"Installation ID: {installation_id}")
    print(f"Private key: {key_path}")

    # Test JWT generation
    print("\nGenerating JWT...", end=" ")
    jwt = _generate_jwt(app_id, key_path)
    print("ok")

    # Test installation token exchange
    print("Exchanging for installation token...", end=" ")
    token = _get_installation_token(app_id, installation_id, key_path)
    print(f"ok (token: {token[:8]}...)")

    # Test API access
    from urllib.request import Request, urlopen
    print("Checking API access...", end=" ")
    req = Request(
        "https://api.github.com/app",
        headers={
            "Authorization": f"Bearer {jwt}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urlopen(req) as resp:
            app_info = json.loads(resp.read())
            print(f"ok (app: {app_info['slug']})")
    except Exception as e:
        print(f"warning: {e}")

    print("\nSetup verified. Posts will appear as the app bot account.")


def cmd_verify(args: argparse.Namespace, auth: dict[str, str] | None = None) -> None:
    """Post a test comment, verify it came from the bot, then delete it."""
    if auth is None:
        print("error: verify requires app credentials (run 'setup' first)", file=sys.stderr)
        sys.exit(1)

    info = repo_info(env=auth)

    # Find an open discussion
    data = _graphql("""
    {
      repository(owner: "%s", name: "%s") {
        discussions(first: 1, states: OPEN) {
          nodes { id number title }
        }
      }
    }
    """ % (info["owner"], info["name"]), env=auth)

    discussions = data["data"]["repository"]["discussions"]["nodes"]
    if not discussions:
        print("error: no open discussions to test with", file=sys.stderr)
        sys.exit(1)

    disc = discussions[0]
    marker = f"__verify_{int(time.time())}__"

    print(f"Using discussion #{disc['number']}: {disc['title'][:50]}")

    # Post
    print("  posting test comment...", end=" ")
    comment_data = _graphql(
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
        env=auth,
        discId=disc["id"],
        body=f"Verification test {marker}",
    )
    comment_id = comment_data["data"]["addDiscussionComment"]["comment"]["id"]
    print("ok")

    # Check author
    print("  checking author...", end=" ")
    verify_data = _graphql("""
    {
      node(id: "%s") {
        ... on DiscussionComment {
          author { login __typename }
        }
      }
    }
    """ % comment_id, env=auth)
    author_info = verify_data["data"]["node"]["author"]
    author = author_info["login"]
    author_type = author_info.get("__typename", "Unknown")
    print(f"{author} (type: {author_type})")

    # Cleanup
    print("  deleting test comment...", end=" ")
    _graphql(
        """
        mutation($id: ID!) {
          deleteDiscussionComment(input: { id: $id }) {
            comment { id }
          }
        }
        """,
        env=auth,
        id=comment_id,
    )
    print("ok")

    # Verdict: bot if type is Bot, or if author differs from repo owner
    is_bot = author_type == "Bot" or author != info["owner"]
    if is_bot:
        print(f"\nPASSED: comments post as '{author}' (type: {author_type})")
    else:
        print(f"\nFAILED: comments post as '{author}' (type: {author_type}) — expected Bot", file=sys.stderr)
        sys.exit(1)


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
    sub.add_parser("setup", help="Validate GitHub App credentials")
    sub.add_parser("verify", help="Post a test comment as bot, verify author, delete it")

    p_list = sub.add_parser("list", help="List open discussions")
    p_list.add_argument("--unclaimed", action="store_true", help="Only unclaimed tasks")
    p_list.add_argument("--decisions", action="store_true", help="Show pending decisions instead of tasks")
    p_list.add_argument("--json", dest="json_output", action="store_true", help="JSON output")

    p_create = sub.add_parser("create", help="Create a task or decision")
    p_create.add_argument("title", nargs="?", default="", help="Discussion title")
    p_create.add_argument("--body", "-b", help="Discussion body")
    p_create.add_argument("--priority", "-p", choices=["p0", "p1", "p2"], help="Priority tag in title")
    p_create.add_argument("--category", help="Discussion category name (overrides default)")
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
    skip_auto_auth = {"setup"}
    auth = _auth_env() if args.command not in skip_auto_auth else None
    commands = {
        "dashboard": cmd_dashboard,
        "setup": cmd_setup,
        "verify": cmd_verify,
        "list": cmd_list,
        "create": cmd_create,
        "claim": cmd_claim,
        "update": cmd_update,
        "complete": cmd_complete,
        "abandon": cmd_abandon,
    }
    commands[args.command](args, auth)


if __name__ == "__main__":
    main()
