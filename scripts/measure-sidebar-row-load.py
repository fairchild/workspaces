#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Measure the sidebar's cost under replayed agent-event load.

The rig #1347 described but never wrote down, assembled from the pieces that arc left
behind. It launches an isolated debug instance carrying a requested number of live agent
sessions, replays hook events into it at a controlled rate, and reports what that costs:
main-thread utilization idle and under load, the SwiftUI/AppKit frames the load lands on,
and the repo-click latency samples taken while it runs.

Why it exists: #1347's acceptance asks for at least twelve live sessions at two or more
events per second, and the standard fixture set carries five, so every number in that arc
was taken at six sessions. `WORKSPACES_UI_FIXTURE_LOAD_WORKSPACES` seeds the rest; this
script drives them.

Two measurement notes worth carrying into any reading of the output:

  * `repo_click_to_focus` yields a latency sample only from a click whose terminal was not
    already up — a re-click of the focused repo emits an abandoned interval, whose elapsed
    time is idle wall clock, and the shared parser excludes those by design. Every sample
    below therefore includes shell spawn and first-prompt readiness; compare it against the
    contract's 220ms median / 300ms p95, not against a render budget.
  * `--no-activate` keeps the run off a shared desktop, and the focus-completion arm of that
    metric needs the app frontmost. Samples here complete through prompt readiness instead.

Usage:
    uv run --script scripts/measure-sidebar-row-load.py --label before --output-dir /tmp/x
    uv run --script scripts/measure-sidebar-row-load.py --label after  --output-dir /tmp/y
    uv run --script scripts/measure-sidebar-row-load.py --compare /tmp/x /tmp/y
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Cycled across the seeded workspaces so the sidebar carries every rung of the attention
# ladder, not one state repeated — the dots, the pane badges, and the bubbled repo rows all
# differ by rung, and a uniform fixture would under-count the work a mixed sidebar does.
AGENT_STATES = ["thinking", "running-tool", "awaiting-input", "errored", "idle", "complete"]

# What the sample is read for. `sample` prints a call tree whose counts already include every
# descendant, so these are summed at the topmost matching node on each branch — counting lines
# instead would score a deep recursion (terminal spawn converts one env var per frame) far above
# the shallow, wide work that actually costs.
#
# `blocked` is the main thread parked in `mach_msg`, which is most of any window; subtracting it
# is what turns a sample into a reading. The three buckets under it are where a sidebar redraw
# lands: SwiftUI's render host driving the update, AttributeGraph recomputing the view graph, and
# AppKit laying the result out.
SAMPLE_BUCKETS: dict[str, list[str]] = {
    "blocked": ["mach_msg2_trap"],
    "view_render_host": ["ViewRendererHost", "NSHostingView"],
    "attribute_graph_update": ["AG::Graph::UpdateStack::update()"],
    "appkit_layout": ["_layoutSubtreeWithOldSize"],
}

CLICK_SUCCESS_OUTCOMES = {"prompt_ready", "focused"}


@dataclass
class MainThreadSample:
    label: str
    main_thread_percent: float | None = None
    process_percent: float | None = None
    raw: str = ""


@dataclass
class RunResult:
    label: str
    sessions_requested: int
    sessions_active: int | None = None
    rate: float = 0.0
    duration: float = 0.0
    idle: MainThreadSample | None = None
    loaded: MainThreadSample | None = None
    sample_buckets: dict = field(default_factory=dict)
    row_builds_per_second: float | None = None
    row_build_window: tuple[int, int, float] | None = None
    click_samples: list[float] = field(default_factory=list)
    click_abandoned: int = 0
    replay_summary: str = ""
    app_log: str = ""


def log(message: str) -> None:
    print(f"[rig] {message}", flush=True)


def percentile(values: list[float], fraction: float) -> float | None:
    """Linear-interpolated percentile, matching `scripts/perf_schema.py`."""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def median(values: list[float]) -> float | None:
    return percentile(values, 0.5)


def agent_states(count: int) -> str:
    return ",".join(
        f"load-{index + 1:02d}:{AGENT_STATES[index % len(AGENT_STATES)]}"
        for index in range(count)
    )


