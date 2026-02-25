#!/bin/bash
# Deterministic preview-open window capture for Open-in-editor header polish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="$REPO_ROOT/output/preview-open"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_PATH="$OUTPUT_DIR/preview-open-${TIMESTAMP}.png"

PREVIEW_REPO="${WORKSPACES_UI_FIXTURE_PREVIEW_REPO:-skills}"
PREVIEW_PATH="${WORKSPACES_UI_FIXTURE_PREVIEW_PATH:-README.md}"
APP_PROCESS_NAMES=("WorkspaceManager" "Workspaces")

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

mkdir -p "$OUTPUT_DIR"

log "Launching fixture app with preview bootstrap (repo=$PREVIEW_REPO path=$PREVIEW_PATH)..."
LAUNCH_OUTPUT="$(
    cd "$REPO_ROOT"
    WORKSPACES_UI_FIXTURE_OPEN_PREVIEW=1 \
        WORKSPACES_UI_FIXTURE_PREVIEW_REPO="$PREVIEW_REPO" \
        WORKSPACES_UI_FIXTURE_PREVIEW_PATH="$PREVIEW_PATH" \
        ./scripts/launch-dev.sh --fixture --clean-data
)"
printf "%s\n" "$LAUNCH_OUTPUT"

LOG_PATH="$(printf "%s\n" "$LAUNCH_OUTPUT" | sed -n 's/.*Log file: //p' | tail -1)"
if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
    for attempt in $(seq 1 20); do
        if rg -q "\\[UIFixture\\] Preview bootstrap applied" "$LOG_PATH"; then
            break
        fi
        sleep 0.25
    done
    if ! rg -q "\\[UIFixture\\] Preview bootstrap applied" "$LOG_PATH"; then
        echo "ERROR: fixture preview bootstrap log not observed in $LOG_PATH" >&2
        exit 1
    fi
fi

log "Activating app window..."
activated=false
for process_name in "${APP_PROCESS_NAMES[@]}"; do
    if osascript -e "tell application \"System Events\" to set frontmost of process \"$process_name\" to true" >/dev/null 2>&1; then
        activated=true
        break
    fi
done

if [[ "$activated" != true ]]; then
    echo "ERROR: failed to activate WorkspaceManager window" >&2
    exit 1
fi

log "Capturing window..."
WIN_ID=""
for attempt in $(seq 1 8); do
    for process_name in "${APP_PROCESS_NAMES[@]}"; do
        WIN_ID="$(osascript \
            -e 'with timeout of 1 seconds' \
            -e "tell application \"System Events\" to tell process \"$process_name\" to return id of window 1" \
            -e 'end timeout' \
            2>/dev/null || true)"
        if [[ "$WIN_ID" =~ ^[0-9]+$ ]]; then
            break
        fi
    done
    if [[ "$WIN_ID" =~ ^[0-9]+$ ]]; then break; fi
    WIN_ID=""
    sleep 0.25
done

if [[ ! "$WIN_ID" =~ ^[0-9]+$ ]]; then
    log "WARN: could not resolve app window id; falling back to full-screen capture"
    if ! screencapture -x "$OUTPUT_PATH"; then
        echo "ERROR: failed to capture preview window" >&2
        exit 1
    fi
else
    if ! screencapture -x -l "$WIN_ID" "$OUTPUT_PATH"; then
        log "WARN: window-specific capture failed; falling back to full-screen capture"
        if ! screencapture -x "$OUTPUT_PATH"; then
            echo "ERROR: failed to capture preview window" >&2
            exit 1
        fi
    fi
fi

cp "$OUTPUT_PATH" "$OUTPUT_DIR/latest.png"

log "Capture complete"
log "Screenshot: $OUTPUT_PATH"
log "Latest: $OUTPUT_DIR/latest.png"
