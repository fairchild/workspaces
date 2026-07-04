#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fable — daily orchestrator that surfaces one recommendation for the owner.

Reads the project's live state (open PRs, `[idea]` discussions), ranks the
things competing for the owner's attention, and names the single highest-value
next action plus a short ranked tail. Fable never acts and never invents an
approval channel: every recommendation points at an existing surface the owner
already uses — merge this PR, reply "plan it" on that idea — preserving the
owner-as-sole-authority invariant in docs/development/agent-owner-protocol.md.

This v1 is deterministic (Oliver-style: boring, never hallucinates). An LLM
synthesis layer is a natural v2 once the ranking earns trust.

Usage:
    fable-orchestrator.py                  # gather live, print the recommendation
    fable-orchestrator.py --json           # structured output
    fable-orchestrator.py --post           # also post to the running discussion thread
    fable-orchestrator.py --fixtures-dir D # replay from a fixture pack (no network)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
THREAD_TITLE = "[orchestrator] Fable — Daily Recommendation"
PREFERRED_CATEGORY = "general"

# Attention weights. A merge-ready PR is pure throughput (work done, only the
# owner gate remains), so it outranks an idea that still needs planning.
SCORE_MERGE_READY = 100
SCORE_CHANGES_REQUESTED = 45
SCORE_IDEA_AWAITING_APPROVAL = 60


class FableError(RuntimeError):
    """Raised when the orchestrator cannot complete."""


@dataclass
class Candidate:
    kind: str  # merge_ready | changes_requested | idea_awaiting_approval
    ref: str  # e.g. "PR #742" or "Discussion #44"
    title: str
    url: str
    score: int
    action: str  # the existing-surface action the owner takes
    reason: str
    tiebreak: float = 0.0  # among equal scores, higher sorts first (recency)


@dataclass
class Pulse:
    open_prs: int
    merge_ready: int
    ideas_awaiting: int
    changes_requested: int


@dataclass
class Snapshot:
    prs: list[dict[str, Any]]
    discussions: list[dict[str, Any]]
    thread: dict[str, Any] | None = None
    now: datetime = field(default_factory=lambda: datetime.now(tz=UTC))


# ---------------------------------------------------------------------------
# Shell / GitHub helpers
# ---------------------------------------------------------------------------


def log(message: str) -> None:
    print(f"[fable] {message}", file=sys.stderr)


def run_checked(cmd: list[str], *, input: str | None = None) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO_ROOT, input=input)
    if result.returncode != 0:
        raise FableError(
            f"command failed ({' '.join(cmd)}): "
            f"{(result.stderr or result.stdout).strip() or 'unknown error'}"
        )
    return result.stdout


def graphql(query: str, **variables: Any) -> dict[str, Any]:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        cmd.extend(["-f", f"{key}={value}"])
    data = json.loads(run_checked(cmd))
    if "errors" in data:
        raise FableError(f"graphql error: {data['errors']}")
    return data


def repo_owner_name() -> tuple[str, str]:
    slug = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
        return owner, name
    data = json.loads(run_checked(["gh", "repo", "view", "--json", "owner,name"]))
    return data["owner"]["login"], data["name"]


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Gathering
# ---------------------------------------------------------------------------


def gather_prs() -> list[dict[str, Any]]:
    return json.loads(
        run_checked(
            [
                "gh", "pr", "list", "--state", "open", "--limit", "100",
                "--json", "number,title,url,isDraft,reviewDecision,labels,updatedAt,author",
            ]
        )
    )


