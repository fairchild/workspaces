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
  channel1_hook_ingest_burst
  channel1_sidebar_churn
  channel1_long_session_memory
  channel2_statusline_burst

Options:
  --scenario <id>         Canonical scenario id.
  --app <path>            App bundle or binary to use for installed scenarios.
  --output-dir <path>     Output directory. Default: /tmp/workspaces-perf-runner-<timestamp>/<scenario>
  --runs <n>              Debug/burst scenario run count. Default: 5.
  --sleep-seconds <n>     Debug scenario sleep per run. Default: 8.
  --capture-seconds <n>   Installed scenario capture length. Default: 12.
  --record                Pass through to perf-baseline.sh for debug scenarios.
  --assert-budget         Enforce the configured budget for the scenario.
  -h, --help              Show this help text.
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/perf-process.sh"
# Names the measurement protocol live captures run under. Must match the epoch
# perf-baseline.sh stamps, so debug and installed rows of the same era compare (#1251).
CURRENT_PROTOCOL_EPOCH="deterministic-delivery-v1"

# UserDefaults is the state axis WORKSPACES_DATA_DIR does not cover (#1251). The debug
# lane has isolated it since #1258; the installed lane did not, so an installed capture
# both read whatever the persistent com.cloudcompute.workspaces domain happened to hold
# — the non-determinism the epoch name claims to have removed — and wrote its own
# selection and restore state back into the domain the shipped app uses.
#
# Same ownership contract as perf-baseline.sh: a caller-provided suite is used as-is and
# never reset or removed, and only a suite this run invented is a suite this run may clear.
if [[ -n "${WORKSPACES_PREFERENCES_SUITE:-}" ]]; then
    PREFERENCES_SUITE="$WORKSPACES_PREFERENCES_SUITE"
    PREFERENCES_SUITE_OWNER="caller"
else
    PREFERENCES_SUITE="com.cloudcompute.workspaces.perf.$$-$(date +%Y%m%d%H%M%S)"
    PREFERENCES_SUITE_OWNER="lane"
fi

cleanup_preferences_suite() {
    [[ "$PREFERENCES_SUITE_OWNER" == "lane" ]] || return 0
    defaults delete "$PREFERENCES_SUITE" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$PREFERENCES_SUITE.plist"
}

# Exporting the suite states an intent; this reads back what the app actually resolved,
# the way perf-baseline.sh already does for the debug lane. Three things defeat the
# intent silently: an app build older than the environment variable, a reserved suite
# name (LaunchPreferences logs it and returns the persistent domain), and a defaults
# system that refuses the suite and falls back the same way. Each leaves a capture that
# is labelled isolated, measured against unknown starting state, and writing into the
# domain the shipped app uses — so a sample whose isolation cannot be shown is a harness
# failure rather than a slow launch, and the lane records nothing.
#
# `domain=scratch` alone is not proof: the refusal path logs that domain too. `isolated=`
# is the field that says which store actually backed the launch.
assert_preferences_isolated() {
    local log_file="$1" line domain isolated suite
    # `|| true` because a no-match grep exits 1, and under `set -e` with `pipefail` that
    # aborts the run at this assignment — failing closed, but silently, which is the one
    # thing this branch exists to avoid.
    line="$(grep -o '\[LaunchPreferences\] domain=.*' "$log_file" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
        echo "  [preferences] no [LaunchPreferences] line in $log_file" >&2
        echo "  [preferences] the app did not report which defaults domain backed the launch — an app" >&2
        echo "  [preferences] predating WORKSPACES_PREFERENCES_SUITE cannot be measured by this lane." >&2
        return 1
    fi
    # Field-anchored rather than a substring match: the suite name is free text and a
    # loose pattern would happily read a value out of the middle of one.
    read_field() {
        awk -v key="$1" '{for (i = 1; i <= NF; i++) if (index($i, key "=") == 1) print substr($i, length(key) + 2)}' <<<"$line"
    }
    domain="$(read_field domain)"
    isolated="$(read_field isolated)"
    suite="$(read_field suite)"

    if [[ "$domain" != "scratch" ]]; then
        echo "  [preferences] resolved domain=$domain, not the scratch suite — the launch read and wrote" >&2
        echo "  [preferences] the persistent com.cloudcompute.workspaces domain." >&2
        return 1
    fi
    if [[ "$isolated" != "true" ]]; then
        echo "  [preferences] domain=scratch but isolated=${isolated:-unreported} — the defaults system refused" >&2
        echo "  [preferences] suite '$PREFERENCES_SUITE' and the app fell back to the persistent domain." >&2
        return 1
    fi
    if [[ -n "$suite" && "$suite" != "$PREFERENCES_SUITE" ]]; then
        echo "  [preferences] launched against suite=$suite, expected $PREFERENCES_SUITE." >&2
        return 1
    fi
    echo "preferences_isolated=true suite=$PREFERENCES_SUITE"
}
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

    echo "preferences_suite=$PREFERENCES_SUITE (owner: $PREFERENCES_SUITE_OWNER)"
    WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" \
        WORKSPACES_PREFERENCES_SUITE="$PREFERENCES_SUITE" \
        "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
        "${launch_args[@]}" \
        "$@"

    assert_preferences_isolated "$log_file"

    summarize_installed_log "$log_file" "$summary_json" "$summary_txt" "$resolved_app_path"
}