def launch_app(data_dir: Path, sessions: int, window_timeout: int) -> tuple[int, Path]:
    """Launch an isolated debug instance beside whatever else is running.

    `--coexist` leaves the installed app alone, `--no-activate` keeps the run off a shared
    desktop, and the hooks-socket override is what stops this instance from contending for the
    installed app's socket and going dormant behind its flock.
    """
    hooks_socket = data_dir / "hooks.sock"
    command = [
        str(REPO_ROOT / "scripts" / "launch-dev.sh"),
        "--no-build",
        "--coexist",
        "--no-activate",
        "--clean-data",
        "--fixture",
        "--data-dir",
        str(data_dir),
        "--window-timeout",
        str(window_timeout),
        "--env",
        f"WORKSPACES_HOOKS_SOCKET_OVERRIDE={hooks_socket}",
        "--env",
        "WORKSPACES_AUTOMATION_API=1",
        "--env",
        "WORKSPACES_AUTOMATION_OPERATOR=1",
        # os.Logger output is stderr-mirrored only under this, and every [Perf] line the run
        # reads is os.Logger-only (#1238).
        "--env",
        "OS_ACTIVITY_DT_MODE=YES",
        "--env",
        f"WORKSPACES_UI_FIXTURE_LOAD_WORKSPACES={sessions}",
        "--env",
        f"WORKSPACES_UI_FIXTURE_AGENT_STATES={agent_states(sessions)}",
    ]
    completed = subprocess.run(
        command, cwd=REPO_ROOT, capture_output=True, text=True, check=False
    )
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise SystemExit(f"launch-dev.sh failed:\n{output}")

    pid_match = re.search(r"WorkspaceManager running \(pid=(\d+)\)", output)
    log_match = re.search(r"Log file: (\S+)", output)
    if not pid_match or not log_match:
        raise SystemExit(f"could not read pid/log from launch output:\n{output}")
    return int(pid_match.group(1)), Path(log_match.group(1))


def wait_for_credential(app_log: Path, timeout: float = 30.0) -> tuple[str, str]:
    """Read the automation socket and handle out of the app's own log.

    Deliberately not the CLI's own resolver: a fixture launch relocates the automation
    directory, and reading the path the running instance printed is the only way to be sure
    the requests reach *this* app rather than an installed one listening elsewhere.
    """
    deadline = time.monotonic() + timeout
    pattern = re.compile(r"operator credential minted at (\S+)")
    while time.monotonic() < deadline:
        if app_log.exists():
            match = None
            for line in app_log.read_text(errors="replace").splitlines():
                found = pattern.search(line)
                if found:
                    match = found
            if match:
                credential = json.loads(Path(match.group(1)).read_text())
                return credential["socketPath"], credential["handle"]
        time.sleep(0.25)
    raise SystemExit("automation operator credential never appeared")


def automation_request(socket_path: str, handle: str, method: str, path: str, body: str = "") -> dict:
    command = [
        "curl",
        "--silent",
        "--show-error",
        "--unix-socket",
        socket_path,
        "--header",
        f"x-workspaces-automation-handle: {handle}",
        "-X",
        method,
    ]
    if body:
        command += ["--header", "Content-Type: application/json", "--data", body]
    command.append(f"http://localhost{path}")
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0 or not completed.stdout:
        raise SystemExit(f"automation {method} {path} failed: {completed.stderr}")
    return json.loads(completed.stdout)


def measure_main_thread(pid: int, seconds: int, label: str) -> MainThreadSample:
    completed = subprocess.run(
        [str(REPO_ROOT / "scripts" / "measure-main-thread.sh"), str(pid), str(seconds)],
        capture_output=True,
        text=True,
        check=False,
    )
    raw = completed.stdout + completed.stderr
    sample = MainThreadSample(label=label, raw=raw.strip())
    main = re.search(r"main thread cpu:\s+\S+\s+\(([\d.]+)% of one core\)", raw)
    total = re.search(r"process total cpu:\s+\S+\s+\(([\d.]+)% of one core\)", raw)
    if main:
        sample.main_thread_percent = float(main.group(1))
    if total:
        sample.process_percent = float(total.group(1))
    return sample


