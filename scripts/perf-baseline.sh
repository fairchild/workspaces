#!/bin/bash
# Capture launch/hydration/repo-focus perf baselines from production signpost logs.
# Optional: record results into docs/performance history + dashboard.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/perf-baseline.sh [runs] [sleep_seconds] [--record] [--assert-budget] [--launch-mode no-activate|activate]

Examples:
  ./scripts/perf-baseline.sh
  ./scripts/perf-baseline.sh 5 8
  ./scripts/perf-baseline.sh 5 8 --record
  ./scripts/perf-baseline.sh 5 8 --record --assert-budget
  ./scripts/perf-baseline.sh 5 8 --launch-mode activate

Notes:
  - --record appends results to docs/performance/metrics-history.csv
  - --record regenerates docs/performance/dashboard.md
  - --assert-budget exits nonzero if any metric exceeds its budget target
EOF
}

RUNS=5
SLEEP_SECONDS=8
RECORD=0
ASSERT_BUDGET=0
POSITIONAL=0
LAUNCH_MODE="no-activate"

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

for i in $(seq 1 "$RUNS"); do
    LOG_FILE="$OUTPUT_DIR/run-$i.log"
    echo "[$i/$RUNS] Launching app..."

    # Only kill the debug binary, not the installed /Applications app.
    pkill -f "$DEBUG_BINARY" 2>/dev/null || true
    sleep 1

    # OS_ACTIVITY_DT_MODE makes os.Logger output mirror to stderr. The app's
    # [Perf] lines are os.Logger-only, so without it a redirected debug launch
    # captures nothing and every metric reads "missing" (#1238).
    (
        cd "$ROOT_DIR"
        if [[ "$LAUNCH_MODE" == "no-activate" ]]; then
            OS_ACTIVITY_DT_MODE=YES \
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            WORKSPACES_SHELL_PROFILE_MODE="$SHELL_PROFILE_MODE" \
            WORKSPACES_TERMINAL_DIAGNOSTICS="$TERMINAL_DIAGNOSTICS" \
            WORKSPACES_DISABLE_STATE_RESTORATION="$DISABLE_STATE_RESTORATION" \
            "$DEBUG_BINARY" -ApplePersistenceIgnoreState YES >"$LOG_FILE" 2>&1
        else
            OS_ACTIVITY_DT_MODE=YES \
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            WORKSPACES_SHELL_PROFILE_MODE="$SHELL_PROFILE_MODE" \
            WORKSPACES_TERMINAL_DIAGNOSTICS="$TERMINAL_DIAGNOSTICS" \
            WORKSPACES_DISABLE_STATE_RESTORATION="$DISABLE_STATE_RESTORATION" \
            "$DEBUG_BINARY" -ApplePersistenceIgnoreState YES >"$LOG_FILE" 2>&1
        fi
    ) &
    APP_PID=$!

    sleep "$SLEEP_SECONDS"
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true

    echo "run=$i" >> "$OUTPUT_DIR/perf-lines.log"
    rg "\\[Perf\\]" "$LOG_FILE" >> "$OUTPUT_DIR/perf-lines.log" || true
    echo "" >> "$OUTPUT_DIR/perf-lines.log"
done

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"

PERF_SUMMARY_TIMESTAMP="$TIMESTAMP" PYTHONPATH="$ROOT_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$OUTPUT_DIR" "$ROOT_DIR" "$RUNS" "$SLEEP_SECONDS" "$RECORD" "$TIMESTAMP" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" "$LAUNCH_MODE" "$ASSERT_BUDGET" "$GHOSTTY_RESOURCES_DIR_RESOLVED" "$SHELL_PROFILE_MODE" "$TERMINAL_DIAGNOSTICS" "$DISABLE_STATE_RESTORATION" <<'PY'
from datetime import datetime
import json
import pathlib
import re
import statistics
import sys

from perf_schema import canonical_summary, load_contract

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

duration_pattern = re.compile(r"metric=([a-z_]+) duration_ms=([0-9]+(?:\.[0-9]+)?)")
hydration_meta_pattern = re.compile(
    r"metric=repo_hydration duration_ms=[0-9]+(?:\.[0-9]+)? discovered=(\d+) imported=(\d+)"
)
timestamp_prefix_pattern = re.compile(r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")

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

for log_file in sorted(out_dir.glob("run-*.log")):
    text = log_file.read_text(errors="ignore")
    per_run = {}
    for match in duration_pattern.finditer(text):
        per_run[match.group(1)] = float(match.group(2))
    for metric in metric_order:
        if metric in per_run:
            metrics[metric].append(per_run[metric])

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
print("\n".join(summary_lines))
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
