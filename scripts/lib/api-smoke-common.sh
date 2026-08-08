#!/bin/bash
# ==========================================================================
# api-smoke-common.sh - shared setup/teardown for the api/desktop smoke family
# ==========================================================================
#
# scripts/api-create-smoke.sh, scripts/api-select-smoke.sh,
# scripts/api-desktop-ui-smoke.sh, and scripts/desktop-ui-smoke.sh each drove
# the debug app through a near-identical launch/cleanup harness (#1236).
# This is the one copy: run-dir + synthetic-root setup, disposable-repo
# fixture, app launch/kill, and a single unconditional-cleanup finalize path
# built on #1247's trap/finalize shape.
#
# Cleanup here is unconditional by design: it runs on every outcome (pass,
# fail, signal) — a failing run is when leftover app processes and worktrees
# cost the most, so `--keep-artifacts` is the only opt-out, not RUN_STATUS.
#
# api-select-smoke.sh deliberately keeps its own local read_workspace_field/
# event_index/wait_for_event and post-select assertion logic rather than
# routing through smoke_read_event_field below — that region overlaps
# in-flight work in PR #1265 (typed wait primitives), so this lib only
# touches api-select-smoke.sh's setup/teardown blocks.
#
# Callers: `set -euo pipefail`, define SCRIPT_DIR/REPO_ROOT, then
# `source "$SCRIPT_DIR/lib/api-smoke-common.sh"` (which sources
# synthetic-root.sh in turn — no separate source line needed).

SMOKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=synthetic-root.sh
source "$SMOKE_LIB_DIR/synthetic-root.sh"

smoke_log() {
    echo "[$(date +%H:%M:%S)] $*"
}

smoke_fail() {
    echo "ERROR: $*" >&2
    FAILURE_MESSAGE="$*"
    exit 1
}

# smoke_init — reset per-run state to its starting values and stamp
# STARTED_AT. Call once at the top of main(), right after parse_args.
smoke_init() {
    RUN_STATUS="failed"
    FAILURE_MESSAGE=""
    FINALIZED=false
    APP_PID=""
    LAUNCH_LOG_PATH=""
    SMOKE_REPO_PATH=""
    STARTED_AT="$(date +%s)"
}

# smoke_setup_run_dir — create the run dir, point `latest` at it, and
# establish the WORKSPACES_SYNTHETIC_ROOT isolation boundary inside it (so a
# created worktree can never leak into the owner's real ~/workspaces).
# Requires RUN_DIR/RUN_LINK; sets EVENTS_PATH.
smoke_setup_run_dir() {
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$RUN_LINK"
    EVENTS_PATH="$RUN_DIR/events.jsonl"
    synthetic_root_ensure "$RUN_DIR/workspaces-root" \
        || smoke_fail "Could not establish WORKSPACES_SYNTHETIC_ROOT."
}

# smoke_create_disposable_repo <readme-label> — a throwaway git repo inside
# the run dir (so a red run leaves zero residue outside it). Sets
# SMOKE_REPO_PATH. Requires RUN_DIR/TIMESTAMP.
smoke_create_disposable_repo() {
    local label="$1"
    SMOKE_REPO_PATH="$(mktemp -d "$RUN_DIR/smoke-repo-XXXXXX")"
    (
        cd "$SMOKE_REPO_PATH" || exit 1
        git init >/dev/null
        git config user.name "WorkspaceManager Smoke" >/dev/null
        git config user.email "smoke@local.invalid" >/dev/null
        printf "# %s\n\nCreated %s\n" "$label" "$TIMESTAMP" >README.md
        git add README.md
        git commit -m "Initial smoke fixture" >/dev/null
    )
}

