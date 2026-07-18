#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Append Factory per-run cost rows to the factory/ops-data branch.

CI hands this the `cost-rows.jsonl` produced by the contributor runner. It
clones factory/ops-data, appends rows to docs/ops/cost/runs.jsonl deduplicated
by row `id` (idempotent across job re-runs and lane races), and pushes as
github-actions[bot], retrying on push contention. It never creates the branch:
the monitor lane owns that, and a missing branch is a hard error here.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

BRANCH = "factory/ops-data"
RUNS_PATH = "docs/ops/cost/runs.jsonl"
COMMIT_MESSAGE = "chore(factory): append cost telemetry rows"
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
MAX_ATTEMPTS = 3


def log(message: str) -> None:
    print(f"[factory-cost-append] {message}", file=sys.stderr)


def die(message: str) -> None:
    log(f"error: {message}")
    raise SystemExit(1)


def run_git(args: list[str], *, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        # Never surface the remote URL (it carries the token) in error text.
        raise RuntimeError(result.stderr.strip() or f"git {args[0]} failed")
    return result


def remote_url() -> str:
    """Clone/push URL for factory/ops-data.

    FACTORY_OPS_DATA_REMOTE overrides the derived GitHub URL (used by tests to
    point at a local bare repo); production leaves it unset.
    """
    override = os.environ.get("FACTORY_OPS_DATA_REMOTE", "").strip()
    if override:
        return override
    token = os.environ.get("GH_TOKEN", "").strip()
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if not token or not repo:
        die("GH_TOKEN and GITHUB_REPOSITORY are required (or set FACTORY_OPS_DATA_REMOTE)")
    return f"https://x-access-token:{token}@github.com/{repo}.git"


def read_candidate_rows(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        die(f"rows file not found: {path}")
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            log(f"skipping unparseable row: {line[:80]}")
            continue
        if isinstance(row, dict) and row.get("id"):
            rows.append(row)
        else:
            log("skipping row without an id")
    return rows


def existing_ids(runs_file: Path) -> set[str]:
    ids: set[str] = set()
    if not runs_file.is_file():
        return ids
    for line in runs_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        row_id = row.get("id") if isinstance(row, dict) else None
        if row_id:
            ids.add(str(row_id))
    return ids


def branch_exists(url: str) -> bool:
    result = run_git(["ls-remote", "--heads", url, BRANCH], check=False)
    if result.returncode not in (0, 2):
        raise RuntimeError(result.stderr.strip() or "git ls-remote failed")
    return bool(result.stdout.strip())


def is_push_rejection(stderr: str) -> bool:
    lowered = stderr.lower()
    return "rejected" in lowered or "non-fast-forward" in lowered or "fetch first" in lowered


def append_and_push(url: str, candidate_rows: list[dict[str, Any]], workdir: Path) -> bool:
    """Clone, append not-yet-present rows, commit and push once.

    Returns True on success or no-op; raises on a push rejection so the caller
    can retry against fresh remote state.
    """
    clone_dir = workdir / "ops-data"
    run_git(["clone", "--depth", "1", "--branch", BRANCH, "--single-branch", url, str(clone_dir)])
    run_git(["config", "user.name", BOT_NAME], cwd=clone_dir)
    run_git(["config", "user.email", BOT_EMAIL], cwd=clone_dir)

    runs_file = clone_dir / RUNS_PATH
    seen = existing_ids(runs_file)
    new_rows: list[dict[str, Any]] = []
    for row in candidate_rows:
        row_id = str(row["id"])
        if row_id in seen:
            continue
        seen.add(row_id)
        new_rows.append(row)

    if not new_rows:
        log("no new cost rows to append (all present or empty); nothing to commit")
        return True

    runs_file.parent.mkdir(parents=True, exist_ok=True)
    with runs_file.open("a", encoding="utf-8") as handle:
        for row in new_rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    run_git(["add", RUNS_PATH], cwd=clone_dir)
    run_git(["commit", "-m", COMMIT_MESSAGE], cwd=clone_dir)
    push = run_git(["push", "origin", f"HEAD:{BRANCH}"], cwd=clone_dir, check=False)
    if push.returncode != 0:
        if is_push_rejection(push.stderr):
            raise RuntimeError("push rejected")
        raise RuntimeError(push.stderr.strip() or "git push failed")
    log(f"appended {len(new_rows)} cost row(s) to {RUNS_PATH}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Append Factory cost rows to factory/ops-data")
    parser.add_argument("--rows", required=True, help="Path to cost-rows.jsonl")
    args = parser.parse_args()

    candidate_rows = read_candidate_rows(Path(args.rows))
    if not candidate_rows:
        log("no cost rows provided; nothing to do")
        return 0

    url = remote_url()
    if not branch_exists(url):
        die(f"{BRANCH} does not exist; the monitor lane must create it first")

    for attempt in range(1, MAX_ATTEMPTS + 1):
        with tempfile.TemporaryDirectory() as tmp:
            try:
                append_and_push(url, candidate_rows, Path(tmp))
                return 0
            except RuntimeError as exc:
                if "push rejected" in str(exc) and attempt < MAX_ATTEMPTS:
                    log(f"push contention on attempt {attempt}; retrying")
                    continue
                die(str(exc))
    die(f"exhausted {MAX_ATTEMPTS} attempts appending cost rows")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
