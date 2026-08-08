#!/bin/bash
# ==========================================================================
# api-create-smoke.sh - API-driven workspace.create smoke for the debug app
# ==========================================================================
#
# Proves the create verb through the real app socket:
#
#   1. The app imports a disposable repo in desktop-ui-smoke mode, parks the
#      active surface on that repo terminal, and emits `awaiting_api_create`.
#   2. This script runs `workspaces workspace create <repo-id> <name>`.
#   3. The verb enters the sidebar create helper, creating the workspace,
#      selecting it, and attaching the new workspace terminal. The JSONL must
#      show workspace/sidebar milestones and a workspace terminal attach after
#      `awaiting_api_create`; the create result's attached surface must match
#      that milestone and differ from the parked repo terminal.
#
# Headless-safe (--no-activate). Artifacts land under output/api-create-smoke/.
# Setup/teardown (run dir, disposable repo, app launch/kill, unconditional
# cleanup) is shared with the rest of the smoke family via
# scripts/lib/api-smoke-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/api-smoke-common.sh
source "$SCRIPT_DIR/lib/api-smoke-common.sh"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CLI_BIN="$REPO_ROOT/.build/arm64-apple-macosx/debug/workspaces"
OUTPUT_ROOT="$REPO_ROOT/output/api-create-smoke"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$TIMESTAMP"
RUN_LINK="$OUTPUT_ROOT/latest"
DEFAULT_TIMEOUT_SECONDS=$((4 * 60))

SKIP_BUILD=false
KEEP_ARTIFACTS=false
TOTAL_TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
WORKSPACE_NAME="api-create-smoke-$TIMESTAMP"
EVENTS_PATH=""

log() { smoke_log "$@"; }
fail() { smoke_fail "$@"; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/api-create-smoke.sh [options]

Options:
  --no-build              Reuse the current debug binary
  --keep-artifacts        Keep the disposable smoke repo after any outcome
  --timeout-seconds <n>   Total timeout (default: 240)
  --help, -h              Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build) SKIP_BUILD=true; shift ;;
            --keep-artifacts) KEEP_ARTIFACTS=true; shift ;;
            --timeout-seconds) [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"; TOTAL_TIMEOUT_SECONDS="$2"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
}

assert_create_result_and_events() {
    local await_idx="$1"
    python3 - "$EVENTS_PATH" "$RUN_DIR/create-result.json" "$await_idx" <<'PY'
import json, sys
from pathlib import Path
events_path, result_path, await_idx = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
events = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()]
result = json.loads(result_path.read_text())

before = events[:await_idx]
after = events[await_idx + 1:]
repo_attach = next(
    (event for event in reversed(before)
     if event.get("type") == "terminal_session_attached" and event.get("selectionKind") == "repo"),
    None,
)
workspace_attach = next(
    (event for event in after
     if event.get("type") == "terminal_session_attached" and event.get("selectionKind") == "workspace"),
    None,
)
workspace_created = next((event for event in after if event.get("type") == "workspace_created"), None)
sidebar_updated = next((event for event in after if event.get("type") == "sidebar_updated"), None)

failures = []
if repo_attach is None:
    failures.append("no repo terminal attach before awaiting_api_create")
if workspace_attach is None:
    failures.append("no workspace terminal attach after awaiting_api_create")
if workspace_created is None:
    failures.append("no workspace_created after awaiting_api_create")
if sidebar_updated is None:
    failures.append("no sidebar_updated after awaiting_api_create")

if result.get("outcome") != "completed":
    failures.append(f"create outcome was {result.get('outcome')!r}, not completed")
if result.get("attachedTerminal") is not True:
    failures.append("create result did not report attachedTerminal=true")

if workspace_attach is not None:
    if result.get("attachedSurfaceID") != workspace_attach.get("sessionID"):
        failures.append("create result attachedSurfaceID did not match workspace attach milestone")
    if repo_attach is not None and workspace_attach.get("sessionID") == repo_attach.get("sessionID"):
        failures.append("workspace attach reused the parked repo terminal session")
    workspace_path = workspace_created.get("workspacePath") if workspace_created else None
    if workspace_path and workspace_attach.get("sessionScope") != workspace_path:
        failures.append("workspace attach scope did not match created workspace path")

if workspace_created is not None:
    if result.get("workspaceID") != workspace_created.get("workspaceID"):
        failures.append("create result workspaceID did not match workspace_created")
    if result.get("workspacePath") != workspace_created.get("workspacePath"):
        failures.append("create result workspacePath did not match workspace_created")

if failures:
    print("ASSERTION FAILED:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    print("Events after awaiting_api_create:", file=sys.stderr)
    for event in after:
        print(
            f"  - {event.get('type')} kind={event.get('selectionKind')} "
            f"session={event.get('sessionID')} scope={event.get('sessionScope')}",
            file=sys.stderr,
        )
    sys.exit(1)

print(
    "OK: API create attached workspace terminal "
    f"{workspace_attach.get('sessionID')} scope={workspace_attach.get('sessionScope')}"
)
PY
}

main() {
    parse_args "$@"
    smoke_init
    smoke_install_traps
    smoke_setup_run_dir
    smoke_create_disposable_repo "API create smoke"

    if [[ "$SKIP_BUILD" != true ]]; then
        log "Building debug binaries..."
        ( cd "$REPO_ROOT" && swift build >/dev/null )
    fi
    [[ -x "$CLI_BIN" ]] || fail "CLI binary not found at $CLI_BIN (run swift build)."

    log "Launching app (api create driver)..."
    smoke_launch_app "WORKSPACES_AUTOMATION_API=1" "WORKSPACES_AUTOMATION_OPERATOR=1" "WORKSPACES_AUTOMATION_CREATE_DRIVER=api"

    log "Waiting for repo terminal park before API create..."
    smoke_wait_for_event awaiting_api_create

    local repo_id
    repo_id="$(smoke_read_event_field repoID awaiting_api_create)"
    [[ -n "$repo_id" ]] || fail "Could not read repoID from awaiting_api_create."
    log "Repo id: $repo_id"

    local await_idx
    await_idx="$(smoke_event_index awaiting_api_create)"

    log "Driving API create: workspaces workspace create $repo_id $WORKSPACE_NAME"
    "$CLI_BIN" workspace create "$repo_id" "$WORKSPACE_NAME" --json | tee "$RUN_DIR/create-result.json"

    log "Waiting for create milestones..."
    smoke_wait_for_event workspace_created
    smoke_wait_for_event sidebar_updated
    smoke_wait_for_event terminal_session_attached
    assert_create_result_and_events "$await_idx"

    if "$CLI_BIN" window snapshot --out "$RUN_DIR/after-create.png" >/dev/null 2>&1; then
        log "Captured post-create window snapshot: $RUN_DIR/after-create.png"
    else
        log "Window snapshot unavailable (likely a locked screen) — JSONL + create result stand as evidence."
    fi

    RUN_STATUS="passed"
    {
        echo "# API Create Smoke"
        echo
        echo "- Outcome: passed"
        echo "- Repo id: $repo_id"
        echo "- Workspace name: $WORKSPACE_NAME"
        echo "- Events: $EVENTS_PATH"
        echo "- Create result: $RUN_DIR/create-result.json"
    } >"$RUN_DIR/summary.md"

    smoke_finalize_and_exit 0 "PASS — API-driven workspace.create created, selected, and attached the new workspace terminal."
}

main "$@"
