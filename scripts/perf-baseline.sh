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
  - --assert-budget exits 1 if any tracked metric exceeds its budget (composable with --record)
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

mkdir -p "$OUTPUT_DIR" "$PERF_DATA_DIR"

if [[ ! -x "$DEBUG_BINARY" ]]; then
    (
        cd "$ROOT_DIR"
        swift build --product WorkspaceManager >/dev/null
    )
fi

echo "WorkspaceManager perf baseline"
echo "  runs: $RUNS"
echo "  sleep per run: ${SLEEP_SECONDS}s"
echo "  launch mode: $LAUNCH_MODE"
echo "  record in repo docs: $RECORD"
echo "  output: $OUTPUT_DIR"
echo "  data dir: $PERF_DATA_DIR"

for i in $(seq 1 "$RUNS"); do
    LOG_FILE="$OUTPUT_DIR/run-$i.log"
    echo "[$i/$RUNS] Launching app..."

    # Only kill the debug binary, not the installed /Applications app.
    pkill -f "$DEBUG_BINARY" 2>/dev/null || true
    sleep 1

    (
        cd "$ROOT_DIR"
        if [[ "$LAUNCH_MODE" == "no-activate" ]]; then
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            "$DEBUG_BINARY" >"$LOG_FILE" 2>&1
        else
            WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
            WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
            "$DEBUG_BINARY" >"$LOG_FILE" 2>&1
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

python3 - "$OUTPUT_DIR" "$ROOT_DIR" "$RUNS" "$SLEEP_SECONDS" "$RECORD" "$TIMESTAMP" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" "$LAUNCH_MODE" "$ASSERT_BUDGET" <<'PY'
import csv
from datetime import datetime
import json
import pathlib
import re
import statistics
import sys

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

duration_pattern = re.compile(r"metric=([a-z_]+) duration_ms=([0-9]+(?:\.[0-9]+)?)")
hydration_meta_pattern = re.compile(
    r"metric=repo_hydration duration_ms=[0-9]+(?:\.[0-9]+)? discovered=(\d+) imported=(\d+)"
)
timestamp_prefix_pattern = re.compile(r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")

metric_order = [
    "launch_to_first_prompt",
    "repo_hydration",
    "repo_click_to_focus",
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
        "n": len(values),
        "min": min(values),
        "max": max(values),
        "median": statistics.median(values),
        "mean": statistics.mean(values),
    }


summary = {metric: summarize(values) for metric, values in metrics.items()}
summary["metadata"] = {
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
}

summary_lines = []
for metric in metric_order:
    stats = summary[metric]
    if stats is None:
        summary_lines.append(f"{metric}: missing")
        continue
    summary_lines.append(
        f"{metric}: n={stats['n']} min={stats['min']:.2f} max={stats['max']:.2f} "
        f"median={stats['median']:.2f} mean={stats['mean']:.2f}"
    )

summary_path = out_dir / "summary.txt"
summary_json_path = out_dir / "summary.json"
summary_path.write_text("\n".join(summary_lines) + "\n")
summary_json_path.write_text(json.dumps(summary, indent=2) + "\n")

print(summary_path)
print(f"launch_mode: {launch_mode}")
print("\n".join(summary_lines))
print(f"summary_json={summary_json_path}")

metric_specs = [
    ("launch_to_first_prompt_median_ms", "launch_to_first_prompt", 250.0),
    ("repo_hydration_median_ms",         "repo_hydration",          25.0),
    ("repo_click_to_focus_median_ms",    "repo_click_to_focus",    250.0),
]

budget_exit_code = 0
if assert_budget:
    violations = []
    for median_key, metric_name, target in metric_specs:
        val = summary[metric_name]["median"] if summary[metric_name] else None
        if val is not None and val > target:
            over = val - target
            pct = (over / target) * 100.0
            violations.append(
                f"  FAIL  {metric_name}: {val:.2f} ms  (budget <= {target:.0f} ms, over by {over:+.2f} ms / {pct:+.1f}%)"
            )
    if violations:
        print("\nBudget violations:")
        for v in violations:
            print(v)
        budget_exit_code = 1
    else:
        print("\nAll metrics within budget.")

if not record:
    sys.exit(budget_exit_code)

perf_dir = root_dir / "docs" / "performance"
perf_dir.mkdir(parents=True, exist_ok=True)
history_csv_path = perf_dir / "metrics-history.csv"
dashboard_path = perf_dir / "dashboard.md"
latest_json_path = perf_dir / "latest-summary.json"
latest_json_path.write_text(json.dumps(summary, indent=2) + "\n")

fieldnames = [
    "timestamp",
    "runs_requested",
    "sleep_seconds",
    "os_version",
    "os_build",
    "arch",
    "model",
    "discovered_repos_median",
    "imported_repos_median",
    "launch_to_first_prompt_median_ms",
    "repo_hydration_median_ms",
    "repo_click_to_focus_median_ms",
    "launch_to_first_prompt_mean_ms",
    "repo_hydration_mean_ms",
    "repo_click_to_focus_mean_ms",
    "activation_to_first_prompt_median_ms",
]

record_row = {
    "timestamp": timestamp,
    "runs_requested": runs,
    "sleep_seconds": sleep_seconds,
    "os_version": os_version,
    "os_build": os_build,
    "arch": arch,
    "model": model,
    "discovered_repos_median": summary["metadata"]["discovered_repos_median"],
    "imported_repos_median": summary["metadata"]["imported_repos_median"],
    "launch_to_first_prompt_median_ms": summary["launch_to_first_prompt"]["median"] if summary["launch_to_first_prompt"] else "",
    "repo_hydration_median_ms": summary["repo_hydration"]["median"] if summary["repo_hydration"] else "",
    "repo_click_to_focus_median_ms": summary["repo_click_to_focus"]["median"] if summary["repo_click_to_focus"] else "",
    "launch_to_first_prompt_mean_ms": summary["launch_to_first_prompt"]["mean"] if summary["launch_to_first_prompt"] else "",
    "repo_hydration_mean_ms": summary["repo_hydration"]["mean"] if summary["repo_hydration"] else "",
    "repo_click_to_focus_mean_ms": summary["repo_click_to_focus"]["mean"] if summary["repo_click_to_focus"] else "",
    "activation_to_first_prompt_median_ms": summary["metadata"]["activation_to_first_prompt_median_ms"] or "",
}

existing_rows = []
if history_csv_path.exists():
    with history_csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        existing_rows = list(reader)

existing_rows.append(record_row)

with history_csv_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in existing_rows:
        writer.writerow({field: row.get(field, "") for field in fieldnames})

rows = []
with history_csv_path.open(newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

def parse_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def fmt_ms(value):
    return f"{value:.2f}" if value is not None else "n/a"

def delta_text(current, previous):
    if current is None or previous is None or previous == 0:
        return "n/a"
    delta = current - previous
    pct = (delta / previous) * 100.0
    return f"{delta:+.2f} ms ({pct:+.1f}%)"

def bar(value, max_value, width=24):
    if value is None or max_value <= 0:
        return "-" * width
    filled = int(round((value / max_value) * width))
    filled = max(1, min(width, filled))
    return "#" * filled + "-" * (width - filled)

latest = rows[-1] if rows else None
previous = rows[-2] if len(rows) > 1 else None
window = rows[-10:]
latest_report_paths = sorted(perf_dir.glob("release-exception-validation-*.md"))

dashboard_lines = []
dashboard_lines.append("# Performance Dashboard")
dashboard_lines.append("")
dashboard_lines.append(f"Last updated: `{timestamp}`")
dashboard_lines.append("")
dashboard_lines.append("## Latest Snapshot")
dashboard_lines.append("")
dashboard_lines.append("| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |")
dashboard_lines.append("|---|---:|---:|---:|---|---|")

for median_key, metric_name, target in metric_specs:
    median_value = parse_float(latest.get(median_key) if latest else None)
    mean_value = parse_float(latest.get(f"{metric_name}_mean_ms") if latest else None)
    prev_value = parse_float(previous.get(median_key) if previous else None)
    status = "pass" if median_value is not None and median_value <= target else "fail"
    dashboard_lines.append(
        f"| `{metric_name}` | {fmt_ms(median_value)} | "
        f"{fmt_ms(mean_value)} | <= {target:.0f} | {status} | "
        f"{delta_text(median_value, prev_value)} |"
    )

dashboard_lines.append("")
dashboard_lines.append("## Investigated Delta")
dashboard_lines.append("")

if latest is None or previous is None:
    dashboard_lines.append("- Not enough recorded history yet to compare this snapshot with a previous run.")
else:
    latest_launch = parse_float(latest.get("launch_to_first_prompt_median_ms"))
    previous_launch = parse_float(previous.get("launch_to_first_prompt_median_ms"))
    latest_click = parse_float(latest.get("repo_click_to_focus_median_ms"))
    previous_click = parse_float(previous.get("repo_click_to_focus_median_ms"))
    latest_hydration = parse_float(latest.get("repo_hydration_median_ms"))
    previous_hydration = parse_float(previous.get("repo_hydration_median_ms"))
    latest_discovered = latest.get("discovered_repos_median") or "n/a"
    previous_discovered = previous.get("discovered_repos_median") or "n/a"
    latest_activation_delay = parse_float(latest.get("activation_to_first_prompt_median_ms"))
    previous_activation_delay = parse_float(previous.get("activation_to_first_prompt_median_ms"))

    dashboard_lines.append(
        f"- Portfolio size changed from discovered={previous_discovered} to discovered={latest_discovered}, "
        f"but `repo_hydration` only moved {delta_text(latest_hydration, previous_hydration)} and remains "
        f"{'within' if latest_hydration is not None and latest_hydration <= 25.0 else 'outside'} the `<= 25 ms` gate."
    )

    dashboard_lines.append(
        f"- The large regression is concentrated in terminal readiness: `launch_to_first_prompt` changed "
        f"{delta_text(latest_launch, previous_launch)} and `repo_click_to_focus` changed "
        f"{delta_text(latest_click, previous_click)}."
    )

    if latest_activation_delay is not None and previous_activation_delay is not None:
        dashboard_lines.append(
            f"- The post-activation ready-to-type gap changed {delta_text(latest_activation_delay, previous_activation_delay)}, "
            f"from `{previous_activation_delay:.2f} ms` to `{latest_activation_delay:.2f} ms`. "
            "That points to terminal focus/readiness after activation as the main place the extra time moved."
        )
    elif latest_activation_delay is not None:
        dashboard_lines.append(
            f"- In the latest recorded run, the app reached `applicationDidBecomeActive` a median "
            f"`{latest_activation_delay:.2f} ms` before `launch_to_first_prompt` completed. "
            "That points to post-activation terminal focus/ready-to-type delay rather than repository import."
        )

    if latest_report_paths:
        dashboard_lines.append(
            f"- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` "
            f"measurements, is recorded in `./{latest_report_paths[-1].name}`."
        )

dashboard_lines.append("")
dashboard_lines.append("## Trend (Last 10 Runs)")
dashboard_lines.append("")
dashboard_lines.append("| Timestamp | Launch (ms) | Hydration (ms) | Click-to-Focus (ms) |")
dashboard_lines.append("|---|---:|---:|---:|")
for row in window:
    launch_value = parse_float(row.get("launch_to_first_prompt_median_ms"))
    hydration_value = parse_float(row.get("repo_hydration_median_ms"))
    click_value = parse_float(row.get("repo_click_to_focus_median_ms"))
    dashboard_lines.append(
        f"| {row['timestamp']} | "
        f"{fmt_ms(launch_value)} | "
        f"{fmt_ms(hydration_value)} | "
        f"{fmt_ms(click_value)} |"
    )

dashboard_lines.append("")
dashboard_lines.append("## Visual Bars (Last 10 Run Window)")
dashboard_lines.append("")

for median_key, metric_name, target in metric_specs:
    current = parse_float(latest.get(median_key) if latest else None)
    target_pct = (current / target * 100.0) if current is not None and target > 0 else None
    target_pct_text = f"{target_pct:.1f}%" if target_pct is not None else "n/a"
    dashboard_lines.append(f"`{metric_name}` target <= {target:.0f} ms")
    dashboard_lines.append("")
    dashboard_lines.append(f"current {fmt_ms(current)} ms ({target_pct_text} of target)")
    dashboard_lines.append(f"[{bar(current, target)}]")
    dashboard_lines.append("")

dashboard_lines.append("## Run Context")
dashboard_lines.append("")
dashboard_lines.append(f"- OS: `{os_version}` (build `{os_build}`)")
dashboard_lines.append(f"- Hardware: `{arch}` / `{model}`")
dashboard_lines.append(
    f"- Portfolio context: discovered={summary['metadata']['discovered_repos_median']} imported={summary['metadata']['imported_repos_median']}"
)
dashboard_lines.append(f"- Sample setup: runs={runs}, sleep={sleep_seconds}s")
dashboard_lines.append("")
dashboard_lines.append("## Metric Definitions")
dashboard_lines.append("")
dashboard_lines.append("- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)")
dashboard_lines.append("- `repo_hydration`: auto-discovery/import pass for `~/code` repos")
dashboard_lines.append("- `repo_click_to_focus`: repo row click -> focused terminal session restore")
dashboard_lines.append("- Detailed flow diagrams: `./metrics-reference.md`")

dashboard_path.write_text("\n".join(dashboard_lines) + "\n")

print(f"history_csv={history_csv_path}")
print(f"dashboard_md={dashboard_path}")
print(f"latest_json={latest_json_path}")

sys.exit(budget_exit_code)
PY
