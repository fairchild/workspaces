#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check agent lifecycle invariants against live GitHub state.

Queries open agent task issues and open PRs, then verifies label exclusivity,
PR↔label consistency, assignment tracking, and stale-claim expiry.

JSON report to stdout, human summary to stderr. Exit 0 if all pass, 1 otherwise.
"""

from __future__ import annotations

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

LANE_LABEL = "agent"
TASK_LABEL = "task"
PHASE_LABELS = {"ready", "claimed", "review"}
MERGEABLE_LABEL = "mergeable"
CLOSING_REFERENCE_RE = re.compile(
    r"(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(?P<number>\d+)\b"
)
CLAIM_MARKER_RE = re.compile(
    r"<!-- contributor:issue=(?P<number>\d+);status=(?P<status>[a-z_]+);"
    r"agent=(?P<agent>[a-z0-9-]+);branch=(?P<branch>[^>\n]+) -->"
)

QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(first: 80, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        labels(first: 20) { nodes { name } }
        assignees(first: 5) { nodes { login } }
        comments(last: 10) { nodes { body createdAt } }
      }
    }
    pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        body
        reviews(last: 20, states: APPROVED) { totalCount }
      }
    }
  }
}
"""


def log(msg: str) -> None:
    print(f"[lifecycle-health] {msg}", file=sys.stderr)


def run_query(env: dict[str, str]) -> dict[str, Any]:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
    else:
        result = subprocess.run(
            ["gh", "repo", "view", "--json", "owner,name"],
            capture_output=True, text=True, cwd=REPO_ROOT, env=env,
            timeout=GITHUB_API_TIMEOUT,
        )
        data = json.loads(result.stdout)
        owner, name = data["owner"]["login"], data["name"]

    result = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}", "-f", f"name={name}"],
        capture_output=True, text=True, cwd=REPO_ROOT, env=env,
        timeout=GITHUB_API_TIMEOUT,
    )
    if result.returncode != 0:
        log(f"GraphQL query failed: {result.stderr.strip()}")
        raise SystemExit(1)
    repo = json.loads(result.stdout).get("data", {}).get("repository", {})
    return {
        "issues": repo.get("issues", {}).get("nodes", []),
        "pull_requests": repo.get("pullRequests", {}).get("nodes", []),
    }


def label_names(issue: dict[str, Any]) -> set[str]:
    return {n["name"] for n in issue.get("labels", {}).get("nodes", []) if isinstance(n, dict)}


def bot_assignees(issue: dict[str, Any]) -> list[str]:
    return [
        n["login"] for n in issue.get("assignees", {}).get("nodes", [])
        if isinstance(n, dict) and n.get("login", "").endswith("[bot]")
    ]


