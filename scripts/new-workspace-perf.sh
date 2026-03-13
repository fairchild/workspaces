#!/bin/bash
# Capture New Workspace sheet-open perf baselines from production signpost logs.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/new-workspace-perf.sh [runs] [sleep_seconds]

Examples:
  ./scripts/new-workspace-perf.sh
  ./scripts/new-workspace-perf.sh 5 12
EOF
}

RUNS=5
SLEEP_SECONDS=12
POSITIONAL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
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
OUTPUT_DIR="/tmp/workspaces-new-workspace-perf-$(date +%Y%m%d-%H%M%S)"
PERF_DATA_DIR="$OUTPUT_DIR/app-data"
DEBUG_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/debug/WorkspaceManager"

mkdir -p "$OUTPUT_DIR" "$PERF_DATA_DIR"

echo "WorkspaceManager New Workspace perf baseline"
echo "  runs: $RUNS"
echo "  sleep per run: ${SLEEP_SECONDS}s"
echo "  output: $OUTPUT_DIR"
echo "  data dir: $PERF_DATA_DIR"

for i in $(seq 1 "$RUNS"); do
    LOG_FILE="$OUTPUT_DIR/run-$i.log"
    echo "[$i/$RUNS] Launching app..."

    pkill -f "$DEBUG_BINARY" 2>/dev/null || true
    sleep 1

    (
        cd "$ROOT_DIR"
        WORKSPACES_DATA_DIR="$PERF_DATA_DIR" \
        WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 \
        WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 \
        WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE=1 \
        swift run WorkspaceManager >"$LOG_FILE" 2>&1
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

python3 - "$OUTPUT_DIR" "$RUNS" "$SLEEP_SECONDS" "$TIMESTAMP" "$OS_VERSION" "$OS_BUILD" "$ARCH" "$MODEL" <<'PY'
import json
import pathlib
import re
import statistics
import sys

out_dir = pathlib.Path(sys.argv[1])
runs = int(sys.argv[2])
sleep_seconds = int(sys.argv[3])
timestamp = sys.argv[4]
os_version = sys.argv[5]
os_build = sys.argv[6]
arch = sys.argv[7]
model = sys.argv[8]

line_pattern = re.compile(r"metric=([a-z_]+)")
duration_pattern = re.compile(r"duration_ms=([0-9]+(?:\.[0-9]+)?)")
trigger_pattern = re.compile(r"trigger=([A-Za-z0-9_]+)")
outcome_pattern = re.compile(r"outcome=([A-Za-z0-9_]+)")
executable_pattern = re.compile(r"executable=([A-Za-z0-9_.-]+)")

metric_order = [
    "new_workspace_sheet_ready",
    "workspace_provider_availability_refresh",
    "lume_runtime_snapshot_refresh",
    "lume_runtime_snapshot",
    "lume_runtime_daemon_reachability",
    "lume_runtime_host_profile",
    "lume_runtime_base_vm_inspection",
]
metric_values: dict[str, list[float]] = {name: [] for name in metric_order}
metric_values["lume_runtime_host_command.sw_vers"] = []
metric_values["lume_runtime_host_command.xcodebuild"] = []
metric_values["lume_runtime_host_command.xcode-select"] = []
new_workspace_triggers: list[str] = []

for log_file in sorted(out_dir.glob("run-*.log")):
    for line in log_file.read_text(errors="ignore").splitlines():
        if "[Perf]" not in line:
            continue
        metric_match = line_pattern.search(line)
        duration_match = duration_pattern.search(line)
        if metric_match is None or duration_match is None:
            continue

        metric = metric_match.group(1)
        duration = float(duration_match.group(1))

        if metric == "new_workspace_sheet_ready":
            outcome_match = outcome_pattern.search(line)
            if outcome_match is None or outcome_match.group(1) != "success":
                continue
            trigger_match = trigger_pattern.search(line)
            if trigger_match is not None:
                new_workspace_triggers.append(trigger_match.group(1))
            metric_values[metric].append(duration)
            continue

        if metric == "lume_runtime_host_command":
            executable_match = executable_pattern.search(line)
            if executable_match is None:
                continue
            key = f"lume_runtime_host_command.{executable_match.group(1)}"
            metric_values.setdefault(key, []).append(duration)
            continue

        if metric in metric_values:
            metric_values[metric].append(duration)


def summarize(values: list[float]):
    if not values:
        return None
    return {
        "n": len(values),
        "min": min(values),
        "max": max(values),
        "median": statistics.median(values),
        "mean": statistics.mean(values),
    }


summary = {
    "metadata": {
        "timestamp": timestamp,
        "runs_requested": runs,
        "sleep_seconds": sleep_seconds,
        "os_version": os_version,
        "os_build": os_build,
        "arch": arch,
        "model": model,
        "new_workspace_sheet_triggers": sorted(set(new_workspace_triggers)),
    },
    "metrics": {
        metric: summarize(values)
        for metric, values in metric_values.items()
    },
}

summary_lines = []
for metric in [
    "new_workspace_sheet_ready",
    "workspace_provider_availability_refresh",
    "lume_runtime_snapshot_refresh",
    "lume_runtime_snapshot",
    "lume_runtime_daemon_reachability",
    "lume_runtime_host_profile",
    "lume_runtime_host_command.sw_vers",
    "lume_runtime_host_command.xcodebuild",
    "lume_runtime_host_command.xcode-select",
    "lume_runtime_base_vm_inspection",
]:
    stats = summary["metrics"].get(metric)
    if stats is None:
        summary_lines.append(f"{metric}: missing")
        continue
    summary_lines.append(
        f"{metric}: n={stats['n']} min={stats['min']:.2f} max={stats['max']:.2f} "
        f"median={stats['median']:.2f} mean={stats['mean']:.2f}"
    )

summary_lines.append(
    "new_workspace_sheet_triggers: "
    + (", ".join(summary["metadata"]["new_workspace_sheet_triggers"]) or "missing")
)

summary_path = out_dir / "summary.txt"
summary_json_path = out_dir / "summary.json"
summary_path.write_text("\n".join(summary_lines) + "\n")
summary_json_path.write_text(json.dumps(summary, indent=2) + "\n")

print(summary_path)
print("\n".join(summary_lines))
print(f"summary_json={summary_json_path}")
PY
