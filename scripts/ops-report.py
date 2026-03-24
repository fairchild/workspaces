#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate an operational timeline and summary from GitHub + perf snapshots."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
OPS_DIR = REPO_ROOT / "docs" / "ops"
PERF_DIR = REPO_ROOT / "docs" / "performance"
PERF_LATEST_PATH = PERF_DIR / "latest-summary.json"
PERF_HISTORY_PATH = PERF_DIR / "metrics-history.csv"
FIXTURE_REQUIRED_FILES = (
    "repo.json",
    "discussions.json",
    "issues.json",
    "prs.json",
    "runs.json",
    "perf-latest-summary.json",
    "perf-history.csv",
)

APPROVAL_PATTERN = re.compile(
    r"\b(yes|let.s do it|plan it|approved|go ahead|ship it|lgtm|do it)\b",
    re.IGNORECASE,
)
PLANNED_MARKER_RE = re.compile(
    r"<!-- peter-planner:discussion=(?P<number>\d+);status=planned -->"
)
ISSUE_MARKER_RE = re.compile(
    r"<!-- peter-planner:discussion=(?P<number>\d+);issue=(?P<slug>[a-z0-9-]+) -->"
)
IDEA_PATTERN = re.compile(r"\[idea\](?:\[endorsed\])?", re.IGNORECASE)

PERF_TARGETS_MS = {
    "launch_to_first_prompt": 250.0,
    "repo_hydration": 25.0,
    "repo_click_to_focus": 250.0,
}
FAILURE_CONCLUSIONS = {"failure", "timed_out", "startup_failure", "action_required"}
AGENT_WORKFLOW_PREFIX = "Agent: "
OPS_IDEA_TITLES = {
    "perf": "[idea] [ops] Investigate performance regression",
    "ci": "[idea] [ops] Stabilize GitHub Actions reliability",
    "agent": "[idea] [ops] Stabilize individual agent reliability",
    "throughput": "[idea] [ops] Unblock planned work from execution",
}
TIMELINE_FIELDS = [
    "discussion_number",
    "discussion_title",
    "discussion_url",
    "discussion_created_at",
    "approved_at",
    "planned_at",
    "milestone_number",
    "milestone_title",
    "issue_numbers",
    "issue_count",
    "open_issue_count",
    "closed_issue_count",
    "pr_numbers",
    "open_pr_count",
    "merged_pr_count",
    "first_pr_opened_at",
    "last_pr_merged_at",
    "latest_activity_at",
    "status",
]


class OpsReportError(RuntimeError):
    """Raised when the report cannot be generated."""


@dataclass(frozen=True)
class RepoInfo:
    owner: str
    name: str
    repository_id: str = ""
    category_ids: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class ReportInputs:
    repo: RepoInfo
    discussions: list[dict[str, Any]]
    issues: list[dict[str, Any]]
    prs: list[dict[str, Any]]
    runs: list[dict[str, Any]]
    perf_latest_path: Path
    perf_history_path: Path
    source_mode: str
    fixture_name: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--open-idea-on-breach", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fixtures-dir", type=Path)
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.days <= 0:
        raise OpsReportError("--days must be a positive integer")
    if args.fixtures_dir is None:
        return
    if args.record:
        raise OpsReportError("--fixtures-dir cannot be combined with --record")
    if args.open_idea_on_breach and not args.dry_run:
        raise OpsReportError("--fixtures-dir with --open-idea-on-breach requires --dry-run")


def log(message: str) -> None:
    print(f"[ops-report] {message}", file=sys.stderr)


def run_checked(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        input=input,
    )
    if result.returncode != 0:
        command = " ".join(cmd)
        raise OpsReportError(
            f"command failed ({command}): {(result.stderr or result.stdout).strip() or 'unknown error'}"
        )
    return result


def load_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise OpsReportError(f"missing required file: {path}") from error
    except json.JSONDecodeError as error:
        raise OpsReportError(f"invalid JSON in {path}: {error}") from error


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
        raise OpsReportError(f"graphql error: {data['errors']}")
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


