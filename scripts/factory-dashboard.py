#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Local reporting dashboard for the Agent Factory.

Incrementally syncs factory signal from three on-disk-cacheable sources — the
Actions API (workflow runs + per-job conclusions), issue/PR label-event
timelines (the ready/claimed/review/mergeable state machine), and the
factory/ops-data branch (cost rows from #1138) — into a SQLite cache, then
renders a self-contained static HTML report. No server, no hosted tracing: all
data stays on the laptop. Missing or unreachable sources degrade to a stale
banner and placeholders rather than crashing.
"""

from __future__ import annotations

import argparse
import html
import json
import sqlite3
import statistics
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable

REPO_DEFAULT = "fairchild/workspaces"
OPS_BRANCH = "factory/ops-data"
COST_RUNS_PATH = "docs/ops/cost/runs.jsonl"

# Factory workflows the dashboard reports on, matched by Actions workflow name.
IMPLEMENT_WORKFLOW = "Factory Implement"
REVIEW_WORKFLOWS = ("Factory Review Executor", "Factory Review")
FACTORY_WORKFLOWS = (
    IMPLEMENT_WORKFLOW,
    "Factory Review",
    "Factory Review Executor",
    "Factory Monitor",
    "Factory Evidence Verify",
)
# State-machine labels whose timeline events yield stage latencies.
STATE_LABELS = ("ready", "claimed", "review", "mergeable")
STAGE_PAIRS = (("ready", "claimed"), ("claimed", "review"), ("review", "mergeable"))
STAGE_TITLES = {
    ("ready", "claimed"): "ready → claimed",
    ("claimed", "review"): "claimed → review",
    ("review", "mergeable"): "review → mergeable",
}

FAILURE_CONCLUSIONS = {"failure", "timed_out", "startup_failure", "action_required"}
DEFAULT_CAP_IMPLEMENT = 6
DEFAULT_CAP_REVIEW = 12

COST_PLACEHOLDER = "No cost data yet — rows accumulate as factory lanes run."


# --------------------------------------------------------------------------- #
# gh boundary (injectable for tests)
# --------------------------------------------------------------------------- #
class FetchError(RuntimeError):
    """A source could not be fetched; the caller degrades to cache."""


def _run_gh(args: list[str]) -> tuple[int, str, str]:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


class GitHubFetcher:
    """Fetches factory signal via `gh` using ambient auth.

    Normalizes GitHub's camelCase payloads into the snake_case dicts the sync
    layer expects, so the SQLite writers never see transport-shaped keys.
    """

    def __init__(self, repo: str) -> None:
        self.repo = repo

    def _api_lines(self, path: str, *fields: str, jq: str, paginate: bool = True) -> list[dict[str, Any]]:
        # -X GET is load-bearing: any -f flag flips gh's default method to POST,
        # which 404s read endpoints and, for pulls/{n}/reviews, would attempt to
        # create a review. Fields become query-string params under GET.
        args = ["api", "-X", "GET"]
        if paginate:
            args.append("--paginate")
        args.append(f"repos/{self.repo}/{path}")
        for field in fields:
            args.extend(["-f", field])
        args.extend(["--jq", jq])
        code, out, err = _run_gh(args)
        if code != 0:
            raise FetchError(f"gh api {path}: {err.strip() or 'failed'}")
        rows: list[dict[str, Any]] = []
        for line in out.splitlines():
            line = line.strip()
            if line:
                rows.append(json.loads(line))
        return rows

    def workflow_ids(self) -> dict[str, int]:
        """Map factory workflow name → id. Scoping run fetches to these ids is
        the only reliable way to attribute a run to its workflow: a run's own
        `.name` is the (customized) run title, e.g. "Factory Implement ready #12".
        """
        rows = self._api_lines(
            "actions/workflows",
            "per_page=100",
            jq=".workflows[] | {name: .name, id: .id}",
        )
        return {row["name"]: row["id"] for row in rows if row["name"] in FACTORY_WORKFLOWS}

    def runs_for_workflow(self, workflow_id: int, since_date: str) -> list[dict[str, Any]]:
        # `.name` is the run's display title; the true workflow name is stamped
        # by the caller from the id→name mapping.
        jq = (
            ".workflow_runs[] | {run_id: .id, event: .event, head_branch: .head_branch, "
            "status: .status, conclusion: .conclusion, run_attempt: .run_attempt, "
            "display_title: .name, url: .html_url, created_at: .created_at, updated_at: .updated_at}"
        )
        return self._api_lines(
            f"actions/workflows/{workflow_id}/runs",
            f"created=>={since_date}",
            "per_page=100",
            jq=jq,
        )

    def jobs_for_run(self, run_id: int) -> list[dict[str, Any]]:
        jq = (
            ".jobs[] | {job_id: .id, run_id: .run_id, name: .name, conclusion: .conclusion, "
            "status: .status, started_at: .started_at, completed_at: .completed_at}"
        )
        return self._api_lines(f"actions/runs/{run_id}/jobs", "per_page=100", jq=jq)

    def label_events(self, issue_number: int) -> list[dict[str, Any]]:
        jq = (
            '.[] | select(.event=="labeled" or .event=="unlabeled") | '
            "{id: .id, event: .event, label: .label.name, "
            "actor: (.actor.login // null), created_at: .created_at}"
        )
        return self._api_lines(f"issues/{issue_number}/events", "per_page=100", jq=jq)

    def pr_reviews(self, pr_number: int) -> list[dict[str, Any]]:
        jq = (
            ".[] | {id: .id, state: .state, author: (.user.login // null), "
            "submitted_at: .submitted_at}"
        )
        return self._api_lines(f"pulls/{pr_number}/reviews", "per_page=100", jq=jq)

    def issues_since(self, since_date: str) -> list[dict[str, Any]]:
        return self._list_since(
            "issue",
            "number,title,state,createdAt,closedAt,updatedAt,labels",
            since_date,
            self._normalize_issue,
        )

    def prs_since(self, since_date: str) -> list[dict[str, Any]]:
        return self._list_since(
            "pr",
            "number,title,state,createdAt,mergedAt,updatedAt,closingIssuesReferences,labels",
            since_date,
            self._normalize_pr,
        )

    def _list_since(
        self,
        kind: str,
        json_fields: str,
        since_date: str,
        normalize: Callable[[dict[str, Any]], dict[str, Any]],
    ) -> list[dict[str, Any]]:
        code, out, err = _run_gh(
            [
                kind,
                "list",
                "--repo",
                self.repo,
                "--state",
                "all",
                "--limit",
                "500",
                "--search",
                f"updated:>={since_date}",
                "--json",
                json_fields,
            ]
        )
        if code != 0:
            raise FetchError(f"gh {kind} list: {err.strip() or 'failed'}")
        return [normalize(item) for item in json.loads(out)]

    @staticmethod
    def _labels(item: dict[str, Any]) -> list[str]:
        return [label["name"] for label in item.get("labels") or []]

    def _normalize_issue(self, item: dict[str, Any]) -> dict[str, Any]:
        return {
            "number": item["number"],
            "title": item.get("title") or "",
            "state": item.get("state") or "",
            "labels": self._labels(item),
            "created_at": item.get("createdAt"),
            "closed_at": item.get("closedAt"),
            "updated_at": item.get("updatedAt"),
        }

    def _normalize_pr(self, item: dict[str, Any]) -> dict[str, Any]:
        return {
            "number": item["number"],
            "title": item.get("title") or "",
            "state": item.get("state") or "",
            "labels": self._labels(item),
            "closing_issues": [ref["number"] for ref in item.get("closingIssuesReferences") or []],
            "created_at": item.get("createdAt"),
            "merged_at": item.get("mergedAt"),
            "updated_at": item.get("updatedAt"),
        }

    def ops_branch_head(self) -> str | None:
        """Head commit SHA of factory/ops-data, or None if the branch is absent.
        Caching on this (not a per-file blob sha) means one call decides whether
        any ops-data file changed."""
        code, out, err = _run_gh(
            ["api", "-X", "GET", f"repos/{self.repo}/commits/{OPS_BRANCH}", "--jq", ".sha"]
        )
        if code != 0:
            if "Not Found" in (out + err) or "404" in (out + err):
                return None
            raise FetchError(f"gh api commits/{OPS_BRANCH}: {err.strip() or 'failed'}")
        return out.strip() or None

    def ops_file(self, path: str) -> str | None:
        # Raw media type, not the Contents JSON representation: runs.jsonl is
        # append-only and will grow past the 1MB JSON-representation ceiling.
        code, out, err = _run_gh(
            [
                "api", "-X", "GET", f"repos/{self.repo}/contents/{path}",
                "-f", f"ref={OPS_BRANCH}", "-H", "Accept: application/vnd.github.raw",
            ]
        )
        if code != 0:
            if "Not Found" in (out + err) or "404" in (out + err):
                return None
            raise FetchError(f"gh api contents/{path}: {err.strip() or 'failed'}")
        return out

    def repo_variables(self) -> dict[str, str]:
        rows = self._api_lines(
            "actions/variables",
            "per_page=100",
            jq=".variables[] | {name: .name, value: .value}",
        )
        return {row["name"]: row["value"] for row in rows}


# --------------------------------------------------------------------------- #
# datetime helpers
# --------------------------------------------------------------------------- #
def now_utc() -> datetime:
    return datetime.now(tz=UTC)


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def in_window(value: str | None, floor: datetime) -> bool:
    parsed = parse_dt(value)
    return parsed is not None and parsed >= floor


def day_key(value: str | None) -> str | None:
    parsed = parse_dt(value)
    return parsed.date().isoformat() if parsed else None


# --------------------------------------------------------------------------- #
# SQLite cache
# --------------------------------------------------------------------------- #
SCHEMA = """
CREATE TABLE IF NOT EXISTS sync_state (source TEXT PRIMARY KEY, cursor TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS workflow_runs (
  run_id INTEGER, workflow_name TEXT, event TEXT, head_branch TEXT,
  status TEXT, conclusion TEXT, run_attempt INTEGER, display_title TEXT, url TEXT,
  created_at TEXT, updated_at TEXT,
  PRIMARY KEY (run_id, run_attempt)
);
CREATE TABLE IF NOT EXISTS jobs (
  job_id INTEGER PRIMARY KEY, run_id INTEGER, name TEXT, conclusion TEXT,
  status TEXT, started_at TEXT, completed_at TEXT
);
CREATE TABLE IF NOT EXISTS issues (
  number INTEGER PRIMARY KEY, title TEXT, state TEXT, labels TEXT,
  created_at TEXT, closed_at TEXT, updated_at TEXT
);
CREATE TABLE IF NOT EXISTS label_events (
  id INTEGER PRIMARY KEY, issue_number INTEGER, event TEXT, label TEXT,
  actor TEXT, created_at TEXT
);
CREATE TABLE IF NOT EXISTS prs (
  number INTEGER PRIMARY KEY, title TEXT, state TEXT, labels TEXT, author_agent TEXT,
  closing_issues TEXT, created_at TEXT, merged_at TEXT, updated_at TEXT
);
CREATE TABLE IF NOT EXISTS reviews (
  id INTEGER PRIMARY KEY, pr_number INTEGER, state TEXT, author TEXT, submitted_at TEXT
);
CREATE TABLE IF NOT EXISTS cost_rows (
  id TEXT PRIMARY KEY, schema INTEGER, ts TEXT, lane TEXT, workflow TEXT,
  run_id INTEGER, run_attempt INTEGER, phase TEXT, issue INTEGER, pr INTEGER,
  reviewer TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
  cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
  cost_usd REAL, cost_usd_reported REAL, cost_usd_derived REAL, cost_source TEXT,
  duration_ms INTEGER, num_turns INTEGER, result_subtype TEXT
);
CREATE TABLE IF NOT EXISTS ops_files (path TEXT PRIMARY KEY, sha TEXT, fetched_at TEXT);
CREATE INDEX IF NOT EXISTS idx_label_events_issue ON label_events(issue_number);
CREATE INDEX IF NOT EXISTS idx_jobs_run ON jobs(run_id);
CREATE INDEX IF NOT EXISTS idx_reviews_pr ON reviews(pr_number);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def get_cursor(conn: sqlite3.Connection, source: str) -> str | None:
    row = conn.execute("SELECT cursor FROM sync_state WHERE source = ?", (source,)).fetchone()
    return row["cursor"] if row else None


def set_cursor(conn: sqlite3.Connection, source: str, cursor: str) -> None:
    conn.execute(
        "INSERT INTO sync_state(source, cursor, updated_at) VALUES(?,?,?) "
        "ON CONFLICT(source) DO UPDATE SET cursor=excluded.cursor, updated_at=excluded.updated_at",
        (source, cursor, now_utc().isoformat()),
    )


def advance_cursor(conn: sqlite3.Connection, source: str, candidate: str | None) -> None:
    if not candidate:
        return
    current = get_cursor(conn, source)
    if current is None or candidate > current:
        set_cursor(conn, source, candidate)


def meta_get(conn: sqlite3.Connection, key: str, default: str | None = None) -> str | None:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def meta_set(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def _upsert(conn: sqlite3.Connection, table: str, key: str | tuple[str, ...], row: dict[str, Any]) -> None:
    keys = (key,) if isinstance(key, str) else tuple(key)
    cols = list(row)
    placeholders = ",".join("?" for _ in cols)
    updates = ",".join(f"{col}=excluded.{col}" for col in cols if col not in keys)
    conn.execute(
        f"INSERT INTO {table}({','.join(cols)}) VALUES({placeholders}) "
        f"ON CONFLICT({','.join(keys)}) DO UPDATE SET {updates}",
        [row[col] for col in cols],
    )


def _later(a: str | None, b: str | None) -> str | None:
    candidates = [value for value in (a, b) if value]
    return max(candidates) if candidates else None


def _effective_since(cursor: str | None, floor: str) -> str:
    # min(cursor, floor): a saved cursor never narrows a wider --days request,
    # so increasing --days backfills; upserts make the re-fetched overlap a no-op.
    return floor if cursor is None else min(cursor, floor)


# --------------------------------------------------------------------------- #
# sync
# --------------------------------------------------------------------------- #
def _author_agent(labels: list[str]) -> str | None:
    for label in labels:
        if label.startswith("author:"):
            return label.split(":", 1)[1]
    return None


def sync_runs(conn: sqlite3.Connection, fetcher: Any, floor: str) -> int:
    # Cursor advances once, after the whole batch lands, to the max timestamp
    # seen — a mid-batch sub-fetch failure raises before any advance, so the
    # next sync re-reads from the same floor rather than skipping unfetched rows.
    since = _effective_since(get_cursor(conn, "workflow_runs"), floor)[:10]
    total = 0
    batch_max: str | None = None
    for workflow_name, workflow_id in fetcher.workflow_ids().items():
        for run in fetcher.runs_for_workflow(workflow_id, since):
            run = {**run, "workflow_name": workflow_name}
            _upsert(conn, "workflow_runs", ("run_id", "run_attempt"), run)
            batch_max = _later(batch_max, run.get("created_at"))
            if run.get("status") == "completed":
                for job in fetcher.jobs_for_run(run["run_id"]):
                    _upsert(conn, "jobs", "job_id", job)
            total += 1
    advance_cursor(conn, "workflow_runs", batch_max)
    return total


def sync_issues(conn: sqlite3.Connection, fetcher: Any, floor: str) -> int:
    since = _effective_since(get_cursor(conn, "issues"), floor)
    issues = fetcher.issues_since(since[:10])
    batch_max: str | None = None
    for issue in issues:
        labels = issue.get("labels") or []
        _upsert(conn, "issues", "number", {**issue, "labels": json.dumps(labels)})
        if any(label in STATE_LABELS for label in labels):
            for event in fetcher.label_events(issue["number"]):
                _upsert(conn, "label_events", "id", {**event, "issue_number": issue["number"]})
        batch_max = _later(batch_max, issue.get("updated_at"))
    advance_cursor(conn, "issues", batch_max)
    return len(issues)


def sync_prs(conn: sqlite3.Connection, fetcher: Any, floor: str) -> int:
    since = _effective_since(get_cursor(conn, "prs"), floor)
    prs = fetcher.prs_since(since[:10])
    batch_max: str | None = None
    for pr in prs:
        labels = pr.get("labels") or []
        author = _author_agent(labels)
        _upsert(
            conn,
            "prs",
            "number",
            {
                "number": pr["number"],
                "title": pr.get("title") or "",
                "state": pr.get("state") or "",
                "labels": json.dumps(labels),
                "author_agent": author,
                "closing_issues": json.dumps(pr.get("closing_issues") or []),
                "created_at": pr.get("created_at"),
                "merged_at": pr.get("merged_at"),
                "updated_at": pr.get("updated_at"),
            },
        )
        if author:
            for review in fetcher.pr_reviews(pr["number"]):
                _upsert(conn, "reviews", "id", {**review, "pr_number": pr["number"]})
        batch_max = _later(batch_max, pr.get("updated_at"))
    advance_cursor(conn, "prs", batch_max)
    return len(prs)


def sync_ops_data(conn: sqlite3.Connection, fetcher: Any) -> int:
    head = fetcher.ops_branch_head()
    if head is None:
        return 0  # branch not created yet; cost panels render the placeholder
    prior = conn.execute("SELECT sha FROM ops_files WHERE path = ?", (COST_RUNS_PATH,)).fetchone()
    if prior and prior["sha"] == head:
        return 0
    text = fetcher.ops_file(COST_RUNS_PATH)
    appended = 0
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict) or not row.get("id"):
            continue
        _upsert(conn, "cost_rows", "id", _cost_row_columns(row))
        appended += 1
    _upsert(
        conn,
        "ops_files",
        "path",
        {"path": COST_RUNS_PATH, "sha": head, "fetched_at": now_utc().isoformat()},
    )
    return appended


def _cost_row_columns(row: dict[str, Any]) -> dict[str, Any]:
    def num(key: str, cast: Callable[[Any], Any]) -> Any:
        value = row.get(key)
        try:
            return cast(value) if value is not None else 0
        except (TypeError, ValueError):
            return 0

    # model_usage (the per-model token breakdown) is intentionally not stored —
    # no panel consumes it yet; the scalar token totals below suffice.
    return {
        "id": str(row["id"]),
        "schema": num("schema", int),
        "ts": row.get("ts"),
        "lane": row.get("lane"),
        "workflow": row.get("workflow"),
        "run_id": row.get("run_id"),
        "run_attempt": row.get("run_attempt"),
        "phase": row.get("phase"),
        "issue": row.get("issue"),
        "pr": row.get("pr"),
        "reviewer": row.get("reviewer"),
        "model": row.get("model"),
        "input_tokens": num("input_tokens", int),
        "output_tokens": num("output_tokens", int),
        "cache_creation_input_tokens": num("cache_creation_input_tokens", int),
        "cache_read_input_tokens": num("cache_read_input_tokens", int),
        "cost_usd": num("cost_usd", float),
        "cost_usd_reported": num("cost_usd_reported", float),
        "cost_usd_derived": num("cost_usd_derived", float),
        "cost_source": row.get("cost_source"),
        "duration_ms": num("duration_ms", int),
        "num_turns": num("num_turns", int),
        "result_subtype": row.get("result_subtype"),
    }


def sync_settings(conn: sqlite3.Connection, fetcher: Any) -> None:
    variables = fetcher.repo_variables()
    if variables.get("FACTORY_IMPLEMENT_DAILY_CAP"):
        meta_set(conn, "cap_implement", variables["FACTORY_IMPLEMENT_DAILY_CAP"])
    if variables.get("FACTORY_REVIEW_DAILY_CAP"):
        meta_set(conn, "cap_review", variables["FACTORY_REVIEW_DAILY_CAP"])


def sync_all(conn: sqlite3.Connection, fetcher: Any, *, days: int) -> dict[str, Any]:
    floor = (now_utc() - timedelta(days=days)).isoformat().replace("+00:00", "Z")
    stats: dict[str, Any] = {"errors": []}
    steps: list[tuple[str, Callable[[], int | None]]] = [
        ("runs", lambda: sync_runs(conn, fetcher, floor)),
        ("issues", lambda: sync_issues(conn, fetcher, floor)),
        ("prs", lambda: sync_prs(conn, fetcher, floor)),
        ("cost_rows", lambda: sync_ops_data(conn, fetcher)),
        ("settings", lambda: sync_settings(conn, fetcher)),
    ]
    for name, step in steps:
        try:
            stats[name] = step()
        except Exception as error:  # per-source isolation; KeyboardInterrupt/SystemExit propagate
            stats["errors"].append(f"{name}: {error}")
            print(f"[factory-dashboard] {name} sync failed: {error}", file=sys.stderr)
    ok = not stats["errors"]
    meta_set(conn, "last_sync_at", now_utc().isoformat())
    meta_set(conn, "last_sync_ok", "1" if ok else "0")
    if stats["errors"]:
        meta_set(conn, "last_sync_error", "; ".join(stats["errors"]))
    conn.commit()
    return stats


# --------------------------------------------------------------------------- #
# metrics
# --------------------------------------------------------------------------- #
def _median(values: list[float]) -> float | None:
    return float(statistics.median(values)) if values else None


def aggregate_cost(cost_rows: list[dict[str, Any]], merged_pr_count: int) -> dict[str, Any]:
    """Fold cost rows into headline efficiency numbers.

    cost_per_merged_pr divides spend by ships; prs_per_dollar is its efficiency
    reciprocal (ships per dollar). Both guard division by zero.
    """
    total_cost = sum(float(row.get("cost_usd") or 0.0) for row in cost_rows)
    total_input = sum(int(row.get("input_tokens") or 0) for row in cost_rows)
    total_output = sum(int(row.get("output_tokens") or 0) for row in cost_rows)
    total_cache_read = sum(int(row.get("cache_read_input_tokens") or 0) for row in cost_rows)
    total_cache_write = sum(int(row.get("cache_creation_input_tokens") or 0) for row in cost_rows)
    by_phase: dict[str, dict[str, float]] = {}
    for row in cost_rows:
        phase = str(row.get("phase") or "unknown")
        bucket = by_phase.setdefault(phase, {"count": 0, "cost": 0.0})
        bucket["count"] += 1
        bucket["cost"] += float(row.get("cost_usd") or 0.0)
    return {
        "row_count": len(cost_rows),
        "total_cost_usd": total_cost,
        "total_input_tokens": total_input,
        "total_output_tokens": total_output,
        "total_cache_read_tokens": total_cache_read,
        "total_cache_write_tokens": total_cache_write,
        "merged_pr_count": merged_pr_count,
        "cost_per_merged_pr": (total_cost / merged_pr_count) if merged_pr_count else None,
        "prs_per_dollar": (merged_pr_count / total_cost) if total_cost > 0 else None,
        "by_phase": by_phase,
    }


def rolling_efficiency(
    cost_rows: list[dict[str, Any]],
    merged_prs: list[dict[str, Any]],
    *,
    days: int,
    now: datetime,
) -> list[dict[str, Any]]:
    """Cumulative ships-per-dollar for each active day in the window.

    Each point divides ships merged on-or-before that day by spend accrued
    on-or-before it, so the series shows efficiency converging as volume grows.
    """
    floor = now - timedelta(days=days)
    cost_by_day: dict[str, float] = {}
    for row in cost_rows:
        key = day_key(row.get("ts"))
        if key:
            cost_by_day[key] = cost_by_day.get(key, 0.0) + float(row.get("cost_usd") or 0.0)
    ships_by_day: dict[str, int] = {}
    for pr in merged_prs:
        key = day_key(pr.get("merged_at"))
        if key:
            ships_by_day[key] = ships_by_day.get(key, 0) + 1
    # Compare date-to-date: day keys parse as UTC midnight, so an exact-time
    # floor would drop the first partial day of the window.
    days_span = sorted({*cost_by_day, *ships_by_day})
    days_span = [d for d in days_span if parse_dt(d) and parse_dt(d).date() >= floor.date()]
    series: list[dict[str, Any]] = []
    cum_cost = 0.0
    cum_ships = 0
    for day in days_span:
        cum_cost += cost_by_day.get(day, 0.0)
        cum_ships += ships_by_day.get(day, 0)
        series.append(
            {
                "date": day,
                "cost_usd": cum_cost,
                "ships": cum_ships,
                "prs_per_dollar": (cum_ships / cum_cost) if cum_cost > 0 else None,
            }
        )
    return series


def stage_latencies(label_events: list[dict[str, Any]]) -> dict[str, Any]:
    """Median hours between state-machine label transitions, per stage.

    Per issue, a `ready` label opens a fresh cycle (a re-dispatch clears the
    earlier cycle's claimed/review/mergeable), and each downstream label is its
    first application within that cycle — so latencies come from one lifecycle,
    not a mix of an abandoned attempt and its retry.
    """
    by_issue: dict[int, list[dict[str, Any]]] = {}
    for event in label_events:
        by_issue.setdefault(int(event["issue_number"]), []).append(event)

    per_stage: dict[tuple[str, str], list[float]] = {pair: [] for pair in STAGE_PAIRS}
    per_issue: list[dict[str, Any]] = []
    for issue_number, events in by_issue.items():
        stamps = _stage_timestamps(events)
        issue_row: dict[str, Any] = {"issue": issue_number}
        for start, end in STAGE_PAIRS:
            hours = _delta_hours(stamps.get(start), stamps.get(end))
            issue_row[f"{start}_{end}"] = hours
            if hours is not None:
                per_stage[(start, end)].append(hours)
        per_issue.append(issue_row)

    stages = [
        {
            "name": STAGE_TITLES[pair],
            "median_hours": _median(values),
            "count": len(values),
        }
        for pair, values in per_stage.items()
    ]
    return {"stages": stages, "per_issue": per_issue}


def _stage_timestamps(events: list[dict[str, Any]]) -> dict[str, datetime]:
    ordered = sorted(
        (e for e in events if parse_dt(e.get("created_at"))),
        key=lambda e: parse_dt(e["created_at"]),  # type: ignore[arg-type]
    )
    stamps: dict[str, datetime] = {}
    for event in ordered:
        if event.get("event") != "labeled":
            continue
        label = event.get("label")
        when = parse_dt(event.get("created_at"))
        if when is None or label not in STATE_LABELS:
            continue
        if label == "ready":
            stamps = {"ready": when}  # re-dispatch: start a fresh cycle
        elif label not in stamps:
            stamps[label] = when
    return stamps


def _delta_hours(start: datetime | None, end: datetime | None) -> float | None:
    if start is None or end is None or end < start:
        return None
    return (end - start).total_seconds() / 3600.0


def failure_stats(
    runs: list[dict[str, Any]],
    jobs_by_run: dict[int, list[dict[str, Any]]],
) -> dict[str, Any]:
    per_workflow: dict[str, dict[str, int]] = {}
    for run in runs:
        if run.get("status") != "completed":
            continue
        name = run.get("workflow_name") or "unknown"
        bucket = per_workflow.setdefault(name, {"completed": 0, "failed": 0})
        bucket["completed"] += 1
        if str(run.get("conclusion") or "").lower() in FAILURE_CONCLUSIONS:
            bucket["failed"] += 1

    implement = per_workflow.get(IMPLEMENT_WORKFLOW, {"completed": 0, "failed": 0})
    failing_jobs: dict[str, int] = {}
    for run in runs:
        if str(run.get("conclusion") or "").lower() not in FAILURE_CONCLUSIONS:
            continue
        for job in jobs_by_run.get(int(run["run_id"]), []):
            if str(job.get("conclusion") or "").lower() in FAILURE_CONCLUSIONS:
                failing_jobs[job["name"]] = failing_jobs.get(job["name"], 0) + 1

    workflows = [
        {
            "workflow": name,
            "completed": data["completed"],
            "failed": data["failed"],
            "failure_rate": (data["failed"] / data["completed"] * 100.0) if data["completed"] else 0.0,
        }
        for name, data in sorted(per_workflow.items())
    ]
    return {
        "workflows": workflows,
        "rollback_count": implement["failed"],
        "rollback_rate": (implement["failed"] / implement["completed"] * 100.0)
        if implement["completed"]
        else 0.0,
        "top_failing_jobs": sorted(failing_jobs.items(), key=lambda kv: kv[1], reverse=True)[:5],
    }


def cap_utilization(
    runs: list[dict[str, Any]],
    *,
    cap_implement: int,
    cap_review: int,
    days: int,
    now: datetime,
) -> dict[str, Any]:
    def daily(workflow_names: tuple[str, ...] | str) -> dict[str, int]:
        names = (workflow_names,) if isinstance(workflow_names, str) else workflow_names
        counts: dict[str, int] = {}
        for run in runs:
            if run.get("workflow_name") not in names:
                continue
            key = day_key(run.get("created_at"))
            if key:
                counts[key] = counts.get(key, 0) + 1
        return counts

    def lane(counts: dict[str, int], cap: int) -> dict[str, Any]:
        floor = now - timedelta(days=days)
        series = []
        cursor = floor
        while cursor.date() <= now.date():
            key = cursor.date().isoformat()
            series.append({"date": key, "count": counts.get(key, 0)})
            cursor += timedelta(days=1)
        peak = max((point["count"] for point in series), default=0)
        return {
            "cap": cap,
            "series": series,
            "peak": peak,
            "peak_utilization": (peak / cap * 100.0) if cap else 0.0,
        }

    return {
        "implement": lane(daily(IMPLEMENT_WORKFLOW), cap_implement),
        "review": lane(daily(REVIEW_WORKFLOWS), cap_review),
    }


def review_verdicts(reviews: list[dict[str, Any]]) -> dict[str, Any]:
    counts = {"approved": 0, "changes_requested": 0, "commented": 0, "dismissed": 0, "other": 0}
    per_pr: dict[int, int] = {}
    for review in reviews:
        state = str(review.get("state") or "").upper()
        key = {
            "APPROVED": "approved",
            "CHANGES_REQUESTED": "changes_requested",
            "COMMENTED": "commented",
            "DISMISSED": "dismissed",
        }.get(state, "other")
        counts[key] += 1
        per_pr[int(review["pr_number"])] = per_pr.get(int(review["pr_number"]), 0) + 1
    decisive = counts["approved"] + counts["changes_requested"]
    return {
        **counts,
        "total": sum(counts.values()),
        "prs_reviewed": len(per_pr),
        "prs_re_reviewed": sum(1 for n in per_pr.values() if n >= 2),
        "approval_rate": (counts["approved"] / decisive * 100.0) if decisive else None,
    }


def throughput(
    issues: list[dict[str, Any]],
    merged_prs: list[dict[str, Any]],
    opened_agent_prs: int,
    *,
    days: int,
    now: datetime,
) -> dict[str, Any]:
    floor = now - timedelta(days=days)
    opened = sum(1 for issue in issues if in_window(issue.get("created_at"), floor))
    closed = sum(1 for issue in issues if in_window(issue.get("closed_at"), floor))
    merged = len(merged_prs)
    return {
        "issues_opened": opened,
        "issues_closed": closed,
        "agent_prs_opened": opened_agent_prs,
        "agent_prs_merged": merged,
        "merged_per_closed": (merged / closed) if closed else None,
    }


def build_metrics(conn: sqlite3.Connection, *, days: int, now: datetime) -> dict[str, Any]:
    floor = now - timedelta(days=days)
    # GitHub and cost-row timestamps end in Z; match that so the boundary-second
    # lexicographic comparison below is exact rather than tripping on Z vs +00:00.
    floor_iso = floor.isoformat().replace("+00:00", "Z")

    runs = [dict(r) for r in conn.execute(
        "SELECT * FROM workflow_runs WHERE created_at >= ?", (floor_iso,)
    )]
    jobs_by_run: dict[int, list[dict[str, Any]]] = {}
    for job in conn.execute("SELECT * FROM jobs"):
        jobs_by_run.setdefault(job["run_id"], []).append(dict(job))

    issues = [dict(r) for r in conn.execute("SELECT * FROM issues")]
    label_events = [dict(r) for r in conn.execute(
        "SELECT * FROM label_events WHERE created_at >= ?", (floor_iso,)
    )]
    cost_rows = [
        dict(r) for r in conn.execute("SELECT * FROM cost_rows WHERE ts >= ?", (floor_iso,))
    ]

    all_prs = [dict(r) for r in conn.execute("SELECT * FROM prs")]
    agent_prs = [pr for pr in all_prs if pr.get("author_agent")]
    merged_prs = [pr for pr in agent_prs if in_window(pr.get("merged_at"), floor)]
    opened_agent_prs = sum(1 for pr in agent_prs if in_window(pr.get("created_at"), floor))
    window_pr_numbers = {
        pr["number"]
        for pr in agent_prs
        if in_window(pr.get("created_at"), floor) or in_window(pr.get("merged_at"), floor)
    }
    reviews = [
        dict(r)
        for r in conn.execute("SELECT * FROM reviews")
        if r["pr_number"] in window_pr_numbers
    ]

    cap_implement = int(meta_get(conn, "cap_implement", str(DEFAULT_CAP_IMPLEMENT)) or DEFAULT_CAP_IMPLEMENT)
    cap_review = int(meta_get(conn, "cap_review", str(DEFAULT_CAP_REVIEW)) or DEFAULT_CAP_REVIEW)

    return {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "window_days": days,
        "last_sync_at": meta_get(conn, "last_sync_at"),
        "last_sync_ok": meta_get(conn, "last_sync_ok", "1") == "1",
        "last_sync_error": meta_get(conn, "last_sync_error"),
        "throughput": throughput(issues, merged_prs, opened_agent_prs, days=days, now=now),
        "cost": aggregate_cost(cost_rows, len(merged_prs)),
        "rolling_efficiency": rolling_efficiency(cost_rows, merged_prs, days=days, now=now),
        "stage_latencies": stage_latencies(label_events),
        "failures": failure_stats(runs, jobs_by_run),
        "cap_utilization": cap_utilization(
            runs, cap_implement=cap_implement, cap_review=cap_review, days=days, now=now
        ),
        "review_verdicts": review_verdicts(reviews),
        "run_count": len(runs),
    }


# --------------------------------------------------------------------------- #
# render
# --------------------------------------------------------------------------- #
def esc(value: Any) -> str:
    return html.escape(str(value))


def fmt_usd(value: float | None) -> str:
    if value is None:
        return "n/a"
    if 0 < value < 0.01:
        return f"${value:.4f}"
    return f"${value:,.2f}"


def fmt_hours(hours: float | None) -> str:
    if hours is None:
        return "n/a"
    if hours < 1:
        return f"{hours * 60:.0f} min"
    if hours < 48:
        return f"{hours:.1f} h"
    return f"{hours / 24:.1f} d"


def fmt_num(value: float | None, digits: int = 1) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def stat_tile(label: str, value: str, sub: str = "", tone: str = "") -> str:
    tone_class = f" tile-{tone}" if tone else ""
    sub_html = f'<div class="tile-sub">{esc(sub)}</div>' if sub else ""
    return (
        f'<div class="tile{tone_class}"><div class="tile-value">{esc(value)}</div>'
        f'<div class="tile-label">{esc(label)}</div>{sub_html}</div>'
    )


def hbar_chart(items: list[tuple[str, float, str, str]], *, max_value: float | None = None) -> str:
    """Horizontal labelled bars. items: (label, value, display, css-tone)."""
    if not items:
        return '<p class="empty">no data in window</p>'
    ceiling = max_value if max_value is not None else max((v for _, v, _, _ in items), default=0.0)
    ceiling = ceiling or 1.0
    rows = []
    for label, value, display, tone in items:
        pct = max(0.0, min(100.0, value / ceiling * 100.0))
        rows.append(
            f'<div class="bar-row"><div class="bar-label">{esc(label)}</div>'
            f'<div class="bar-track"><div class="bar-fill bar-{tone}" style="width:{pct:.1f}%"></div></div>'
            f'<div class="bar-value">{esc(display)}</div></div>'
        )
    return f'<div class="bars">{"".join(rows)}</div>'


def daily_cap_chart(lane: dict[str, Any], tone: str) -> str:
    series = lane["series"]
    cap = lane["cap"]
    if not series:
        return '<p class="empty">no runs in window</p>'
    ceiling = max(cap, max((point["count"] for point in series), default=0)) or 1
    bar_w = max(6, min(28, int(560 / max(len(series), 1)) - 4))
    gap = 4
    height = 90
    cap_y = height - (cap / ceiling * height)
    bars = []
    for index, point in enumerate(series):
        x = index * (bar_w + gap)
        bar_h = point["count"] / ceiling * height
        y = height - bar_h
        over = point["count"] > cap
        fill = "var(--untrusted)" if over else f"var(--{tone})"
        bars.append(
            f'<rect x="{x}" y="{y:.1f}" width="{bar_w}" height="{bar_h:.1f}" fill="{fill}" rx="1">'
            f'<title>{esc(point["date"])}: {point["count"]} runs</title></rect>'
        )
    total_w = len(series) * (bar_w + gap)
    cap_line = (
        f'<line x1="0" y1="{cap_y:.1f}" x2="{total_w}" y2="{cap_y:.1f}" '
        f'stroke="var(--gate)" stroke-width="1" stroke-dasharray="4 3"/>'
        f'<text x="{total_w}" y="{cap_y - 3:.1f}" text-anchor="end" class="cap-lbl">cap {cap}/day</text>'
    )
    return (
        f'<svg width="{total_w}" height="{height + 14}" viewBox="0 0 {total_w} {height + 14}" '
        f'role="img" class="daily-chart">{"".join(bars)}{cap_line}</svg>'
    )


def sparkline(series: list[dict[str, Any]], key: str) -> str:
    points = [(i, p[key]) for i, p in enumerate(series) if p.get(key) is not None]
    if len(points) < 2:
        return '<p class="empty">not enough data for a trend yet</p>'
    values = [v for _, v in points]
    lo, hi = min(values), max(values)
    span = (hi - lo) or 1.0
    width, height = 560, 70
    step = width / (len(series) - 1 or 1)
    coords = [
        f"{i * step:.1f},{height - (value - lo) / span * height:.1f}" for i, value in points
    ]
    last = points[-1][1]
    return (
        f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" class="spark">'
        f'<polyline points="{" ".join(coords)}" fill="none" stroke="var(--verified)" stroke-width="1.6"/>'
        f'<text x="{width}" y="12" text-anchor="end" class="spark-lbl">{last:.2f} PRs/$</text></svg>'
    )


def render_html(metrics: dict[str, Any]) -> str:
    tp = metrics["throughput"]
    cost = metrics["cost"]
    failures = metrics["failures"]
    caps = metrics["cap_utilization"]
    verdicts = metrics["review_verdicts"]

    banner = ""
    if not metrics["last_sync_ok"]:
        detail = metrics.get("last_sync_error")
        reason = f" ({esc(detail)})" if detail else ""
        banner = (
            '<div class="banner">Rendered from cache — last sync failed'
            f"{reason}. Numbers may be stale.</div>"
        )

    throughput_tiles = "".join(
        [
            stat_tile("Issues opened", str(tp["issues_opened"])),
            stat_tile("Issues closed", str(tp["issues_closed"])),
            stat_tile("Agent PRs opened", str(tp["agent_prs_opened"])),
            stat_tile("Agent PRs merged", str(tp["agent_prs_merged"]), tone="ver"),
            stat_tile(
                "Merged per closed issue",
                fmt_num(tp["merged_per_closed"], 2),
                sub="ships ÷ issues closed",
            ),
        ]
    )

    if cost["row_count"] == 0:
        cost_body = f'<p class="empty">{esc(COST_PLACEHOLDER)}</p>'
    else:
        cost_tiles = "".join(
            [
                stat_tile("Total spend", fmt_usd(cost["total_cost_usd"])),
                stat_tile("Cost per merged PR", fmt_usd(cost["cost_per_merged_pr"]), tone="gate"),
                stat_tile(
                    "Efficiency",
                    fmt_num(cost["prs_per_dollar"], 2),
                    sub="merged PRs per $",
                    tone="ver",
                ),
                stat_tile("Cost rows", str(cost["row_count"])),
                stat_tile(
                    "Input / output tokens",
                    f'{cost["total_input_tokens"]:,} / {cost["total_output_tokens"]:,}',
                ),
            ]
        )
        phase_rows = sorted(
            cost["by_phase"].items(), key=lambda kv: kv[1]["cost"], reverse=True
        )
        phase_bars = hbar_chart(
            [
                (phase, data["cost"], f'{fmt_usd(data["cost"])} · {int(data["count"])} invocations', "gate")
                for phase, data in phase_rows
            ]
        )
        spark = sparkline(metrics["rolling_efficiency"], "prs_per_dollar")
        cost_body = (
            f'<div class="tiles">{cost_tiles}</div>'
            f'<h3>Spend by phase</h3>{phase_bars}'
            f'<h3>Rolling efficiency (cumulative ships ÷ spend)</h3>{spark}'
            '<p class="footnote">Denominator is every merged <code>author:*</code> PR in '
            'the window — factory-attributed or not; no PR-level factory provenance signal '
            'exists yet, so agent PRs opened outside the factory are counted as ships.</p>'
        )

    stage_items = []
    for stage in metrics["stage_latencies"]["stages"]:
        median = stage["median_hours"]
        stage_items.append(
            (
                stage["name"],
                median if median is not None else 0.0,
                f'{fmt_hours(median)} · n={stage["count"]}',
                "gate",
            )
        )
    stage_bars = hbar_chart(stage_items)

    workflow_items = [
        (
            wf["workflow"],
            wf["failure_rate"],
            f'{wf["failed"]}/{wf["completed"]} · {fmt_num(wf["failure_rate"])}%',
            "untr" if wf["failure_rate"] > 0 else "ver",
        )
        for wf in failures["workflows"]
    ]
    failure_bars = hbar_chart(workflow_items, max_value=100.0)
    rollback_tile = "".join(
        [
            stat_tile(
                "Rollbacks",
                str(failures["rollback_count"]),
                sub=f'{fmt_num(failures["rollback_rate"])}% of implement runs',
                tone="untr" if failures["rollback_count"] else "",
            ),
        ]
    )
    if failures["top_failing_jobs"]:
        job_lines = "".join(
            f"<li><code>{esc(name)}</code> — {count} failure(s)</li>"
            for name, count in failures["top_failing_jobs"]
        )
        failing_jobs_html = f"<h3>Top failing jobs</h3><ul class='plain'>{job_lines}</ul>"
    else:
        failing_jobs_html = ""

    cap_body = (
        f'<div class="cap-lane"><div class="cap-head">Implement '
        f'<span>peak {caps["implement"]["peak"]}/{caps["implement"]["cap"]} · '
        f'{fmt_num(caps["implement"]["peak_utilization"])}%</span></div>'
        f'{daily_cap_chart(caps["implement"], "verified")}</div>'
        f'<div class="cap-lane"><div class="cap-head">Review '
        f'<span>peak {caps["review"]["peak"]}/{caps["review"]["cap"]} · '
        f'{fmt_num(caps["review"]["peak_utilization"])}%</span></div>'
        f'{daily_cap_chart(caps["review"], "verified")}</div>'
    )

    if verdicts["total"] == 0:
        verdict_body = '<p class="empty">no counterpart reviews on agent PRs in window</p>'
    else:
        verdict_tiles = "".join(
            [
                stat_tile("Approvals", str(verdicts["approved"]), tone="ver"),
                stat_tile("Changes requested", str(verdicts["changes_requested"]), tone="untr"),
                stat_tile(
                    "Approval rate",
                    "n/a" if verdicts["approval_rate"] is None else f'{fmt_num(verdicts["approval_rate"])}%',
                ),
                stat_tile("PRs reviewed", str(verdicts["prs_reviewed"])),
                stat_tile(
                    "Re-reviewed PRs",
                    str(verdicts["prs_re_reviewed"]),
                    sub="≥2 review rounds",
                ),
            ]
        )
        verdict_body = f'<div class="tiles">{verdict_tiles}</div>'

    sync_line = (
        f'last sync <b>{esc(metrics["last_sync_at"] or "never")}</b>'
        if metrics.get("last_sync_at")
        else "not yet synced"
    )

    return f"""<!DOCTYPE html>
<!-- Agent Factory operations dashboard — generated by scripts/factory-dashboard.py. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent Factory — Operations Dashboard</title>
<style>
{DASHBOARD_CSS}
</style>
</head>
<body>
<div class="sheet">
<header class="masthead">
  <p class="kicker">Workspaces · Factory Telemetry</p>
  <h1>Factory Operations</h1>
  <p class="dek">Throughput, cost, latency, and reliability for the autonomous
  issue-to-PR pipeline — cached from GitHub and the ops-data branch, rendered on
  the laptop.</p>
  <div class="status-strip">
    <span>window: <b>{metrics["window_days"]} days</b></span>
    <span>generated: <b>{esc(metrics["generated_at"])}</b></span>
    <span>{sync_line}</span>
  </div>
</header>
{banner}
<section>
  <h2><span class="sn">§01 · Throughput</span>Issues into merged PRs</h2>
  <div class="tiles">{throughput_tiles}</div>
</section>
<section>
  <h2><span class="sn">§02 · Economics</span>Cost per merged PR &amp; efficiency</h2>
  {cost_body}
</section>
<section>
  <h2><span class="sn">§03 · Latency</span>Stage latencies from label events</h2>
  {stage_bars}
</section>
<section>
  <h2><span class="sn">§04 · Reliability</span>Failure &amp; rollback rates</h2>
  {failure_bars}
  <div class="tiles">{rollback_tile}</div>
  {failing_jobs_html}
</section>
<section>
  <h2><span class="sn">§05 · Budget</span>Daily cap utilization</h2>
  {cap_body}
</section>
<section>
  <h2><span class="sn">§06 · Review</span>Counterpart verdicts</h2>
  {verdict_body}
</section>
<footer>
  <div>source: cached GitHub Actions + label timelines + <code>{OPS_BRANCH}</code></div>
  <div>regenerate: <code>uv run --script scripts/factory-dashboard.py</code></div>
</footer>
</div>
</body>
</html>
"""


DASHBOARD_CSS = """
  :root {
    --paper: #f6f2ea; --paper-raised: #fdfaf4; --ink: #26221c; --ink-soft: #5c554a;
    --hairline: #d8d0c0; --gate: #b45f06; --gate-soft: #f3e2cb; --verified: #1f6f63;
    --verified-soft: #d9e9e4; --untrusted: #8a4a52; --untrusted-soft: #f0dfe0;
    --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    --serif: Charter, "Iowan Old Style", Georgia, serif;
    --sans: "Avenir Next", Avenir, Futura, "Century Gothic", sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #1c1a17; --paper-raised: #26231e; --ink: #e8e2d6; --ink-soft: #a89f8f;
      --hairline: #3d382f; --gate: #e0a458; --gate-soft: #3a2e1d; --verified: #6fbfae;
      --verified-soft: #1e332e; --untrusted: #cf8891; --untrusted-soft: #362226;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--paper); color: var(--ink); font-family: var(--serif);
    font-size: 17px; line-height: 1.6; }
  .sheet { max-width: 52rem; margin: 0 auto; padding: 3rem 1.5rem 6rem; }
  header.masthead { border-bottom: 3px double var(--hairline); padding-bottom: 1.5rem; margin-bottom: 2rem; }
  .kicker { font-family: var(--mono); font-size: .72rem; letter-spacing: .18em;
    text-transform: uppercase; color: var(--gate); margin: 0 0 .75rem; }
  h1 { font-family: var(--sans); font-weight: 600; font-size: 2.1rem; line-height: 1.15;
    margin: 0 0 .75rem; letter-spacing: -.01em; }
  .dek { color: var(--ink-soft); font-size: 1.02rem; margin: 0; max-width: 40rem; }
  .status-strip { display: flex; flex-wrap: wrap; gap: .4rem 1.5rem; margin-top: 1.25rem;
    font-family: var(--mono); font-size: .74rem; color: var(--ink-soft); }
  .status-strip b { color: var(--ink); font-weight: 600; }
  .banner { background: var(--untrusted-soft); border: 1px solid var(--untrusted);
    color: var(--ink); font-family: var(--mono); font-size: .8rem; padding: .7rem 1rem;
    border-radius: 4px; margin-bottom: 2rem; }
  section { margin: 0 0 2.75rem; }
  h2 { font-family: var(--sans); font-weight: 600; font-size: 1.3rem; margin: 0 0 1.1rem;
    padding-top: 1.25rem; border-top: 1px solid var(--hairline); }
  h2 .sn { display: block; font-family: var(--mono); font-weight: 400; font-size: .7rem;
    letter-spacing: .18em; color: var(--gate); margin-bottom: .35rem; }
  h3 { font-family: var(--sans); font-size: 1rem; font-weight: 600; margin: 1.6rem 0 .7rem; }
  code { font-family: var(--mono); font-size: .82em; background: var(--paper-raised);
    border: 1px solid var(--hairline); padding: .08em .35em; border-radius: 3px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(9.5rem, 1fr));
    gap: .75rem; margin: 0 0 1rem; }
  .tile { background: var(--paper-raised); border: 1px solid var(--hairline);
    border-left: 3px solid var(--ink-soft); padding: .85rem 1rem; border-radius: 3px; }
  .tile-ver { border-left-color: var(--verified); }
  .tile-gate { border-left-color: var(--gate); }
  .tile-untr { border-left-color: var(--untrusted); }
  .tile-value { font-family: var(--sans); font-weight: 600; font-size: 1.55rem; line-height: 1.1; }
  .tile-label { font-family: var(--mono); font-size: .68rem; letter-spacing: .06em;
    text-transform: uppercase; color: var(--ink-soft); margin-top: .35rem; }
  .tile-sub { font-size: .78rem; color: var(--ink-soft); margin-top: .2rem; }
  .bars { display: flex; flex-direction: column; gap: .5rem; margin: 1rem 0; }
  .bar-row { display: grid; grid-template-columns: 12rem 1fr auto; align-items: center; gap: .75rem; }
  .bar-label { font-family: var(--mono); font-size: .78rem; color: var(--ink); overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap; }
  .bar-track { background: var(--paper-raised); border: 1px solid var(--hairline);
    height: 1.1rem; border-radius: 3px; overflow: hidden; }
  .bar-fill { height: 100%; }
  .bar-gate { background: var(--gate); }
  .bar-ver { background: var(--verified); }
  .bar-untr { background: var(--untrusted); }
  .bar-value { font-family: var(--mono); font-size: .74rem; color: var(--ink-soft); white-space: nowrap; }
  .cap-lane { margin: 0 0 1.5rem; }
  .cap-head { font-family: var(--sans); font-weight: 600; font-size: .95rem; margin-bottom: .3rem; }
  .cap-head span { font-family: var(--mono); font-weight: 400; font-size: .74rem; color: var(--ink-soft); }
  .daily-chart, .spark { display: block; max-width: 100%; overflow: visible; }
  .cap-lbl, .spark-lbl { font-family: var(--mono); font-size: 9.5px; fill: var(--ink-soft); }
  .empty { font-family: var(--mono); font-size: .82rem; color: var(--ink-soft);
    background: var(--paper-raised); border: 1px dashed var(--hairline);
    padding: .9rem 1rem; border-radius: 4px; }
  .footnote { font-size: .8rem; color: var(--ink-soft); margin: .75rem 0 0;
    padding-left: .9rem; border-left: 2px solid var(--hairline); }
  ul.plain { font-size: .9rem; padding-left: 1.1rem; }
  ul.plain li { margin: .2rem 0; }
  footer { border-top: 3px double var(--hairline); margin-top: 3rem; padding-top: 1.25rem;
    font-family: var(--mono); font-size: .74rem; color: var(--ink-soft); line-height: 1.9; }
  @media (max-width: 640px) { h1 { font-size: 1.7rem; } .bar-row { grid-template-columns: 7rem 1fr auto; } }
"""


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sync", action="store_true", help="fetch new signal into the cache")
    parser.add_argument("--render", action="store_true", help="render HTML from the cache")
    parser.add_argument("--days", type=int, default=30, help="reporting window in days")
    parser.add_argument("--repo", default=REPO_DEFAULT, help="owner/name slug")
    parser.add_argument("--db", type=Path, help="SQLite cache path")
    parser.add_argument("--out", type=Path, help="HTML output path")
    return parser.parse_args(argv)


def default_output_dir() -> Path:
    return Path("output/factory-dashboard")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.days <= 0:
        print("error: --days must be positive", file=sys.stderr)
        return 2
    do_sync = args.sync or not (args.sync or args.render)
    do_render = args.render or not (args.sync or args.render)

    out_dir = default_output_dir()
    db_path = args.db or (out_dir / "cache.sqlite3")
    out_path = args.out or (out_dir / "index.html")

    conn = connect(db_path)
    try:
        if do_sync:
            fetcher = GitHubFetcher(args.repo)
            stats = sync_all(conn, fetcher, days=args.days)
            summary = ", ".join(
                f"{name}={stats[name]}" for name in ("runs", "issues", "prs", "cost_rows") if name in stats
            )
            print(f"[factory-dashboard] synced: {summary}")
            if stats["errors"]:
                print(f"[factory-dashboard] {len(stats['errors'])} source(s) degraded to cache")
        if do_render:
            metrics = build_metrics(conn, days=args.days, now=now_utc())
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(render_html(metrics), encoding="utf-8")
            print(f"[factory-dashboard] wrote {out_path}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
