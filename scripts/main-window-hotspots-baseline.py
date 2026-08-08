#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run canonical main-window hotspot performance scenarios.

This runner keeps the four #637 measurement paths behind the shared
performance-contract entrypoint. It emits a canonical summary.json for each
scenario and leaves raw logs beside it for diagnosis.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from perf_schema import canonical_summary, load_contract, numeric_stats  # noqa: E402


SCENARIOS = {
    "main_window_agent_activity_burst",
    "main_window_session_switcher_snapshot",
    "main_window_workspace_create_ui_stall",
    "main_window_idle_cpu_diagnostics_closed",
    "main_window_resident_memory_20_workspaces",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True, choices=sorted(SCENARIOS))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--sleep-seconds", type=int, default=12)
    parser.add_argument("--sample-seconds", type=int, default=12)
    parser.add_argument("--surface-count", type=int, default=20)
    parser.add_argument("--assert-budget", action="store_true")
    return parser.parse_args()


def run_command(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    log_path: Path,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
    if check and result.returncode != 0:
        tail = "\n".join(log_path.read_text(encoding="utf-8", errors="ignore").splitlines()[-80:])
        raise SystemExit(f"command failed: {' '.join(command)}\n{tail}")
    return result


def expand_home(path: str) -> Path:
    if path == "~":
        return Path.home()
    if path.startswith("~/"):
        return Path.home() / path[2:]
    return Path(path)


def usable_ghostty_resources_dir(path: Path) -> bool:
    terminfo = path.parent / "terminfo" / "78" / "xterm-ghostty"
    return path.is_dir() and terminfo.is_file()


def resolve_ghostty_resources_dir(env: dict[str, str]) -> str | None:
    candidates: list[Path] = []
    if env.get("GHOSTTY_RESOURCES_DIR"):
        candidates.append(expand_home(env["GHOSTTY_RESOURCES_DIR"]))
    if env.get("GHOSTTY_SHARE_DIR"):
        candidates.append(expand_home(env["GHOSTTY_SHARE_DIR"]) / "ghostty")
    if env.get("GHOSTTY_DIR"):
        candidates.append(expand_home(env["GHOSTTY_DIR"]) / "zig-out" / "share" / "ghostty")
    candidates.append(Path.home() / ".cache" / "workspacemanager" / "ghostty" / "zig-out" / "share" / "ghostty")

    for candidate in candidates:
        if usable_ghostty_resources_dir(candidate):
            return str(candidate)
    return None


def write_summary(summary: dict[str, Any], output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path = output_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [f"scenario: {summary['scenario']}"]
    for metric_name, stats in summary["metrics"].items():
        unit = stats.get("unit", "")
        lines.append(
            f"{metric_name}: count={stats.get('count', 0)} "
            f"min={float(stats.get('min', 0)):.2f} "
            f"median={float(stats.get('median', 0)):.2f} "
            f"mean={float(stats.get('mean', 0)):.2f} "
            f"p95={float(stats.get('p95', 0)):.2f} "
            f"max={float(stats.get('max', 0)):.2f} {unit}"
        )
        budget = summary.get("budget_results", {}).get(metric_name, {})
        if budget:
            lines.append(
                f"  budget_status={budget.get('status')} "
                f"gate={budget.get('gate_budget')} {budget.get('unit', unit)} "
                f"diagnostic={budget.get('diagnostic_threshold')} {budget.get('unit', unit)}"
            )
    (output_dir / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"summary_json={summary_path}")
    print("\n".join(lines))
    return summary_path


def assert_budget(summary: dict[str, Any]) -> None:
    violations: list[str] = []
    for metric_name, budget in summary.get("budget_results", {}).items():
        if budget.get("status") in {"fail", "missing"}:
            unit = budget.get("unit", "")
            violations.append(
                f"{metric_name}: {budget.get('status')} "
                f"observed={budget.get('observed_gate')} {unit} "
                f"budget={budget.get('gate_budget')} {unit}"
            )
    if violations:
        raise SystemExit("budget assertion failed:\n" + "\n".join(f"  {line}" for line in violations))


def canonicalize_raw_result(
    *,
    scenario: str,
    raw_payload: dict[str, Any],
    output_dir: Path,
    artifacts: dict[str, Any],
) -> dict[str, Any]:
    metrics = raw_payload.get("metrics", {})
    summary = canonical_summary(
        scenario=scenario,
        build_kind="debug",
        metrics=metrics,
        diagnostic_findings=[],
        artifacts=artifacts,
        contract=load_contract(),
        extra={
            "metadata": {
                "raw_payload": raw_payload,
            }
        },
    )
    write_summary(summary, output_dir)
    return summary


def run_swift_perf_test(
    *,
    scenario: str,
    filter_name: str,
    output_dir: Path,
    extra_env: dict[str, str] | None = None,
) -> dict[str, Any]:
    raw_path = output_dir / "raw-result.json"
    env = os.environ.copy()
    env["WORKSPACES_PERF_RUN"] = "1"
    env["WORKSPACES_PERF_OUT"] = str(raw_path)
    if extra_env:
        env.update(extra_env)
    if "GHOSTTY_RESOURCES_DIR" not in env:
        resources_dir = resolve_ghostty_resources_dir(env)
        if resources_dir:
            env["GHOSTTY_RESOURCES_DIR"] = resources_dir

    run_command(
        ["swift", "test", "--disable-sandbox", "--filter", filter_name],
        env=env,
        log_path=output_dir / "swift-test.log",
    )
    if not raw_path.is_file():
        raise SystemExit(f"Swift perf test did not produce {raw_path}")
    raw_payload = json.loads(raw_path.read_text(encoding="utf-8"))
    return canonicalize_raw_result(
        scenario=scenario,
        raw_payload=raw_payload,
        output_dir=output_dir,
        artifacts={
            "raw_result": str(raw_path),
            "swift_test_log": str(output_dir / "swift-test.log"),
            "filter": filter_name,
        },
    )


def run_agent_activity_burst(output_dir: Path) -> dict[str, Any]:
    return run_swift_perf_test(
        scenario="main_window_agent_activity_burst",
        filter_name="agentActivityBurstSidebarLatency",
        output_dir=output_dir,
    )


def run_session_switcher_snapshot(output_dir: Path) -> dict[str, Any]:
    return run_swift_perf_test(
        scenario="main_window_session_switcher_snapshot",
        filter_name="sessionSwitcherSnapshotLatency",
        output_dir=output_dir,
    )


def run_resident_memory(output_dir: Path, surface_count: int) -> dict[str, Any]:
    binary = ensure_debug_binary(output_dir)
    app_data = output_dir / "app-data"
    app_data.mkdir(parents=True, exist_ok=True)
    pid, log_path = launch_debug_app(
        output_dir=output_dir,
        app_data=app_data,
        extra_env={"WORKSPACES_PERF_PREWARM_TERMINAL_SURFACES": str(surface_count)},
    )
    try:
        requested, initialized = wait_for_surface_prewarm(log_path, timeout_seconds=20)
        if initialized < surface_count:
            raise SystemExit(f"terminal surface prewarm initialized {initialized}/{surface_count} surfaces")
        samples: list[float] = []
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not process_is_running(pid):
                raise SystemExit(f"WorkspaceManager exited early (pid={pid})")
            rss_kb = ps_rss_kb(pid)
            if rss_kb is not None:
                samples.append(rss_kb / 1024.0)
            time.sleep(1)
    finally:
        terminate_pid(pid)

    if not samples:
        raise SystemExit("no RSS samples collected")
    metric = numeric_stats(samples, unit="MB")
    assert metric is not None
    summary = canonical_summary(
        scenario="main_window_resident_memory_20_workspaces",
        build_kind="debug",
        metrics={"main_window_resident_memory_20_workspaces_mb": metric},
        diagnostic_findings=[
            f"Live debug app prewarmed {initialized}/{requested} terminal surfaces before RSS sampling."
        ],
        artifacts={
            "app_log": str(log_path),
            "app_data": str(app_data),
            "surface_count_requested": surface_count,
            "surface_count_initialized": initialized,
            "rss_mb_samples": samples,
        },
        contract=load_contract(),
        extra={
            "metadata": {
                "surface_count_requested": surface_count,
                "surface_count_initialized": initialized,
                "sample_count": len(samples),
                "launch_mode": "no-activate",
                "ui_fixture": True,
            }
        },
    )
    write_summary(summary, output_dir)
    return summary


def run_workspace_create(output_dir: Path, runs: int, sleep_seconds: int) -> dict[str, Any]:
    result = run_command(
        [
            str(REPO_ROOT / "scripts" / "new-workspace-perf.sh"),
            str(runs),
            str(sleep_seconds),
            "--launch-mode",
            "no-activate",
        ],
        log_path=output_dir / "new-workspace-perf.log",
    )
    match = re.search(r"summary_json=(?P<path>.+)", result.stdout + result.stderr)
    if match is None:
        raise SystemExit("new-workspace-perf.sh did not report summary_json")
    source_summary_path = Path(match.group("path").strip())
    source_summary = json.loads(source_summary_path.read_text(encoding="utf-8"))
    source_metrics = source_summary.get("metrics", {})
    metrics = {
        name: source_metrics[name]
        for name in [
            "new_workspace_sheet_ready",
            "workspace_provider_availability_refresh",
            "lume_runtime_snapshot_refresh",
        ]
        if name in source_metrics
    }
    if "new_workspace_sheet_ready" not in metrics:
        raise SystemExit("new-workspace perf did not produce new_workspace_sheet_ready")

    summary = canonical_summary(
        scenario="main_window_workspace_create_ui_stall",
        build_kind="debug",
        metrics=metrics,
        diagnostic_findings=source_summary.get("diagnostic_findings", []),
        artifacts={
            "source_summary": str(source_summary_path),
            "source_output_dir": str(source_summary_path.parent),
            "runner_log": str(output_dir / "new-workspace-perf.log"),
        },
        contract=load_contract(),
        extra={
            "metadata": {
                "runs_requested": runs,
                "sleep_seconds": sleep_seconds,
                "launch_mode": "no-activate",
                "source_scenario": source_summary.get("scenario"),
            }
        },
    )
    write_summary(summary, output_dir)
    return summary


def ensure_debug_binary(log_dir: Path) -> Path:
    binary = REPO_ROOT / ".build" / "arm64-apple-macosx" / "debug" / "WorkspaceManager"
    run_command(
        ["swift", "build", "--disable-sandbox", "--product", "WorkspaceManager"],
        log_path=log_dir / "swift-build.log",
    )
    if not binary.is_file():
        raise SystemExit(f"debug binary not found after build: {binary}")
    return binary


def live_app_env_overrides(app_data: Path, extra_env: dict[str, str] | None = None) -> dict[str, str]:
    overrides = {
        "WORKSPACES_SHELL_PROFILE_MODE": "clean",
        "WORKSPACES_DISABLE_STATE_RESTORATION": "1",
        "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
        # os.Logger output only reaches the captured launch log when Apple's
        # dt-mode stderr mirroring is on; without it wait_for_surface_prewarm
        # times out on a log line the app did emit (#1238).
        "OS_ACTIVITY_DT_MODE": "YES",
    }
    resources_dir = resolve_ghostty_resources_dir(os.environ.copy())
    if resources_dir:
        overrides["GHOSTTY_RESOURCES_DIR"] = resources_dir
    if extra_env:
        overrides.update(extra_env)
    return overrides


def launch_debug_app(
    *,
    output_dir: Path,
    app_data: Path,
    extra_env: dict[str, str] | None = None,
) -> tuple[int, Path]:
    command = [
        str(REPO_ROOT / "scripts" / "launch-dev.sh"),
        "--no-build",
        "--no-activate",
        "--fixture",
        "--clean-data",
        "--data-dir",
        str(app_data),
        "--window-timeout",
        "20",
        "--trust-mise",
    ]
    for key, value in live_app_env_overrides(app_data, extra_env).items():
        command.extend(["--env", f"{key}={value}"])

    launch_env = os.environ.copy()
    launch_env["MISE_STATE_DIR"] = os.environ.get("MISE_STATE_DIR", "/tmp/workspaces-mise-state")
    launch_env["WORKSPACES_LAUNCH_DEV_SKIP_PROCESS_VERIFY"] = "1"
    result = run_command(command, env=launch_env, log_path=output_dir / "launch-dev.log")
    output = result.stdout + result.stderr
    pid_match = re.search(r"WorkspaceManager running \(pid=(?P<pid>\d+)\)", output)
    log_match = re.search(r"Log file: (?P<path>.+)", output)
    if pid_match is None or log_match is None:
        raise SystemExit("launch-dev.sh did not report pid/log path")
    return int(pid_match.group("pid")), Path(log_match.group("path").strip())


def ps_cpu(pid: int) -> float | None:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "%cpu="],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    text = result.stdout.strip()
    if not text:
        return None
    try:
        return float(text.split()[0])
    except ValueError:
        return None


def process_is_running(pid: int) -> bool:
    return subprocess.run(["/bin/kill", "-0", str(pid)], check=False).returncode == 0


def ps_rss_kb(pid: int) -> int | None:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "rss="],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    text = result.stdout.strip()
    if not text:
        return None
    try:
        return int(text.split()[0])
    except ValueError:
        return None


