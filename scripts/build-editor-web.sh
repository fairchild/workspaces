#!/usr/bin/env bash
#
# build-editor-web.sh — build the embedded CodeMirror diff/editor bundle and stage it
# into the app's SPM resources so `swift build` packages it without a Node toolchain.
#
# The built output under Sources/WorkspaceManager/Resources/DiffEditorWeb is committed,
# mirroring how the prebuilt GhosttyKit.xcframework keeps plain `swift build` working.
# Run this after changing anything under editor-web/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/editor-web"
DEST="$ROOT/Sources/WorkspaceManager/Resources/DiffEditorWeb"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build editor-web (https://bun.sh)" >&2
  exit 1
fi

echo "[build-editor-web] installing dependencies"
(cd "$SRC" && bun install --frozen-lockfile)

echo "[build-editor-web] building bundle"
(cd "$SRC" && bun run build)

echo "[build-editor-web] staging into $DEST"
mkdir -p "$DEST"
cp "$SRC/dist/main.js" "$DEST/main.js"
cp "$SRC/index.html" "$DEST/index.html"

echo "[build-editor-web] done"
ls -la "$DEST"
