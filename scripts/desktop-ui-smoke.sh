#!/bin/bash
# ==========================================================================
# desktop-ui-smoke.sh - Daily-driver desktop UI smoke for the debug app
# ==========================================================================
#
# Drives the two flows a daily driver exercises constantly, end to end, in the
# real debug app via the `desktop-ui-smoke` automation mode:
#
#   1. Create a local workspace through the UI -> it lands in the sidebar with
#      a live terminal session.
#   2. Switch selection to the repo terminal and back -> the terminal surface
#      follows selection (no stale session).
#
# The app emits JSONL milestones; this script asserts the sequence. It is
# headless-safe (launches with --no-activate / WORKSPACES_NO_ACTIVATE_ON_LAUNCH)
# so it can run on a shared desktop without stealing focus. Artifacts land under
# output/desktop-ui-smoke/<timestamp>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
OUTPUT_ROOT="$REPO_ROOT/output/desktop-ui-smoke"
DEFAULT_TIMEOUT_SECONDS=$((5 * 60))
DEFAULT_INACTIVITY_SECONDS=$((90))

SKIP_BUILD=false
KEEP_ARTIFACTS=false
TOTAL_TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
INACTIVITY_TIMEOUT_SECONDS="$DEFAULT_INACTIVITY_SECONDS"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$TIMESTAMP"
RUN_LINK="$OUTPUT_ROOT/latest"
RUN_STATUS="failed"
FAILURE_MESSAGE=""
APP_PID=""
LAUNCH_LOG_PATH=""
SMOKE_REPO_PATH=""
WORKSPACE_NAME="desktop-ui-smoke-$TIMESTAMP"
EVENTS_PATH=""
STARTED_AT=0

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    FAILURE_MESSAGE="$*"
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/desktop-ui-smoke.sh [options]

Options:
  --no-build               Reuse the current debug binary
  --keep-artifacts         Keep the disposable smoke repo after a passing run
  --timeout-seconds <n>    Total timeout for the smoke (default: 300)
  --inactivity-seconds <n> Fail if no new event progress occurs (default: 90)
  --help, -h               Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                SKIP_BUILD=true
                shift
                ;;
            --keep-artifacts)
                KEEP_ARTIFACTS=true
                shift
                ;;
            --timeout-seconds)
                [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"
                TOTAL_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --inactivity-seconds)
                [[ $# -ge 2 ]] || fail "--inactivity-seconds requires a value"
                INACTIVITY_TIMEOUT_SECONDS="$2"
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

setup_run_dir() {
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$RUN_LINK"
    EVENTS_PATH="$RUN_DIR/events.jsonl"
}

cleanup_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        sleep 1
    fi
    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
}

cleanup_repo() {
    if [[ "$KEEP_ARTIFACTS" == true ]]; then
        return
    fi
    if [[ -n "$SMOKE_REPO_PATH" && -d "$SMOKE_REPO_PATH" ]]; then
        chmod -R u+w "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
        rm -rf "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
    fi
    cleanup_created_worktrees
}

# The app creates the workspace as a git worktree under the configured
# workspaces root (default ~/workspaces/<repo-name>/<workspace-name>). Remove it
# using the path the app reported in the milestone stream so a passing run leaves
# no residue on disk.
cleanup_created_worktrees() {
    [[ -f "$EVENTS_PATH" ]] || return 0
    local workspace_path
    workspace_path="$(
        python3 - "$EVENTS_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
result = ""
for raw_line in path.read_text().splitlines():
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    event = json.loads(raw_line)
    if event.get("type") == "workspace_created" and event.get("workspacePath"):
        result = event["workspacePath"]
print(result)
PY
    )"

    [[ -n "$workspace_path" && -d "$workspace_path" ]] || return 0
    chmod -R u+w "$workspace_path" >/dev/null 2>&1 || true
    rm -rf "$workspace_path" >/dev/null 2>&1 || true

    # Prune the now-empty per-repo container the worktree lived in.
    local repo_container
    repo_container="$(dirname "$workspace_path")"
    if [[ -d "$repo_container" ]] && [[ -z "$(ls -A "$repo_container" 2>/dev/null)" ]]; then
        rmdir "$repo_container" >/dev/null 2>&1 || true
    fi
}

copy_supporting_logs() {
    if [[ -n "$LAUNCH_LOG_PATH" && -f "$LAUNCH_LOG_PATH" ]]; then
        cp "$LAUNCH_LOG_PATH" "$RUN_DIR/launch.log" 2>/dev/null || true
    fi
}

