#!/bin/bash
# ==========================================================================
# launch-dev.sh - Launch the latest local debug build with explicit data-root isolation
# ==========================================================================
#
# Why this script exists:
# - Avoid stale bundle confusion:
#   `build/WorkSpaces.app` can be outdated unless explicitly rebuilt/copied.
#   This script always launches `.build/arm64-apple-macosx/debug/WorkspaceManager`
#   after an optional `swift build`.
#
# - Dogfood isolation design:
#   We intentionally isolate app runtime state (SwiftData store + logs) into a
#   workspace-local directory by default (`.dev-data/workspacemanager`).
#   This mirrors our product direction in `backlog/isolation-strategies.md`:
#   explicit, inspectable runtime boundaries.
#
# Isolation model (important distinction):
# 1) Execution sandbox isolation:
#    An outer runner (agent/tooling/CI sandbox) can restrict process privileges.
#    Example: blocking writes to `~/Library/Application Support`.
#
# 2) App data-root isolation (this script):
#    We control where WorkspaceManager persists state via `WORKSPACES_DATA_DIR`.
#    This keeps state scoped, reproducible, and resettable per environment.
#
# Practical usage:
# - Default mode (recommended for dev + reproducibility):
#     ./scripts/launch-dev.sh
#   Builds and launches latest debug binary with local isolated data root.
#
# - Use host Application Support (less isolated, closer to installed behavior):
#     ./scripts/launch-dev.sh --use-app-support
#
# - UI fixture mode for deterministic screenshots:
#     ./scripts/launch-dev.sh --fixture --clean-data
#
# - Shared-desktop mode (do not steal foreground focus at launch):
#     ./scripts/launch-dev.sh --no-activate
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="WorkspaceManager"
INSTALLED_APP_BUNDLE_NAME="WorkSpaces"
DEBUG_BINARY="$REPO_ROOT/.build/arm64-apple-macosx/debug/$APP_NAME"
INSTALLED_APP_BINARY="/Applications/$INSTALLED_APP_BUNDLE_NAME.app/Contents/MacOS/$APP_NAME"
GHOSTTYKIT_FRAMEWORK="$REPO_ROOT/Frameworks/GhosttyKit.xcframework"
MISE_CONFIG_PATH="$REPO_ROOT/.mise.toml"
DEFAULT_DATA_DIR="$REPO_ROOT/.dev-data/workspacemanager"
LOG_DIR="$REPO_ROOT/.dev-data/logs"

DO_BUILD=true
KILL_EXISTING=true
RUN_IN_BACKGROUND=true
USE_APP_SUPPORT=false
FIXTURE_MODE=false
CLEAN_DATA=false
NO_ACTIVATE_ON_LAUNCH=false
TRUST_MISE=false
VERBOSE_BUILD=false
WATCH_LOG=false
WINDOW_TIMEOUT_SECONDS=10
DATA_DIR="$DEFAULT_DATA_DIR"
LOG_PATH=""
BUILD_LOG_PATH=""
APP_PID=""
WINDOW_ID=""
DIAGNOSTICS_DIR=""
declare -a ENV_VARS=()