def pr_issue_map(pull_requests: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    """Map issue_number -> list of PRs that close it."""
    mapping: dict[int, list[dict[str, Any]]] = {}
    for pr in pull_requests:
        match = CLOSING_REFERENCE_RE.search(str(pr.get("body", "")))
        if match:
            mapping.setdefault(int(match.group("number")), []).append(pr)
    return mapping


def latest_claim(issue_number: int, comments: list[dict[str, Any]]) -> dict[str, str] | None:
    claims = []
    for c in comments:
        m = CLAIM_MARKER_RE.search(str(c.get("body", "")))
        if m and int(m.group("number")) == issue_number:
            claims.append({"agent": m.group("agent"), "createdAt": str(c.get("createdAt", ""))})
    if not claims:
        return None
    return max(claims, key=lambda x: x.get("createdAt", ""))


def parse_dt(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


# --- Checks ---

def check_label_exclusivity(issues: list[dict[str, Any]]) -> dict[str, Any]:
    problems = []
    for issue in issues:
        labels = label_names(issue)
        active = labels & PHASE_LABELS
        if len(active) > 1:
            problems.append({"number": issue["number"], "problem": f"multiple phase labels: {sorted(active)}"})
    return {"name": "label_exclusivity", "pass": len(problems) == 0, "issues": problems}


def check_review_pr_consistency(issues: list[dict[str, Any]], prs_by_issue: dict[int, list[dict[str, Any]]]) -> dict[str, Any]:
    problems = []
    for issue in issues:
        n = issue["number"]
        labels = label_names(issue)
        has_review = "review" in labels
        has_pr = n in prs_by_issue

        if has_review and not has_pr:
            problems.append({"number": n, "problem": "review but no open PR references this issue"})
        if has_pr and not has_review:
            problems.append({"number": n, "problem": f"open PR exists but review missing (sync may not have run yet)", "severity": "warn"})
    return {"name": "review_pr_consistency", "pass": all(p.get("severity") == "warn" for p in problems) if problems else True, "issues": problems}


def check_claim_assignment_consistency(issues: list[dict[str, Any]]) -> dict[str, Any]:
    # App installation tokens cannot assign agent accounts, so assignment is
    # best-effort visibility; the claim-marker comment is the canonical record.
    problems = []
    for issue in issues:
        n = issue["number"]
        labels = label_names(issue)
        if "claimed" not in labels:
            continue
        bots = bot_assignees(issue)
        comments = issue.get("comments", {}).get("nodes", [])
        if not bots and latest_claim(n, comments) is None:
            problems.append({"number": n, "problem": "claimed but no bot assignee or claim comment"})
    return {"name": "claim_assignment_consistency", "pass": len(problems) == 0, "issues": problems}


def check_mergeable_coherence(issues: list[dict[str, Any]], prs_by_issue: dict[int, list[dict[str, Any]]]) -> dict[str, Any]:
    problems = []
    for issue in issues:
        n = issue["number"]
        labels = label_names(issue)
        if MERGEABLE_LABEL not in labels:
            continue
        if "review" not in labels:
            problems.append({"number": n, "problem": "mergeable without review"})
            continue
        prs = prs_by_issue.get(n, [])
        if prs and all(pr.get("reviews", {}).get("totalCount", 0) == 0 for pr in prs):
            problems.append({"number": n, "problem": "mergeable but linked PR has no approved reviews"})
    return {"name": "mergeable_coherence", "pass": len(problems) == 0, "issues": problems}


def check_stale_claims(issues: list[dict[str, Any]], prs_by_issue: dict[int, list[dict[str, Any]]], now: datetime) -> dict[str, Any]:
    problems = []
    for issue in issues:
        n = issue["number"]
        labels = label_names(issue)
        if "claimed" not in labels:
            continue
        if n in prs_by_issue:
            continue
        comments = issue.get("comments", {}).get("nodes", [])
        claim = latest_claim(n, comments)
        if claim is None:
            continue
        created = parse_dt(claim["createdAt"])
        if created and now - created >= timedelta(hours=STALE_CLAIM_HOURS):
            age_h = (now - created).total_seconds() / 3600
            problems.append({"number": n, "problem": f"claimed for {age_h:.0f}h with no PR (stale)"})
    return {"name": "stale_claims", "pass": len(problems) == 0, "issues": problems}


def check_orphaned_assignments(issues: list[dict[str, Any]]) -> dict[str, Any]:
    problems = []
    for issue in issues:
        n = issue["number"]
        labels = label_names(issue)
        bots = bot_assignees(issue)
        if bots and "claimed" not in labels and "review" not in labels:
            problems.append({"number": n, "problem": f"bot {bots[0]} assigned but no claimed/review label"})
    return {"name": "orphaned_assignments", "pass": len(problems) == 0, "issues": problems}


def main() -> int:
    if not os.environ.get("GH_TOKEN", "").strip():
        log("GH_TOKEN required")
        return 1

    env = dict(os.environ)
    data = run_query(env)
    now = datetime.now(timezone.utc)

    task_issues = [
        i for i in data["issues"]
        if {LANE_LABEL, TASK_LABEL}.issubset(label_names(i))
    ]
    prs_by_issue = pr_issue_map(data["pull_requests"])

    checks = [
        check_label_exclusivity(task_issues),
        check_review_pr_consistency(task_issues, prs_by_issue),
        check_claim_assignment_consistency(task_issues),
        check_mergeable_coherence(task_issues, prs_by_issue),
        check_stale_claims(task_issues, prs_by_issue, now),
        check_orphaned_assignments(task_issues),
    ]

    passed = sum(1 for c in checks if c["pass"])
    total = len(checks)
    all_issues = [p for c in checks for p in c["issues"]]

    report = {
        "timestamp": now.isoformat(),
        "task_issues_checked": len(task_issues),
        "checks": checks,
        "summary": f"{passed}/{total} checks passed. {len(all_issues)} issue(s) flagged.",
    }

    print(json.dumps(report, indent=2))

    log(f"Checked {len(task_issues)} agent task issue(s)")
    for check in checks:
        status = "PASS" if check["pass"] else "FAIL"
        log(f"  {status}  {check['name']}")
        for issue in check["issues"]:
            severity = issue.get("severity", "error")
            log(f"         #{issue['number']}: {issue['problem']} [{severity}]")

    log(report["summary"])
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