write_summary() {
    local elapsed_seconds="$1"
    local outcome_message="$2"
    cat >"$RUN_DIR/summary.md" <<EOF
# Desktop UI Smoke

- Outcome: $RUN_STATUS
- Message: $outcome_message
- Repo path: ${SMOKE_REPO_PATH:-unknown}
- Workspace name: ${WORKSPACE_NAME:-unknown}
- Elapsed seconds: $elapsed_seconds
- Events: $EVENTS_PATH
- Launch log: ${LAUNCH_LOG_PATH:-unknown}
EOF
}

finalize_and_exit() {
    local exit_code="$1"
    local message="$2"
    local elapsed_seconds
    elapsed_seconds=$(( $(date +%s) - STARTED_AT ))

    copy_supporting_logs
    cleanup_app
    if [[ "$RUN_STATUS" == "passed" ]]; then
        cleanup_repo
    fi
    write_summary "$elapsed_seconds" "$message"
    log "$message"
    log "Run directory: $RUN_DIR"
    exit "$exit_code"
}

on_exit() {
    local exit_code="$?"
    trap - EXIT
    if [[ "$exit_code" -ne 0 && "$RUN_STATUS" != "passed" ]]; then
        finalize_and_exit "$exit_code" "${FAILURE_MESSAGE:-Smoke run failed.}"
    fi
}

create_disposable_repo() {
    SMOKE_REPO_PATH="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-ui-smoke-XXXXXX")"
    (
        cd "$SMOKE_REPO_PATH"
        git init >/dev/null
        git config user.name "WorkspaceManager Smoke" >/dev/null
        git config user.email "smoke@local.invalid" >/dev/null
        printf "# Desktop UI smoke\n\nCreated %s\n" "$TIMESTAMP" >README.md
        git add README.md
        git commit -m "Initial smoke fixture" >/dev/null
    )
}

launch_automated_app() {
    local app_data_dir="$RUN_DIR/app-data"
    local launch_output
    local -a args=(
        "--no-activate"
        "--data-dir" "$app_data_dir"
        "--clean-data"
        "--window-timeout" "20"
        "--env" "WORKSPACES_DISABLE_AUTO_IMPORT=1"
        "--env" "WORKSPACES_AUTOMATION_MODE=desktop-ui-smoke"
        "--env" "WORKSPACES_AUTOMATION_REPO_PATH=$SMOKE_REPO_PATH"
        "--env" "WORKSPACES_AUTOMATION_WORKSPACE_NAME=$WORKSPACE_NAME"
        "--env" "WORKSPACES_AUTOMATION_EVENTS_PATH=$EVENTS_PATH"
    )
    if [[ "$SKIP_BUILD" == true ]]; then
        args+=("--no-build")
    fi

    launch_output="$(
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${args[@]}" 2>&1 | tee "$RUN_DIR/launch-command.log"
    )"

    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    LAUNCH_LOG_PATH="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"

    [[ -n "$APP_PID" ]] || fail "Could not determine WorkspaceManager pid from launch output."

    (
        cd "$REPO_ROOT"
        "$CAPTURE_SCRIPT" --output "$RUN_DIR/01-launch.png"
    ) >/dev/null 2>&1 || true
}

file_mtime() {
    local target="$1"
    if [[ -e "$target" ]]; then
        stat -f %m "$target"
    else
        echo 0
    fi
}

read_event_status() {
    python3 - "$EVENTS_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
status = "pending"
failure_message = ""

if path.exists():
    for raw_line in path.read_text().splitlines():
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        event = json.loads(raw_line)
        kind = event.get("type", "")
        if kind == "failure":
            status = "failure"
            failure_message = event.get("message", "")
        elif kind == "scenario_complete":
            status = "complete"

print(f"status={status}")
print(f"failure_message={failure_message}")
PY
}