def count_active_sessions(data_dir: Path) -> int | None:
    store = data_dir / "local-state.sqlite"
    if not store.exists() or not shutil.which("sqlite3"):
        return None
    completed = subprocess.run(
        ["sqlite3", str(store), "select count(*) from terminal_sessions where is_active=1;"],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return int(completed.stdout.strip())
    except ValueError:
        return None


def start_replay(data_dir: Path, rate: float, duration: float, output: Path) -> subprocess.Popen:
    handle = output.open("w")
    return subprocess.Popen(
        [
            "uv",
            "run",
            "--script",
            str(REPO_ROOT / "scripts" / "replay-agent-events.py"),
            "--socket",
            str(data_dir / "hooks.sock"),
            "--store",
            str(data_dir / "local-state.sqlite"),
            "--auto-sessions",
            "--rate",
            str(rate),
            "--duration",
            str(duration),
            "--mix",
            "measured",
            "--verify-store",
        ],
        cwd=REPO_ROOT,
        stdout=handle,
        stderr=subprocess.STDOUT,
    )


def analyze_sample(path: Path) -> dict[str, int]:
    """Read the main thread's call tree out of a `sample` file.

    Counts nest, so each bucket sums the topmost matching node on every branch rather than every
    line that mentions the symbol.
    """
    if not path.exists():
        return {}
    lines = path.read_text(errors="replace").splitlines()
    # `sample` labels the first thread either "Main Thread" or by its dispatch queue
    # ("com.apple.main-thread"), and which one it picks varies run to run — match both, and fall
    # back to the first thread listed, which is always the main one.
    main_thread = re.compile(r"^\s*\d+ Thread_\S*.*(Main Thread|com\.apple\.main-thread)")
    any_thread = re.compile(r"^\s*\d+ Thread_")
    start = next(
        (index for index, line in enumerate(lines) if main_thread.match(line)),
        next((index for index, line in enumerate(lines) if any_thread.match(line)), None),
    )
    if start is None:
        return {}
    end = next(
        (
            index
            for index, line in enumerate(lines[start + 1 :], start + 1)
            if re.match(r"^\s*\d+ Thread_", line)
        ),
        len(lines),
    )

    node_pattern = re.compile(r"^([^\d]*?)(\d+) (.*)$")
    nodes: list[tuple[int, int, str]] = []
    for line in lines[start:end]:
        match = node_pattern.match(line)
        if match:
            nodes.append((len(match.group(1)), int(match.group(2)), match.group(3)))
    if not nodes:
        return {}

    def total_under(patterns: list[str]) -> int:
        total = 0
        skip_below: int | None = None
        for depth, count, symbol in nodes:
            if skip_below is not None and depth > skip_below:
                continue
            skip_below = None
            if any(pattern in symbol for pattern in patterns):
                total += count
                skip_below = depth
        return total

    result = {"main_thread_samples": nodes[0][1]}
    for name, patterns in SAMPLE_BUCKETS.items():
        result[name] = total_under(patterns)
    result["active"] = result["main_thread_samples"] - result.get("blocked", 0)
    return result


def collect_sample(pid: int, seconds: int, output: Path) -> dict[str, int]:
    subprocess.run(
        ["sample", str(pid), str(seconds), "-file", str(output)],
        capture_output=True,
        text=True,
        check=False,
    )
    return analyze_sample(output)


def drive_repo_clicks(
    socket_path: str, handle: str, interval: float, stop_at: float
) -> None:
    """Click every repo in turn, at `interval`, until `stop_at`.

    Ordered rather than random so before and after runs click the same repos in the same
    order — the samples are cold-terminal clicks, and which repo is cold when matters.
    """
    listing = automation_request(socket_path, handle, "GET", "/v1/workspaces")
    repo_ids = [repo["repoID"] for repo in listing.get("result", {}).get("repos", [])]
    if not repo_ids:
        log("no repos to click; skipping the click driver")
        return
    index = 0
    while time.monotonic() < stop_at:
        repo_id = repo_ids[index % len(repo_ids)]
        try:
            automation_request(
                socket_path, handle, "POST", "/v1/repo/terminal", json.dumps({"repoID": repo_id})
            )
        except SystemExit as error:
            log(f"click failed: {error}")
        index += 1
        time.sleep(interval)


def parse_click_samples(app_log: Path) -> tuple[list[float], int]:
    text = app_log.read_text(errors="replace")
    samples = [
        float(duration)
        for duration, outcome in re.findall(
            r"metric=repo_click_to_focus duration_ms=([\d.]+) \S+ outcome=(\S+)", text
        )
        if outcome in CLICK_SUCCESS_OUTCOMES
    ]
    abandoned = len(re.findall(r"metric=repo_click_to_focus status=abandoned", text))
    return samples, abandoned


def parse_row_builds(app_log: Path) -> tuple[int, int, float] | None:
    """Rows built between the first and last sampled counter line, and the seconds between them.

    The counter is sampled every fiftieth evaluation, so the two endpoints are exact counts at
    exact instants — the rate between them is a measurement, not an estimate.
    """
    pattern = re.compile(
        r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*sidebar_row_body_evaluations count=(\d+)",
        re.MULTILINE,
    )
    points = pattern.findall(app_log.read_text(errors="replace"))
    if len(points) < 2:
        return None
    from datetime import datetime

    def moment(stamp: str) -> datetime:
        return datetime.strptime(stamp[:26], "%Y-%m-%d %H:%M:%S.%f")

    first_time, first_count = points[0]
    last_time, last_count = points[-1]
    return int(first_count), int(last_count), (moment(last_time) - moment(first_time)).total_seconds()


def stop_app(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(40):
        time.sleep(0.25)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run(args: argparse.Namespace) -> RunResult:
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    data_dir = Path(args.data_dir).resolve()

    result = RunResult(
        label=args.label,
        sessions_requested=args.sessions,
        rate=args.rate,
        duration=args.duration,
    )

    log(f"launching with {args.sessions} seeded agent sessions")
    pid, app_log = launch_app(data_dir, args.sessions, args.window_timeout)
    result.app_log = str(app_log)
    log(f"app pid={pid} log={app_log}")

    try:
        socket_path, handle = wait_for_credential(app_log)
        log(f"automation socket {socket_path}")
        health = automation_request(socket_path, handle, "GET", "/v1/health")
        served_pid = health.get("result", {}).get("server", {}).get("pid")
        if served_pid != pid:
            raise SystemExit(
                f"automation socket serves pid {served_pid}, not the launched {pid}; refusing to drive it"
            )

        # Let launch settle before the idle reading, or the baseline carries hydration cost.
        time.sleep(args.settle_seconds)
        result.sessions_active = count_active_sessions(data_dir)
        log(f"active sessions: {result.sessions_active}")

        log(f"idle main-thread reading over {args.idle_seconds}s")
        result.idle = measure_main_thread(pid, args.idle_seconds, "idle")

        log(f"replaying at {args.rate} ev/s for {args.duration}s")
        replay = start_replay(data_dir, args.rate, args.duration, output_dir / "replay.log")
        # Give the replay a moment to reach its rate before the loaded reading starts.
        time.sleep(2)

        clicks_until = time.monotonic() + args.duration - args.sample_seconds - 4
        loaded_seconds = int(args.duration) - 6
        sample_path = output_dir / "sample-under-load.txt"

        import threading

        clicker = threading.Thread(
            target=drive_repo_clicks,
            args=(socket_path, handle, args.click_interval, clicks_until),
            daemon=True,
        )
        sampler_result: dict[str, dict[str, int]] = {}

        def sample_worker() -> None:
            sampler_result["buckets"] = collect_sample(pid, args.sample_seconds, sample_path)

        sampler = threading.Thread(target=sample_worker, daemon=True)

        if args.clicks:
            clicker.start()
        sampler.start()

        result.loaded = measure_main_thread(pid, max(loaded_seconds, 5), "under load")
        sampler.join(timeout=args.sample_seconds + 30)
        if args.clicks:
            clicker.join(timeout=10)

        replay.wait(timeout=args.duration + 60)
        result.replay_summary = (output_dir / "replay.log").read_text(errors="replace").strip()

        result.sample_buckets = sampler_result.get("buckets", {})

        # The app has to still be alive when the log is read; it is killed below.
        time.sleep(1)
        result.click_samples, result.click_abandoned = parse_click_samples(app_log)
        result.row_build_window = parse_row_builds(app_log)
        if result.row_build_window:
            first, last, elapsed = result.row_build_window
            result.row_builds_per_second = (last - first) / elapsed if elapsed > 0 else None
    finally:
        log("stopping app")
        stop_app(pid)

    shutil.copy(app_log, output_dir / "app.log")
    write_summary(result, output_dir)
    return result


def summary_dict(result: RunResult) -> dict:
    return {
        "label": result.label,
        "sessions_requested": result.sessions_requested,
        "sessions_active": result.sessions_active,
        "rate_events_per_second": result.rate,
        "duration_seconds": result.duration,
        "main_thread_percent_idle": result.idle.main_thread_percent if result.idle else None,
        "main_thread_percent_loaded": result.loaded.main_thread_percent if result.loaded else None,
        "process_percent_loaded": result.loaded.process_percent if result.loaded else None,
        "sample": result.sample_buckets,
        "sidebar_row_builds": {
            "per_second": result.row_builds_per_second,
            "window": result.row_build_window,
        },
        "repo_click_to_focus_ms": {
            "count": len(result.click_samples),
            "median": median(result.click_samples),
            "p95": percentile(result.click_samples, 0.95),
            "max": max(result.click_samples) if result.click_samples else None,
            "samples": result.click_samples,
            "abandoned_intervals": result.click_abandoned,
        },
    }


def write_summary(result: RunResult, output_dir: Path) -> None:
    summary = summary_dict(result)
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


def compare(before_dir: Path, after_dir: Path) -> None:
    before = json.loads((before_dir / "summary.json").read_text())
    after = json.loads((after_dir / "summary.json").read_text())

    def row(name: str, lhs, rhs, unit: str = "") -> str:
        if lhs is None or rhs is None:
            return f"| {name} | {lhs} | {rhs} | – |"
        delta = rhs - lhs
        pct = f" ({delta / lhs * 100:+.0f}%)" if lhs else ""
        return f"| {name} | {lhs:.2f}{unit} | {rhs:.2f}{unit} | {delta:+.2f}{unit}{pct} |"

    print("| metric | before | after | delta |")
    print("|---|---|---|---|")
    print(row("main thread, idle", before["main_thread_percent_idle"], after["main_thread_percent_idle"], "%"))
    print(row("main thread, under load", before["main_thread_percent_loaded"], after["main_thread_percent_loaded"], "%"))
    print(row("process, under load", before["process_percent_loaded"], after["process_percent_loaded"], "%"))
    print(
        row(
            "sidebar row builds / second",
            before["sidebar_row_builds"]["per_second"],
            after["sidebar_row_builds"]["per_second"],
        )
    )
    for bucket in ("active", "view_render_host", "attribute_graph_update", "appkit_layout"):
        print(row(f"sample · {bucket}", before["sample"].get(bucket), after["sample"].get(bucket)))
    print(
        row(
            "repo_click_to_focus p95",
            before["repo_click_to_focus_ms"]["p95"],
            after["repo_click_to_focus_ms"]["p95"],
            "ms",
        )
    )
    print(
        row(
            "repo_click_to_focus median",
            before["repo_click_to_focus_ms"]["median"],
            after["repo_click_to_focus_ms"]["median"],
            "ms",
        )
    )
    print()
    print(
        f"sessions: before {before['sessions_active']}, after {after['sessions_active']} "
        f"(requested {before['sessions_requested']}/{after['sessions_requested']}) "
        f"at {after['rate_events_per_second']} ev/s"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", default="run", help="name for this run in the summary")
    parser.add_argument("--output-dir", help="where summary.json, the sample, and the app log land")
    parser.add_argument("--data-dir", default=".dev-data/perf1366", help="isolated app data root")
    parser.add_argument("--sessions", type=int, default=12, help="seeded agent sessions (default 12)")
    parser.add_argument("--rate", type=float, default=2.0, help="replay events/second (default 2)")
    parser.add_argument("--duration", type=float, default=60.0, help="replay seconds (default 60)")
    parser.add_argument("--idle-seconds", type=int, default=10, help="idle main-thread window")
    parser.add_argument("--sample-seconds", type=int, default=5, help="`sample` window under load")
    parser.add_argument("--settle-seconds", type=float, default=8.0, help="post-launch settle")
    parser.add_argument("--click-interval", type=float, default=3.0, help="seconds between repo clicks")
    parser.add_argument("--window-timeout", type=int, default=30)
    parser.add_argument("--clicks", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"), help="print a before/after table")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.compare:
        compare(Path(args.compare[0]), Path(args.compare[1]))
        return 0
    if not args.output_dir:
        raise SystemExit("--output-dir is required")
    run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
