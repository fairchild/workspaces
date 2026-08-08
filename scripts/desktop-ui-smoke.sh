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
# output/desktop-ui-smoke/<timestamp>/. Setup/teardown (run dir, disposable
# repo, app launch/kill, unconditional cleanup) is shared with the rest of the
# smoke family via scripts/lib/api-smoke-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/api-smoke-common.sh
source "$SCRIPT_DIR/lib/api-smoke-common.sh"
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
WORKSPACE_NAME="desktop-ui-smoke-$TIMESTAMP"
EVENTS_PATH=""

log() { smoke_log "$@"; }
fail() { smoke_fail "$@"; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/desktop-ui-smoke.sh [options]

Options:
  --no-build               Reuse the current debug binary
  --keep-artifacts         Keep the smoke repo and created worktree, any outcome
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

smoke_write_summary() {
    local exit_code="$1"
    local message="$2"
    local elapsed_seconds
    elapsed_seconds=$(( $(date +%s) - STARTED_AT ))
    cat >"$RUN_DIR/summary.md" <<EOF
# Desktop UI Smoke

- Outcome: $RUN_STATUS
- Exit code: $exit_code
- Message: $message
- Repo path: ${SMOKE_REPO_PATH:-unknown}
- Workspace name: ${WORKSPACE_NAME:-unknown}
- Elapsed seconds: $elapsed_seconds
- Events: $EVENTS_PATH
- Launch log: ${LAUNCH_LOG_PATH:-unknown}
EOF
    if [[ -n "$LAUNCH_LOG_PATH" && -f "$LAUNCH_LOG_PATH" ]]; then
        cp "$LAUNCH_LOG_PATH" "$RUN_DIR/launch.log" 2>/dev/null || true
    fi
}

# Wraps smoke_launch_app with this lane's best-effort post-launch screenshot
# (no automation-API env — desktop-ui-smoke drives the UI directly, not the CLI).
launch_automated_app() {
    smoke_launch_app
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

attaches = [
    (i, e)
    for i, e in enumerate(events)
    if e.get("type") == "terminal_session_attached"
]
workspace_attaches = [(i, a) for i, a in attaches if a.get("selectionKind") == "workspace"]
repo_attaches = [(i, a) for i, a in attaches if a.get("selectionKind") == "repo"]

if not workspace_attaches:
    fail("no workspace terminal session was attached")
if not repo_attaches:
    fail("repo terminal session never attached (selection switch did not run)")

# Flow 2: prove the surface follows selection. The first workspace attach, a
# repo attach, then a workspace attach again, with the repo session distinct
# from the workspace session and the workspace session reused on return.
_, first_workspace = workspace_attaches[0]
first_repo_index, first_repo = repo_attaches[0]

if first_repo.get("sessionID") == first_workspace.get("sessionID"):
    fail("repo terminal reused the workspace session — selection did not switch")

later_workspace = [
    a
    for i, a in workspace_attaches
    if i > first_repo_index
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
web_attach_index = next(i for i, e in enumerate(events) if e.get("type") == "web_surface_attached")
post_web_workspace = [
    a
    for i, a in workspace_attaches
    if i > web_attach_index
]
if not post_web_workspace:
    fail("no workspace terminal session attached after the web pane")

# scenario_complete must be the terminal milestone.
if types[-1] != "scenario_complete":
    fail("scenario_complete was not the final milestone")

focus_events = [e for e in events if e.get("type") == "surface_focused"]
focus_timeouts = [e for e in events if e.get("type") == "surface_focus_timed_out"]
# The app emits surface_focus_not_applicable when it launched non-activating:
# focus cannot fire in that mode, so report it as unavailable, not as zero.
focus_not_applicable = any(
    e.get("type") == "surface_focus_not_applicable" for e in events
)
focus_summary = (
    "surface focus n/a (no-activate launch)"
    if focus_not_applicable
    else f"{len(focus_events)} surface focuses, {len(focus_timeouts)} focus timeouts"
)
print(
    f"OK: {len(attaches)} terminal attaches, "
    f"{len(web_attaches)} web surface attaches, "
    f"{focus_summary}"
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
    smoke_init
    smoke_install_traps
    smoke_setup_run_dir

    smoke_create_disposable_repo "Desktop UI smoke"
    launch_automated_app
    monitor_until_complete
    smoke_finalize_and_exit 0 "Desktop UI smoke completed successfully."
}

main "$@"
