#!/bin/bash
# ==========================================================================
# api-desktop-ui-smoke.sh - API-driven daily-driver smoke for the debug app
# ==========================================================================
#
# Runs the desktop daily-driver scenario beside the authoritative UI lane while
# driving the reviewed operator verbs from outside the app:
#
#   1. Launch the debug app headless-safe with operator scope enabled.
#   2. Read the repo target with `workspaces workspace list`, then create a
#      local workspace with `workspaces workspace create`.
#   3. Read the workspace target with `workspaces workspace list`, then reselect
#      the workspace with `workspaces workspace select` after the app parks on
#      the repo terminal. Repo selection is app-side because no reviewed
#      repo-select operator verb exists.
#
# Artifacts land under output/api-desktop-ui-smoke/<timestamp>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/synthetic-root.sh
source "$SCRIPT_DIR/lib/synthetic-root.sh"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CLI_BIN="$REPO_ROOT/.build/arm64-apple-macosx/debug/workspaces"
OUTPUT_ROOT="$REPO_ROOT/output/api-desktop-ui-smoke"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$TIMESTAMP"
RUN_LINK="$OUTPUT_ROOT/latest"
DEFAULT_TIMEOUT_SECONDS=$((5 * 60))

SKIP_BUILD=false
KEEP_ARTIFACTS=false
TOTAL_TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
APP_PID=""
LAUNCH_LOG_PATH=""
SMOKE_REPO_PATH=""
WORKSPACE_NAME="api-desktop-ui-smoke-$TIMESTAMP"
EVENTS_PATH=""
RUN_STATUS="failed"
STARTED_AT=0

log() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/api-desktop-ui-smoke.sh [options]

Options:
  --no-build              Reuse the current debug binary
  --keep-artifacts        Keep the disposable smoke repo after a passing run
  --timeout-seconds <n>   Total timeout (default: 300)
  --help, -h              Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build) SKIP_BUILD=true; shift ;;
            --keep-artifacts) KEEP_ARTIFACTS=true; shift ;;
            --timeout-seconds)
                [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"
                TOTAL_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --help|-h) usage; exit 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
}

setup_run_dir() {
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$RUN_LINK"
    EVENTS_PATH="$RUN_DIR/events.jsonl"
    # Isolation boundary: the app's workspaces root lives inside the run dir, so
    # created worktrees can never leak into the owner's real ~/workspaces.
    synthetic_root_ensure "$RUN_DIR/workspaces-root" || fail "Could not establish WORKSPACES_SYNTHETIC_ROOT."
}

cleanup_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        sleep 1
    fi
    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
}

read_event_field() {
    local field="$1" event_type="$2"
    python3 - "$EVENTS_PATH" "$field" "$event_type" <<'PY'
import json
import sys
from pathlib import Path

path, field, event_type = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
value = ""
if path.exists():
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == event_type and event.get(field):
            value = event[field]
print(value)
PY
}

cleanup_created_worktree() {
    [[ -f "$EVENTS_PATH" ]] || return 0
    local workspace_path
    workspace_path="$(read_event_field workspacePath workspace_created)"
    [[ -n "$workspace_path" && -d "$workspace_path" ]] || return 0
    chmod -R u+w "$workspace_path" >/dev/null 2>&1 || true
    rm -rf "$workspace_path" >/dev/null 2>&1 || true
    local repo_container
    repo_container="$(dirname "$workspace_path")"
    if [[ -d "$repo_container" && -z "$(ls -A "$repo_container" 2>/dev/null)" ]]; then
        rmdir "$repo_container" >/dev/null 2>&1 || true
    fi
}

cleanup_repo() {
    [[ "$KEEP_ARTIFACTS" == true ]] && return 0
    if [[ -n "$SMOKE_REPO_PATH" && -d "$SMOKE_REPO_PATH" ]]; then
        chmod -R u+w "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
        rm -rf "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
    fi
    cleanup_created_worktree
}

