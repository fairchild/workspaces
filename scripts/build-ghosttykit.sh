#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# build-ghosttykit.sh
#
# Builds the pinned GhosttyKit xcframework used by this repository's
# Swift Package Manager (SwiftPM) binary target at
# `Frameworks/GhosttyKit.xcframework`.
#
# Why this exists in Workspaces:
# - The app embeds libghostty for terminal rendering/input.
# - We pin a Ghostty commit so local + continuous integration (CI) builds are
#   reproducible.
# - This script standardizes where Ghostty comes from and where the framework
#   lands so `swift build` and Xcode open/build work reliably.
#
# Usage:
#   ./scripts/build-ghosttykit.sh
#
# Optional environment variables:
#   GHOSTTY_DIR       Existing Ghostty checkout (must already be at pinned commit).
#   GHOSTTY_CACHE_DIR Cache root for auto-cloned Ghostty checkout.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/Frameworks"

# Pinned versions for reproducible builds.
GHOSTTY_COMMIT="da10707f93104c5466cd4e64b80ff48f789238a0"
ZIG_VERSION="0.15.2"

GHOSTTY_REPO_URL="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="${GHOSTTY_CACHE_DIR:-$HOME/.cache/workspacemanager}"
AUTO_CLONE_DIR="$CACHE_DIR/ghostty"
EXPLICIT_GHOSTTY_DIR="${GHOSTTY_DIR:-}"
GHOSTTY_DIR=""

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die "$cmd is required ($hint)"
    fi
    die "$cmd is required"
  fi
}

resolve_ghostty_dir() {
  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    GHOSTTY_DIR="$EXPLICIT_GHOSTTY_DIR"
  else
    GHOSTTY_DIR="$AUTO_CLONE_DIR"
  fi
}

ensure_ghostty_checkout() {
  if [[ -d "$GHOSTTY_DIR/.git" ]]; then
    return
  fi

  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    die "GHOSTTY_DIR is set but is not a git checkout: $GHOSTTY_DIR"
  fi

  mkdir -p "$CACHE_DIR"
  rm -rf "$GHOSTTY_DIR"
  git clone "$GHOSTTY_REPO_URL" "$GHOSTTY_DIR"
}

ensure_pinned_commit() {
  local current_commit
  current_commit="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"

  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    if [[ "$current_commit" != "$GHOSTTY_COMMIT" ]]; then
      die "GHOSTTY_DIR is not at pinned commit
  expected: $GHOSTTY_COMMIT
  actual:   $current_commit"
    fi
    return
  fi

  if [[ "$current_commit" != "$GHOSTTY_COMMIT" ]]; then
    git -C "$GHOSTTY_DIR" fetch --tags origin
    git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_COMMIT"
  fi
}

build_ghostty_xcframework() {
  (
    cd "$GHOSTTY_DIR"
    mise exec "zig@$ZIG_VERSION" -- zig build \
      -Demit-xcframework=true \
      -Dxcframework-target=native \
      -Doptimize=ReleaseFast
  )
}

find_xcframework_src() {
  local candidate
  local candidates=(
    "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
    "$GHOSTTY_DIR/zig-out/macos/GhosttyKit.xcframework"
    "$GHOSTTY_DIR/zig-out/GhosttyKit.xcframework"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

install_xcframework() {
  local src="$1"
  mkdir -p "$OUT_DIR"
  rm -rf "$OUT_DIR/GhosttyKit.xcframework"
  cp -R "$src" "$OUT_DIR/"
}

main() {
  require_cmd mise "https://mise.jdx.dev/"
  require_cmd git

  resolve_ghostty_dir
  ensure_ghostty_checkout
  ensure_pinned_commit
  build_ghostty_xcframework

  local xcframework_src
  if ! xcframework_src="$(find_xcframework_src)"; then
    die "expected xcframework not found in known output locations"
  fi

  install_xcframework "$xcframework_src"
  echo "Built GhosttyKit.xcframework -> $OUT_DIR/GhosttyKit.xcframework"
}

main "$@"
