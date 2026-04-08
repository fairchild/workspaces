#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO = "fairchild/workspaces"


@dataclass
class CommandResult:
    ok: bool
    stdout: str
    stderr: str
    code: int


def run(cmd: list[str]) -> CommandResult:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        return CommandResult(False, "", str(exc), 127)
    return CommandResult(proc.returncode == 0, proc.stdout, proc.stderr, proc.returncode)


def run_json(cmd: list[str]) -> Any:
    result = run(cmd)
    if not result.ok:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{result.stderr.strip()}")
    return json.loads(result.stdout or "null")


def known_runner_dirs() -> list[Path]:
    base = Path.home() / ".local" / "share"
    candidates = sorted(base.glob("actions-runner-workspaces*"))
    return [path for path in candidates if path.is_dir()]


def tail_text(path: Path, max_bytes: int = 16_000) -> str:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes))
            return handle.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def summarize_local_runner(path: Path) -> dict[str, Any]:
    runner_file = path / ".runner"
    diag_dir = path / "_diag"
    diag_logs = sorted(diag_dir.glob("Runner_*.log"))
    latest_diag = diag_logs[-1] if diag_logs else None
    runner_log = path / "runner.log"

    summary: dict[str, Any] = {
        "path": str(path),
        "configured": runner_file.exists(),
        "latest_diag": str(latest_diag) if latest_diag else None,
        "signatures": [],
    }

    if runner_file.exists():
        try:
            summary["runner_config"] = json.loads(runner_file.read_text())
        except json.JSONDecodeError:
            summary["runner_config"] = {"parse_error": True}

    combined = "\n".join(
        part for part in [tail_text(runner_log), tail_text(latest_diag) if latest_diag else ""] if part
    )

    patterns = {
        "listening_for_jobs": "Listening for Jobs",
        "registration_deleted": "registration has been deleted",
        "session_conflict": "A session for this runner already exists",
        "token_expired": "token expired",
        "runner_connect_error": "Runner connect error",
        "session_created": "Session created.",
    }
    for key, needle in patterns.items():
        if needle in combined:
            summary["signatures"].append(key)

    if latest_diag:
        summary["latest_diag_mtime"] = latest_diag.stat().st_mtime
    if runner_log.exists():
        summary["runner_log_mtime"] = runner_log.stat().st_mtime
    return summary


def render_runner_inventory(runners: list[dict[str, Any]]) -> list[str]:
    lines = []
    for runner in runners:
        labels = ",".join(label["name"] for label in runner.get("labels", []))
        lines.append(
            f"- {runner['name']}: status={runner['status']} busy={runner['busy']} labels={labels}"
        )
    return lines


def render_local_runner(summary: dict[str, Any]) -> list[str]:
    name = summary.get("runner_config", {}).get("agentName", Path(summary["path"]).name)
    signatures = ",".join(summary["signatures"]) if summary["signatures"] else "none"
    return [
        f"- {name}: configured={summary['configured']} path={summary['path']}",
        f"  latest_diag={summary['latest_diag'] or 'none'} signatures={signatures}",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize GitHub and local self-hosted runner state.")
    parser.add_argument("--repo", default=REPO, help="GitHub repo in owner/name form.")
    parser.add_argument("--run-id", type=int, help="Optional GitHub Actions run id to inspect.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    args = parser.parse_args()

    output: dict[str, Any] = {"repo": args.repo}

    output["runners"] = run_json(["gh", "api", f"repos/{args.repo}/actions/runners"]).get("runners", [])
    output["queued_runs"] = run_json(
        [
            "gh",
            "run",
            "list",
            "--repo",
            args.repo,
            "--status",
            "queued",
            "--limit",
            "20",
            "--json",
            "databaseId,name,workflowName,headBranch,createdAt",
        ]
    )

    if args.run_id:
        output["run"] = run_json(["gh", "api", f"repos/{args.repo}/actions/runs/{args.run_id}"])
        output["jobs"] = run_json(["gh", "api", f"repos/{args.repo}/actions/runs/{args.run_id}/jobs"]).get(
            "jobs", []
        )

    output["local_runners"] = [summarize_local_runner(path) for path in known_runner_dirs()]

    if args.json:
        json.dump(output, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print(f"Repo: {args.repo}")
    print()
    print("GitHub runners:")
    for line in render_runner_inventory(output["runners"]):
        print(line)
    print()

    print("Queued runs:")
    if output["queued_runs"]:
        for run_item in output["queued_runs"]:
            print(
                f"- {run_item['databaseId']}: workflow={run_item['workflowName']} "
                f"branch={run_item['headBranch']} created_at={run_item['createdAt']}"
            )
    else:
        print("- none")
    print()

    if args.run_id:
        print(f"Run {args.run_id}:")
        run_item = output["run"]
        print(
            f"- status={run_item['status']} conclusion={run_item['conclusion']} "
            f"attempt={run_item['run_attempt']} head_sha={run_item['head_sha']}"
        )
        for job in output.get("jobs", []):
            print(
                f"- job {job['id']} {job['name']}: status={job['status']} "
                f"conclusion={job['conclusion']} runner={job.get('runner_name')}"
            )
        print()

    print("Local runner directories:")
    if output["local_runners"]:
        for runner_summary in output["local_runners"]:
            for line in render_local_runner(runner_summary):
                print(line)
    else:
        print("- none found")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
