#!/bin/bash
# ==========================================================================
# api-select-smoke.sh - API-driven workspace.select smoke for the debug app
# ==========================================================================
#
# Proves the verbs-=-clicks contract end to end, through the real socket:
#
#   1. The app (desktop-ui-smoke mode, WORKSPACES_AUTOMATION_SELECT_DRIVER=api)
#      creates a local workspace, then parks the active surface on the repo
#      terminal and emits `awaiting_api_select`.
#   2. This script reads the created workspace id from the JSONL, then runs
#      `workspaces workspace select <id>` against the operator socket.
#   3. The verb enters the SAME selection binding a sidebar click writes, so the
#      app emits `terminal_session_attached` (selectionKind=workspace) — proving
#      the API select attached the workspace's terminal and switched the active
#      PTY off the repo terminal (the wrong-PTY guard).
#
# Headless-safe (--no-activate). Artifacts land under output/api-select-smoke/.
# The socket + operator credential resolve under the standard app-support path
# keyed by bundle id (com.cloudcompute.workspaces), same as `workspaces window
# list`, so the CLI finds them regardless of --data-dir.
#
# Setup/teardown (run dir, disposable repo, app launch/kill, unconditional
# cleanup) is shared with the rest of the smoke family via
# scripts/lib/api-smoke-common.sh. The post-select milestone/wait logic below
# (read_workspace_field, event_index, wait_for_event, and main()'s driving of
# the select verb) stays local rather than routing through that lib — it
# overlaps in-flight work in PR #1265 (typed wait primitives), so this
# consolidation deliberately leaves it alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/api-smoke-common.sh
source "$SCRIPT_DIR/lib/api-smoke-common.sh"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CLI_BIN="$REPO_ROOT/.build/arm64-apple-macosx/debug/workspaces"
OUTPUT_ROOT="$REPO_ROOT/output/api-select-smoke"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$TIMESTAMP"
RUN_LINK="$OUTPUT_ROOT/latest"
DEFAULT_TIMEOUT_SECONDS=$((4 * 60))

SKIP_BUILD=false
KEEP_ARTIFACTS=false
TOTAL_TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
WORKSPACE_NAME="api-select-smoke-$TIMESTAMP"
EVENTS_PATH=""
APP_PID=""
LAUNCH_LOG_PATH=""
SMOKE_REPO_PATH=""
RUN_STATUS="failed"
FAILURE_MESSAGE=""
FINALIZED=false

log() { smoke_log "$@"; }
fail() { smoke_fail "$@"; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/api-select-smoke.sh [options]

Options:
  --no-build         Reuse the current debug binary
  --keep-artifacts   Keep the disposable smoke repo after any outcome
  --timeout-seconds <n>  Total timeout (default: 240)
  --help, -h         Show this help
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

# Thin wrappers so main() below (kept in lockstep with in-flight PR #1265)
# keeps calling these exact names, while the implementations live in
# scripts/lib/api-smoke-common.sh.
setup_run_dir() { smoke_setup_run_dir; }
create_disposable_repo() { smoke_create_disposable_repo "API select smoke"; }
launch_automated_app() {
    smoke_launch_app \
        "WORKSPACES_AUTOMATION_API=1" \
        "WORKSPACES_AUTOMATION_OPERATOR=1" \
        "WORKSPACES_AUTOMATION_SELECT_DRIVER=api"
}

# EXIT trap. Cleanup (app process, disposable repo, created worktree) is
# unconditional now — see smoke_finalize_and_exit — so a failing run leaves
# the same zero residue a passing run does; --keep-artifacts is the opt-out.
on_exit() {
    local code="$?"
    trap - EXIT
    smoke_finalize_and_exit "$code"
}

# Reads the value of $1 from the last JSONL event whose type == $2.
read_workspace_field() {
    local field="$1" event_type="$2"
    python3 - "$EVENTS_PATH" "$field" "$event_type" <<'PY'
import json, sys
from pathlib import Path
path, field, event_type = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
value = ""
if path.exists():
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("type") == event_type and e.get(field):
            value = e[field]
print(value)
PY
}

# Prints the 0-based index of the first event of type $1 at or after index ${3:-0}, optionally
# narrowed to selectionKind $2, or -1. The kind and start-index narrowing is what makes a
# barrier assert the attach this run drove rather than an earlier one of the same type.
event_index() {
    python3 - "$EVENTS_PATH" "$1" "${2:-}" "${3:-0}" <<'PY'
import json, sys
from pathlib import Path
path, target, kind, start = Path(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
idx = -1
if path.exists():
    lines = [l.strip() for l in path.read_text().splitlines() if l.strip()]
    for i, line in enumerate(lines):
        if i < start:
            continue
        event = json.loads(line)
        if event.get("type") == target and (not kind or event.get("selectionKind") == kind):
            idx = i
            break
print(idx)
PY
}

# Prints the top-level string field $2 from the JSON document at $1, or "".
read_json_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text()).get(sys.argv[2])
print("" if value is None else value)
PY
}