# smoke_launch_app [--env KEY=VALUE]... — launch the debug app headless-safe
# with the isolation boundary and milestone-stream env wired; any extra
# arguments are appended verbatim to launch-dev.sh's argv (each lane's own
# --env pairs, e.g. the automation driver selection). Sets APP_PID and
# LAUNCH_LOG_PATH from the launch output. Requires LAUNCH_SCRIPT/REPO_ROOT/
# RUN_DIR/SKIP_BUILD/WORKSPACE_NAME/EVENTS_PATH/SMOKE_REPO_PATH.
smoke_launch_app() {
    synthetic_root_require || smoke_fail "Refusing to launch without WORKSPACES_SYNTHETIC_ROOT."
    local app_data_dir="$RUN_DIR/app-data"
    local -a args=(
        "--no-activate"
        "--data-dir" "$app_data_dir"
        "--clean-data"
        "--window-timeout" "20"
        "--env" "WORKSPACES_DISABLE_AUTO_IMPORT=1"
        "--env" "WORKSPACES_SYNTHETIC_ROOT=$WORKSPACES_SYNTHETIC_ROOT"
        "--env" "WORKSPACES_AUTOMATION_MODE=desktop-ui-smoke"
        "--env" "WORKSPACES_AUTOMATION_REPO_PATH=$SMOKE_REPO_PATH"
        "--env" "WORKSPACES_AUTOMATION_WORKSPACE_NAME=$WORKSPACE_NAME"
        "--env" "WORKSPACES_AUTOMATION_EVENTS_PATH=$EVENTS_PATH"
    )
    local extra
    for extra in "$@"; do
        args+=("--env" "$extra")
    done
    [[ "$SKIP_BUILD" == true ]] && args+=("--no-build")

    local launch_output
    launch_output="$(
        cd "$REPO_ROOT" || exit 1
        "$LAUNCH_SCRIPT" "${args[@]}" 2>&1 | tee "$RUN_DIR/launch-command.log"
    )"
    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    LAUNCH_LOG_PATH="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"
    [[ -n "$APP_PID" ]] || smoke_fail "Could not determine WorkspaceManager pid from launch output."
}

smoke_cleanup_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        sleep 1
    fi
    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
}

smoke_cleanup_repo() {
    [[ "$KEEP_ARTIFACTS" == true ]] && return 0
    if [[ -n "$SMOKE_REPO_PATH" && -d "$SMOKE_REPO_PATH" ]]; then
        chmod -R u+w "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
        rm -rf "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
    fi
}