assert_milestone_sequence() {
    python3 - "$EVENTS_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
events = []
for raw_line in path.read_text().splitlines():
    raw_line = raw_line.strip()
    if raw_line:
        events.append(json.loads(raw_line))

types = [event.get("type") for event in events]


def fail(message):
    print(f"ASSERTION FAILED: {message}", file=sys.stderr)
    print("Observed milestone order:", file=sys.stderr)
    for event in events:
        print(
            f"  - {event.get('type')} "
            f"kind={event.get('selectionKind')} session={event.get('sessionID')}",
            file=sys.stderr,
        )
    sys.exit(1)


if "failure" in types:
    failure = next(e for e in events if e.get("type") == "failure")
    fail(f"app reported failure: {failure.get('message')}")


def index_of(kind):
    return types.index(kind) if kind in types else None


for required in (
    "launch_ready",
    "repo_ready",
    "workspace_creation_started",
    "workspace_created",
    "sidebar_updated",
    "web_surface_attached",
    "scenario_complete",
):
    if required not in types:
        fail(f"missing required milestone: {required}")

# Creation flow ordering.
if not (
    index_of("launch_ready")
    < index_of("repo_ready")
    < index_of("workspace_creation_started")
    < index_of("workspace_created")
):
    fail("creation milestones are out of order")

attaches = [e for e in events if e.get("type") == "terminal_session_attached"]
workspace_attaches = [a for a in attaches if a.get("selectionKind") == "workspace"]
repo_attaches = [a for a in attaches if a.get("selectionKind") == "repo"]

if not workspace_attaches:
    fail("no workspace terminal session was attached")
if not repo_attaches:
    fail("repo terminal session never attached (selection switch did not run)")

# Flow 2: prove the surface follows selection. The first workspace attach, a
# repo attach, then a workspace attach again, with the repo session distinct
# from the workspace session and the workspace session reused on return.
first_workspace = workspace_attaches[0]
first_repo = repo_attaches[0]

if first_repo.get("sessionID") == first_workspace.get("sessionID"):
    fail("repo terminal reused the workspace session — selection did not switch")

later_workspace = [
    a
    for a in workspace_attaches
    if events.index(a) > events.index(first_repo)
]
if not later_workspace:
    fail("workspace terminal did not re-attach after switching back")

restored = later_workspace[0]
if restored.get("sessionScope") != first_workspace.get("sessionScope"):
    fail("restored workspace session scope did not match the original workspace")

# Flow 3: the web pane rendered through the Surface seam, and workspace
# selection routed a terminal session again afterwards. This gates session
# routing after the web swap; surface remount/focus stays best-effort
# (surface_focused), matching Flows 1-2.
web_attaches = [e for e in events if e.get("type") == "web_surface_attached"]
post_web_workspace = [
    a
    for a in workspace_attaches
    if events.index(a) > events.index(web_attaches[0])
]
if not post_web_workspace:
    fail("no workspace terminal session attached after the web pane")

# scenario_complete must be the terminal milestone.
if types[-1] != "scenario_complete":
    fail("scenario_complete was not the final milestone")

focus_events = [e for e in events if e.get("type") == "surface_focused"]
focus_timeouts = [e for e in events if e.get("type") == "surface_focus_timed_out"]
print(
    f"OK: {len(attaches)} terminal attaches, "
    f"{len(web_attaches)} web surface attaches, "
    f"{len(focus_events)} surface focuses, "
    f"{len(focus_timeouts)} focus timeouts"
)
PY
}

capture_final_screenshot() {
    (
        cd "$REPO_ROOT"
        "$CAPTURE_SCRIPT" --output "$RUN_DIR/02-final.png"
    ) >/dev/null 2>&1 || true
}

monitor_until_complete() {
    local last_progress_at
    last_progress_at="$(date +%s)"

    while true; do
        if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" >/dev/null 2>&1; then
            capture_final_screenshot
            fail "WorkspaceManager exited before the desktop UI smoke completed."
        fi

        local events_mtime
        events_mtime="$(file_mtime "$EVENTS_PATH")"
        if (( events_mtime > last_progress_at )); then
            last_progress_at="$events_mtime"
        fi

        eval "$(read_event_status)"

        if [[ "${status:-pending}" == "failure" ]]; then
            capture_final_screenshot
            fail "App reported failure: ${failure_message:-Unknown failure}"
        fi

        if [[ "${status:-pending}" == "complete" ]]; then
            capture_final_screenshot
            if assert_milestone_sequence | tee "$RUN_DIR/assertions.log"; then
                RUN_STATUS="passed"
                return
            fi
            fail "Milestone sequence assertion failed."
        fi

        local now
        now="$(date +%s)"
        if (( now - STARTED_AT > TOTAL_TIMEOUT_SECONDS )); then
            capture_final_screenshot
            fail "Timed out waiting for the desktop UI smoke to complete."
        fi
        if (( now - last_progress_at > INACTIVITY_TIMEOUT_SECONDS )); then
            capture_final_screenshot
            fail "Timed out waiting for new milestone progress."
        fi

        sleep 2
    done
}

main() {
    parse_args "$@"
    setup_run_dir
    STARTED_AT="$(date +%s)"
    trap on_exit EXIT

    create_disposable_repo
    launch_automated_app
    monitor_until_complete
    finalize_and_exit 0 "Desktop UI smoke completed successfully."
}

main "$@"