usage() {
    cat <<'USAGE'
Usage: ./scripts/launch-dev.sh [options]

Options:
  --no-build           Skip swift build and launch existing debug binary
  --no-kill            Do not stop existing WorkspaceManager processes
  --foreground         Run attached to current terminal (no nohup)
  --use-app-support    Do not set WORKSPACES_DATA_DIR (use platform defaults)
  --data-dir <path>    Override isolated data root (default: ./.dev-data/workspacemanager)
  --fixture            Enable deterministic UI fixture mode
  --no-activate        Do not call NSApp.activate on startup (shared-desktop safe)
  --clean-data         Remove selected data dir before launch
  --env KEY=VALUE      Add an extra environment override (repeatable)
  --trust-mise         Trust this repo's .mise.toml before build/launch
  --verbose-build      Stream full swift build output instead of summarizing to a log
  --watch              Tail the launch log after successful startup until interrupted
  --window-timeout <s> Require a visible app window within this many seconds (default: 10)
  --help, -h           Show this help

Isolation notes:
- Default launch sets WORKSPACES_DATA_DIR to a workspace-local path.
- This simulates explicit state isolation and avoids leaking dev state into
  global user directories.
- It does not emulate full OS sandboxing; it isolates app persistence scope.
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                DO_BUILD=false
                shift
                ;;
            --no-kill)
                KILL_EXISTING=false
                shift
                ;;
            --foreground)
                RUN_IN_BACKGROUND=false
                shift
                ;;
            --use-app-support)
                USE_APP_SUPPORT=true
                shift
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || fail "--data-dir requires a value"
                DATA_DIR="$2"
                shift 2
                ;;
            --fixture)
                FIXTURE_MODE=true
                shift
                ;;
            --no-activate)
                NO_ACTIVATE_ON_LAUNCH=true
                shift
                ;;
            --clean-data)
                CLEAN_DATA=true
                shift
                ;;
            --env)
                [[ $# -ge 2 ]] || fail "--env requires KEY=VALUE"
                [[ "$2" == *=* ]] || fail "--env requires KEY=VALUE"
                ENV_VARS+=("$2")
                shift 2
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --verbose-build)
                VERBOSE_BUILD=true
                shift
                ;;
            --watch)
                WATCH_LOG=true
                shift
                ;;
            --window-timeout)
                [[ $# -ge 2 ]] || fail "--window-timeout requires a value"
                WINDOW_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

verify_repo_root() {
    if [[ ! -f "$REPO_ROOT/Package.swift" ]]; then
        fail "Package.swift not found at repo root: $REPO_ROOT"
    fi
}

preflight_mise_trust() {
    if [[ ! -f "$MISE_CONFIG_PATH" ]]; then
        return
    fi

    if ! command -v mise >/dev/null 2>&1; then
        return
    fi

    local trust_status
    trust_status="$(mise trust --show -C "$REPO_ROOT" 2>/dev/null || true)"
    if [[ "$trust_status" != *": untrusted"* ]]; then
        return
    fi

    if [[ "$TRUST_MISE" == true ]]; then
        log "Trusting repo mise config: $MISE_CONFIG_PATH"
        (
            cd "$REPO_ROOT"
            mise trust -y .mise.toml
        )
        return
    fi

    fail "Repo mise config is untrusted. Run 'mise trust $MISE_CONFIG_PATH' once, or rerun this script with --trust-mise."
}

ensure_ghosttykit_framework() {
    if [[ -d "$GHOSTTYKIT_FRAMEWORK" ]]; then
        return
    fi

    if [[ "$DO_BUILD" != true ]]; then
        fail "GhosttyKit.xcframework is missing at $GHOSTTYKIT_FRAMEWORK. Run ./scripts/build-ghosttykit.sh first or rerun without --no-build."
    fi

    log "GhosttyKit.xcframework missing. Building pinned GhosttyKit first..."
    (
        cd "$REPO_ROOT"
        ./scripts/build-ghosttykit.sh
    )
}

build_if_requested() {
    if [[ "$DO_BUILD" == true ]]; then
        ensure_ghosttykit_framework
        log "Building latest debug binary..."
        mkdir -p "$LOG_DIR"
        BUILD_LOG_PATH="$LOG_DIR/build-dev-$(date +%Y%m%d-%H%M%S).log"

        if [[ "$VERBOSE_BUILD" == true ]]; then
            (
                cd "$REPO_ROOT"
                swift build --product "$APP_NAME"
            )
            return
        fi

        if ! (
            cd "$REPO_ROOT"
            swift build --product "$APP_NAME" >"$BUILD_LOG_PATH" 2>&1
        ); then
            log "Build failed. Full build log: $BUILD_LOG_PATH"
            tail -n 80 "$BUILD_LOG_PATH" || true
            fail "WorkspaceManager build failed"
        fi

        local warning_count
        warning_count="$(rg -c "warning:" "$BUILD_LOG_PATH" 2>/dev/null || true)"
        if [[ -z "$warning_count" ]]; then
            warning_count=0
        fi

        if [[ "$warning_count" -gt 0 ]]; then
            log "Build complete with $warning_count warning(s). Full build log: $BUILD_LOG_PATH"
        else
            log "Build complete with no warnings."
        fi
    fi
}

verify_debug_binary() {
    if [[ ! -x "$DEBUG_BINARY" ]]; then
        fail "Debug binary not found: $DEBUG_BINARY"
    fi
}

list_instances_for_binary() {
    local binary_path="$1"
    ps -axo pid=,command= | awk -v target="$binary_path" '$2 == target { print $1 " " $2 }'
}

ensure_no_installed_app_instance() {
    local installed_instances
    installed_instances="$(list_instances_for_binary "$INSTALLED_APP_BINARY")"
    if [[ -n "$installed_instances" ]]; then
        log "Unexpected installed app instance detected:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  - $line"
        done <<< "$installed_instances"
        fail "Stale install process detected at $INSTALLED_APP_BINARY"
    fi
}

stop_existing_if_requested() {
    if [[ "$KILL_EXISTING" != true ]]; then
        return
    fi

    log "Stopping any running WorkspaceManager instances..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    pkill -f "$INSTALLED_APP_BINARY" >/dev/null 2>&1 || true
    pkill -f "$REPO_ROOT/build/WorkSpaces.app/Contents/MacOS/WorkspaceManager" >/dev/null 2>&1 || true
    # Legacy bundle name from before the public WorkSpaces rename.
    pkill -f "$REPO_ROOT/build/WorkspaceManager.app/Contents/MacOS/WorkspaceManager" >/dev/null 2>&1 || true
    pkill -f "$DEBUG_BINARY" >/dev/null 2>&1 || true
    sleep 1
}

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf "%s\n" "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf "%s\n" "$HOME/${path#~/}"
        return
    fi
    printf "%s\n" "$path"
}

configure_data_root() {
    if [[ "$USE_APP_SUPPORT" == true ]]; then
        return
    fi

    DATA_DIR="$(expand_home_prefix "$DATA_DIR")"
    ENV_VARS+=("WORKSPACES_DATA_DIR=$DATA_DIR")
    ENV_VARS+=("WORKSPACES_APP_VARIANT=dev")

    mkdir -p "$DATA_DIR"
    if [[ "$CLEAN_DATA" == true ]]; then
        log "Cleaning isolated data dir: $DATA_DIR"
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
    fi
}

configure_fixture_mode() {
    if [[ "$FIXTURE_MODE" == true ]]; then
        ENV_VARS+=("WORKSPACES_UI_FIXTURE=1")
        ENV_VARS+=("WORKSPACES_DISABLE_AUTO_IMPORT=1")
    fi
}

configure_launch_behavior() {
    if [[ "$NO_ACTIVATE_ON_LAUNCH" == true ]]; then
        ENV_VARS+=("WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1")
    fi
}

# Dev builds don't bundle Ghostty's themes/terminfo (only release does), so the
# in-app GhosttyResourcesLocator finds nothing unless GHOSTTY_RESOURCES_DIR
# points at a Ghostty share dir. Resolve one from the pinned checkout so the
# theme catalog + terminfo work in dev without an explicit flag. Mirrors
# build-release.sh's share-dir resolution; honors a user-provided value.
configure_ghostty_resources() {
    # Respect an explicit --env override or an inherited value.
    local entry
    for entry in "${ENV_VARS[@]}"; do
        [[ "$entry" == GHOSTTY_RESOURCES_DIR=* ]] && return
    done
    [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]] && return

    local -a share_candidates=()
    [[ -n "${GHOSTTY_SHARE_DIR:-}" ]] && share_candidates+=("$(expand_home_prefix "$GHOSTTY_SHARE_DIR")")
    [[ -n "${GHOSTTY_DIR:-}" ]] && share_candidates+=("$(expand_home_prefix "$GHOSTTY_DIR")/zig-out/share")
    share_candidates+=("$HOME/.cache/workspacemanager/ghostty/zig-out/share")

    local share
    for share in "${share_candidates[@]}"; do
        if [[ -d "$share/ghostty/themes" && -f "$share/terminfo/78/xterm-ghostty" ]]; then
            ENV_VARS+=("GHOSTTY_RESOURCES_DIR=$share/ghostty")
            log "Using Ghostty resources: $share/ghostty"
            return
        fi
    done

    log "Ghostty resources dir not found; terminal themes/terminfo may be unavailable in this dev launch."
}

prepare_log_path() {
    mkdir -p "$LOG_DIR"
    LOG_PATH="$LOG_DIR/launch-dev-$(date +%Y%m%d-%H%M%S).log"
}

prepare_diagnostics_dir() {
    if [[ -n "$DIAGNOSTICS_DIR" ]]; then
        printf "%s\n" "$DIAGNOSTICS_DIR"
        return
    fi

    mkdir -p "$LOG_DIR"
    DIAGNOSTICS_DIR="$LOG_DIR/launch-diagnostics-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DIAGNOSTICS_DIR"
    printf "%s\n" "$DIAGNOSTICS_DIR"
}

latest_crash_report_path() {
    local reports_dir="$HOME/Library/Logs/DiagnosticReports"
    [[ -d "$reports_dir" ]] || return 1

    local latest_report
    latest_report="$(
        find "$reports_dir" -maxdepth 1 -type f \( -name 'WorkspaceManager*.crash' -o -name 'WorkspaceManager*.ips' \) \
            -print0 2>/dev/null \
            | xargs -0 ls -1t 2>/dev/null \
            | head -n 1
    )"

    [[ -n "$latest_report" ]] || return 1
    printf "%s\n" "$latest_report"
}

