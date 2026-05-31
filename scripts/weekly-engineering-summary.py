#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate a weekly engineering summary across configured repos."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


INCIDENT_QUERY = "incident OR postmortem OR sev OR outage OR rollback OR regression"
DEFAULT_REPOS = (
    "fairchild/workspaces",
    "fairchild/services",
    "fairchild/code-cadence",
)


@dataclass
class RepoSummary:
    repo: str
    prs: list[dict[str, Any]]
    releases: list[dict[str, str]]
    releases_in_window: list[dict[str, str]]
    confirmed_incidents: list[dict[str, Any]]
    incident_query_matches: list[dict[str, Any]]
    review_counts: dict[str, int]
    prs_with_reviews: int
    previous_pr_count: int


def run_gh_json(args: list[str]) -> Any:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        msg = (result.stderr or result.stdout).strip() or "unknown gh error"
        raise RuntimeError(f"gh {' '.join(args)} failed: {msg}")
    return json.loads(result.stdout)


def run_gh_text(args: list[str]) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        msg = (result.stderr or result.stdout).strip() or "unknown gh error"
        raise RuntimeError(f"gh {' '.join(args)} failed: {msg}")
    return result.stdout


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def parse_window_end(line: str) -> datetime | None:
    marker = "- Window reviewed: "
    if marker not in line or " to " not in line:
        return None
    raw = line.split(" to ", 1)[1].strip()
    return parse_iso(raw)


def parse_run_time(line: str) -> datetime | None:
    marker = "- Run time (UTC): "
    if marker not in line:
        return None
    return parse_iso(line.split(marker, 1)[1].strip())


def parse_last_window_end(memory_path: Path) -> datetime:
    if not memory_path.exists():
        raise RuntimeError(f"automation memory does not exist: {memory_path}")
    latest: datetime | None = None
    latest_run_time: datetime | None = None
    for line in memory_path.read_text(encoding="utf-8").splitlines():
        try:
            window_end = parse_window_end(line)
            run_time = parse_run_time(line)
        except ValueError:
            continue
        if window_end is not None and (latest is None or window_end > latest):
            latest = window_end
        if run_time is not None and (latest_run_time is None or run_time > latest_run_time):
            latest_run_time = run_time
    if latest is None and latest_run_time is not None:
        return latest_run_time.astimezone(UTC)
    if latest is None:
        raise RuntimeError(f"could not find a previous window or run time in {memory_path}")
    return latest.astimezone(UTC)


def fmt_iso(timestamp: datetime) -> str:
    return timestamp.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def in_window(*, since: datetime, now: datetime, timestamps: list[str | None]) -> bool:
    return any(
        t is not None and since <= t <= now
        for t in (parse_iso(timestamp) for timestamp in timestamps)
    )


def parse_release_rows(rows: list[str]) -> list[dict[str, str]]:
    releases: list[dict[str, str]] = []
    for row in rows:
        columns = row.split("\t")
        if len(columns) < 4:
            continue
        releases.append(
            {
                "title": columns[0],
                "tag": columns[2],
                "createdAt": columns[3],
                "raw": row,
            }
        )
    return releases


def release_in_window(release: dict[str, str], since: datetime, now: datetime) -> bool:
    created_at = parse_iso(release.get("createdAt"))
    return created_at is not None and since <= created_at <= now


def is_confirmed_incident(issue: dict[str, Any]) -> bool:
    title = issue.get("title", "").lower()
    labels = {label.get("name", "").lower() for label in issue.get("labels", [])}
    if "prod regression" in title or "postmortem" in title or "outage" in title:
        return True
    return any(label.startswith("cd-failure") for label in labels) or "incident" in labels


def summarize_repo(repo: str, since: datetime, now: datetime) -> RepoSummary:
    since_iso = fmt_iso(since)
    prs = run_gh_json(
        [
            "pr",
            "list",
            "-R",
            repo,
            "--state",
            "merged",
            "--search",
            f"merged:>={since_iso}",
            "--limit",
            "200",
            "--json",
            "number,title,mergedAt,url,author",
        ]
    )
    release_output = run_gh_text(["release", "list", "-R", repo, "--limit", "10"]).strip()
    releases = parse_release_rows([line for line in release_output.splitlines() if line.strip()])
    releases_in_window = [
        release for release in releases if release_in_window(release, since, now)
    ]

    incident_matches = run_gh_json(
        [
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "all",
            "--search",
            f"updated:>={since_iso} {INCIDENT_QUERY}",
            "--limit",
            "100",
            "--json",
            "number,title,state,updatedAt,url",
        ]
    )
    incident_details: list[dict[str, Any]] = []
    if incident_matches:
        for issue in incident_matches:
            detail = run_gh_json(
                [
                    "issue",
                    "view",
                    "-R",
                    repo,
                    str(issue["number"]),
                    "--json",
                    "number,title,state,createdAt,closedAt,url,labels",
                ]
            )
            incident_details.append(detail)
    updated_by_number = {issue["number"]: issue.get("updatedAt") for issue in incident_matches}
    incident_query_matches = [
        detail
        for detail in incident_details
        if in_window(
            since=since,
            now=now,
            timestamps=[
                detail.get("createdAt"),
                detail.get("closedAt"),
                updated_by_number.get(detail["number"]),
            ],
        )
    ]
    confirmed_incidents = [
        issue for issue in incident_query_matches if is_confirmed_incident(issue)
    ]

    window_span = now - since
    prev_start = since - window_span
    prev_end = since
    previous_prs = run_gh_json(
        [
            "pr",
            "list",
            "-R",
            repo,
            "--state",
            "merged",
            "--search",
            f"merged:>={fmt_iso(prev_start)} merged:<={fmt_iso(prev_end)}",
            "--limit",
            "200",
            "--json",
            "number",
        ]
    )

    review_counts: dict[str, int] = {}
    prs_with_reviews = 0
    for pr in prs:
        pr_view = run_gh_json(
            [
                "pr",
                "view",
                "-R",
                repo,
                str(pr["number"]),
                "--json",
                "reviews",
            ]
        )
        reviews = pr_view.get("reviews", [])
        if reviews:
            prs_with_reviews += 1
        for review in reviews:
            state = review.get("state", "UNKNOWN")
            review_counts[state] = review_counts.get(state, 0) + 1

    return RepoSummary(
        repo=repo,
        prs=prs,
        releases=releases,
        releases_in_window=releases_in_window,
        confirmed_incidents=confirmed_incidents,
        incident_query_matches=incident_query_matches,
        review_counts=review_counts,
        prs_with_reviews=prs_with_reviews,
        previous_pr_count=len(previous_prs),
    )


