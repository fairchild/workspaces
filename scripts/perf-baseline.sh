#!/bin/bash
# Capture launch/hydration/repo-focus perf baselines from production signpost logs.
# Optional: record results into docs/performance history + dashboard.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/perf-baseline.sh [runs] [sleep_seconds] [--record] [--assert-budget] [--launch-mode no-activate|activate] [--preferences clean|carry-over]

Examples:
  ./scripts/perf-baseline.sh
  ./scripts/perf-baseline.sh 5 8
  ./scripts/perf-baseline.sh 5 8 --record
  ./scripts/perf-baseline.sh 5 8 --record --assert-budget
  ./scripts/perf-baseline.sh 5 8 --launch-mode activate
  ./scripts/perf-baseline.sh 10 8 --preferences carry-over

Notes:
  - --record appends results to docs/performance/metrics-history.csv
  - --record regenerates docs/performance/dashboard.md
  - --assert-budget exits nonzero if any metric exceeds its budget target
  - --preferences clean (default) wipes the run's scratch preferences suite before
    every sample, so each launch starts from a known-empty domain. carry-over wipes
    once per invocation, so sample 1 seeds continuity state that samples 2..N restore
    — the shape the lane had when UserDefaults was un-isolated (#1251, #1252).
EOF
}

RUNS=5
SLEEP_SECONDS=8
RECORD=0
ASSERT_BUDGET=0
POSITIONAL=0
LAUNCH_MODE="no-activate"
PREFERENCES_MODE="clean"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
            ;;
        --assert-budget)
            ASSERT_BUDGET=1
            shift
            ;;
        --launch-mode)
            [[ $# -ge 2 ]] || { echo "--launch-mode requires a value" >&2; usage; exit 1; }
            LAUNCH_MODE="$2"
            case "$LAUNCH_MODE" in
                no-activate|activate) ;;
                *)
                    echo "Unsupported launch mode: $LAUNCH_MODE" >&2
                    usage
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --preferences)
            [[ $# -ge 2 ]] || { echo "--preferences requires a value" >&2; usage; exit 1; }
            PREFERENCES_MODE="$2"
            case "$PREFERENCES_MODE" in
                clean|carry-over) ;;
                *)
                    echo "Unsupported preferences mode: $PREFERENCES_MODE" >&2
                    usage
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                if [[ $POSITIONAL -eq 0 ]]; then
                    RUNS="$1"
                    POSITIONAL=1
                    shift
                elif [[ $POSITIONAL -eq 1 ]]; then
                    SLEEP_SECONDS="$1"
                    POSITIONAL=2
                    shift
                else
                    echo "Unexpected argument: $1" >&2
                    usage
                    exit 1
                fi
            else
                echo "Unexpected argument: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="/tmp/workspaces-perf-baseline-$(date +%Y%m%d-%H%M%S)"
PERF_DATA_DIR="$OUTPUT_DIR/app-data"
DEBUG_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/debug/WorkspaceManager"

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf '%s\n' "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf '%s\n' "$HOME/${path#~/}"
        return
    fi
    printf '%s\n' "$path"
}

is_usable_ghostty_resources_dir() {
    local resources_dir="$1"
    local share_dir
    share_dir="$(cd "$resources_dir/.." 2>/dev/null && pwd -P)" || return 1

    [[ -d "$resources_dir/themes" ]] || return 1
    [[ -f "$share_dir/terminfo/78/xterm-ghostty" ]] || return 1
}

