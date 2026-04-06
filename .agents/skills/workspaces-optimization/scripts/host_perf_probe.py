#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Collect host-side Workspaces performance evidence.

This script is intended to run on any macOS machine that can reproduce
WorkspaceManager slowness, including target machines with extra monitoring
or policy software.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from statistics import median
from typing import Any, Iterable


DEFAULT_PATTERNS = ["WorkspaceManager", "ghostty", "tmux", "zsh", "bash", "login"]


@dataclass
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str
    duration_ms: float


@dataclass
class ShellProbeSummary:
    cwd: str
    variant: str
    runs: list[float]
    median_ms: float
    min_ms: float
    max_ms: float
    failures: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect host-side shell and process evidence for Workspaces performance debugging."
    )
    parser.add_argument(
        "--cwd",
        action="append",
        default=[],
        help="Directory to probe. Can be passed more than once. Defaults to the current directory and the home directory.",
    )
    parser.add_argument(
        "--shell",
        default=os.environ.get("SHELL", "/bin/zsh"),
        help="Shell executable to probe. Defaults to $SHELL or /bin/zsh.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=3,
        help="Number of runs per shell variant and directory. Default: 3.",
    )
    parser.add_argument(
        "--sample-running",
        action="store_true",
        help="Capture `sample` traces for running WorkspaceManager and child shell processes.",
    )
    parser.add_argument(
        "--sample-seconds",
        type=int,
        default=5,
        help="Duration for each `sample` capture. Default: 5.",
    )
    parser.add_argument(
        "--process-pattern",
        action="append",
        default=[],
        help="Extra process pattern to match in the process snapshot.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory for output artifacts. Defaults to a timestamped directory under the system temp directory.",
    )
    return parser.parse_args()


def now_stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def ensure_output_dir(path: Path | None) -> Path:
    if path is not None:
        path.mkdir(parents=True, exist_ok=True)
        return path
    return Path(tempfile.mkdtemp(prefix=f"workspaces-host-probe-{now_stamp()}-"))


def run_command(
    command: list[str],
    *,
    cwd: Path | None = None,
    timeout: int = 30,
) -> CommandResult:
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=os.environ.copy(),
            check=False,
        )
        duration_ms = (time.perf_counter() - started) * 1000.0
        return CommandResult(
            command=command,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            duration_ms=duration_ms,
        )
    except subprocess.TimeoutExpired as error:
        duration_ms = (time.perf_counter() - started) * 1000.0
        return CommandResult(
            command=command,
            returncode=124,
            stdout=error.stdout or "",
            stderr=(error.stderr or "") + "\n<timeout>",
            duration_ms=duration_ms,
        )


def shell_variants(shell_path: str) -> list[tuple[str, list[str]]]:
    name = Path(shell_path).name
    if name == "zsh":
        return [
            ("login_interactive", [shell_path, "--login", "-i", "-c", "exit"]),
            ("clean_interactive", [shell_path, "-f", "-i", "-c", "exit"]),
        ]
    if name == "bash":
        return [
            ("login_interactive", [shell_path, "--login", "-i", "-c", "exit"]),
            ("clean_interactive", [shell_path, "--noprofile", "--norc", "-i", "-c", "exit"]),
        ]
    return [
        ("interactive", [shell_path, "-i", "-c", "exit"]),
        ("non_interactive", [shell_path, "-c", "exit"]),
    ]