def top_prs(prs: list[dict[str, Any]], limit: int = 6) -> list[dict[str, Any]]:
    return sorted(prs, key=lambda pr: pr["mergedAt"], reverse=True)[:limit]


def emit_markdown(since: datetime, now: datetime, summaries: list[RepoSummary]) -> str:
    lines: list[str] = []
    lines.append(f"# Weekly Engineering Summary ({fmt_iso(since)} to {fmt_iso(now)})")
    lines.append("")
    lines.append("## Scope")
    lines.append(f"- Window: `{fmt_iso(since)}` to `{fmt_iso(now)}`")
    lines.append("- Repos: " + ", ".join(f"`{s.repo}`" for s in summaries))
    lines.append("")
    lines.append("## PR Throughput")
    for summary in summaries:
        lines.append(f"- `{summary.repo}`: {len(summary.prs)} merged PRs")
        for pr in top_prs(summary.prs):
            lines.append(
                f"  - [#{pr['number']}]({pr['url']}) {pr['title']} (merged {pr['mergedAt']})"
            )
    lines.append("")
    lines.append("## Rollouts / Releases")
    for summary in summaries:
        if summary.releases_in_window:
            lines.append(f"- `{summary.repo}` releases in window:")
            for release in summary.releases_in_window:
                lines.append(
                    f"  - `{release['title']}` (`{release['tag']}`, {release['createdAt']})"
                )
        elif summary.releases:
            latest = summary.releases[0]
            lines.append(
                f"- `{summary.repo}`: no release in window; latest is "
                f"`{latest['title']}` (`{latest['tag']}`, {latest['createdAt']})"
            )
        else:
            lines.append(f"- `{summary.repo}`: no releases returned")
    lines.append("")
    lines.append("## Incidents")
    any_incidents = False
    for summary in summaries:
        if not summary.confirmed_incidents:
            continue
        any_incidents = True
        lines.append(f"- `{summary.repo}` confirmed incident matches:")
        for issue in summary.confirmed_incidents:
            labels = ",".join(label["name"] for label in issue.get("labels", [])) or "none"
            lines.append(
                f"  - [#{issue['number']}]({issue['url']}) {issue['title']} "
                f"(state={issue['state']}, created={issue['createdAt']}, closed={issue.get('closedAt')}, labels={labels})"
            )
    if not any_incidents:
        lines.append("- No confirmed incident matches in the window.")
    for summary in summaries:
        other_matches = [
            issue
            for issue in summary.incident_query_matches
            # confirmed_incidents is derived from incident_query_matches without copying.
            if issue not in summary.confirmed_incidents
        ]
        if other_matches:
            lines.append(
                f"- `{summary.repo}` also had {len(other_matches)} broad incident-query matches not classified as confirmed incidents."
            )
    lines.append("")
    lines.append("## Review Signal")
    for summary in summaries:
        lines.append(
            f"- `{summary.repo}`: {summary.prs_with_reviews}/{len(summary.prs)} merged PRs have review events"
        )
        if summary.review_counts:
            ordered = ", ".join(
                f"{state}={count}" for state, count in sorted(summary.review_counts.items())
            )
            lines.append(f"  - Review events: {ordered}")
        else:
            lines.append("  - Review events: none")
    lines.append("")
    lines.append("## Deltas Vs Previous Window")
    for summary in summaries:
        current_pr_count = len(summary.prs)
        pr_delta = current_pr_count - summary.previous_pr_count
        sign = "+" if pr_delta >= 0 else ""
        lines.append(
            f"- `{summary.repo}` PRs: {current_pr_count} vs {summary.previous_pr_count} ({sign}{pr_delta})"
        )
        lines.append(f"  - Confirmed incidents in window: {len(summary.confirmed_incidents)}")
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--automation-memory",
        type=Path,
        default=Path.home() / ".codex/automations/weekly-engineering-summary/memory.md",
        help="Path to automation memory.md used to infer the previous run window start.",
    )
    parser.add_argument(
        "--since",
        help="Optional UTC ISO timestamp override (e.g. 2026-05-22T23:00:50Z).",
    )
    parser.add_argument(
        "--repo",
        action="append",
        help="Repo to include (owner/name). Repeat for multiple repos.",
    )
    parser.add_argument("--output", type=Path, help="Optional markdown output path.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    now = datetime.now(UTC)
    if args.since:
        since = parse_iso(args.since)
        if since is None:
            raise RuntimeError("--since must be a non-empty ISO timestamp")
    else:
        since = parse_last_window_end(args.automation_memory)
    repos = tuple(args.repo) if args.repo else DEFAULT_REPOS
    summaries = [summarize_repo(repo, since, now) for repo in repos]
    markdown = emit_markdown(since, now, summaries)
    if args.output:
        args.output.write_text(markdown, encoding="utf-8")
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
