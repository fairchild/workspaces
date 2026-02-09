#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/Frameworks"

# Pinned for reproducible builds.
GHOSTTY_COMMIT="da10707f93104c5466cd4e64b80ff48f789238a0"
GHOSTTY_REPO_URL="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="${GHOSTTY_CACHE_DIR:-$HOME/.cache/workspacemanager}"
AUTO_CLONE_DIR="$CACHE_DIR/ghostty"
EXPLICIT_GHOSTTY_DIR="${GHOSTTY_DIR:-}"

if ! command -v mise >/dev/null 2>&1; then
  echo "error: mise is required (https://mise.jdx.dev/)" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required" >&2
  exit 1
fi

if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
  GHOSTTY_DIR="$EXPLICIT_GHOSTTY_DIR"
else
  GHOSTTY_DIR="$AUTO_CLONE_DIR"
fi

if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    echo "error: GHOSTTY_DIR is set but is not a git checkout: $GHOSTTY_DIR" >&2
    exit 1
  fi

  mkdir -p "$CACHE_DIR"
  rm -rf "$GHOSTTY_DIR"
  git clone "$GHOSTTY_REPO_URL" "$GHOSTTY_DIR"
fi

cd "$GHOSTTY_DIR"
CURRENT_COMMIT="$(git rev-parse HEAD)"

if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
  if [[ "$CURRENT_COMMIT" != "$GHOSTTY_COMMIT" ]]; then
    echo "error: GHOSTTY_DIR is not at pinned commit" >&2
    echo "  expected: $GHOSTTY_COMMIT" >&2
    echo "  actual:   $CURRENT_COMMIT" >&2
    exit 1
  fi
else
  if [[ "$CURRENT_COMMIT" != "$GHOSTTY_COMMIT" ]]; then
    git fetch --tags origin
    git checkout --detach "$GHOSTTY_COMMIT"
  fi
fi

mise exec zig@0.15.2 -- zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast

XCFRAMEWORK_SRC=""
for candidate in \
  "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" \
  "$GHOSTTY_DIR/zig-out/macos/GhosttyKit.xcframework" \
  "$GHOSTTY_DIR/zig-out/GhosttyKit.xcframework"; do
  if [[ -d "$candidate" ]]; then
    XCFRAMEWORK_SRC="$candidate"
    break
  fi
done

if [[ -z "$XCFRAMEWORK_SRC" ]]; then
  echo "error: expected xcframework not found in known output locations" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/GhosttyKit.xcframework"
cp -R "$XCFRAMEWORK_SRC" "$OUT_DIR/"

echo "Built GhosttyKit.xcframework -> $OUT_DIR/GhosttyKit.xcframework"
