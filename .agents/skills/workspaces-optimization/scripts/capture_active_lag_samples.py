#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Capture active-lag samples for WorkspaceManager and child shell processes.

Use this while actively reproducing visible typing or terminal lag. The script
captures a process-tree snapshot, waits for a short reproduce window, then runs
`sample` against the app and matching child shell or tmux processes in parallel.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_APP_PATTERNS = ["WorkspaceManager"]
DEFAULT_CHILD_PATTERNS = ["zsh", "bash", "tmux", "fish", "sh", "login"]


@dataclass
class SampleTarget:
    pid: int
    ppid: int
    comm: str
    args: str
    role: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture active-lag samples for WorkspaceManager and child shell processes."
    )
    parser.add_argument(
        "--pid",
        action="append",
        type=int,
        default=[],
        help="Explicit WorkspaceManager PID to target. Can be passed more than once.",
    )
    parser.add_argument(
        "--app-pattern",
        action="append",
        default=[],
        help="Extra substring used to locate WorkspaceManager when --pid is not supplied.",
    )
    parser.add_argument(
        "--child-pattern",
        action="append",
        default=[],
        help="Extra substring used to locate descendant shell or tmux processes.",
    )
    parser.add_argument(
        "--countdown",
        type=int,
        default=5,
        help="Seconds to wait before starting the samples so you can reproduce lag. Default: 5.",
    )
    parser.add_argument(
        "--sample-seconds",
        type=int,
        default=8,
        help="Duration for each sample capture. Default: 8.",
    )
    parser.add_argument(
        "--max-child-targets",
        type=int,
        default=4,
        help="Maximum number of descendant shell or tmux targets to sample. Default: 4.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory for output artifacts. Defaults to a timestamped directory under the system temp directory.",
    )
    return parser.parse_args()


def ensure_output_dir(path: Path | None) -> Path:
    if path is not None:
        path.mkdir(parents=True, exist_ok=True)
        return path
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path(tempfile.mkdtemp(prefix=f"workspaces-active-lag-{stamp}-"))


def run_command(command: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=os.environ.copy(),
    )


def process_snapshot() -> list[dict[str, Any]]:
    result = run_command(["/bin/ps", "-axo", "pid=,ppid=,rss=,state=,comm=,args="], timeout=20)
    processes: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 5)
        if len(parts) < 6:
            continue
        pid_s, ppid_s, rss_s, state, comm, args = parts
        processes.append(
            {
                "pid": int(pid_s),
                "ppid": int(ppid_s),
                "rss_kb": int(rss_s),
                "state": state,
                "comm": comm,
                "args": args,
            }
        )
    return processes


def find_app_pids(processes: list[dict[str, Any]], explicit_pids: list[int], patterns: list[str]) -> list[int]:
    if explicit_pids:
        known = {proc["pid"] for proc in processes}
        return [pid for pid in explicit_pids if pid in known]

    lowered = [pattern.lower() for pattern in patterns]
    app_pids: list[int] = []
    for proc in processes:
        searchable = f"{proc['comm']} {proc['args']}".lower()
        if any(pattern in searchable for pattern in lowered):
            if proc["pid"] not in app_pids:
                app_pids.append(proc["pid"])
    return app_pids


def descendant_targets(
    processes: list[dict[str, Any]],
    root_pids: list[int],
    child_patterns: list[str],
    max_children: int,
) -> list[SampleTarget]:
    by_ppid: dict[int, list[dict[str, Any]]] = {}
    by_pid: dict[int, dict[str, Any]] = {}
    for proc in processes:
        by_pid[proc["pid"]] = proc
        by_ppid.setdefault(proc["ppid"], []).append(proc)

    descendant_pids: list[int] = []
    queue = list(root_pids)
    seen: set[int] = set(root_pids)
    while queue:
        current = queue.pop(0)
        for child in by_ppid.get(current, []):
            child_pid = child["pid"]
            if child_pid in seen:
                continue
            seen.add(child_pid)
            descendant_pids.append(child_pid)
            queue.append(child_pid)

    lowered = [pattern.lower() for pattern in child_patterns]
    child_targets: list[SampleTarget] = []
    for pid in descendant_pids:
        proc = by_pid[pid]
        searchable = f"{proc['comm']} {proc['args']}".lower()
        if lowered and not any(pattern in searchable for pattern in lowered):
            continue
        child_targets.append(
            SampleTarget(
                pid=proc["pid"],
                ppid=proc["ppid"],
                comm=proc["comm"],
                args=proc["args"],
                role="child",
            )
        )
    child_targets.sort(key=lambda target: target.pid)
    return child_targets[:max_children]