on_exit() {
    local code="$?"
    trap - EXIT
    cleanup_app
    [[ "$RUN_STATUS" == "passed" ]] && cleanup_repo
    write_summary "$code"
    log "Run directory: $RUN_DIR"
    exit "$code"
}

write_summary() {
    local exit_code="$1"
    local elapsed_seconds
    elapsed_seconds=$(( $(date +%s) - STARTED_AT ))
    cat >"$RUN_DIR/summary.md" <<EOF
# API Desktop UI Smoke

- Outcome: $RUN_STATUS
- Exit code: $exit_code
- Repo path: ${SMOKE_REPO_PATH:-unknown}
- Workspace name: $WORKSPACE_NAME
- Elapsed seconds: $elapsed_seconds
- Events: $EVENTS_PATH
- Create result: $RUN_DIR/create-result.json
- Select result: $RUN_DIR/select-result.json
- Repo selection driver: app-side handoff; no reviewed repo-select operator verb exists yet
EOF
    if [[ -n "$LAUNCH_LOG_PATH" && -f "$LAUNCH_LOG_PATH" ]]; then
        cp "$LAUNCH_LOG_PATH" "$RUN_DIR/launch.log" 2>/dev/null || true
    fi
}

create_disposable_repo() {
    # Inside the run dir so a red run leaves zero residue outside it.
    SMOKE_REPO_PATH="$(mktemp -d "$RUN_DIR/smoke-repo-XXXXXX")"
    (
        cd "$SMOKE_REPO_PATH"
        git init >/dev/null
        git config user.name "WorkspaceManager Smoke" >/dev/null
        git config user.email "smoke@local.invalid" >/dev/null
        printf "# API desktop UI smoke\n\nCreated %s\n" "$TIMESTAMP" >README.md
        git add README.md
        git commit -m "Initial smoke fixture" >/dev/null
    )
}

launch_automated_app() {
    synthetic_root_require || fail "Refusing to launch without WORKSPACES_SYNTHETIC_ROOT."
    local app_data_dir="$RUN_DIR/app-data"
    local -a args=(
        "--no-activate"
        "--data-dir" "$app_data_dir"
        "--clean-data"
        "--window-timeout" "20"
        "--env" "WORKSPACES_DISABLE_AUTO_IMPORT=1"
        "--env" "WORKSPACES_SYNTHETIC_ROOT=$WORKSPACES_SYNTHETIC_ROOT"
        "--env" "WORKSPACES_AUTOMATION_API=1"
        "--env" "WORKSPACES_AUTOMATION_OPERATOR=1"
        "--env" "WORKSPACES_AUTOMATION_MODE=desktop-ui-smoke"
        "--env" "WORKSPACES_AUTOMATION_CREATE_DRIVER=api"
        "--env" "WORKSPACES_AUTOMATION_SELECT_DRIVER=api"
        "--env" "WORKSPACES_AUTOMATION_REPO_PATH=$SMOKE_REPO_PATH"
        "--env" "WORKSPACES_AUTOMATION_WORKSPACE_NAME=$WORKSPACE_NAME"
        "--env" "WORKSPACES_AUTOMATION_EVENTS_PATH=$EVENTS_PATH"
    )
    [[ "$SKIP_BUILD" == true ]] && args+=("--no-build")

    local launch_output
    launch_output="$(
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${args[@]}" 2>&1 | tee "$RUN_DIR/launch-command.log"
    )"
    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    LAUNCH_LOG_PATH="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"
    [[ -n "$APP_PID" ]] || fail "Could not determine WorkspaceManager pid from launch output."
}

event_index() {
    python3 - "$EVENTS_PATH" "$1" <<'PY'
import json
import sys
from pathlib import Path

path, target = Path(sys.argv[1]), sys.argv[2]
idx = -1
if path.exists():
    for index, line in enumerate(l.strip() for l in path.read_text().splitlines() if l.strip()):
        if json.loads(line).get("type") == target:
            idx = index
            break
print(idx)
PY
}