resolve_ghostty_resources_dir() {
    local -a share_candidates=()
    local candidate=""

    if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
        candidate="$(expand_home_prefix "$GHOSTTY_RESOURCES_DIR")"
        if is_usable_ghostty_resources_dir "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    if [[ -n "${GHOSTTY_SHARE_DIR:-}" ]]; then
        share_candidates+=("$(expand_home_prefix "$GHOSTTY_SHARE_DIR")")
    fi

    if [[ -n "${GHOSTTY_DIR:-}" ]]; then
        share_candidates+=("$(expand_home_prefix "$GHOSTTY_DIR")/zig-out/share")
    fi

    share_candidates+=("$HOME/.cache/workspacemanager/ghostty/zig-out/share")

    local share
    for share in "${share_candidates[@]}"; do
        candidate="$share/ghostty"
        if is_usable_ghostty_resources_dir "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# UserDefaults is a third state axis WORKSPACES_DATA_DIR never covered: the terminal
# continuity manifest lives there, so an un-isolated lane restored whatever sessions the
# last dev or fixture launch left behind and no sample could be attributed to a known
# starting state (#1251). #1258 made the domain switchable; this names the suite.
#
# #1258's contract is that an explicitly named suite belongs to whoever named it, and that
# holds here: a caller-provided WORKSPACES_PREFERENCES_SUITE is used as-is and never reset
# or removed, which also means the per-sample wipe `--preferences clean` promises is the
# caller's to perform. Only a suite this run invented is a suite this run may clear.
if [[ -n "${WORKSPACES_PREFERENCES_SUITE:-}" ]]; then
    PREFERENCES_SUITE="$WORKSPACES_PREFERENCES_SUITE"
    PREFERENCES_SUITE_OWNER="caller"
else
    PREFERENCES_SUITE="com.cloudcompute.workspaces.perf.$$-$(date +%Y%m%d%H%M%S)"
    PREFERENCES_SUITE_OWNER="lane"
fi

reset_preferences_suite() {
    [[ "$PREFERENCES_SUITE_OWNER" == "lane" ]] || return 0
    defaults delete "$PREFERENCES_SUITE" >/dev/null 2>&1 || true
}

# `pgrep -f` matches a regex against whole command lines, and this path is full of `.`
# metacharacters that would otherwise match anything. Escaped, the pattern means the binary
# it names — and it is only ever used to *observe* the process table. Signals go to the pid
# this invocation launched, never to whatever a pattern happens to match (#1280).
DEBUG_BINARY_PATTERN="$(printf '%s' "$DEBUG_BINARY" | sed 's/[][\\.*^$(){}?+|]/\\&/g')"

debug_instance_pids() {
    pgrep -f -- "$DEBUG_BINARY_PATTERN" 2>/dev/null || true
}

# A sample that overlaps a live instance measures a loaded machine rather than a launch —
# how the previous measurement pass on this lane was invalidated, with instances
# accumulating one per sample until the timings meant nothing (#1277). Read-only on
# purpose: an instance this run did not start belongs to someone else (a `launch-dev.sh`
# app, a concurrent capture), so the lane refuses to measure rather than killing it.
assert_no_debug_instance() {
    local label="$1"
    local pids
    pids="$(debug_instance_pids)"
    [[ -z "$pids" ]] && return 0
    echo "  [$label] a debug WorkspaceManager from this worktree is running: $(echo "$pids" | tr '\n' ' ')" >&2
    echo "  [$label] refusing to measure beside it — stop it and re-run." >&2
    return 1
}

# TERM, then KILL, and only ever the pid this invocation launched.
stop_launched_app() {
    local pid="$1"
    local attempt
    kill "$pid" 2>/dev/null || true
    for attempt in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "  escalating to SIGKILL for launched pid $pid"
    kill -9 "$pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.25
    done
    return 1
}

cleanup_preferences_suite() {
    [[ "$PREFERENCES_SUITE_OWNER" == "lane" ]] || return 0
    reset_preferences_suite
    rm -f "$HOME/Library/Preferences/$PREFERENCES_SUITE.plist"
}
trap cleanup_preferences_suite EXIT

mkdir -p "$OUTPUT_DIR" "$PERF_DATA_DIR"

if [[ ! -x "$DEBUG_BINARY" ]]; then
    (
        cd "$ROOT_DIR"
        swift build --product WorkspaceManager >/dev/null
    )
fi

GHOSTTY_RESOURCES_DIR_RESOLVED=""
if GHOSTTY_RESOURCES_DIR_RESOLVED="$(resolve_ghostty_resources_dir)"; then
    export GHOSTTY_RESOURCES_DIR="$GHOSTTY_RESOURCES_DIR_RESOLVED"
else
    if [[ "$ASSERT_BUDGET" -eq 1 ]]; then
        echo "Ghostty resources dir unavailable; cannot assert debug perf budget against a non-comparable launch." >&2
        echo "Set GHOSTTY_RESOURCES_DIR, GHOSTTY_SHARE_DIR, or GHOSTTY_DIR, or run ./scripts/build-ghosttykit.sh first." >&2
        exit 1
    fi
fi

SHELL_PROFILE_MODE="${WORKSPACES_SHELL_PROFILE_MODE:-clean}"
TERMINAL_DIAGNOSTICS="${WORKSPACES_TERMINAL_DIAGNOSTICS:-1}"
DISABLE_STATE_RESTORATION="${WORKSPACES_DISABLE_STATE_RESTORATION:-1}"

echo "WorkspaceManager perf baseline"
echo "  runs: $RUNS"
echo "  sleep per run: ${SLEEP_SECONDS}s"
echo "  launch mode: $LAUNCH_MODE"
echo "  record in repo docs: $RECORD"
echo "  assert budget: $ASSERT_BUDGET"
echo "  output: $OUTPUT_DIR"
echo "  data dir: $PERF_DATA_DIR"
echo "  ghostty resources: ${GHOSTTY_RESOURCES_DIR_RESOLVED:-unavailable}"
echo "  shell profile mode: $SHELL_PROFILE_MODE"
echo "  terminal diagnostics: $TERMINAL_DIAGNOSTICS"
echo "  preferences mode: $PREFERENCES_MODE"
echo "  preferences suite: $PREFERENCES_SUITE (owner: $PREFERENCES_SUITE_OWNER)"
if [[ "$PREFERENCES_SUITE_OWNER" == "caller" ]]; then
    echo "  note: caller-provided suite — this lane never resets it, so --preferences $PREFERENCES_MODE describes the caller's handling, not the lane's."
fi

reset_preferences_suite

for i in $(seq 1 "$RUNS"); do
    LOG_FILE="$OUTPUT_DIR/run-$i.log"
    echo "[$i/$RUNS] Launching app..."

    assert_no_debug_instance "pre-run $i" || exit 1

    if [[ "$PREFERENCES_MODE" == "clean" ]]; then
        reset_preferences_suite
    fi

    # This lane runs on a laptop that also hosts other work (`perf-measurement-laptop-optin`),
    # and launch latency tracks whatever else is on the CPU. Stamping each sample with the
    # load it launched under is what separates "the app got slower" from "the machine was
    # busy" without re-running the whole capture to find out.
    printf '%s\t%s\n' "$i" "$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')" \
        >> "$OUTPUT_DIR/sample-context.tsv"

    # OS_ACTIVITY_DT_MODE makes os.Logger output mirror to stderr. The app's
    # [Perf] lines are os.Logger-only, so without it a redirected debug launch
    # captures nothing and every metric reads "missing" (#1238).
    #
    # `exec` so the subshell becomes the app: APP_PID is then the pid teardown signals,
    # rather than a wrapper whose death would leave the app running.
    (
        cd "$ROOT_DIR"
        if [[ "$LAUNCH_MODE" == "no-activate" ]]; then
            OS_ACTIVITY_DT_MODE=YES \
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_PREFERENCES_SUITE="$PREFERENCES_SUITE" \
            WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            WORKSPACES_SHELL_PROFILE_MODE="$SHELL_PROFILE_MODE" \
            WORKSPACES_TERMINAL_DIAGNOSTICS="$TERMINAL_DIAGNOSTICS" \
            WORKSPACES_DISABLE_STATE_RESTORATION="$DISABLE_STATE_RESTORATION" \
            exec "$DEBUG_BINARY" -ApplePersistenceIgnoreState YES >"$LOG_FILE" 2>&1
        else
            OS_ACTIVITY_DT_MODE=YES \
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_PREFERENCES_SUITE="$PREFERENCES_SUITE" \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            WORKSPACES_SHELL_PROFILE_MODE="$SHELL_PROFILE_MODE" \
            WORKSPACES_TERMINAL_DIAGNOSTICS="$TERMINAL_DIAGNOSTICS" \
            WORKSPACES_DISABLE_STATE_RESTORATION="$DISABLE_STATE_RESTORATION" \
            exec "$DEBUG_BINARY" -ApplePersistenceIgnoreState YES >"$LOG_FILE" 2>&1
        fi
    ) &
    APP_PID=$!

    sleep "$SLEEP_SECONDS"
    stop_launched_app "$APP_PID" || {
        echo "sample $i: the launched app survived SIGKILL (pid $APP_PID)" >&2
        exit 1
    }
    wait "$APP_PID" 2>/dev/null || true
    assert_no_debug_instance "post-run $i" || exit 1

    echo "run=$i" >> "$OUTPUT_DIR/perf-lines.log"
    rg "\\[Perf\\]|\\[LaunchPreferences\\]" "$LOG_FILE" >> "$OUTPUT_DIR/perf-lines.log" || true
    echo "" >> "$OUTPUT_DIR/perf-lines.log"
done

assert_no_debug_instance "post-run sweep" || exit 1

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"

PERF_SUMMARY_TIMESTAMP="$TIMESTAMP" PYTHONPATH="$ROOT_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$OUTPUT_DIR" "$ROOT_DIR" "$RUNS" "$SLEEP_SECONDS" "$RECORD" "$TIMESTAMP" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" "$LAUNCH_MODE" "$ASSERT_BUDGET" "$GHOSTTY_RESOURCES_DIR_RESOLVED" "$SHELL_PROFILE_MODE" "$TERMINAL_DIAGNOSTICS" "$DISABLE_STATE_RESTORATION" "$PREFERENCES_MODE" "$PREFERENCES_SUITE" "$PREFERENCES_SUITE_OWNER" <<'PY'
from datetime import datetime
import json
import pathlib
import re
import statistics
import sys

from perf_schema import (
    canonical_summary,
    launch_trigger_label,
    load_contract,
    measured_duration_samples,
)

out_dir = pathlib.Path(sys.argv[1])
root_dir = pathlib.Path(sys.argv[2])
runs = int(sys.argv[3])
sleep_seconds = int(sys.argv[4])
record = int(sys.argv[5]) == 1
timestamp = sys.argv[6]
os_version = sys.argv[7]
os_build = sys.argv[8]
arch = sys.argv[9]
model = sys.argv[10]
launch_mode = sys.argv[11]
assert_budget = int(sys.argv[12]) == 1
ghostty_resources_dir = sys.argv[13] or None
shell_profile_mode = sys.argv[14]
terminal_diagnostics = sys.argv[15]
disable_state_restoration = sys.argv[16]
preferences_mode = sys.argv[17]
preferences_suite = sys.argv[18]
preferences_suite_owner = sys.argv[19]

hydration_meta_pattern = re.compile(
    r"metric=repo_hydration duration_ms=[0-9]+(?:\.[0-9]+)? discovered=(\d+) imported=(\d+)"
)
timestamp_prefix_pattern = re.compile(r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")
bootstrap_pattern = re.compile(
    r"event=initial_host_session caller=(?P<caller>\w+) branch=(?P<branch>\w+) sessions=(?P<sessions>\d+)"
)
# Which trigger closed the interval decides what the sample measured. `terminal_focus`
# on a backgrounded launch measures time-to-foreground — the app was ready and the clock
# kept running until something brought it forward — while a readiness trigger measures
# launch. Indistinguishable by duration alone, so each sample carries its own (#1399).
launch_trigger_pattern = re.compile(
    r"metric=launch_to_first_prompt duration_ms=[0-9.]+ trigger=(?P<trigger>\S+)"
)
# `domain=scratch` alone is not proof of isolation: when the defaults system refuses a
# suite the app logs the refusal and falls back to the persistent domain, still under a
# scratch resolution. `isolated=` is the field that says which store actually backed the
# launch, so the sample reports that rather than the intent.
preferences_pattern = re.compile(
    r"\[LaunchPreferences\] domain=(?P<domain>\w+)"
    r"(?:\s+suite=(?P<suite>\S+))?"
    r"(?:.*?\bisolated=(?P<isolated>\w+))?"
)
run_index_pattern = re.compile(r"run-(?P<index>\d+)\.log$")

metric_order = [
    "launch_to_first_prompt",
    "repo_hydration",
    "repo_click_to_focus",
    "workspace_click_to_focus",
]
metrics = {name: [] for name in metric_order}
discovered_values = []
imported_values = []
activation_to_first_prompt_values = []


def parse_log_timestamp(line: str):
    match = timestamp_prefix_pattern.match(line)
    if match is None:
        return None
    try:
        return datetime.strptime(match.group("ts"), "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None

launch_samples = []

load_by_run = {}
context_path = out_dir / "sample-context.tsv"
if context_path.exists():
    for line in context_path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            try:
                load_by_run[int(parts[0])] = float(parts[1])
            except ValueError:
                continue


def run_index(log_file):
    match = run_index_pattern.search(log_file.name)
    return int(match.group("index")) if match else 0


for log_file in sorted(out_dir.glob("run-*.log"), key=run_index):
    text = log_file.read_text(errors="ignore")
    per_run = {}
    for metric_name, duration in measured_duration_samples(text):
        per_run[metric_name] = duration
    for metric in metric_order:
        if metric in per_run:
            metrics[metric].append(per_run[metric])

    # Which path seeded the first session, and what it seeded. `launch_to_first_prompt`
    # closes on the first shell's prompt, so a sample is only comparable to another sample
    # that took the same branch — the correlation #1251 needs read per run rather than
    # inferred from the shape of the distribution.
    bootstraps = [match.groupdict() for match in bootstrap_pattern.finditer(text)]
    seeding = next((entry for entry in bootstraps if entry["branch"] != "noop"), None)
    preferences_match = preferences_pattern.search(text)
    launch_trigger_match = launch_trigger_pattern.search(text)
    launch_samples.append(
        {
            "run": run_index(log_file),
            "launch_to_first_prompt_ms": per_run.get("launch_to_first_prompt"),
            "launch_trigger": (
                launch_trigger_match.group("trigger") if launch_trigger_match else None
            ),
            "seeded_by": seeding["caller"] if seeding else None,
            "branch": seeding["branch"] if seeding else None,
            "sessions": int(seeding["sessions"]) if seeding else None,
            "bootstrap_calls": [
                f"{entry['caller']}:{entry['branch']}:{entry['sessions']}" for entry in bootstraps
            ],
            "preferences_domain": (
                preferences_match.group("domain") if preferences_match else None
            ),
            "preferences_isolated": (
                preferences_match.group("isolated") if preferences_match else None
            ),
            "preferences_suite": (
                preferences_match.group("suite") if preferences_match else None
            ),
            "load_average_1m": load_by_run.get(run_index(log_file)),
            # The SwiftData store and SQLite sidecar are shared by every sample in an
            # invocation and are not reset between them — sample 1 imports the discovered
            # repos, samples 2..N open a populated store. `--preferences clean` says nothing
            # about that axis, so the hydration cost each sample actually paid is reported
            # here rather than left to be assumed equal.
            "repo_hydration_ms": per_run.get("repo_hydration"),
        }
    )

    hydration_meta_match = hydration_meta_pattern.search(text)
    if hydration_meta_match:
        discovered_values.append(int(hydration_meta_match.group(1)))
        imported_values.append(int(hydration_meta_match.group(2)))

    activation_time = None
    first_prompt_time = None
    for line in text.splitlines():
        if "[AppDelegate] applicationDidBecomeActive" in line and activation_time is None:
            activation_time = parse_log_timestamp(line)
            continue
        if "metric=launch_to_first_prompt duration_ms=" in line and first_prompt_time is None:
            first_prompt_time = parse_log_timestamp(line)

    if activation_time is not None and first_prompt_time is not None and first_prompt_time >= activation_time:
        activation_to_first_prompt_values.append(
            (first_prompt_time - activation_time).total_seconds() * 1000.0
        )


def summarize(values):
    if not values:
        return None
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "median": statistics.median(values),
        "mean": statistics.mean(values),
        "p95": max(values),
        "unit": "ms",
    }


scenario = "debug_no_activate" if launch_mode == "no-activate" else "debug_activate"
metrics_summary = {}
for metric, values in metrics.items():
    stats = summarize(values)
    if stats is not None:
        metrics_summary[metric] = stats

findings = []
launch_stats = metrics_summary.get("launch_to_first_prompt")
if launch_stats and launch_stats["median"] > 500:
    findings.append(
        f"launch_to_first_prompt median is {launch_stats['median']:.2f} ms in {scenario}. Raw SwiftPM debug startup should be compared against debug-only references, not packaged-app release gates."
    )
repo_focus_stats = metrics_summary.get("repo_click_to_focus")
if repo_focus_stats and repo_focus_stats["median"] > 300:
    findings.append(
        f"repo_click_to_focus median is {repo_focus_stats['median']:.2f} ms. Repo switching still has measurable post-prompt lag."
    )
if not findings:
    findings.append("No automated debug perf findings were derived from the captured [Perf] lines.")

summary = canonical_summary(
    scenario=scenario,
    build_kind="debug",
    metrics=metrics_summary,
    diagnostic_findings=findings,
    artifacts={
        "output_dir": str(out_dir),
        "runs_requested": runs,
        "sleep_seconds": sleep_seconds,
        "log_files": [str(path) for path in sorted(out_dir.glob("run-*.log"))],
    },
    os_version=os_version,
    os_build=os_build,
    machine_model=model,
    arch=arch,
    contract=load_contract(),
    extra={
        "metadata": {
            "timestamp": timestamp,
            "runs_requested": runs,
            "sleep_seconds": sleep_seconds,
            "launch_mode": launch_mode,
            "os_version": os_version,
            "os_build": os_build,
            "arch": arch,
            "model": model,
            "discovered_repos_median": int(statistics.median(discovered_values)) if discovered_values else None,
            "imported_repos_median": int(statistics.median(imported_values)) if imported_values else None,
            "activation_to_first_prompt_median_ms": (
                statistics.median(activation_to_first_prompt_values)
                if activation_to_first_prompt_values else None
            ),
            "ghostty_resources_dir": ghostty_resources_dir,
            "shell_profile_mode": shell_profile_mode,
            "terminal_diagnostics": terminal_diagnostics,
            "disable_state_restoration": disable_state_restoration,
            # Names the protocol this row was measured under, so the dashboard never
            # reports a measurement-boundary change as an app-side delta. Bumped from
            # `isolated-preferences-v1` when the wakeup tick stopped running inline
            # (#1251): before that, a launch whose first title happened to arrive on a
            # main-thread wakeup closed the metric early, so a v1 row is a mix of that
            # artifact and honest samples. v2 rows close at main-drain, always.
            "protocol_epoch": "deterministic-delivery-v1",
            "preferences_mode": preferences_mode,
            "preferences_suite": preferences_suite,
            "preferences_suite_owner": preferences_suite_owner,
            # The per-sample triggers reduced to the one value a recorded row carries, so
            # the console callout below and the committed CSV cell tell the same story
            # about the same run (#1399).
            "launch_trigger": launch_trigger_label(
                sample["launch_trigger"] for sample in launch_samples
            ),
            "launch_samples": launch_samples,
        }
    },
)

summary_lines = []
for metric in metric_order:
    stats = summary["metrics"].get(metric)
    if stats is None:
        summary_lines.append(f"{metric}: missing")
        continue
    summary_lines.append(
        f"{metric}: count={stats['count']} min={stats['min']:.2f} max={stats['max']:.2f} "
        f"median={stats['median']:.2f} mean={stats['mean']:.2f} p95={stats['p95']:.2f}"
    )

summary_path = out_dir / "summary.txt"
summary_json_path = out_dir / "summary.json"
summary_path.write_text("\n".join(summary_lines) + "\n")
summary_json_path.write_text(json.dumps(summary, indent=2) + "\n")

print(summary_path)
print(f"scenario: {scenario}")
print(f"launch_mode: {launch_mode}")
print(f"preferences_mode: {preferences_mode}")
print("\n".join(summary_lines))

print("\nper-sample launch modes:")
for sample in launch_samples:
    duration = sample["launch_to_first_prompt_ms"]
    print(
        f"  run={sample['run']} "
        f"launch_to_first_prompt={'missing' if duration is None else format(duration, '.2f')} "
        f"trigger={sample['launch_trigger'] or 'unreported'} "
        f"seeded_by={sample['seeded_by'] or 'none'} "
        f"branch={sample['branch'] or 'none'} "
        f"sessions={sample['sessions'] if sample['sessions'] is not None else 'none'} "
        f"preferences={sample['preferences_domain'] or 'unreported'}"
        f"/isolated={sample['preferences_isolated'] or '?'} "
        f"load1m={'?' if sample['load_average_1m'] is None else format(sample['load_average_1m'], '.2f')} "
        f"hydration={'?' if sample['repo_hydration_ms'] is None else format(sample['repo_hydration_ms'], '.2f')}"
    )

# Isolation has to fail closed. A sample whose log carries no [LaunchPreferences] line, or
# reports the persistent domain, or names a different suite, is a sample whose starting state
# is unknown — and an unknown starting state is exactly what this lane exists to remove. That
# is a harness failure rather than a slow launch, so the run exits non-zero and records
# nothing; summary.json is still written, because diagnosing the failure needs it.
isolation_failures = []
for sample in launch_samples:
    domain = sample["preferences_domain"]
    isolated = sample["preferences_isolated"]
    suite = sample["preferences_suite"]
    if domain is None:
        isolation_failures.append(f"  run={sample['run']}: no [LaunchPreferences] line in the run log")
    elif domain != "scratch":
        isolation_failures.append(f"  run={sample['run']}: resolved domain={domain}, not the scratch suite")
    elif isolated != "true":
        isolation_failures.append(
            f"  run={sample['run']}: domain=scratch but isolated={isolated} — the defaults system refused the suite"
        )
    elif suite is not None and suite != preferences_suite:
        isolation_failures.append(
            f"  run={sample['run']}: launched against suite={suite}, expected {preferences_suite}"
        )

if isolation_failures:
    print("")
    print("ISOLATION FAILURES (preferences domain not pinned; measurements discarded):")
    for failure in isolation_failures:
        print(failure)
    print("")
    sys.exit(2)

# A launch closed by `terminal_focus` stopped its clock when something brought the app
# forward, not when the app became usable — on a backgrounded launch that is a
# time-to-foreground number wearing a launch metric's name, and it is indistinguishable
# from a slow launch by duration alone (#1399). Flagged rather than discarded: the sample
# is real data about a real launch, and a consumer that knows which trigger closed it can
# decide. Silence is the one option ruled out — an unlabelled focus close is how a 61 s
# sample reaches an aggregate unchallenged.
attention_closed = [
    sample for sample in launch_samples if sample["launch_trigger"] == "terminal_focus"
]
if attention_closed:
    print("")
    print(
        f"NOTE: {len(attention_closed)} of {len(launch_samples)} launch samples closed on "
        "trigger=terminal_focus (time-to-foreground, not time-to-ready):"
    )
    for sample in attention_closed:
        duration = sample["launch_to_first_prompt_ms"]
        print(
            f"  run={sample['run']} "
            f"launch_to_first_prompt={'missing' if duration is None else format(duration, '.2f')}"
        )
    print(
        "  These measured attention. Exclude them from a launch comparison, or re-measure "
        "with the app foregrounded."
    )

sample_loads = [
    sample["load_average_1m"] for sample in launch_samples if sample["load_average_1m"] is not None
]
if sample_loads:
    print(
        f"  machine load (1m) across samples: min={min(sample_loads):.2f} "
        f"median={statistics.median(sample_loads):.2f} max={max(sample_loads):.2f}"
    )

print(f"summary_json={summary_json_path}")

# Metrics this scenario is asserted on. budget_results only covers metrics that
# produced samples, so the assertion iterates this list directly: a metric with
# no samples is a harness/capture failure and must fail the run, not pass it
# (#1238). workspace_click_to_focus has a debug_activate reference in the
# contract, but no launch-lane flow drives a workspace click yet, so asserting
# it here would hard-fail the lane on a known coverage gap.
asserted_metrics_by_scenario = {
    "debug_no_activate": ["launch_to_first_prompt", "repo_hydration"],
    "debug_activate": ["launch_to_first_prompt", "repo_hydration", "repo_click_to_focus"],
}

budget_exit_code = 0
if assert_budget:
    violations = []
    for metric_name in asserted_metrics_by_scenario[scenario]:
        stats = summary["metrics"].get(metric_name)
        if stats is None:
            violations.append(
                f"  {metric_name}: MISSING (no samples captured; a missing metric is a harness failure, not a pass)"
            )
            continue
        budget = summary["budget_results"].get(metric_name, {})
        target = budget.get("gate_budget_ms")
        if target is None:
            continue
        median = float(stats["median"])
        if median > float(target):
            overshoot = median - float(target)
            violations.append(
                f"  {metric_name}: {median:.2f} ms (budget {float(target):.0f} ms, over by {overshoot:.2f} ms)"
            )
    if violations:
        budget_exit_code = 1
        print("")
        print("BUDGET VIOLATIONS:")
        for v in violations:
            print(v)
        print("")
    else:
        print("\nAll metrics within budget.\n")

if not record:
    sys.exit(budget_exit_code)

from perf_history import record_summary

paths = record_summary(summary=summary, root_dir=root_dir, timestamp=timestamp)

print(f"history_csv={paths['history_csv']}")
print(f"dashboard_md={paths['dashboard_md']}")
print(f"latest_json={paths['latest_json']}")

sys.exit(budget_exit_code)
PY