def root_targets(processes: list[dict[str, Any]], root_pids: list[int]) -> list[SampleTarget]:
    by_pid = {proc["pid"]: proc for proc in processes}
    targets: list[SampleTarget] = []
    for pid in root_pids:
        proc = by_pid.get(pid)
        if proc is None:
            continue
        targets.append(
            SampleTarget(
                pid=proc["pid"],
                ppid=proc["ppid"],
                comm=proc["comm"],
                args=proc["args"],
                role="app",
            )
        )
    return targets


def print_countdown(seconds: int) -> None:
    if seconds <= 0:
        return
    print(f"Reproduce lag now. Sampling starts in {seconds} seconds...")
    for remaining in range(seconds, 0, -1):
        print(f"  {remaining}...", flush=True)
        time.sleep(1)


def capture_samples(output_dir: Path, targets: list[SampleTarget], sample_seconds: int) -> list[dict[str, Any]]:
    if shutil.which("sample") is None:
        raise SystemExit("`sample` is not available on this machine.")

    running: list[tuple[SampleTarget, subprocess.Popen[str], Path]] = []
    results: list[dict[str, Any]] = []

    for target in targets:
        target_file = output_dir / f"sample-{target.role}-{target.pid}.txt"
        command = ["sample", str(target.pid), str(sample_seconds), "-file", str(target_file)]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
        running.append((target, process, target_file))

    for target, process, target_file in running:
        stdout, stderr = process.communicate(timeout=max(30, sample_seconds + 20))
        results.append(
            {
                "pid": target.pid,
                "role": target.role,
                "comm": target.comm,
                "args": target.args,
                "sample_file": str(target_file),
                "returncode": process.returncode,
                "stdout": stdout.strip(),
                "stderr": stderr.strip(),
                "exists": target_file.exists(),
            }
        )

    return results


def write_summary(output_dir: Path, before: list[dict[str, Any]], after: list[dict[str, Any]], targets: list[SampleTarget], sample_results: list[dict[str, Any]]) -> None:
    summary = {
        "collected_at": datetime.now().astimezone().isoformat(),
        "targets": [
            {
                "pid": target.pid,
                "ppid": target.ppid,
                "comm": target.comm,
                "args": target.args,
                "role": target.role,
            }
            for target in targets
        ],
        "sample_results": sample_results,
        "before_count": len(before),
        "after_count": len(after),
    }

    (output_dir / "process-tree-before.json").write_text(
        json.dumps(before, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "process-tree-after.json").write_text(
        json.dumps(after, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    lines = [
        "Workspaces active lag capture",
        f"Output directory: {output_dir}",
        "",
        "Targets:",
    ]
    for target in targets:
        lines.append(f"  - {target.role} pid={target.pid} comm={target.comm} args={target.args}")
    lines.append("")
    lines.append("Sample results:")
    for result in sample_results:
        status = "ok" if result["returncode"] == 0 and result["exists"] else f"returncode={result['returncode']}"
        lines.append(f"  - pid={result['pid']} role={result['role']} file={result['sample_file']} status={status}")

    (output_dir / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    output_dir = ensure_output_dir(args.output_dir)

    app_patterns = DEFAULT_APP_PATTERNS + args.app_pattern
    child_patterns = DEFAULT_CHILD_PATTERNS + args.child_pattern

    before = process_snapshot()
    root_pids = find_app_pids(before, args.pid, app_patterns)
    if not root_pids:
        raise SystemExit("No WorkspaceManager process matched. Pass --pid or adjust --app-pattern.")

    print("Matched WorkspaceManager PIDs:", ", ".join(str(pid) for pid in root_pids))
    print_countdown(args.countdown)

    active_snapshot = process_snapshot()
    targets = root_targets(active_snapshot, root_pids)
    targets.extend(
        descendant_targets(
            active_snapshot,
            root_pids,
            child_patterns,
            args.max_child_targets,
        )
    )
    if not targets:
        raise SystemExit("No sample targets were found.")

    print("Sampling targets:")
    for target in targets:
        print(f"  - {target.role} pid={target.pid} comm={target.comm}")

    sample_results = capture_samples(output_dir, targets, args.sample_seconds)
    after = process_snapshot()
    write_summary(output_dir, before, after, targets, sample_results)

    print(f"Active lag capture written to {output_dir}")
    for result in sample_results:
        sample_file = result["sample_file"]
        status = "ok" if result["returncode"] == 0 and result["exists"] else f"returncode={result['returncode']}"
        print(f"- pid={result['pid']} role={result['role']} status={status} file={sample_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