def gather_discussions(owner: str, name: str) -> list[dict[str, Any]]:
    query = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 100, states: OPEN) {
      nodes { number title url createdAt }
    }
  }
}
"""
    data = graphql(query, owner=owner, name=name)
    return data["data"]["repository"]["discussions"]["nodes"]


# ---------------------------------------------------------------------------
# Ranking (pure — the testable core)
# ---------------------------------------------------------------------------


def label_names(pr: dict[str, Any]) -> set[str]:
    return {str(label.get("name", "")) for label in pr.get("labels", []) or []}


def is_merge_ready(pr: dict[str, Any]) -> bool:
    if pr.get("isDraft"):
        return False
    return "mergeable" in label_names(pr) or pr.get("reviewDecision") == "APPROVED"


def is_idea_awaiting_approval(title: str) -> bool:
    # The documented lifecycle uses `[idea]` as a title *prefix*; matching it
    # anywhere pulls in malformed/rambling posts that merely mention it.
    lowered = title.strip().lower()
    return lowered.startswith("[idea]") and "[endorsed]" not in lowered


def score_snapshot(snapshot: Snapshot) -> list[Candidate]:
    candidates: list[Candidate] = []

    for pr in snapshot.prs:
        title = str(pr.get("title", "")).strip()
        url = str(pr.get("url", ""))
        ref = f"PR #{pr.get('number')}"
        recency = timestamp_of(pr.get("updatedAt"))
        if is_merge_ready(pr):
            candidates.append(
                Candidate(
                    kind="merge_ready",
                    ref=ref,
                    title=title,
                    url=url,
                    score=SCORE_MERGE_READY,
                    action=f"Merge {ref}",
                    reason="Agent-approved and waiting only on your merge — pure throughput.",
                    tiebreak=recency,
                )
            )
        elif not pr.get("isDraft") and pr.get("reviewDecision") == "CHANGES_REQUESTED":
            candidates.append(
                Candidate(
                    kind="changes_requested",
                    ref=ref,
                    title=title,
                    url=url,
                    score=SCORE_CHANGES_REQUESTED,
                    action=f"Look at {ref}",
                    reason="Review requested changes; it is stalled until someone responds.",
                    tiebreak=recency,
                )
            )

    for disc in snapshot.discussions:
        title = str(disc.get("title", "")).strip()
        if not is_idea_awaiting_approval(title):
            continue
        ref = f"Discussion #{disc.get('number')}"
        candidates.append(
            Candidate(
                kind="idea_awaiting_approval",
                ref=ref,
                title=title,
                url=str(disc.get("url", "")),
                score=SCORE_IDEA_AWAITING_APPROVAL,
                action=f'Reply "plan it" on {ref} to send it to Peter',
                reason="An idea is proposed and waiting on your approve-to-plan decision.",
                # Freshest proposal first: a new idea is a live decision, while a
                # long-unendorsed one is likelier stale than urgent.
                tiebreak=timestamp_of(disc.get("createdAt")),
            )
        )

    candidates.sort(key=lambda c: (c.score, c.tiebreak), reverse=True)
    return candidates


def timestamp_of(value: str | None) -> float:
    parsed = parse_datetime(value)
    return parsed.timestamp() if parsed else 0.0


def compute_pulse(snapshot: Snapshot, candidates: list[Candidate]) -> Pulse:
    return Pulse(
        open_prs=len(snapshot.prs),
        merge_ready=sum(1 for c in candidates if c.kind == "merge_ready"),
        ideas_awaiting=sum(1 for c in candidates if c.kind == "idea_awaiting_approval"),
        changes_requested=sum(1 for c in candidates if c.kind == "changes_requested"),
    )


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_markdown(candidates: list[Candidate], pulse: Pulse, now: datetime) -> str:
    date = now.strftime("%Y-%m-%d")
    if not candidates:
        return (
            f"## Fable — Daily Recommendation ({date})\n\n"
            "Nothing needs your attention today: no merge-ready PRs, no ideas "
            "awaiting approval. The team is either heads-down or idle.\n"
        )

    top = candidates[0]
    lines = [
        f"## Fable — Daily Recommendation ({date})",
        "",
        f"**Do this first: {top.action}.**",
        "",
        f"[{top.ref}]({top.url}) — {top.title}",
        f"_{top.reason}_",
    ]

    tail = candidates[1:6]
    if tail:
        lines += ["", "### Then, in priority order", ""]
        lines += [f"- {c.action} — [{c.ref}]({c.url}): {c.title}" for c in tail]

    lines += [
        "",
        "### Pulse",
        f"- Open PRs: {pulse.open_prs} ({pulse.merge_ready} merge-ready, "
        f"{pulse.changes_requested} awaiting a response)",
        f"- Ideas awaiting your approval: {pulse.ideas_awaiting}",
        "",
        "_Fable points at existing surfaces; nothing here acts on its own. "
        "Merge, or reply on the linked discussion, exactly as you would today._",
    ]
    return "\n".join(lines) + "\n"


def build_result(snapshot: Snapshot) -> dict[str, Any]:
    candidates = score_snapshot(snapshot)
    pulse = compute_pulse(snapshot, candidates)
    return {
        "date": snapshot.now.strftime("%Y-%m-%d"),
        "recommendation": (
            {
                "action": candidates[0].action,
                "ref": candidates[0].ref,
                "url": candidates[0].url,
                "title": candidates[0].title,
                "kind": candidates[0].kind,
            }
            if candidates
            else None
        ),
        "runners_up": [
            {"action": c.action, "ref": c.ref, "url": c.url, "kind": c.kind}
            for c in candidates[1:6]
        ],
        "pulse": pulse.__dict__,
        "markdown": render_markdown(candidates, pulse, snapshot.now),
    }


# ---------------------------------------------------------------------------
# Posting (opt-in)
# ---------------------------------------------------------------------------


def find_thread(discussions: list[dict[str, Any]]) -> dict[str, Any] | None:
    for disc in discussions:
        if str(disc.get("title", "")).strip().lower() == THREAD_TITLE.lower():
            return disc
    return None


def post_recommendation(owner: str, name: str, thread: dict[str, Any] | None, markdown: str) -> str:
    thread_id = (
        _discussion_node_id(owner, name, int(thread["number"]))
        if thread is not None
        else create_thread(owner, name)
    )
    mutation = """
