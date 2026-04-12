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
APP_PATH="/Applications/WorkspaceManager.app/Contents/MacOS/WorkspaceManager"
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
    "${cmd[@]}"

    local latest_after=""
    latest_after="$(ls -td /tmp/workspaces-perf-baseline-* 2>/dev/null | head -n 1 || true)"
    if [[ -n "$latest_after" && "$latest_after" != "$latest_before" ]]; then
        rm -rf "$OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
        cp -R "$latest_after"/. "$OUTPUT_DIR"/
        echo "copied_artifacts=$OUTPUT_DIR"
    fi
}

run_installed() {
    local shell_mode_flag="$1"
    shift
    local log_file="$OUTPUT_DIR/$SCENARIO.log"
    local summary_json="$OUTPUT_DIR/summary.json"
    local summary_txt="$OUTPUT_DIR/summary.txt"
    mkdir -p "$OUTPUT_DIR/app-data"

    WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
        --app "$APP_PATH" \
        "$shell_mode_flag" \
        --no-activate \
        --capture-seconds "$CAPTURE_SECONDS" \
        "$@" \
        --log-file "$log_file"

    "$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
        --json \
        --scenario "$SCENARIO" \
        --build-kind installed \
        --app-path "$APP_PATH" \
        "$log_file" >"$summary_json"

    "$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
        --scenario "$SCENARIO" \
        --build-kind installed \
        --app-path "$APP_PATH" \
        "$log_file" >"$summary_txt"

    echo "summary_json=$summary_json"
    echo "summary_txt=$summary_txt"
    echo "log_file=$log_file"
}

case "$SCENARIO" in
    debug_no_activate)
        run_debug "no-activate"
        ;;
    debug_activate)
        run_debug "activate"
        ;;
    installed_clean_shell)
        run_installed "--clean-shell"
        ;;
    installed_login_shell)
        run_installed "--login-shell"
        ;;
    installed_input_short_capture)
        run_installed "--login-shell" "--with-input-diagnostics"
        ;;
    *)
        echo "Unsupported scenario: $SCENARIO" >&2
        usage
        exit 1
        ;;
esac