summarize_installed_log() {
    local log_file="$1"
    local summary_json="$2"
    local summary_txt="$3"
    local app_path="$4"

    # A live capture ran under the current protocol; an archived log re-summarized later
    # does not, which is why the epoch is passed here rather than assumed by the summarizer.
    "$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
        --json \
        --scenario "$SCENARIO" \
        --build-kind installed \
        --app-path "$app_path" \
        --protocol-epoch "$CURRENT_PROTOCOL_EPOCH" \
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

    echo "preferences_suite=$PREFERENCES_SUITE (owner: $PREFERENCES_SUITE_OWNER)"
    WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" \
        WORKSPACES_PREFERENCES_SUITE="$PREFERENCES_SUITE" \
        "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
        --app "$resolved_app_path" \
        --login-shell \
        --with-input-diagnostics \
        --capture-seconds "$CAPTURE_SECONDS" \
        --log-file "$log_file"

    assert_preferences_isolated "$log_file"

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

run_channel() {
    local cmd=(
        "$ROOT_DIR/scripts/perf_channel_baseline.py"
        --scenario "$SCENARIO"
        --output-dir "$OUTPUT_DIR"
        --runs "$RUNS"
    )
    if [[ "$ASSERT_BUDGET" -eq 1 ]]; then
        cmd+=(--assert-budget)
    fi
    UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/workspaces-uv-cache}" "${cmd[@]}"
}

# Whole-run sweep. Each lane already gates its own teardown, but a scenario that
# exits early — an unsupported flag, a failed summarizer, an interrupt — skips
# that gate, and the survivor only reappears as a slower number in whatever runs
# next. Checked for both build kinds because a run can be pointed at either.
sweep_survivors() {
    local status=$?
    local label="perf-runner sweep"
    local binary
    for binary in \
        "$(normalize_installed_app_path "$APP_PATH")" \
        "$ROOT_DIR/.build/debug/WorkspaceManager"; do
        perf_assert_clean_exit "$binary" "$label" || status=1
    done
    # After the survivor check, so a lane that failed still drops the scratch suite it
    # invented rather than leaving a plist behind for every aborted run.
    cleanup_preferences_suite
    return "$status"
}
trap 'sweep_survivors || exit 1' EXIT

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
    channel1_hook_ingest_burst|channel1_sidebar_churn|channel1_long_session_memory|channel2_statusline_burst)
        run_channel
        ;;
    *)
        echo "Unsupported scenario: $SCENARIO" >&2
        usage
        exit 1
        ;;
esac