def wait_for_surface_prewarm(log_path: Path, timeout_seconds: int) -> tuple[int, int]:
    pattern = re.compile(
        r"metric=main_window_terminal_surface_prewarm requested=(?P<requested>\d+) initialized=(?P<initialized>\d+)"
    )
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if log_path.is_file():
            text = log_path.read_text(encoding="utf-8", errors="ignore")
            match = pattern.search(text)
            if match:
                return int(match.group("requested")), int(match.group("initialized"))
        time.sleep(0.5)
    raise SystemExit(f"timed out waiting for terminal surface prewarm log in {log_path}")


def terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def terminate_pid(pid: int) -> None:
    subprocess.run(["/bin/kill", str(pid)], check=False)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not process_is_running(pid):
            return
        time.sleep(0.2)
    subprocess.run(["/bin/kill", "-9", str(pid)], check=False)


def run_idle_cpu(output_dir: Path, sample_seconds: int) -> dict[str, Any]:
    binary = ensure_debug_binary(output_dir)
    app_data = output_dir / "app-data"
    app_data.mkdir(parents=True, exist_ok=True)
    pid, log_path = launch_debug_app(output_dir=output_dir, app_data=app_data)
    try:
        time.sleep(3)
        samples: list[float] = []
        deadline = time.monotonic() + sample_seconds
        while time.monotonic() < deadline:
            if not process_is_running(pid):
                raise SystemExit(f"WorkspaceManager exited early (pid={pid})")
            sample = ps_cpu(pid)
            if sample is not None:
                samples.append(sample)
            time.sleep(1)
    finally:
        terminate_pid(pid)

    if not samples:
        raise SystemExit("no CPU samples collected")
    metric = numeric_stats(samples, unit="percent")
    assert metric is not None
    summary = canonical_summary(
        scenario="main_window_idle_cpu_diagnostics_closed",
        build_kind="debug",
        metrics={"main_window_idle_cpu_diagnostics_closed_percent": metric},
        diagnostic_findings=[
            "Diagnostics pane remained closed; this samples idle app process CPU, not Diagnostics tab sampling cost."
        ],
        artifacts={
            "app_log": str(log_path),
            "app_data": str(app_data),
            "sample_seconds": sample_seconds,
            "samples": samples,
        },
        contract=load_contract(),
        extra={
            "metadata": {
                "sample_seconds": sample_seconds,
                "sample_count": len(samples),
                "launch_mode": "no-activate",
                "ui_fixture": True,
                "diagnostics_open": False,
            }
        },
    )
    write_summary(summary, output_dir)
    return summary


def main() -> int:
    args = parse_args()
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.scenario == "main_window_agent_activity_burst":
        summary = run_agent_activity_burst(output_dir)
    elif args.scenario == "main_window_session_switcher_snapshot":
        summary = run_session_switcher_snapshot(output_dir)
    elif args.scenario == "main_window_workspace_create_ui_stall":
        summary = run_workspace_create(output_dir, args.runs, args.sleep_seconds)
    elif args.scenario == "main_window_idle_cpu_diagnostics_closed":
        summary = run_idle_cpu(output_dir, args.sample_seconds)
    elif args.scenario == "main_window_resident_memory_20_workspaces":
        summary = run_resident_memory(output_dir, args.surface_count)
    else:
        raise AssertionError(args.scenario)

    if args.assert_budget:
        assert_budget(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
