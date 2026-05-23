#!/bin/bash
# Capture a deterministic WorkSpaces screenshot in a named fixture state.
#
# Single source of truth for scenarios. Documented mirror lives in
# `.claude/skills/release-screenshot/references/scenarios.md` — if you change
# the `case` arm below, update that table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/ui-test-common.sh
source "$REPO_ROOT/scripts/lib/ui-test-common.sh"

scenario=""
output_path=""
do_build=1
keep_running=0

usage() {
    cat <<EOF
Usage: capture.sh <scenario> [--output PATH] [--no-build] [--keep-running]
       capture.sh --scenario <id-or-inline> [--output PATH] [...]

Scenarios:
  phase-1-release   Matches .context/ux-review/release-screenshot.png
  attention-only    Single workspace awaiting input
  clean             Baseline — no agent states
  inline:<env>      Pass <env> directly as WORKSPACES_UI_FIXTURE_AGENT_STATES
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            scenario="$2"
            shift 2
            ;;
        --output)
            output_path="$2"
            shift 2
            ;;
        --no-build)
            do_build=0
            shift
            ;;
        --keep-running)
            keep_running=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$scenario" ]]; then
                scenario="$1"
                shift
            else
                echo "Unknown argument: $1" >&2
                usage
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$scenario" ]]; then
    echo "ERROR: scenario is required." >&2
    usage
    exit 2
fi

if [[ "$scenario" == inline:* ]]; then
    agent_states="${scenario#inline:}"
    scenario_id="inline"
else
    case "$scenario" in
        phase-1-release)
            agent_states="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        attention-only)
            agent_states="bugfix-422:awaitingInput"
            ;;
        clean)
            agent_states=""
            ;;
        *)
            echo "ERROR: unknown scenario '$scenario'." >&2
            usage
            exit 2
            ;;
    esac
    scenario_id="$scenario"
fi

DEFAULT_OUTPUT_DIR="$REPO_ROOT/output/release-screenshots"
mkdir -p "$DEFAULT_OUTPUT_DIR"
timestamp="$(date +%Y%m%d-%H%M%S)"
default_output="$DEFAULT_OUTPUT_DIR/${scenario_id}-${timestamp}.png"

ws_prepare_artifacts "release-screenshot-${scenario_id}"
ws_register_cleanup_trap

ws_log "=== release-screenshot · ${scenario_id} ==="
ws_kill_existing
ws_require_cmd swift
ws_require_cmd osascript
ws_require_cmd screencapture

export WORKSPACES_UI_FIXTURE=1
export WORKSPACES_DISABLE_AUTO_IMPORT=1
if [[ -n "$agent_states" ]]; then
    export WORKSPACES_UI_FIXTURE_AGENT_STATES="$agent_states"
    ws_log "WORKSPACES_UI_FIXTURE_AGENT_STATES=${agent_states}"
else
    unset WORKSPACES_UI_FIXTURE_AGENT_STATES || true
fi

if [[ $do_build -eq 1 ]]; then
    ws_build_app
fi

ws_launch_app 4
ws_activate_app
ws_take_window_screenshot "$scenario_id"

captured="$ARTIFACT_DIR/${scenario_id}.png"
cp "$captured" "$default_output"
final_path="$default_output"
if [[ -n "$output_path" ]]; then
    cp "$captured" "$output_path"
    final_path="$output_path"
fi

if [[ $keep_running -eq 0 ]]; then
    ws_log "Stopping app..."
    ws_stop_app
else
    ws_log "Leaving app running (--keep-running)."
fi

ws_log "=== capture complete ==="
echo "$final_path"