# smoke_cleanup_created_worktree — the app creates the workspace as a git
# worktree under the synthetic workspaces root inside the run dir; remove it
# using the path the app reported in the workspace_created milestone. Tolerant
# of a torn/missing events.jsonl (app killed before writing anything).
smoke_cleanup_created_worktree() {
    [[ "$KEEP_ARTIFACTS" == true ]] && return 0
    [[ -f "$EVENTS_PATH" ]] || return 0
    local workspace_path
    workspace_path="$(smoke_read_event_field workspacePath workspace_created)"
    [[ -n "$workspace_path" && -d "$workspace_path" ]] || return 0

    # Refuse to act on a path outside this run's own isolation boundary — a
    # reused/stale events.jsonl must never make cleanup follow a workspacePath
    # outside WORKSPACES_SYNTHETIC_ROOT (the #1245 boundary). An unset boundary
    # (setup never got far enough to export it) fails safe the same way: skip.
    case "$workspace_path" in
        "${WORKSPACES_SYNTHETIC_ROOT:-/dev/null/unset}"/*) ;;
        *)
            echo "warning: workspace_created reported a path outside WORKSPACES_SYNTHETIC_ROOT ($workspace_path) — skipping its cleanup." >&2
            return 0
            ;;
    esac

    chmod -R u+w "$workspace_path" >/dev/null 2>&1 || true
    rm -rf "$workspace_path" >/dev/null 2>&1 || true

    # Prune the now-empty per-repo container the worktree lived in.
    local repo_container
    repo_container="$(dirname "$workspace_path")"
    if [[ -d "$repo_container" && -z "$(ls -A "$repo_container" 2>/dev/null)" ]]; then
        rmdir "$repo_container" >/dev/null 2>&1 || true
    fi
}

# smoke_read_event_field <field> <event-type> — last value of <field> on an
# event whose type == <event-type> in $EVENTS_PATH, or "".
smoke_read_event_field() {
    python3 "$SMOKE_LIB_DIR/smoke_events.py" read-field "$EVENTS_PATH" "$1" "$2"
}

# smoke_event_index <event-type> — 0-based index of the first event of that
# type in $EVENTS_PATH, or -1.
smoke_event_index() {
    python3 "$SMOKE_LIB_DIR/smoke_events.py" event-index "$EVENTS_PATH" "$1"
}

# smoke_wait_for_event <event-type> — block until the milestone appears in
# $EVENTS_PATH, surfacing an app-side failure milestone immediately rather
# than waiting out the timeout. Bounded by $TOTAL_TIMEOUT_SECONDS.
smoke_wait_for_event() {
    local event_type="$1" deadline=$(( $(date +%s) + TOTAL_TIMEOUT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(smoke_event_index "$event_type")" != "-1" ]]; then
            return 0
        fi
        if [[ "$(smoke_event_index failure)" != "-1" ]]; then
            smoke_fail "App reported a failure milestone: $(smoke_read_event_field message failure)"
        fi
        sleep 1
    done
    smoke_fail "Timed out waiting for milestone: $event_type"
}

# smoke_finalize_and_exit <exit-code> [<message>] — single finalize path for
# every outcome (pass, fail, signal). FINALIZED guards re-entrancy (a second
# call, from smoke_on_exit firing after an explicit call already ran, just
# exits). TERM/INT/HUP are ignored (not restored to default) for the duration
# of cleanup so a second signal during teardown can't kill it mid-cleanup;
# EXIT is cleared immediately so this function's own `exit` below doesn't
# re-enter smoke_on_exit. Cleanup is unconditional (see file header).
#
# Every step here is backstopped with `|| true`: finalize inherits the
# caller's `set -e`, so any step that exits non-zero — a cleanup helper, the
# JSONL reader behind it, the optional `smoke_write_summary <exit-code>
# <message>` callback — would otherwise abort finalize partway and replace
# the real exit code with its own. The three properties this function owns
# (processes and worktrees cleaned, summary written, exit code preserved) all
# depend on reaching the last line, so no step is allowed to be fatal.
smoke_finalize_and_exit() {
    if [[ "$FINALIZED" == true ]]; then
        exit "$1"
    fi
    FINALIZED=true
    trap '' TERM INT HUP
    trap - EXIT
    local exit_code="$1"
    local message="${2:-}"

    smoke_cleanup_app || true
    smoke_cleanup_repo || true
    smoke_cleanup_created_worktree || true

    if declare -F smoke_write_summary >/dev/null 2>&1; then
        smoke_write_summary "$exit_code" "$message" || true
    fi

    [[ -n "$message" ]] && smoke_log "$message"
    smoke_log "Run directory: $RUN_DIR"
    # Cleanup being unconditional means a red run's repo and worktree are gone
    # by the time anyone reads the failure, so name the opt-out at the moment
    # it is wanted.
    if (( exit_code != 0 )) && [[ "${KEEP_ARTIFACTS:-false}" != true ]]; then
        smoke_log "Re-run with --keep-artifacts to preserve the disposable repo and created worktree for inspection."
    fi
    exit "$exit_code"
}

# smoke_on_exit — EXIT trap. If it fires at all, smoke_finalize_and_exit has
# never run yet for this exit (finalize clears the EXIT trap as its first
# act), so this always finalizes — whether the script fell through an
# unguarded `set -e` abort, or `smoke_fail` exited directly.
smoke_on_exit() {
    local exit_code="$?"
    smoke_finalize_and_exit "$exit_code" "${FAILURE_MESSAGE:-Smoke run failed.}"
}

# smoke_on_signal <name> <number> — TERM/INT/HUP do not fire the EXIT trap (a
# plain `kill`, and what CI timeouts send), so route them into the same
# finalize path with the conventional 128+signum exit code.
smoke_on_signal() {
    local signal_name="$1" signal_number="$2"
    RUN_STATUS="interrupted"
    smoke_finalize_and_exit "$((128 + signal_number))" "Smoke run interrupted by SIG${signal_name}."
}

# smoke_install_traps — wire the unconditional-cleanup trap set. Call once
# setup is ready to be torn down (right after parse_args/smoke_init).
smoke_install_traps() {
    trap smoke_on_exit EXIT
    trap 'smoke_on_signal TERM 15' TERM
    trap 'smoke_on_signal INT 2' INT
    trap 'smoke_on_signal HUP 1' HUP
}