def unique_paths(values: Iterable[Path]) -> list[Path]:
    seen: set[str] = set()
    result: list[Path] = []
    for value in values:
        resolved = str(value.expanduser().resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        result.append(Path(resolved))
    return result


def collect_system_info() -> dict[str, Any]:
    def read_output(command: list[str]) -> str:
        result = run_command(command, timeout=15)
        return (result.stdout or result.stderr).strip()

    memsize_raw = read_output(["/usr/sbin/sysctl", "-n", "hw.memsize"])
    mem_gb = None
    if memsize_raw.isdigit():
        mem_gb = round(int(memsize_raw) / (1024**3), 1)

    return {
        "collected_at": datetime.now().astimezone().isoformat(),
        "os_version": read_output(["/usr/bin/sw_vers", "-productVersion"]),
        "os_build": read_output(["/usr/bin/sw_vers", "-buildVersion"]),
        "architecture": read_output(["/usr/bin/uname", "-m"]),
        "hardware_model": read_output(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "processor_count": os.cpu_count(),
        "physical_memory_gb": mem_gb,
        "shell": os.environ.get("SHELL", ""),
        "user": os.environ.get("USER", ""),
        "hostname": read_output(["/bin/hostname"]),
    }


def collect_shell_probes(shell_path: str, directories: list[Path], runs: int) -> tuple[list[ShellProbeSummary], list[dict[str, Any]]]:
    summaries: list[ShellProbeSummary] = []
    raw_runs: list[dict[str, Any]] = []

    for directory in directories:
        for variant_name, command in shell_variants(shell_path):
            timings: list[float] = []
            failures = 0
            for index in range(1, runs + 1):
                result = run_command(command, cwd=directory, timeout=90)
                raw_runs.append(
                    {
                        "cwd": str(directory),
                        "variant": variant_name,
                        "run_index": index,
                        "duration_ms": result.duration_ms,
                        "returncode": result.returncode,
                        "stderr_preview": result.stderr.strip()[:500],
                    }
                )
                timings.append(result.duration_ms)
                if result.returncode != 0:
                    failures += 1

            summaries.append(
                ShellProbeSummary(
                    cwd=str(directory),
                    variant=variant_name,
                    runs=timings,
                    median_ms=median(timings),
                    min_ms=min(timings),
                    max_ms=max(timings),
                    failures=failures,
                )
            )

    return summaries, raw_runs


def collect_process_snapshot(patterns: list[str]) -> dict[str, Any]:
    ps_result = run_command(
        ["/bin/ps", "-axo", "pid=,ppid=,rss=,state=,comm=,args="],
        timeout=20,
    )
    lines = [line.rstrip() for line in ps_result.stdout.splitlines() if line.strip()]
    processes: list[dict[str, Any]] = []
    for line in lines:
        parts = line.strip().split(None, 5)
        if len(parts) < 6:
            continue
        pid_s, ppid_s, rss_s, state, comm, args = parts
        searchable = f"{comm} {args}".lower()
        if not any(pattern.lower() in searchable for pattern in patterns):
            continue
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

    app_pids = [proc["pid"] for proc in processes if "WorkspaceManager" in proc["args"] or proc["comm"] == "WorkspaceManager"]
    child_pids = [proc["pid"] for proc in processes if proc["ppid"] in app_pids]
    return {
        "patterns": patterns,
        "matched_processes": processes,
        "workspace_manager_pids": app_pids,
        "child_pids": child_pids,
        "ps_returncode": ps_result.returncode,
    }


def capture_samples(output_dir: Path, process_snapshot: dict[str, Any], seconds: int) -> list[str]:
    if shutil.which("sample") is None:
        return []

    target_pids: list[int] = []
    for pid in process_snapshot["workspace_manager_pids"] + process_snapshot["child_pids"]:
        if pid not in target_pids:
            target_pids.append(pid)

    sample_files: list[str] = []
    for pid in target_pids[:4]:
        target = output_dir / f"sample-{pid}.txt"
        result = run_command(
            ["sample", str(pid), str(seconds), "-file", str(target)],
            timeout=max(30, seconds + 10),
        )
        if result.returncode == 0 and target.exists():
            sample_files.append(str(target))
    return sample_files


def build_findings(shell_summaries: list[ShellProbeSummary]) -> list[str]:
    findings: list[str] = []
    by_cwd: dict[str, dict[str, ShellProbeSummary]] = {}
    for summary in shell_summaries:
        by_cwd.setdefault(summary.cwd, {})[summary.variant] = summary

    for cwd, variants in by_cwd.items():
        login = variants.get("login_interactive")
        clean = variants.get("clean_interactive")
        if login and clean:
            delta = login.median_ms - clean.median_ms
            ratio = login.median_ms / clean.median_ms if clean.median_ms > 0 else None
            if delta > 500 and ratio and ratio >= 3:
                findings.append(
                    f"{cwd}: login shell median is {login.median_ms:.0f} ms versus clean shell {clean.median_ms:.0f} ms. Shell init or host monitoring is a strong suspect."
                )

    if not findings:
        findings.append("No strong shell-startup anomaly was detected from the automated probe.")
    return findings


def write_text_summary(
    output_dir: Path,
    system_info: dict[str, Any],
    shell_summaries: list[ShellProbeSummary],
    findings: list[str],
    process_snapshot: dict[str, Any],
    sample_files: list[str],
) -> None:
    lines = [
        "Workspaces host performance probe",
        f"Output directory: {output_dir}",
        "",
        "System:",
        f"  Hostname: {system_info['hostname']}",
        f"  macOS: {system_info['os_version']} ({system_info['os_build']})",
        f"  Model: {system_info['hardware_model']} ({system_info['architecture']})",
        f"  Memory: {system_info['physical_memory_gb']} GB",
        f"  Shell: {system_info['shell']}",
        "",
        "Shell probes:",
    ]

    for summary in shell_summaries:
        lines.append(
            f"  {summary.variant} @ {summary.cwd}: median={summary.median_ms:.2f} ms "
            f"min={summary.min_ms:.2f} ms max={summary.max_ms:.2f} ms failures={summary.failures}"
        )

    lines.extend(["", "Findings:"])
    for finding in findings:
        lines.append(f"  - {finding}")

    lines.extend(
        [
            "",
            f"Matched processes: {len(process_snapshot['matched_processes'])}",
            f"WorkspaceManager PIDs: {process_snapshot['workspace_manager_pids']}",
            f"Child PIDs: {process_snapshot['child_pids']}",
        ]
    )
    if sample_files:
        lines.append("Sample files:")
        for sample_file in sample_files:
            lines.append(f"  - {sample_file}")

    (output_dir / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    output_dir = ensure_output_dir(args.output_dir)

    requested_paths = [Path.cwd(), Path.home()]
    requested_paths.extend(Path(value).expanduser() for value in args.cwd)
    directories = [path for path in unique_paths(requested_paths) if path.exists() and path.is_dir()]
    if not directories:
        raise SystemExit("No valid probe directories were found.")

    system_info = collect_system_info()
    shell_summaries, shell_runs = collect_shell_probes(args.shell, directories, args.runs)
    patterns = DEFAULT_PATTERNS + args.process_pattern
    process_snapshot = collect_process_snapshot(patterns)
    sample_files = capture_samples(output_dir, process_snapshot, args.sample_seconds) if args.sample_running else []
    findings = build_findings(shell_summaries)

    summary = {
        "output_dir": str(output_dir),
        "system": system_info,
        "directories": [str(directory) for directory in directories],
        "shell_summaries": [asdict(summary) for summary in shell_summaries],
        "shell_runs": shell_runs,
        "process_snapshot": process_snapshot,
        "sample_files": sample_files,
        "findings": findings,
    }

    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "ps-matched.json").write_text(
        json.dumps(process_snapshot, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_text_summary(
        output_dir,
        system_info,
        shell_summaries,
        findings,
        process_snapshot,
        sample_files,
    )

    print(f"Workspaces host probe written to {output_dir}")
    for finding in findings:
        print(f"- {finding}")
    if sample_files:
        print("- Sample traces captured:")
        for sample_file in sample_files:
            print(f"  {sample_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
