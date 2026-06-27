#!/bin/bash
# Run a canonical Workspaces performance scenario and emit summary artifacts.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/perf-runner.sh --scenario <id> [options]

Scenarios:
  debug_no_activate
  debug_activate
  installed_clean_shell
  installed_login_shell
  installed_input_short_capture
  main_window_agent_activity_burst
  main_window_session_switcher_snapshot
  main_window_workspace_create_ui_stall
  main_window_idle_cpu_diagnostics_closed
  main_window_resident_memory_20_workspaces

Options:
  --scenario <id>         Canonical scenario id.
  --app <path>            App bundle or binary to use for installed scenarios.
  --output-dir <path>     Output directory. Default: /tmp/workspaces-perf-runner-<timestamp>/<scenario>
  --runs <n>              Debug scenario run count. Default: 5.
  --sleep-seconds <n>     Debug scenario sleep per run. Default: 8.
  --capture-seconds <n>   Installed scenario capture length. Default: 12.
  --record                Pass through to perf-baseline.sh for debug scenarios.
  --assert-budget         Enforce the configured budget for the scenario.
  -h, --help              Show this help text.
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO=""
APP_PATH="/Applications/WorkSpaces.app/Contents/MacOS/WorkspaceManager"
RUNS=5
SLEEP_SECONDS=8
CAPTURE_SECONDS=12
RECORD=0
ASSERT_BUDGET=0
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --app)
            APP_PATH="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --sleep-seconds)
            SLEEP_SECONDS="$2"
            shift 2
            ;;
        --capture-seconds)
            CAPTURE_SECONDS="$2"
            shift 2
            ;;
        --record)
            RECORD=1
            shift
            ;;
        --assert-budget)
            ASSERT_BUDGET=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$SCENARIO" ]]; then
    echo "--scenario is required" >&2
    usage
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/tmp/workspaces-perf-runner-$(date +%Y%m%d-%H%M%S)/$SCENARIO"
fi
mkdir -p "$OUTPUT_DIR"

normalize_installed_app_path() {
    local candidate="${1%/}"
    if [[ -d "$candidate" && "$candidate" == *.app ]]; then
        local binary="$candidate/Contents/MacOS/WorkspaceManager"
        if [[ ! -x "$binary" ]]; then
            echo "App bundle binary not found or not executable: $binary" >&2
            exit 1
        fi
        printf '%s\n' "$binary"
        return
    fi
    printf '%s\n' "$candidate"
}

run_debug() {
    local launch_mode="$1"
    local latest_before=""
    latest_before="$(ls -td /tmp/workspaces-perf-baseline-* 2>/dev/null | head -n 1 || true)"
    local cmd=("$ROOT_DIR/scripts/perf-baseline.sh" "$RUNS" "$SLEEP_SECONDS" "--launch-mode" "$launch_mode")
    if [[ "$RECORD" -eq 1 ]]; then
        cmd+=("--record")
    fi
    if [[ "$ASSERT_BUDGET" -eq 1 ]]; then
        cmd+=("--assert-budget")
    fi
    local status=0
    "${cmd[@]}" || status=$?

    local latest_after=""
    latest_after="$(ls -td /tmp/workspaces-perf-baseline-* 2>/dev/null | head -n 1 || true)"
    if [[ -n "$latest_after" && "$latest_after" != "$latest_before" ]]; then
        rm -rf "$OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
        cp -R "$latest_after"/. "$OUTPUT_DIR"/
        echo "copied_artifacts=$OUTPUT_DIR"
    fi
    return "$status"
}