# The waits are assertions on what the select gesture left behind, not latency barriers:
# `workspace select` returns only after the real selection gesture completed, so both are
# expected to report waitedMS 0. What makes them load-bearing is the predicates — the
# workspace this script asked for must be the selected one, and the surface the select result
# claims it attached must be live in the tile tree, checked here against app state rather than
# against the app's own milestone stream.
assert_wait_outcomes() {
    python3 - "$RUN_DIR/wait-workspace-selected.json" "$RUN_DIR/wait-surface-attached.json" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path

selected, attached = (json.loads(Path(p).read_text()) for p in sys.argv[1:3])
expected_workspace_id, expected_surface_id = sys.argv[3], sys.argv[4]
failures = []

# UUID spellings differ in case across the JSONL, the verb result, and the wait observation;
# the identity does not.
def uuid_eq(left, right):
    return isinstance(left, str) and left.lower() == right.lower()

observed_selection = selected.get("observed", {}).get("selectedWorkspaceID")
observed_surface = attached.get("observed", {}).get("attachedSurfaceID")

if selected.get("outcome") != "satisfied":
    failures.append(f"workspace_selected outcome={selected.get('outcome')} observed={selected.get('observed')}")
if not uuid_eq(observed_selection, expected_workspace_id):
    failures.append(f"workspace_selected observed selection {observed_selection} != requested {expected_workspace_id}")
if attached.get("outcome") != "satisfied":
    failures.append(f"surface_attached outcome={attached.get('outcome')} observed={attached.get('observed')}")
if not uuid_eq(observed_surface, expected_surface_id):
    failures.append(
        f"surface_attached observed surface {observed_surface} "
        f"!= select result's attachedSurfaceID {expected_surface_id}"
    )

if failures:
    print("ASSERTION FAILED: server-side waits did not confirm the select post-conditions", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print(f"OK: waits confirm workspace {expected_workspace_id} selected and surface {expected_surface_id} attached")
PY
}

# wait_for_event <type> [selectionKind] [start-index]
wait_for_event() {
    local event_type="$1" kind="${2:-}" start="${3:-0}"
    local deadline=$(( $(date +%s) + TOTAL_TIMEOUT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(event_index "$event_type" "$kind" "$start")" != "-1" ]]; then
            return 0
        fi
        # Surface an app-side failure milestone immediately rather than waiting out the timeout.
        if [[ "$(event_index failure)" != "-1" ]]; then
            fail "App reported a failure milestone: $(read_workspace_field message failure)"
        fi
        sleep 1
    done
    fail "Timed out waiting for milestone: $event_type${kind:+ (selectionKind=$kind)}"
}

main() {
    parse_args "$@"
    trap on_exit EXIT
    setup_run_dir
    create_disposable_repo

    if [[ "$SKIP_BUILD" != true ]]; then
        log "Building debug binaries…"
        ( cd "$REPO_ROOT" && swift build >/dev/null )
    fi
    [[ -x "$CLI_BIN" ]] || fail "CLI binary not found at $CLI_BIN (run swift build)."

    log "Launching app (api select driver)…"
    launch_automated_app

    log "Waiting for the app to create the workspace and park on the repo terminal…"
    wait_for_event awaiting_api_select

    local workspace_id
    workspace_id="$(read_workspace_field workspaceID awaiting_api_select)"
    [[ -n "$workspace_id" ]] || fail "Could not read workspaceID from awaiting_api_select."
    log "Workspace id: $workspace_id"

    local await_idx
    await_idx="$(event_index awaiting_api_select)"

    log "Driving API select: workspaces workspace select $workspace_id"
    "$CLI_BIN" workspace select "$workspace_id" --json | tee "$RUN_DIR/select-result.json"

    local attached_surface_id
    attached_surface_id="$(read_json_field "$RUN_DIR/select-result.json" attachedSurfaceID)"
    [[ -n "$attached_surface_id" ]] || fail "workspace select reported no attachedSurfaceID."

    # Two server-side typed waits (POST /v1/wait) check the selection and the terminal attach
    # against the app's own live state, each bound to the id this run cares about. A
    # timed_out/not_applicable outcome exits non-zero (2/3) and fails the run under set -e;
    # assert_wait_outcomes then checks the observations, not just the outcomes.
    log "Confirming the selection server-side (workspaces wait)…"
    "$CLI_BIN" wait --for workspace_selected --workspace-id "$workspace_id" --timeout-ms 20000 --json \
        | tee "$RUN_DIR/wait-workspace-selected.json"
    "$CLI_BIN" wait --for surface_attached --surface-id "$attached_surface_id" --timeout-ms 20000 --json \
        | tee "$RUN_DIR/wait-surface-attached.json"
    assert_wait_outcomes "$workspace_id" "$attached_surface_id"

    # The milestone stream is written asynchronously relative to the verb's return, so the
    # ordering assertion below needs its own barrier. The waits above prove app state; this
    # proves the app emitted the milestone that state should have produced. The
    # awaiting_api_select poll earlier stays JSONL-based for the same reason — that milestone
    # is scenario-driver state the wait vocabulary does not model.
    log "Waiting for the post-handoff terminal_session_attached to reach the milestone stream…"
    wait_for_event terminal_session_attached workspace $((await_idx + 1))

    # Assert a workspace-scoped terminal attach occurred AFTER the handoff — i.e. the API verb, not
    # the app's own scenario, drove it.
    python3 - "$EVENTS_PATH" "$await_idx" <<'PY'
import json, sys
from pathlib import Path
events = [json.loads(l) for l in Path(sys.argv[1]).read_text().splitlines() if l.strip()]
await_idx = int(sys.argv[2])
after = events[await_idx + 1:]
attach = next(
    (e for e in after
     if e.get("type") == "terminal_session_attached" and e.get("selectionKind") == "workspace"),
    None,
)
if attach is None:
    print("ASSERTION FAILED: no workspace-scoped terminal_session_attached after awaiting_api_select", file=sys.stderr)
    for e in after:
        print(f"  - {e.get('type')} kind={e.get('selectionKind')} session={e.get('sessionID')}", file=sys.stderr)
    sys.exit(1)
print(f"OK: API select attached workspace terminal session {attach.get('sessionID')} scope={attach.get('sessionScope')}")
PY

    # Best-effort visual: snapshot the app window (operator scope) in the post-select state, showing
    # the workspace's terminal attached. Composited capture fails on a locked screen (unsupported) —
    # that is fine, the JSONL above is the load-bearing evidence; the snapshot is a bonus when unlocked.
    if "$CLI_BIN" window snapshot --out "$RUN_DIR/after-select.png" >/dev/null 2>&1; then
        log "Captured post-select window snapshot: $RUN_DIR/after-select.png"
    else
        log "Window snapshot unavailable (likely a locked screen) — JSONL + select result stand as evidence."
    fi

    RUN_STATUS="passed"
    log "PASS — API-driven workspace.select attached the workspace terminal via the real binding."
    {
        echo "# API Select Smoke"
        echo
        echo "- Outcome: passed"
        echo "- Workspace id: $workspace_id"
        echo "- Events: $EVENTS_PATH"
        echo "- Select result: $RUN_DIR/select-result.json"
    } >"$RUN_DIR/summary.md"
}

main "$@"