write_diagnostics_bundle() {
    local reason="$1"
    local diagnostics_dir
    diagnostics_dir="$(prepare_diagnostics_dir)"

    printf "%s\n" "$reason" >"$diagnostics_dir/reason.txt"
    printf "app_pid=%s\nwindow_id=%s\nlog_path=%s\n" "$APP_PID" "${WINDOW_ID:-unknown}" "$LOG_PATH" \
        >"$diagnostics_dir/context.txt"

    tail -n 120 "$LOG_PATH" >"$diagnostics_dir/launch-tail.log" 2>/dev/null || true
    ps -p "$APP_PID" -o pid=,ppid=,etime=,state=,command= >"$diagnostics_dir/process.txt" 2>/dev/null || true
    /usr/bin/log show --style compact --last 3m --predicate 'process == "WorkspaceManager"' \
        >"$diagnostics_dir/unified.log" 2>/dev/null || true

    local crash_report
    if crash_report="$(latest_crash_report_path)"; then
        cp "$crash_report" "$diagnostics_dir/$(basename "$crash_report")" 2>/dev/null || true
    fi

    printf "%s\n" "$diagnostics_dir"
}

print_launch_plan() {
    log "Launching: $DEBUG_BINARY"
    if [[ "$NO_ACTIVATE_ON_LAUNCH" == true ]]; then
        log "Launch mode: shared-desktop-safe (--no-activate)"
    else
        log "Launch mode: interactive (activation allowed)"
    fi
    if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
        log "Environment overrides:"
        for entry in "${ENV_VARS[@]}"; do
            log "  - $entry"
        done
    else
        log "Environment overrides: (none)"
    fi
}