run_installed() {
    local shell_mode_flag="$1"
    local activate_mode="${2:-no-activate}"
    shift 2
    local resolved_app_path
    resolved_app_path="$(normalize_installed_app_path "$APP_PATH")"
    local log_file="$OUTPUT_DIR/$SCENARIO.log"
    local summary_json="$OUTPUT_DIR/summary.json"
    local summary_txt="$OUTPUT_DIR/summary.txt"
    mkdir -p "$OUTPUT_DIR/app-data"

    local launch_args=(
        --app "$resolved_app_path"
        "$shell_mode_flag"
        --capture-seconds "$CAPTURE_SECONDS"
        --log-file "$log_file"
    )
    if [[ "$activate_mode" == "no-activate" ]]; then
        launch_args+=(--no-activate)
    fi

    WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
        "${launch_args[@]}" \
        "$@"

    summarize_installed_log "$log_file" "$summary_json" "$summary_txt" "$resolved_app_path"
}

summarize_installed_log() {
    local log_file="$1"
    local summary_json="$2"
    local summary_txt="$3"
    local app_path="$4"

    "$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
        --json \
        --scenario "$SCENARIO" \
        --build-kind installed \
        --app-path "$app_path" \
        "$log_file" >"$summary_json"

    "$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
        --scenario "$SCENARIO" \
        --build-kind installed \
        --app-path "$app_path" \
        "$log_file" >"$summary_txt"

    echo "summary_json=$summary_json"
    echo "summary_txt=$summary_txt"
    echo "log_file=$log_file"
}

run_installed_input_short_capture() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "installed_input_short_capture requires an interactive terminal and focused manual typing." >&2
        echo "Run this scenario from a local terminal session so Workspaces can activate and receive input." >&2
        exit 1
    fi

    local resolved_app_path
    resolved_app_path="$(normalize_installed_app_path "$APP_PATH")"
    local log_file="$OUTPUT_DIR/$SCENARIO.log"
    local summary_json="$OUTPUT_DIR/summary.json"
    local summary_txt="$OUTPUT_DIR/summary.txt"
    mkdir -p "$OUTPUT_DIR/app-data"

    echo "Interactive capture: Workspaces will activate and run for $CAPTURE_SECONDS seconds."
    echo "Type in the focused terminal during that window to produce input metrics."

    WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
        --app "$resolved_app_path" \
        --login-shell \
        --with-input-diagnostics \
        --capture-seconds "$CAPTURE_SECONDS" \
        --log-file "$log_file"

    summarize_installed_log "$log_file" "$summary_json" "$summary_txt" "$resolved_app_path"

    python3 - "$summary_json" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
metrics = summary.get("metrics", {})
missing = [
    metric
    for metric in ("input_event_age_ms_median", "input_handler_duration_ms_median")
    if metric not in metrics
]
if missing:
    raise SystemExit(
        "interactive input capture did not produce canonical input metrics: "
        + ", ".join(missing)
    )
PY
}

run_main_window_hotspot() {
    local cmd=(
        "$ROOT_DIR/scripts/main-window-hotspots-baseline.py"
        --scenario "$SCENARIO"
        --output-dir "$OUTPUT_DIR"
        --runs "$RUNS"
        --sleep-seconds "$SLEEP_SECONDS"
        --sample-seconds "$CAPTURE_SECONDS"
    )
    if [[ "$ASSERT_BUDGET" -eq 1 ]]; then
        cmd+=(--assert-budget)
    fi
    UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/workspaces-uv-cache}" "${cmd[@]}"
}

case "$SCENARIO" in
    debug_no_activate)
        run_debug "no-activate"
        ;;
    debug_activate)
        run_debug "activate"
        ;;
    installed_clean_shell)
        run_installed "--clean-shell" "no-activate"
        ;;
    installed_login_shell)
        run_installed "--login-shell" "no-activate"
        ;;
    installed_input_short_capture)
        run_installed_input_short_capture
        ;;
    main_window_agent_activity_burst|main_window_session_switcher_snapshot|main_window_workspace_create_ui_stall|main_window_idle_cpu_diagnostics_closed|main_window_resident_memory_20_workspaces)
        run_main_window_hotspot
        ;;
    *)
        echo "Unsupported scenario: $SCENARIO" >&2
        usage
        exit 1
        ;;
esac