def format_number(value: float | None, *, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def now_utc() -> datetime:
    return datetime.now(tz=UTC)


def current_branch() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return "unknown"


def normalize_title_key(title: str) -> str:
    return re.sub(r"\s+", " ", title.strip().lower())


def agent_header(repo: RepoInfo) -> str:
    return f"**Agent**: `{repo.name}-oliver-obever` | **Branch**: `{current_branch()}`"


def repo_info(env: dict[str, str]) -> RepoInfo:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if slug and "/" in slug:
        owner, name = slug.split("/", 1)
    else:
        result = run_checked(
            ["gh", "repo", "view", "--json", "owner,name"],
            cwd=REPO_ROOT,
            env=env,
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


def load_fixture_inputs(fixtures_dir: Path) -> ReportInputs:
    if not fixtures_dir.is_dir():
        raise OpsReportError(f"fixture pack not found: {fixtures_dir}")

    missing = [name for name in FIXTURE_REQUIRED_FILES if not (fixtures_dir / name).is_file()]
    if missing:
        raise OpsReportError(
            f"fixture pack {fixtures_dir} is missing required files: {', '.join(missing)}"
        )

    repo_payload = load_json_file(fixtures_dir / "repo.json")
    owner = str(repo_payload.get("owner", "")).strip()
    name = str(repo_payload.get("name", "")).strip()
    if not owner or not name:
        raise OpsReportError(f"{fixtures_dir / 'repo.json'} must include non-empty owner and name")

    category_ids = {
        str(key): str(value)
        for key, value in dict(repo_payload.get("category_ids") or {}).items()
    }
    return ReportInputs(
        repo=RepoInfo(
            owner=owner,
            name=name,
            repository_id=str(repo_payload.get("repository_id", "")),
            category_ids=category_ids,
        ),
        discussions=list(load_json_file(fixtures_dir / "discussions.json")),
        issues=list(load_json_file(fixtures_dir / "issues.json")),
        prs=list(load_json_file(fixtures_dir / "prs.json")),
        runs=list(load_json_file(fixtures_dir / "runs.json")),
        perf_latest_path=fixtures_dir / "perf-latest-summary.json",
        perf_history_path=fixtures_dir / "perf-history.csv",
        source_mode="fixture",
        fixture_name=fixtures_dir.name,
    )


def load_live_inputs(env: dict[str, str]) -> ReportInputs:
    repo = repo_info(env)
    return ReportInputs(
        repo=repo,
        discussions=fetch_discussions(repo, env),
        issues=fetch_issues(env),
        prs=fetch_pull_requests(env),
        runs=fetch_runs(env),
        perf_latest_path=PERF_LATEST_PATH,
        perf_history_path=PERF_HISTORY_PATH,
        source_mode="live",
    )


def load_inputs(args: argparse.Namespace, env: dict[str, str]) -> ReportInputs:
    if args.fixtures_dir is not None:
        fixture_path = args.fixtures_dir
        if not fixture_path.is_absolute():
            fixture_path = (REPO_ROOT / fixture_path).resolve()
        log(f"Loading fixture data from {fixture_path}")
        return load_fixture_inputs(fixture_path)
    log("Fetching GitHub data")
    return load_live_inputs(env)


def fetch_discussions_by_state(repo: RepoInfo, state: str, env: dict[str, str]) -> list[dict[str, Any]]:
    if state not in {"OPEN", "CLOSED"}:
        raise OpsReportError(f"unexpected discussion state {state}")

    query = f"""
query($owner: String!, $name: String!, $after: String) {{
  repository(owner: $owner, name: $name) {{
    discussions(first: 50, after: $after, states: {state}) {{
      pageInfo {{ hasNextPage endCursor }}
      nodes {{
        id
        number
        url
        title
        createdAt
        updatedAt
        closed
        closedAt
        category {{ name slug }}
        author {{ login }}
        comments(first: 100) {{
          nodes {{
            id
            body
            createdAt
            author {{ login }}
          }}
        }}
      }}
    }}
  }}
}}
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


def fetch_discussions(repo: RepoInfo, env: dict[str, str]) -> list[dict[str, Any]]:
    discussions = fetch_discussions_by_state(repo, "OPEN", env)
    discussions.extend(fetch_discussions_by_state(repo, "CLOSED", env))
    return discussions


def fetch_issues(env: dict[str, str]) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh",
            "issue",
            "list",
            "--state",
            "all",
            "--limit",
            "500",
            "--json",
            (
                "number,title,body,url,createdAt,updatedAt,state,closedAt,"
                "milestone,labels,closedByPullRequestsReferences"
            ),
        ],
        cwd=REPO_ROOT,
        env=env,
    )
    return json.loads(result.stdout)


def fetch_pull_requests(env: dict[str, str]) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh",
            "pr",
            "list",
            "--state",
            "all",
            "--limit",
            "500",
            "--json",
            "number,title,state,createdAt,updatedAt,mergedAt,url,closingIssuesReferences",
        ],
        cwd=REPO_ROOT,
        env=env,
    )
    return json.loads(result.stdout)


def fetch_runs(env: dict[str, str], limit: int = 500) -> list[dict[str, Any]]:
    result = run_checked(
        [
            "gh",
            "run",
            "list",
            "--limit",
            str(limit),
            "--json",
            (
                "attempt,conclusion,createdAt,databaseId,displayTitle,event,"
                "headBranch,name,number,startedAt,status,updatedAt,url,workflowName"
            ),
        ],
        cwd=REPO_ROOT,
        env=env,
    )
    return json.loads(result.stdout)


def contains_idea_title(title: str) -> bool:
    return IDEA_PATTERN.search(title) is not None


def select_approval_timestamp(comments: list[dict[str, Any]], owner_login: str) -> str | None:
    matches = [
        comment["createdAt"]
        for comment in comments
        if comment.get("author", {}).get("login") == owner_login
        and APPROVAL_PATTERN.search(str(comment.get("body", "")))
    ]
    if not matches:
        return None
    return sorted(matches)[0]


def marker_status(body: str, discussion_number: int) -> str | None:
    match = PLANNED_MARKER_RE.search(body)
    if not match or int(match.group("number")) != discussion_number:
        return None
    return "planned"


def extract_summary_issue_numbers(body: str, discussion_number: int) -> list[int]:
    if marker_status(body, discussion_number) != "planned":
        return []
    numbers = [int(match) for match in re.findall(r"(?m)^\s*-\s+#(\d+)\b", body)]
    return unique_numbers(numbers)


def extract_issue_discussion_numbers(body: str) -> list[int]:
    matches = ISSUE_MARKER_RE.finditer(body or "")
    return unique_numbers(int(match.group("number")) for match in matches)


def unique_numbers(values: Any) -> list[int]:
    seen: set[int] = set()
    ordered: list[int] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def latest_comment_with_summary(comments: list[dict[str, Any]], discussion_number: int) -> dict[str, Any] | None:
    matches = [
        comment
        for comment in comments
        if extract_summary_issue_numbers(str(comment.get("body", "")), discussion_number)
    ]
    if not matches:
        return None
    return sorted(matches, key=lambda item: item["createdAt"])[-1]


def build_issue_indexes(issues: list[dict[str, Any]]) -> tuple[dict[int, dict[str, Any]], dict[int, list[int]]]:
    by_number = {int(issue["number"]): issue for issue in issues}
    by_discussion: dict[int, list[int]] = defaultdict(list)
    for issue in issues:
        for discussion_number in extract_issue_discussion_numbers(str(issue.get("body", ""))):
            by_discussion[discussion_number].append(int(issue["number"]))
    for discussion_number, numbers in list(by_discussion.items()):
        by_discussion[discussion_number] = sorted(unique_numbers(numbers))
    return by_number, by_discussion


def build_pr_index(prs: list[dict[str, Any]]) -> dict[int, list[dict[str, Any]]]:
    by_issue: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for pr in prs:
        for issue in pr.get("closingIssuesReferences", []) or []:
            by_issue[int(issue["number"])].append(pr)
    return by_issue


def latest_timestamp(values: list[str | None]) -> str | None:
    candidates = [(parse_datetime(value), value) for value in values if value]
    candidates = [(dt, raw) for dt, raw in candidates if dt is not None and raw is not None]
    if not candidates:
        return None
    return max(candidates, key=lambda item: item[0])[1]


def days_between(start: str | None, end: str | None) -> float | None:
    start_dt = parse_datetime(start)
    end_dt = parse_datetime(end)
    if start_dt is None or end_dt is None:
        return None
    return (end_dt - start_dt).total_seconds() / 86400.0


def days_since(value: str | None, current_time: datetime) -> float | None:
    timestamp = parse_datetime(value)
    if timestamp is None:
        return None
    return (current_time - timestamp.astimezone(UTC)).total_seconds() / 86400.0


def derive_status(
    approved_at: str | None,
    planned_at: str | None,
    open_pr_count: int,
    merged_pr_count: int,
    latest_activity_at: str | None,
    current_time: datetime,
) -> str:
    if not approved_at and not planned_at:
        return "idea"
    if planned_at and merged_pr_count > 0:
        return "merged"
    if open_pr_count > 0:
        return "active"
    if planned_at and (days_since(latest_activity_at, current_time) or 0.0) >= 14.0:
        return "stalled"
    if planned_at:
        return "planned"
    return "idea"


def timeline_row_for_discussion(
    discussion: dict[str, Any],
    owner_login: str,
    issues_by_number: dict[int, dict[str, Any]],
    issues_by_discussion: dict[int, list[int]],
    prs_by_issue: dict[int, list[dict[str, Any]]],
    current_time: datetime,
) -> dict[str, str]:
    discussion_number = int(discussion["number"])
    comments = discussion["comments"]["nodes"]
    approved_at = select_approval_timestamp(comments, owner_login)
    planned_comment = latest_comment_with_summary(comments, discussion_number)
    planned_at = planned_comment["createdAt"] if planned_comment else None

    summary_issue_numbers = (
        extract_summary_issue_numbers(str(planned_comment.get("body", "")), discussion_number)
        if planned_comment
        else []
    )
    issue_numbers = [number for number in summary_issue_numbers if number in issues_by_number]
    if not issue_numbers:
        issue_numbers = list(issues_by_discussion.get(discussion_number, []))

    issue_objects = [issues_by_number[number] for number in issue_numbers if number in issues_by_number]
    milestone = next((issue.get("milestone") for issue in issue_objects if issue.get("milestone")), None)

    pr_map: dict[int, dict[str, Any]] = {}
    for number in issue_numbers:
        for pr in prs_by_issue.get(number, []):
            pr_map[int(pr["number"])] = pr
    pr_objects = [pr_map[number] for number in sorted(pr_map)]

    latest_activity_at = latest_timestamp(
        [
            discussion.get("updatedAt"),
            approved_at,
            planned_at,
            *[comment.get("createdAt") for comment in comments],
            *[issue.get("updatedAt") for issue in issue_objects],
            *[pr.get("updatedAt") for pr in pr_objects],
        ]
    )

    open_issue_count = sum(1 for issue in issue_objects if str(issue.get("state", "")).upper() == "OPEN")
    closed_issue_count = len(issue_objects) - open_issue_count
    open_pr_count = sum(1 for pr in pr_objects if str(pr.get("state", "")).upper() == "OPEN")
    merged_pr_count = sum(
        1
        for pr in pr_objects
        if pr.get("mergedAt") or str(pr.get("state", "")).upper() == "MERGED"
    )
    first_pr_opened_at = latest_timestamp([] if not pr_objects else [min(pr["createdAt"] for pr in pr_objects)])
    merged_times = [str(pr["mergedAt"]) for pr in pr_objects if pr.get("mergedAt")]
    last_pr_merged_at = latest_timestamp(merged_times)

    return {
        "discussion_number": str(discussion_number),
        "discussion_title": str(discussion["title"]),
        "discussion_url": str(discussion["url"]),
        "discussion_created_at": str(discussion["createdAt"]),
        "approved_at": approved_at or "",
        "planned_at": planned_at or "",
        "milestone_number": str(milestone["number"]) if milestone else "",
        "milestone_title": str(milestone["title"]) if milestone else "",
        "issue_numbers": ",".join(str(number) for number in issue_numbers),
        "issue_count": str(len(issue_objects)),
        "open_issue_count": str(open_issue_count),
        "closed_issue_count": str(closed_issue_count),
        "pr_numbers": ",".join(str(pr["number"]) for pr in pr_objects),
        "open_pr_count": str(open_pr_count),
        "merged_pr_count": str(merged_pr_count),
        "first_pr_opened_at": first_pr_opened_at or "",
        "last_pr_merged_at": last_pr_merged_at or "",
        "latest_activity_at": latest_activity_at or "",
        "status": derive_status(
            approved_at,
            planned_at,
            open_pr_count,
            merged_pr_count,
            latest_activity_at,
            current_time,
        ),
    }


def build_timeline_rows(
    discussions: list[dict[str, Any]],
    issues: list[dict[str, Any]],
    prs: list[dict[str, Any]],
    owner_login: str,
    current_time: datetime,
) -> list[dict[str, str]]:
    issues_by_number, issues_by_discussion = build_issue_indexes(issues)
    prs_by_issue = build_pr_index(prs)
    rows = [
        timeline_row_for_discussion(
            discussion,
            owner_login,
            issues_by_number,
            issues_by_discussion,
            prs_by_issue,
            current_time,
        )
        for discussion in discussions
        if contains_idea_title(str(discussion.get("title", "")))
    ]
    return sorted(
        rows,
        key=lambda row: parse_datetime(row["discussion_created_at"]) or datetime.min.replace(tzinfo=UTC),
    )


def median_or_none(values: list[float]) -> float | None:
    if not values:
        return None
    return float(statistics.median(values))


def build_lead_times(rows: list[dict[str, str]]) -> dict[str, float | None]:
    idea_to_approved = [
        value
        for row in rows
        if (value := days_between(row["discussion_created_at"], row["approved_at"])) is not None
    ]
    approved_to_planned = [
        value
        for row in rows
        if (value := days_between(row["approved_at"], row["planned_at"])) is not None
    ]
    planned_to_first_pr = [
        value
        for row in rows
        if (value := days_between(row["planned_at"], row["first_pr_opened_at"])) is not None
    ]
    first_pr_to_merged = [
        value
        for row in rows
        if (value := days_between(row["first_pr_opened_at"], row["last_pr_merged_at"])) is not None
    ]
    return {
        "idea_to_approved_days": median_or_none(idea_to_approved),
        "approved_to_planned_days": median_or_none(approved_to_planned),
        "planned_to_first_pr_days": median_or_none(planned_to_first_pr),
        "first_pr_to_merged_days": median_or_none(first_pr_to_merged),
    }


def build_funnel(rows: list[dict[str, str]]) -> dict[str, int]:
    return {
        "ideas": len(rows),
        "approved": sum(1 for row in rows if row["approved_at"]),
        "planned": sum(1 for row in rows if row["planned_at"]),
        "active": sum(1 for row in rows if row["status"] == "active"),
        "merged": sum(1 for row in rows if row["status"] == "merged"),
        "stalled": sum(1 for row in rows if row["status"] == "stalled"),
    }


def summarize_ci(runs: list[dict[str, Any]], days: int, current_time: datetime) -> dict[str, Any]:
    cutoff = current_time - timedelta(days=days)
    completed_runs = [
        run
        for run in runs
        if str(run.get("status", "")).lower() == "completed"
        and (parse_datetime(str(run.get("createdAt", ""))) or datetime.min.replace(tzinfo=UTC)) >= cutoff
    ]
    total_runs = len(completed_runs)
    failure_runs = [
        run
        for run in completed_runs
        if str(run.get("conclusion", "")).lower() in FAILURE_CONCLUSIONS
    ]
    rerun_runs = [run for run in completed_runs if int(run.get("attempt") or 1) > 1]

    workflow_failures = Counter(
        str(run.get("workflowName") or run.get("name") or "Unknown")
        for run in failure_runs
    )

    agents: dict[str, dict[str, Any]] = {}
    by_workflow: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for run in completed_runs:
        wf = str(run.get("workflowName") or run.get("name") or "Unknown")
        by_workflow[wf].append(run)
    for wf_name, wf_runs in by_workflow.items():
        if not wf_name.startswith(AGENT_WORKFLOW_PREFIX):
            continue
        agent_name = wf_name[len(AGENT_WORKFLOW_PREFIX):]
        agent_total = len(wf_runs)
        agent_failures = sum(
            1 for r in wf_runs if str(r.get("conclusion", "")).lower() in FAILURE_CONCLUSIONS
        )
        agent_reruns = sum(1 for r in wf_runs if int(r.get("attempt") or 1) > 1)
        agents[agent_name] = {
            "completed_runs": agent_total,
            "failure_runs": agent_failures,
            "failure_rate": (agent_failures / agent_total * 100.0) if agent_total else 0.0,
            "rerun_runs": agent_reruns,
            "rerun_rate": (agent_reruns / agent_total * 100.0) if agent_total else 0.0,
        }

    return {
        "window_days": days,
        "window_start": cutoff.isoformat().replace("+00:00", "Z"),
        "completed_runs": total_runs,
        "failure_runs": len(failure_runs),
        "failure_rate": (len(failure_runs) / total_runs * 100.0) if total_runs else 0.0,
        "rerun_runs": len(rerun_runs),
        "rerun_rate": (len(rerun_runs) / total_runs * 100.0) if total_runs else 0.0,
        "top_failing_workflows": [
            {"workflow_name": name, "failures": count}
            for name, count in workflow_failures.most_common(5)
        ],
        "agents": agents,
    }


def load_perf_history(history_path: Path = PERF_HISTORY_PATH) -> list[dict[str, str]]:
    if not history_path.is_file():
        return []
    with history_path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def load_perf_summary(
    current_time: datetime,
    *,
    latest_path: Path = PERF_LATEST_PATH,
    history_path: Path = PERF_HISTORY_PATH,
) -> dict[str, Any]:
    if not latest_path.is_file():
        return {
            "available": False,
            "latest_timestamp": None,
            "freshness_days": None,
            "metrics": {},
        }

    latest = json.loads(latest_path.read_text(encoding="utf-8"))
    history = load_perf_history(history_path)
    latest_timestamp = latest.get("metadata", {}).get("timestamp")
    latest_dt = parse_datetime(str(latest_timestamp)) if latest_timestamp else None
    freshness_days = None
    if latest_dt is not None:
        freshness_days = (current_time - latest_dt.astimezone(UTC)).total_seconds() / 86400.0

    history_rows = sorted(
        history,
        key=lambda row: parse_datetime(row.get("timestamp")) or datetime.min.replace(tzinfo=UTC),
    )
    previous_row = history_rows[-2] if len(history_rows) >= 2 else None

    metrics: dict[str, Any] = {}
    for metric_name, target in PERF_TARGETS_MS.items():
        latest_metric = latest.get(metric_name) or {}
        latest_median = latest_metric.get("median")
        previous_median = None
        if previous_row is not None:
            previous_value = previous_row.get(f"{metric_name}_median_ms", "")
            previous_median = float(previous_value) if previous_value else None
        delta_percent = None
        if latest_median is not None and previous_median not in {None, 0.0}:
            delta_percent = ((float(latest_median) - float(previous_median)) / float(previous_median)) * 100.0
        metrics[metric_name] = {
            "latest_median_ms": float(latest_median) if latest_median is not None else None,
            "previous_median_ms": float(previous_median) if previous_median is not None else None,
            "delta_percent": delta_percent,
            "target_ms": target,
            "status": "fail" if latest_median is not None and float(latest_median) > target else "pass",
        }

    return {
        "available": True,
        "latest_timestamp": latest_timestamp,
        "freshness_days": freshness_days,
        "metrics": metrics,
    }


def stale_items(rows: list[dict[str, str]], current_time: datetime) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for row in rows:
        if row["status"] != "stalled":
            continue
        items.append(
            {
                "discussion_number": int(row["discussion_number"]),
                "discussion_title": row["discussion_title"],
                "days_since_activity": days_since(row["latest_activity_at"], current_time),
                "discussion_url": row["discussion_url"],
            }
        )
    return sorted(
        items,
        key=lambda item: item["days_since_activity"] or 0.0,
        reverse=True,
    )


def detect_breaches(
    perf: dict[str, Any],
    ci: dict[str, Any],
    stale: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    breaches: list[dict[str, Any]] = []

    if perf.get("available"):
        perf_failures = [
            {
                "metric": metric,
                "latest_median_ms": data["latest_median_ms"],
                "target_ms": data["target_ms"],
                "delta_percent": data["delta_percent"],
            }
            for metric, data in perf["metrics"].items()
            if data["status"] == "fail"
            or (
                data["delta_percent"] is not None
                and float(data["delta_percent"]) > 15.0
            )
        ]
        if perf_failures:
            breaches.append(
                {
                    "category": "perf",
                    "title": OPS_IDEA_TITLES["perf"],
                    "summary": "Performance targets regressed or exceeded threshold",
                    "details": perf_failures,
                    "suggested_direction": (
                        "Re-run the affected benchmarks, isolate the regression window, and harden "
                        "the slow path before adding new surface area."
                    ),
                }
            )

    ci_failure_rate = float(ci["failure_rate"])
    ci_rerun_rate = float(ci["rerun_rate"])
    if ci["completed_runs"] >= 10 and (ci_failure_rate >= 25.0 or ci_rerun_rate >= 15.0):
        breaches.append(
            {
                "category": "ci",
                "title": OPS_IDEA_TITLES["ci"],
                "summary": "GitHub Actions failure or rerun rate crossed the alert threshold",
                "details": {
                    "completed_runs": ci["completed_runs"],
                    "failure_rate": ci_failure_rate,
                    "rerun_rate": ci_rerun_rate,
                    "top_failing_workflows": ci["top_failing_workflows"],
                },
                "suggested_direction": (
                    "Target the top failing workflows first, convert flaky failure modes into "
                    "deterministic checks, and reduce rerun dependence."
                ),
            }
        )

    failing_agents = [
        {"agent": name, **stats}
        for name, stats in ci.get("agents", {}).items()
        if stats["completed_runs"] >= 5 and stats["failure_rate"] >= 20.0
    ]
    if failing_agents:
        breaches.append(
            {
                "category": "agent",
                "title": OPS_IDEA_TITLES["agent"],
                "summary": "Individual agent failure rate crossed the alert threshold",
                "details": failing_agents,
                "suggested_direction": (
                    "Investigate the top failure modes for the flagged agent(s), fix deterministic "
                    "errors first, and add regression tests before re-enabling automated runs."
                ),
            }
        )

    if len(stale) >= 2:
        breaches.append(
            {
                "category": "throughput",
                "title": OPS_IDEA_TITLES["throughput"],
                "summary": "Planned discussions are sitting without linked PR activity",
                "details": stale[:5],
                "suggested_direction": (
                    "Pick the oldest planned work, assign an execution owner, and tighten the path "
                    "from endorsed idea to first PR."
                ),
            }
        )

    priority = {"perf": 0, "ci": 1, "agent": 2, "throughput": 3}
    return sorted(breaches, key=lambda item: priority[item["category"]])


def build_summary(
    rows: list[dict[str, str]],
    ci: dict[str, Any],
    perf: dict[str, Any],
    current_time: datetime,
    days: int,
    *,
    source_mode: str,
    fixture_name: str | None,
) -> dict[str, Any]:
    stale = stale_items(rows, current_time)
    breaches = detect_breaches(perf, ci, stale)
    return {
        "generated_at": current_time.isoformat().replace("+00:00", "Z"),
        "source_mode": source_mode,
        "fixture_name": fixture_name,
        "window_days": days,
        "funnel": build_funnel(rows),
        "lead_times": build_lead_times(rows),
        "ci": ci,
        "perf": perf,
        "stale_items": stale,
        "breaches": breaches,
    }


def render_dashboard(rows: list[dict[str, str]], summary: dict[str, Any]) -> str:
    funnel = summary["funnel"]
    lead_times = summary["lead_times"]
    ci = summary["ci"]
    perf = summary["perf"]
    stale = summary["stale_items"]
    breaches = summary["breaches"]

    lines = [
        "# Ops Dashboard",
        "",
        f"Last updated: `{summary['generated_at']}`",
        (
            f"Source: `fixture:{summary['fixture_name']}`"
            if summary.get("source_mode") == "fixture"
            else "Source: `live`"
        ),
        "",
        "## Funnel",
        "",
        "| Ideas | Approved | Planned | Active | Merged | Stalled |",
        "|---:|---:|---:|---:|---:|---:|",
        (
            f"| {funnel['ideas']} | {funnel['approved']} | {funnel['planned']} | "
            f"{funnel['active']} | {funnel['merged']} | {funnel['stalled']} |"
        ),
        "",
        "## Lead Times",
        "",
        "| Stage | Median Days |",
        "|---|---:|",
        f"| Idea -> approval | {format_number(lead_times['idea_to_approved_days'])} |",
        f"| Approval -> plan | {format_number(lead_times['approved_to_planned_days'])} |",
        f"| Plan -> first PR | {format_number(lead_times['planned_to_first_pr_days'])} |",
        f"| First PR -> merge | {format_number(lead_times['first_pr_to_merged_days'])} |",
        "",
        f"## CI Health ({summary['window_days']} Days)",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Completed runs | {ci['completed_runs']} |",
        f"| Failure rate | {format_number(ci['failure_rate'])}% |",
        f"| Rerun rate | {format_number(ci['rerun_rate'])}% |",
        "",
        "Top failing workflows:",
    ]
    if ci["top_failing_workflows"]:
        for workflow in ci["top_failing_workflows"]:
            lines.append(
                f"- `{workflow['workflow_name']}` — {workflow['failures']} failure(s)"
            )
    else:
        lines.append("- none in window")

    agents = ci.get("agents", {})
    lines.extend(["", "## Agent Health", ""])
    if agents:
        lines.extend(
            [
                "| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |",
                "|---|---:|---:|---:|---:|---:|",
            ]
        )
        for agent_name in sorted(agents):
            a = agents[agent_name]
            lines.append(
                f"| {agent_name} | {a['completed_runs']} | {a['failure_runs']} | "
                f"{format_number(a['failure_rate'])}% | {a['rerun_runs']} | "
                f"{format_number(a['rerun_rate'])}% |"
            )
    else:
        lines.append("- no agent workflows in window")

    lines.extend(["", "## Perf Snapshot", ""])
    if perf["available"]:
        lines.extend(
            [
                f"Latest perf snapshot: `{perf['latest_timestamp']}`",
                f"Freshness: {format_number(perf['freshness_days'], digits=1)} days",
                "",
                "| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |",
                "|---|---:|---:|---:|---|",
            ]
        )
        for metric_name, metric in perf["metrics"].items():
            delta = (
                f"{metric['delta_percent']:.1f}%"
                if metric["delta_percent"] is not None
                else "n/a"
            )
            lines.append(
                f"| `{metric_name}` | {format_number(metric['latest_median_ms'])} | "
                f"{format_number(metric['target_ms'])} | {delta} | {metric['status']} |"
            )
    else:
        lines.append("No performance snapshot available.")

    lines.extend(["", "## Stale Planned Work", ""])
    if stale:
        for item in stale:
            lines.append(
                f"- #{item['discussion_number']} — {item['discussion_title']} "
                f"({format_number(item['days_since_activity'], digits=1)} days idle)"
            )
    else:
        lines.append("- none")

    lines.extend(["", "## Current Breaches", ""])
    if breaches:
        for breach in breaches:
            lines.append(f"- `{breach['category']}` — {breach['summary']}")
    else:
        lines.append("- none")

    if rows:
        lines.extend(["", "## Latest Discussions", ""])
        for row in rows[-5:]:
            lines.append(
                f"- #{row['discussion_number']} — {row['discussion_title']} (`{row['status']}`)"
            )

    lines.append("")
    return "\n".join(lines)


def write_timeline_csv(rows: list[dict[str, str]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=TIMELINE_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def create_output_dir(args: argparse.Namespace) -> Path:
    if args.output_dir is not None:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        return args.output_dir
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path(tempfile.mkdtemp(prefix=f"workspaces-ops-report-{timestamp}-"))


def build_report(
    inputs: ReportInputs,
    *,
    current_time: datetime,
    days: int,
) -> tuple[list[dict[str, str]], dict[str, Any]]:
    rows = build_timeline_rows(
        inputs.discussions,
        inputs.issues,
        inputs.prs,
        inputs.repo.owner,
        current_time,
    )
    ci = summarize_ci(inputs.runs, days, current_time)
    perf = load_perf_summary(
        current_time,
        latest_path=inputs.perf_latest_path,
        history_path=inputs.perf_history_path,
    )
    summary = build_summary(
        rows,
        ci,
        perf,
        current_time,
        days,
        source_mode=inputs.source_mode,
        fixture_name=inputs.fixture_name,
    )
    return rows, summary


def write_artifacts(output_dir: Path, rows: list[dict[str, str]], summary: dict[str, Any]) -> dict[str, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    timeline_path = output_dir / "timeline.csv"
    summary_path = output_dir / "latest-summary.json"
    dashboard_path = output_dir / "dashboard.md"
    write_timeline_csv(rows, timeline_path)
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    dashboard_path.write_text(render_dashboard(rows, summary), encoding="utf-8")
    return {
        "timeline": timeline_path,
        "summary": summary_path,
        "dashboard": dashboard_path,
    }


def record_artifacts(paths: dict[str, Path]) -> None:
    OPS_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(paths["timeline"], OPS_DIR / "timeline.csv")
    shutil.copyfile(paths["summary"], OPS_DIR / "latest-summary.json")
    shutil.copyfile(paths["dashboard"], OPS_DIR / "dashboard.md")


def candidate_idea_from_breaches(summary: dict[str, Any]) -> dict[str, str] | None:
    breaches = summary["breaches"]
    if not breaches:
        return None
    breach = breaches[0]
    details_json = json.dumps(breach["details"], indent=2, ensure_ascii=False)
    title = breach["title"]
    body = "\n".join(
        [
            "## Evidence Summary",
            breach["summary"],
            "",
            "## Exact Metrics",
            "```json",
            details_json,
            "```",
            "",
            "## Affected Workflows/Discussions",
            affected_entities_lines(breach),
            "",
            "## Suggested Hardening Direction",
            breach["suggested_direction"],
        ]
    )
    return {"category": breach["category"], "title": title, "body": body}


def affected_entities_lines(breach: dict[str, Any]) -> str:
    category = breach["category"]
    if category == "ci":
        workflows = breach["details"]["top_failing_workflows"]
        if workflows:
            return "\n".join(
                f"- `{workflow['workflow_name']}`"
                for workflow in workflows
            )
        return "- none identified"
    if category == "throughput":
        items = breach["details"]
        return "\n".join(
            f"- Discussion #{item['discussion_number']} — {item['discussion_title']}"
            for item in items
        )
    if category == "agent":
        items = breach["details"]
        return "\n".join(
            f"- `{item['agent']}` — {format_number(item['failure_rate'])}% failure rate "
            f"({item['failure_runs']}/{item['completed_runs']} runs)"
            for item in items
        )
    if category == "perf":
        items = breach["details"]
        return "\n".join(f"- `{item['metric']}`" for item in items)
    return "- none"


def build_discussion_body(repo: RepoInfo, idea: dict[str, str]) -> str:
    return "\n".join([agent_header(repo), "", idea["body"]])


def should_skip_idea(
    idea: dict[str, str] | None,
    discussions: list[dict[str, Any]],
    current_time: datetime,
) -> str | None:
    if idea is None:
        return "no breach candidate"

    title_key = normalize_title_key(idea["title"])
    for discussion in discussions:
        if normalize_title_key(str(discussion["title"])) != title_key:
            continue
        if not discussion.get("closed"):
            return "matching open ops discussion already exists"
        last_closed_time = parse_datetime(str(discussion.get("closedAt") or discussion.get("updatedAt") or ""))
        if last_closed_time is not None and (current_time - last_closed_time.astimezone(UTC)).days < 30:
            return "matching ops discussion closed within the 30-day cooldown"
    return None


def create_ops_discussion(repo: RepoInfo, idea: dict[str, str], env: dict[str, str]) -> dict[str, Any]:
    ideas_category = repo.category_ids.get("ideas")
    if not ideas_category:
        raise OpsReportError("discussion category 'ideas' is not configured for this repository")
    mutation = """
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
"""
    data = graphql(
        mutation,
        env,
        repoId=repo.repository_id,
        catId=ideas_category,
        title=idea["title"],
        body=build_discussion_body(repo, idea),
    )
    return data["data"]["createDiscussion"]["discussion"]


def print_paths(output_dir: Path, paths: dict[str, Path]) -> None:
    print(f"output_dir={output_dir}")
    print(f"timeline_csv={paths['timeline']}")
    print(f"summary_json={paths['summary']}")
    print(f"dashboard_md={paths['dashboard']}")


def print_idea_preview(idea: dict[str, str] | None, skip_reason: str | None) -> None:
    payload = {
        "would_open_discussion": (
            {
                "title": idea["title"],
                "body": idea["body"],
                "category": "ideas",
            }
            if idea is not None and skip_reason is None
            else None
        ),
        "reason": skip_reason,
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))


def main() -> int:
    args = parse_args()
    validate_args(args)

    env = dict(os.environ)
    current_time = now_utc()
    inputs = load_inputs(args, env)
    rows, summary = build_report(inputs, current_time=current_time, days=args.days)

    output_dir = create_output_dir(args)
    paths = write_artifacts(output_dir, rows, summary)
    if args.record:
        record_artifacts(paths)
        log("Recorded artifacts into docs/ops")

    print_paths(output_dir, paths)

    if not args.open_idea_on_breach:
        return 0

    idea = candidate_idea_from_breaches(summary)
    skip_reason = should_skip_idea(idea, inputs.discussions, current_time)
    if args.dry_run:
        print_idea_preview(idea, skip_reason)
        return 0

    if inputs.source_mode == "fixture":
        raise OpsReportError("fixture mode cannot create discussions")
    if idea is None:
        log("No breach candidate found; nothing to open")
        return 0
    if skip_reason is not None:
        log(f"Skipping ops discussion creation: {skip_reason}")
        return 0

    discussion = create_ops_discussion(inputs.repo, idea, env)
    log(f"Created ops discussion #{discussion['number']}")
    print(json.dumps({"created_discussion": discussion}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OpsReportError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