dump_recent_log_and_fail() {
    local reason="$1"
    local diagnostics_dir
    diagnostics_dir="$(write_diagnostics_bundle "$reason")"
    log "$reason"
    tail -n 40 "$LOG_PATH" || true
    log "Diagnostics bundle: $diagnostics_dir"
    fail "WorkspaceManager exited during startup"
}

read_window_id() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    if let windowID = window[kCGWindowNumber as String] as? Int {
        print(windowID)
        exit(0)
    }
}

exit(1)
SWIFT
}

wait_for_visible_window() {
    local attempt=0
    local win_id=""

    while (( attempt < WINDOW_TIMEOUT_SECONDS )); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            dump_recent_log_and_fail "Launch failed before a window appeared."
        fi

        if win_id="$(read_window_id 2>/dev/null)"; then
            WINDOW_ID="$win_id"
            return
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    dump_recent_log_and_fail "Launch failed: no visible WorkspaceManager window appeared within ${WINDOW_TIMEOUT_SECONDS}s."
}

verify_background_process() {
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        dump_recent_log_and_fail "Launch failed. Last log lines:"
    fi

    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        dump_recent_log_and_fail "Launch failed during warmup. Last log lines:"
    fi

    if [[ "${WORKSPACES_LAUNCH_DEV_SKIP_PROCESS_VERIFY:-0}" == "1" ]]; then
        log "Skipping ps-based process verification due to WORKSPACES_LAUNCH_DEV_SKIP_PROCESS_VERIFY=1"
    else
        local app_command
        app_command="$(ps -p "$APP_PID" -o command= | sed -e 's/^[[:space:]]*//')"
        if [[ "$app_command" != "$DEBUG_BINARY" && "$app_command" != "$DEBUG_BINARY "* ]]; then
            log "Unexpected executable for pid=$APP_PID: $app_command"
            fail "Launch verification failed: running process is not debug binary"
        fi

        ensure_no_installed_app_instance

        # Guardrail against stale app confusion: surface any other WorkspaceManager
        # processes that are not our expected debug binary.
        local other_instances
        other_instances="$(ps -axo pid=,command= | awk -v expected="$DEBUG_BINARY" '$2 ~ /WorkspaceManager$/ && $2 != expected { print $1 " " $2 }')"
        if [[ -n "$other_instances" ]]; then
            log "Warning: additional WorkspaceManager processes detected:"
            while IFS= read -r line; do
                [[ -n "$line" ]] && log "  - $line"
            done <<< "$other_instances"
        fi
    fi

    wait_for_visible_window
}