wait_for_event() {
    local event_type="$1" deadline=$(( $(date +%s) + TOTAL_TIMEOUT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(event_index "$event_type")" != "-1" ]]; then
            return 0
        fi
        if [[ "$(event_index failure)" != "-1" ]]; then
            fail "App reported a failure milestone: $(read_event_field message failure)"
        fi
        sleep 1
    done
    fail "Timed out waiting for milestone: $event_type"
}

workspace_list_json() {
    local output_path="$1"
    "$CLI_BIN" workspace list --json | tee "$output_path" >/dev/null
}

extract_repo_id() {
    python3 - "$1" "$SMOKE_REPO_PATH" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
target = Path(sys.argv[2]).resolve()
for repo in data.get("repos", []):
    if Path(repo.get("path", "")).resolve() == target:
        print(repo["repoID"])
        sys.exit(0)
print(f"No repo from workspace list matched {target}", file=sys.stderr)
sys.exit(1)
PY
}

extract_workspace_id() {
    python3 - "$1" "$2" "$WORKSPACE_NAME" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
repo_id, workspace_name = sys.argv[2], sys.argv[3]
for workspace in data.get("workspaces", []):
    if workspace.get("repoID") == repo_id and workspace.get("name") == workspace_name:
        print(workspace["workspaceID"])
        sys.exit(0)
print(
    f"No workspace from workspace list matched repoID={repo_id} name={workspace_name}",
    file=sys.stderr,
)
sys.exit(1)
PY
}

assert_create_result() {
    python3 - "$RUN_DIR/create-result.json" <<'PY'
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text())
failures = []
if result.get("outcome") != "completed":
    failures.append(f"outcome was {result.get('outcome')!r}")
if result.get("attachedTerminal") is not True:
    failures.append("attachedTerminal was not true")
if not result.get("workspaceID"):
    failures.append("workspaceID was missing")
if failures:
    print("ASSERTION FAILED: create result", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_select_result() {
    python3 - "$RUN_DIR/select-result.json" "$1" <<'PY'
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text())
workspace_id = sys.argv[2]
failures = []
if result.get("outcome") != "completed":
    failures.append(f"outcome was {result.get('outcome')!r}")
if result.get("workspaceID") != workspace_id:
    failures.append("workspaceID did not match target")
if result.get("attachedTerminal") is not True:
    failures.append("attachedTerminal was not true")
if failures:
    print("ASSERTION FAILED: select result", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_api_milestone_sequence() {
    python3 - "$EVENTS_PATH" <<'PY'
import json
import sys
from pathlib import Path

events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
types = [event.get("type") for event in events]


def fail(message):
    print(f"ASSERTION FAILED: {message}", file=sys.stderr)
    print("Observed milestone order:", file=sys.stderr)
    for event in events:
        print(
            f"  - {event.get('type')} kind={event.get('selectionKind')} "
            f"session={event.get('sessionID')}",
            file=sys.stderr,
        )
    sys.exit(1)


if "failure" in types:
    failure = next(event for event in events if event.get("type") == "failure")
    fail(f"app reported failure: {failure.get('message')}")


def index_of(kind):
    return types.index(kind) if kind in types else None


required = [
    "launch_ready",
    "repo_ready",
    "awaiting_api_create",
    "workspace_created",
    "sidebar_updated",
    "awaiting_api_select",
    "scenario_complete",
]
for kind in required:
    if kind not in types:
        fail(f"missing required milestone: {kind}")

if not (
    index_of("launch_ready")
    < index_of("repo_ready")
    < index_of("awaiting_api_create")
    < index_of("workspace_created")
    < index_of("sidebar_updated")
    < index_of("awaiting_api_select")
    < index_of("scenario_complete")
):
    fail("API handoff milestones are out of order")

if types[-1] != "scenario_complete":
    fail("scenario_complete was not the final milestone")

await_create = index_of("awaiting_api_create")
await_select = index_of("awaiting_api_select")
attaches = [
    (index, event)
    for index, event in enumerate(events)
    if event.get("type") == "terminal_session_attached"
]
repo_before_create = [
    event for index, event in attaches
    if index < await_create and event.get("selectionKind") == "repo"
]
workspace_after_create = [
    event for index, event in attaches
    if await_create < index < await_select and event.get("selectionKind") == "workspace"
]
repo_before_select = [
    event for index, event in attaches
    if await_create < index < await_select and event.get("selectionKind") == "repo"
]
workspace_after_select = [
    event for index, event in attaches
    if index > await_select and event.get("selectionKind") == "workspace"
]

if not repo_before_create:
    fail("repo terminal did not attach before API create handoff")
if not workspace_after_create:
    fail("workspace terminal did not attach after API create")
if not repo_before_select:
    fail("repo terminal did not attach before API select handoff")
if not workspace_after_select:
    fail("workspace terminal did not attach after API select")

created_workspace = next(event for event in events if event.get("type") == "workspace_created")
if workspace_after_select[0].get("sessionScope") != created_workspace.get("workspacePath"):
    fail("API select workspace attach scope did not match created workspace path")

focus_events = [event for event in events if event.get("type") == "surface_focused"]
focus_timeouts = [event for event in events if event.get("type") == "surface_focus_timed_out"]
# The app emits surface_focus_not_applicable when it launched non-activating:
# focus cannot fire in that mode, so report it as unavailable, not as zero.
focus_not_applicable = any(
    event.get("type") == "surface_focus_not_applicable" for event in events
)
focus_summary = (
    "surface focus n/a (no-activate launch)"
    if focus_not_applicable
    else f"{len(focus_events)} surface focuses, {len(focus_timeouts)} focus timeouts"
)
print(
    "OK: API lane emitted create/sidebar/select milestones, "
    f"{len(attaches)} terminal attaches, "
    f"{focus_summary}"
)
PY
}

main() {
    parse_args "$@"
    STARTED_AT="$(date +%s)"
    trap on_exit EXIT
    setup_run_dir
    create_disposable_repo

    if [[ "$SKIP_BUILD" != true ]]; then
        log "Building debug binaries..."
        ( cd "$REPO_ROOT" && swift build >/dev/null )
    fi
    [[ -x "$CLI_BIN" ]] || fail "CLI binary not found at $CLI_BIN (run swift build)."

    log "Launching app (API create + API select drivers)..."
    launch_automated_app

    log "Waiting for API create handoff..."
    wait_for_event awaiting_api_create

    workspace_list_json "$RUN_DIR/workspace-list-before-create.json"
    local repo_id
    repo_id="$(extract_repo_id "$RUN_DIR/workspace-list-before-create.json")"
    log "Repo id from workspace list: $repo_id"

    log "Driving API create: workspaces workspace create $repo_id $WORKSPACE_NAME"
    "$CLI_BIN" workspace create "$repo_id" "$WORKSPACE_NAME" --json | tee "$RUN_DIR/create-result.json"
    assert_create_result

    log "Waiting for API select handoff..."
    wait_for_event awaiting_api_select

    workspace_list_json "$RUN_DIR/workspace-list-before-select.json"
    local workspace_id
    workspace_id="$(extract_workspace_id "$RUN_DIR/workspace-list-before-select.json" "$repo_id")"
    log "Workspace id from workspace list: $workspace_id"

    log "Driving API select: workspaces workspace select $workspace_id"
    "$CLI_BIN" workspace select "$workspace_id" --json | tee "$RUN_DIR/select-result.json"
    assert_select_result "$workspace_id"

    log "Waiting for scenario completion..."
    wait_for_event scenario_complete
    assert_api_milestone_sequence | tee "$RUN_DIR/assertions.log"

    if "$CLI_BIN" window snapshot --out "$RUN_DIR/final.png" >/dev/null 2>&1; then
        log "Captured final window snapshot: $RUN_DIR/final.png"
    else
        log "Window snapshot unavailable (likely a locked screen) — JSONL + API results stand as evidence."
    fi

    RUN_STATUS="passed"
    log "PASS — API-driven lane created and reselected the workspace through operator verbs."
}

main "$@"