mutation($discId: ID!, $body: String!) {
  addDiscussionComment(input: { discussionId: $discId, body: $body }) {
    comment { url }
  }
}
"""
    data = graphql(mutation, discId=thread_id, body=markdown)
    return data["data"]["addDiscussionComment"]["comment"]["url"]


def create_thread(owner: str, name: str) -> str:
    """Create the running recommendation thread on first post and return its node id."""
    query = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 20) { nodes { id slug } }
  }
}
"""
    repo = graphql(query, owner=owner, name=name)["data"]["repository"]
    categories = {n["slug"].lower(): n["id"] for n in repo["discussionCategories"]["nodes"]}
    category_id = categories.get(PREFERRED_CATEGORY) or next(iter(categories.values()), None)
    if not category_id:
        raise FableError("no discussion category available to create the Fable thread")
    mutation = """
mutation($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: { repositoryId: $repoId, categoryId: $catId, title: $title, body: $body }) {
    discussion { id }
  }
}
"""
    body = (
        "Fable's running daily recommendation for the owner. Each comment names "
        "the single highest-value next action and points at the existing surface "
        "to act on it. Fable never acts on its own."
    )
    data = graphql(mutation, repoId=repo["id"], catId=category_id, title=THREAD_TITLE, body=body)
    return data["data"]["createDiscussion"]["discussion"]["id"]


def _discussion_node_id(owner: str, name: str, number: int) -> str:
    query = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { discussion(number: $number) { id } }
}
"""
    cmd = [
        "gh", "api", "graphql", "-f", f"query={query}",
        "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={number}",
    ]
    data = json.loads(run_checked(cmd))
    return data["data"]["repository"]["discussion"]["id"]


# ---------------------------------------------------------------------------
# Fixtures + CLI
# ---------------------------------------------------------------------------


def load_fixture(fixtures_dir: Path) -> Snapshot:
    if not fixtures_dir.is_dir():
        raise FableError(f"fixture directory not found: {fixtures_dir}")
    prs = json.loads((fixtures_dir / "prs.json").read_text(encoding="utf-8"))
    discussions = json.loads((fixtures_dir / "discussions.json").read_text(encoding="utf-8"))
    now_path = fixtures_dir / "now.txt"
    now = (
        parse_datetime(now_path.read_text(encoding="utf-8").strip())
        if now_path.is_file()
        else datetime.now(tz=UTC)
    ) or datetime.now(tz=UTC)
    return Snapshot(prs=prs, discussions=discussions, now=now)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--post", action="store_true", help="Post to the running discussion thread")
    parser.add_argument("--fixtures-dir", type=Path, help="Replay from a fixture pack (no network)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.fixtures_dir:
        snapshot = load_fixture(args.fixtures_dir)
    else:
        owner, name = repo_owner_name()
        log("Gathering live project state")
        discussions = gather_discussions(owner, name)
        snapshot = Snapshot(
            prs=gather_prs(),
            discussions=discussions,
            thread=find_thread(discussions),
        )

    result = build_result(snapshot)

    if args.post:
        if args.fixtures_dir:
            raise FableError("--post is not available in fixture mode")
        owner, name = repo_owner_name()
        url = post_recommendation(owner, name, snapshot.thread, result["markdown"])
        log(f"Posted recommendation: {url}")
        result["posted_url"] = url

    if args.json_output:
        print(json.dumps(result, indent=2))
    else:
        print(result["markdown"])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except FableError as error:
        log(f"error: {error}")
        sys.exit(1)