launch_background() {
    pushd "$REPO_ROOT" >/dev/null
    nohup env "${ENV_VARS[@]}" "$DEBUG_BINARY" >"$LOG_PATH" 2>&1 &
    APP_PID=$!
    popd >/dev/null

    verify_background_process
    log "WorkspaceManager running (pid=$APP_PID)"
    log "Verified executable path: $DEBUG_BINARY"
    log "Verified visible window id: $WINDOW_ID"
    log "Log file: $LOG_PATH"
    if [[ "$NO_ACTIVATE_ON_LAUNCH" == true ]]; then
        log "Shared-desktop follow-up: capture with ./scripts/capture-window.sh while leaving the app in the background."
    fi
}

launch_foreground() {
    log "Foreground mode. Logs will stream in this terminal."
    ensure_no_installed_app_instance
    (
        cd "$REPO_ROOT"
        exec env "${ENV_VARS[@]}" "$DEBUG_BINARY"
    )
}

watch_log_if_requested() {
    if [[ "$WATCH_LOG" != true ]]; then
        return
    fi

    log "Watching $LOG_PATH (Ctrl-C to stop)..."
    tail -n +1 -f "$LOG_PATH" &
    local tail_pid=$!

    trap 'kill "$tail_pid" >/dev/null 2>&1 || true; exit 0' INT TERM

    while kill -0 "$tail_pid" >/dev/null 2>&1; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            local diagnostics_dir
            diagnostics_dir="$(write_diagnostics_bundle "WorkspaceManager exited while watch mode was active.")"
            log "WorkspaceManager exited while watch mode was active."
            log "Diagnostics bundle: $diagnostics_dir"
            break
        fi

        sleep 1
    done

    kill "$tail_pid" >/dev/null 2>&1 || true
    wait "$tail_pid" 2>/dev/null || true
    trap - INT TERM
}

main() {
    parse_args "$@"
    verify_repo_root
    if [[ "$RUN_IN_BACKGROUND" != true && "$WATCH_LOG" == true ]]; then
        fail "--watch is only supported in background mode"
    fi
    preflight_mise_trust
    build_if_requested
    verify_debug_binary
    stop_existing_if_requested
    configure_data_root
    configure_fixture_mode
    configure_launch_behavior
    configure_ghostty_resources
    prepare_log_path
    print_launch_plan

    if [[ "$RUN_IN_BACKGROUND" == true ]]; then
        launch_background
        watch_log_if_requested
    else
        launch_foreground
    fi
}

main "$@"
