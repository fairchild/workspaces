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
#   3. Answer each `awaiting_api_repo_terminal` handoff with `workspaces
#      automation repo terminal <repo-id>`, so the walk's repo step crosses the
#      socket like the rest of it (#958). The app holds at the handoff and waits
#      for the attach this verb produces instead of driving the gesture itself.
#   4. Read the workspace target with `workspaces workspace list`, then reselect
#      the workspace with `workspaces workspace select`.
#
# Every selection in the daily-driver walk — workspace, repo, workspace — is
# therefore driven from outside the app.
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
- Repo selection driver: external \`workspaces automation repo terminal\` (#958)
EOF
    if [[ -n "$LAUNCH_LOG_PATH" && -f "$LAUNCH_LOG_PATH" ]]; then
        cp "$LAUNCH_LOG_PATH" "$RUN_DIR/launch.log" 2>/dev/null || true
    fi
}

# Prints the repoID carried by the <n>th (1-based) awaiting_api_repo_terminal
# milestone, or "" when that many have not landed yet.
repo_terminal_handoff_id() {
    python3 - "$EVENTS_PATH" "$1" <<'HANDOFF_PY'
import json, sys
from pathlib import Path
path, occurrence = Path(sys.argv[1]), int(sys.argv[2])
handoffs = []
if path.exists():
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "awaiting_api_repo_terminal":
            handoffs.append(event.get("repoID") or "")
print(handoffs[occurrence - 1] if len(handoffs) >= occurrence else "")
HANDOFF_PY
}

# The verb has to report the attach it made, not merely exit 0 — an "opened, no
# terminal attached" result is the walk quietly losing its repo step.
assert_repo_terminal_result() {
    python3 - "$1" "$2" <<'REPO_RESULT_PY'
import json, sys
from pathlib import Path
result, label = json.loads(Path(sys.argv[1]).read_text()), sys.argv[2]
if not result.get("attachedTerminal"):
    print(f"ASSERTION FAILED: repo.terminal ({label}) attached no terminal: {result}", file=sys.stderr)
    sys.exit(1)
if not result.get("attachedSurfaceID"):
    print(f"ASSERTION FAILED: repo.terminal ({label}) reported no surface: {result}", file=sys.stderr)
    sys.exit(1)
print(f"OK: repo.terminal ({label}) attached surface {result['attachedSurfaceID']} at {result.get('directoryPath')}")
REPO_RESULT_PY
}

# Blocks for the <n>th repo-terminal handoff, then answers it with the operator
# verb. The app is holding its own attach wait while this runs, so a round trip
# slow enough to matter surfaces as that wait expiring rather than as a hang.
drive_repo_terminal_handoff() {
    local occurrence="$1" label="$2" repo_id=""
    local deadline=$(( $(date +%s) + TOTAL_TIMEOUT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        repo_id="$(repo_terminal_handoff_id "$occurrence")"
        [[ -n "$repo_id" ]] && break
        if [[ "$(smoke_event_index failure)" != "-1" ]]; then
            fail "App reported a failure milestone: $(smoke_read_event_field message failure)"
        fi
        sleep 1
    done
    [[ -n "$repo_id" ]] || fail "Timed out waiting for repo-terminal handoff #$occurrence"

    log "Driving API repo terminal ($label): workspaces automation repo terminal $repo_id"
    "$CLI_BIN" automation repo terminal "$repo_id" --json \
        | tee "$RUN_DIR/repo-terminal-$label.json"
    assert_repo_terminal_result "$RUN_DIR/repo-terminal-$label.json" "$label"
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
    "awaiting_api_repo_terminal",
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

# The repo step is externally driven now (#958): each repo attach must follow an
# awaiting_api_repo_terminal handoff, which is what makes it the verb's work and
# not the app's. Two handoffs, one before create and one mid-walk.
repo_handoffs = [index for index, event in enumerate(events)
                 if event.get("type") == "awaiting_api_repo_terminal"]
if len(repo_handoffs) != 2:
    fail(f"expected 2 repo-terminal handoffs, saw {len(repo_handoffs)}")
if not (repo_handoffs[0] < await_create < repo_handoffs[1] < await_select):
    fail(
        "repo-terminal handoffs were not one before create and one before select: "
        f"{repo_handoffs} against create={await_create} select={await_select}"
    )

repo_attach_indices = [index for index, event in attaches if event.get("selectionKind") == "repo"]

# Each handoff needs EXACTLY ONE attach before the next handoff. "At least one"
# would pass a run where the app parked itself right after announcing the
# handoff and the verb then attached a second time — the regression this lane
# exists to catch, wearing the evidence of the fix.
handoff_bounds = repo_handoffs[1:] + [len(events)]
for handoff, next_handoff in zip(repo_handoffs, handoff_bounds):
    answering = [index for index in repo_attach_indices if handoff < index < next_handoff]
    if len(answering) != 1:
        fail(
            f"expected exactly 1 repo terminal attach answering the handoff at index "
            f"{handoff}, saw {len(answering)} at {answering} — 0 means the verb never ran, "
            "more than 1 means something attached the repo terminal besides the verb"
        )

# And nothing may attach the repo terminal before the first handoff: an attach
# there is the app parking itself, which is the thing this lane stopped doing.
if any(index < repo_handoffs[0] for index in repo_attach_indices):
    fail("a repo terminal attached before any handoff — the app parked itself")

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

    log "Answering the repo-terminal handoff that precedes create..."
    drive_repo_terminal_handoff 1 before-create

    log "Waiting for API create handoff..."
    smoke_wait_for_event awaiting_api_create

    workspace_list_json "$RUN_DIR/workspace-list-before-create.json"
    local repo_id
    repo_id="$(extract_repo_id "$RUN_DIR/workspace-list-before-create.json")"
    log "Repo id from workspace list: $repo_id"

    log "Driving API create: workspaces workspace create $repo_id $WORKSPACE_NAME"
    "$CLI_BIN" workspace create "$repo_id" "$WORKSPACE_NAME" --json | tee "$RUN_DIR/create-result.json"
    assert_create_result

    log "Answering the repo-terminal handoff in the middle of the walk..."
    drive_repo_terminal_handoff 2 walk-repo-step

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
