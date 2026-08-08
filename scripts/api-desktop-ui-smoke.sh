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
# Artifacts land under output/api-desktop-ui-smoke/<timestamp>/. Setup/teardown
# (run dir, disposable repo, app launch/kill, unconditional cleanup) is shared
# with the rest of the smoke family via scripts/lib/api-smoke-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/api-smoke-common.sh
source "$SCRIPT_DIR/lib/api-smoke-common.sh"
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
WORKSPACE_NAME="api-desktop-ui-smoke-$TIMESTAMP"
EVENTS_PATH=""

log() { smoke_log "$@"; }
fail() { smoke_fail "$@"; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/api-desktop-ui-smoke.sh [options]

Options:
  --no-build              Reuse the current debug binary
  --keep-artifacts        Keep the disposable smoke repo after any outcome
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

smoke_write_summary() {
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
    smoke_init
    smoke_install_traps
    smoke_setup_run_dir
    smoke_create_disposable_repo "API desktop UI smoke"

    if [[ "$SKIP_BUILD" != true ]]; then
        log "Building debug binaries..."
        ( cd "$REPO_ROOT" && swift build >/dev/null )
    fi
    [[ -x "$CLI_BIN" ]] || fail "CLI binary not found at $CLI_BIN (run swift build)."

    log "Launching app (API create + API select drivers)..."
    smoke_launch_app \
        "WORKSPACES_AUTOMATION_API=1" \
        "WORKSPACES_AUTOMATION_OPERATOR=1" \
        "WORKSPACES_AUTOMATION_CREATE_DRIVER=api" \
        "WORKSPACES_AUTOMATION_SELECT_DRIVER=api"

    log "Waiting for API create handoff..."
    smoke_wait_for_event awaiting_api_create

    workspace_list_json "$RUN_DIR/workspace-list-before-create.json"
    local repo_id
    repo_id="$(extract_repo_id "$RUN_DIR/workspace-list-before-create.json")"
    log "Repo id from workspace list: $repo_id"

    log "Driving API create: workspaces workspace create $repo_id $WORKSPACE_NAME"
    "$CLI_BIN" workspace create "$repo_id" "$WORKSPACE_NAME" --json | tee "$RUN_DIR/create-result.json"
    assert_create_result

    log "Waiting for API select handoff..."
    smoke_wait_for_event awaiting_api_select

    workspace_list_json "$RUN_DIR/workspace-list-before-select.json"
    local workspace_id
    workspace_id="$(extract_workspace_id "$RUN_DIR/workspace-list-before-select.json" "$repo_id")"
    log "Workspace id from workspace list: $workspace_id"

    log "Driving API select: workspaces workspace select $workspace_id"
    "$CLI_BIN" workspace select "$workspace_id" --json | tee "$RUN_DIR/select-result.json"
    assert_select_result "$workspace_id"

    log "Waiting for scenario completion..."
    smoke_wait_for_event scenario_complete
    assert_api_milestone_sequence | tee "$RUN_DIR/assertions.log"

    if "$CLI_BIN" window snapshot --out "$RUN_DIR/final.png" >/dev/null 2>&1; then
        log "Captured final window snapshot: $RUN_DIR/final.png"
    else
        log "Window snapshot unavailable (likely a locked screen) — JSONL + API results stand as evidence."
    fi

    RUN_STATUS="passed"
    smoke_finalize_and_exit 0 "PASS — API-driven lane created and reselected the workspace through operator verbs."
}

main "$@"
