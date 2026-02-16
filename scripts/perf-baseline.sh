#!/bin/bash
# Capture launch/hydration/repo-focus perf baselines from production signpost logs.
# Optional: record results into docs/performance history + dashboard.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/perf-baseline.sh [runs] [sleep_seconds] [--record]

Examples:
  ./scripts/perf-baseline.sh
  ./scripts/perf-baseline.sh 5 8
  ./scripts/perf-baseline.sh 5 8 --record

Notes:
  - --record appends results to docs/performance/metrics-history.csv
  - --record regenerates docs/performance/dashboard.md
EOF
}

RUNS=5
SLEEP_SECONDS=8
RECORD=0
POSITIONAL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)
            RECORD=1
            shift
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

mkdir -p "$OUTPUT_DIR"

echo "WorkspaceManager perf baseline"
echo "  runs: $RUNS"
echo "  sleep per run: ${SLEEP_SECONDS}s"
echo "  record in repo docs: $RECORD"
echo "  output: $OUTPUT_DIR"

for i in $(seq 1 "$RUNS"); do
    LOG_FILE="$OUTPUT_DIR/run-$i.log"
    echo "[$i/$RUNS] Launching app..."

    pkill -f "WorkspaceManager" 2>/dev/null || true
    sleep 1

    (
        cd "$ROOT_DIR"
        WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 swift run WorkspaceManager >"$LOG_FILE" 2>&1
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

python3 - "$OUTPUT_DIR" "$ROOT_DIR" "$RUNS" "$SLEEP_SECONDS" "$RECORD" "$TIMESTAMP" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" <<'PY'
import csv
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

duration_pattern = re.compile(r"metric=([a-z_]+) duration_ms=([0-9]+(?:\.[0-9]+)?)")
hydration_meta_pattern = re.compile(
    r"metric=repo_hydration duration_ms=[0-9]+(?:\.[0-9]+)? discovered=(\d+) imported=(\d+)"
)

metric_order = [
    "launch_to_first_prompt",
    "repo_hydration",
    "repo_click_to_focus",
]
metrics = {name: [] for name in metric_order}
discovered_values = []
imported_values = []

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
    "os_version": os_version,
    "os_build": os_build,
    "arch": arch,
    "model": model,
    "discovered_repos_median": int(statistics.median(discovered_values)) if discovered_values else None,
    "imported_repos_median": int(statistics.median(imported_values)) if imported_values else None,
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
print("\n".join(summary_lines))
print(f"summary_json={summary_json_path}")

if not record:
    sys.exit(0)

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
}

write_header = not history_csv_path.exists()
with history_csv_path.open("a", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    if write_header:
        writer.writeheader()
    writer.writerow(record_row)

rows = []
with history_csv_path.open(newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

metric_specs = [
    ("launch_to_first_prompt_median_ms", "launch_to_first_prompt", 250.0),
    ("repo_hydration_median_ms", "repo_hydration", 25.0),
    ("repo_click_to_focus_median_ms", "repo_click_to_focus", 250.0),
]

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
PY
