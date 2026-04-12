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
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

is_non_black_capture() {
    local image_path="$1"
    swift - "$image_path" <<'SWIFT'
import AppKit
import Foundation

let imagePath = CommandLine.arguments[1]
guard
    let image = NSImage(contentsOfFile: imagePath),
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff)
else {
    exit(2)
}

let width = rep.pixelsWide
let height = rep.pixelsHigh
let stride = max(1, min(width, height) / 200)
var sampledPixels = 0
var visiblePixels = 0

for y in Swift.stride(from: 0, to: height, by: stride) {
    for x in Swift.stride(from: 0, to: width, by: stride) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        sampledPixels += 1
        if color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
            visiblePixels += 1
        }
    }
}

let visibleRatio = sampledPixels > 0 ? Double(visiblePixels) / Double(sampledPixels) : 0
exit(visibleRatio >= 0.01 ? 0 : 1)
SWIFT
}

mkdir -p "$OUTPUT_DIR"

if [[ ! -x "$CAPTURE_SCRIPT" ]]; then
    echo "ERROR: capture helper not found or not executable: $CAPTURE_SCRIPT" >&2
    exit 1
fi

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

log "Capturing app window..."
captured=false
for attempt in $(seq 1 10); do
    if "$CAPTURE_SCRIPT" --activate --output "$OUTPUT_PATH"; then
        captured=true
        break
    fi
    sleep 0.25
done

if [[ "$captured" != true ]]; then
    log "WARN: window capture failed after retries; attempting full-screen fallback"
    if ! screencapture -x "$OUTPUT_PATH"; then
        echo "ERROR: failed to capture WorkspaceManager window and full-screen fallback" >&2
        exit 1
    fi
fi

if ! is_non_black_capture "$OUTPUT_PATH"; then
    echo "ERROR: screenshot appears fully black (check macOS Screen Recording permission for Terminal/Codex)" >&2
    exit 1
fi

cp "$OUTPUT_PATH" "$OUTPUT_DIR/latest.png" >/dev/null 2>&1 || true

log "Capture complete"
log "Screenshot: $OUTPUT_PATH"
log "Latest: $OUTPUT_DIR/latest.png"
