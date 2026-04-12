#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Resolve a drive-style milestone target and print the latest GitHub state."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


PLANNER_MARKER_RE = re.compile(r"<!-- peter-planner:discussion=(?P<number>\d+);milestone -->")
MILESTONE_URL_RE = re.compile(r"/milestone/(?P<number>\d+)")
M_SHORT_RE = re.compile(r"\bm(?P<number>\d+)\b", re.IGNORECASE)
MILESTONE_WORD_RE = re.compile(r"\bmilestone\s+(?P<number>\d+)\b", re.IGNORECASE)
H2_HEADING_RE = re.compile(r"^##\s+\S", re.MULTILINE)


class MilestoneError(RuntimeError):
    """Raised when milestone resolution fails."""


def discover_repo_root() -> Path:
    # This script lives at .agents/skills/drive/scripts/, which is four levels
    # below the repo root in this repository layout.
    repo_root = Path(__file__).resolve().parents[4]
    if not (repo_root / "AGENTS.md").exists():
        raise MilestoneError(
            f"could not locate repo root from {__file__}; expected {repo_root / 'AGENTS.md'} to exist"
        )
    return repo_root


REPO_ROOT = discover_repo_root()


def run_checked(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise MilestoneError((result.stderr or result.stdout).strip() or "unknown command failure")
    return result


def repo_slug(explicit_repo: str | None) -> str:
    if explicit_repo:
        return explicit_repo

    data = json.loads(
        run_checked(["gh", "repo", "view", "--json", "owner,name"]).stdout
    )
    return f"{data['owner']['login']}/{data['name']}"


def normalize_target(raw_target: str) -> str:
    target = raw_target.strip()
    lowered = target.lower()

    if lowered.startswith("/drive"):
        target = target[6:].strip()
        lowered = target.lower()
    elif lowered.startswith("drive"):
        target = target[5:].strip()
        lowered = target.lower()

    if lowered.startswith("to "):
        target = target[3:].strip()

    if not target:
        raise MilestoneError("missing milestone target; try '/drive m4' or '/drive next milestone'")

    return target


def resolve_target(raw_target: str, repo: str) -> tuple[int, str]:
    target = normalize_target(raw_target)
    lowered = target.lower()

    url_match = MILESTONE_URL_RE.search(target)
    if url_match:
        return int(url_match.group("number")), "url"

    if lowered in {"next", "next milestone"}:
        return resolve_next_open_milestone(repo), "next-open"

    word_match = MILESTONE_WORD_RE.search(target)
    if word_match:
        return int(word_match.group("number")), "milestone-number"

    short_match = M_SHORT_RE.search(target)
    if short_match:
        return int(short_match.group("number")), "m-short"

    if target.isdigit():
        return int(target), "number"

    raise MilestoneError(
        f"could not parse milestone target '{raw_target}'. "
        "Use forms like 'm4', 'milestone 4', a milestone URL, or 'next milestone'."
    )


def resolve_next_open_milestone(repo: str) -> int:
    milestones = json.loads(
        run_checked(["gh", "api", f"repos/{repo}/milestones?state=open&per_page=100"]).stdout
    )
    if not milestones:
        raise MilestoneError("no open milestones found")

    with_open_issues = [item for item in milestones if int(item.get("open_issues", 0)) > 0]
    candidates = with_open_issues if with_open_issues else milestones

    planner_candidates = [
        item for item in candidates if PLANNER_MARKER_RE.search(item.get("description") or "")
    ]
    selected_pool = planner_candidates if planner_candidates else candidates
    selected = min(
        selected_pool,
        key=lambda item: (
            item.get("due_on") is None,
            item.get("due_on") or "",
            int(item["number"]),
        ),
    )
    return int(selected["number"])


def fetch_milestone(repo: str, number: int) -> dict[str, Any]:
    return json.loads(run_checked(["gh", "api", f"repos/{repo}/milestones/{number}"]).stdout)


def fetch_issues(repo: str, milestone_number: int) -> list[dict[str, Any]]:
    data: list[dict[str, Any]] = []
    page = 1

    while True:
        page_items = json.loads(
            run_checked(
                [
                    "gh",
                    "api",
                    f"repos/{repo}/issues?milestone={milestone_number}&state=all&per_page=100&page={page}",
                ]
            ).stdout
        )
        if not page_items:
            break

        data.extend(item for item in page_items if "pull_request" not in item)

        if len(page_items) < 100:
            break
        page += 1

    data.sort(key=lambda item: int(item["number"]))
    return data


def simplify_issue(issue: dict[str, Any]) -> dict[str, Any]:
    return {
        "number": int(issue["number"]),
        "title": issue["title"],
        "state": issue["state"],
        "url": issue["html_url"],
        "labels": [label["name"] for label in issue.get("labels", [])],
        "assignees": [assignee["login"] for assignee in issue.get("assignees", [])],
    }


def has_structured_milestone_description(description: str) -> bool:
    return len(H2_HEADING_RE.findall(description)) >= 2


def build_output(repo: str, raw_target: str) -> dict[str, Any]:
    milestone_number, resolved_via = resolve_target(raw_target, repo)
    milestone = fetch_milestone(repo, milestone_number)
    issues = [simplify_issue(issue) for issue in fetch_issues(repo, milestone_number)]
    description = milestone.get("description") or ""

    open_issue_numbers = [issue["number"] for issue in issues if issue["state"].upper() == "OPEN"]
    closed_issue_numbers = [issue["number"] for issue in issues if issue["state"].upper() != "OPEN"]

    return {
        "repo": repo,
        "requested_target": raw_target,
        "resolved_target": {
            "number": milestone_number,
            "via": resolved_via,
        },
        "milestone": {
            "number": int(milestone["number"]),
            "title": milestone["title"],
            "state": milestone["state"],
            "html_url": milestone["html_url"],
            "open_issues": int(milestone.get("open_issues", 0)),
            "closed_issues": int(milestone.get("closed_issues", 0)),
            "due_on": milestone.get("due_on"),
            "description": description,
        },
        "planning_signals": {
            "planner_marker_present": bool(PLANNER_MARKER_RE.search(description)),
            "description_has_markdown_sections": has_structured_milestone_description(description),
        },
        "issue_summary": {
            "open_numbers": open_issue_numbers,
            "closed_numbers": closed_issue_numbers,
        },
        "issues": issues,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="Milestone target such as 'm4' or 'next milestone'")
    parser.add_argument("--repo", help="GitHub repo slug (owner/name). Defaults to the current repo.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = build_output(repo_slug(args.repo), args.target)
    except MilestoneError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
