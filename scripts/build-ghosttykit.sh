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
#   GHOSTTY_ZIG_BIN   Zig executable to use for building Ghostty.
#   GHOSTTY_ZIG_CACHE_DIR Zig cache root for building Ghostty.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/Frameworks"

# Pinned versions for reproducible builds.
GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
ZIG_VERSION="0.15.2"
HOMEBREW_ZIG_BIN="/opt/homebrew/opt/zig@0.15/bin/zig"

GHOSTTY_REPO_URL="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="${GHOSTTY_CACHE_DIR:-$HOME/.cache/workspacemanager}"
ZIG_CACHE_DIR="${GHOSTTY_ZIG_CACHE_DIR:-$CACHE_DIR/zig-cache/$GHOSTTY_COMMIT}"
AUTO_CLONE_DIR="$CACHE_DIR/ghostty"
EXPLICIT_GHOSTTY_DIR="${GHOSTTY_DIR:-}"
EXPLICIT_ZIG_BIN="${GHOSTTY_ZIG_BIN:-}"
GHOSTTY_DIR=""
ZIG_RUNNER=()

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

resolve_zig_runner() {
  if [[ -n "$EXPLICIT_ZIG_BIN" ]]; then
    if [[ ! -x "$EXPLICIT_ZIG_BIN" ]]; then
      die "GHOSTTY_ZIG_BIN is set but is not executable: $EXPLICIT_ZIG_BIN"
    fi

    ZIG_RUNNER=("$EXPLICIT_ZIG_BIN")
    return
  fi

  if [[ -x "$HOMEBREW_ZIG_BIN" ]]; then
    ZIG_RUNNER=("$HOMEBREW_ZIG_BIN")
    return
  fi

  # Some Xcode Cloud macOS images run Homebrew from /usr/local instead of the
  # standard Apple Silicon /opt/homebrew prefix. Only used as a fallback here
  # so a host with a real /opt/homebrew zig@0.15 (checked above) never gets
  # overridden by a different-prefix (and potentially different-arch) one.
  if command -v brew >/dev/null 2>&1; then
    local brew_zig_prefix
    brew_zig_prefix="$(brew --prefix zig@0.15 2>/dev/null || true)"
    if [[ -n "$brew_zig_prefix" && -x "$brew_zig_prefix/bin/zig" ]]; then
      ZIG_RUNNER=("$brew_zig_prefix/bin/zig")
      return
    fi
  fi

  if command -v mise >/dev/null 2>&1; then
    ZIG_RUNNER=(
      env
      "MISE_CONFIG_FILE=$PROJECT_DIR/.mise.toml"
      "MISE_CONFIG_ROOT=$PROJECT_DIR"
      "MISE_IGNORED_CONFIG_PATHS=$HOME/.config/mise${MISE_IGNORED_CONFIG_PATHS:+:$MISE_IGNORED_CONFIG_PATHS}"
      MISE_PARANOID=1
      mise exec --locked "zig@$ZIG_VERSION" -- zig
    )
    return
  fi

  require_cmd mise "https://mise.jdx.dev/"
}

require_msgfmt() {
  if command -v msgfmt >/dev/null 2>&1; then
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    local gettext_prefix
    gettext_prefix="$(brew --prefix gettext 2>/dev/null || true)"
    if [[ -x "$gettext_prefix/bin/msgfmt" ]]; then
      export PATH="$gettext_prefix/bin:$PATH"
      return
    fi
  fi

  die "msgfmt is required to build Ghostty translations (install Homebrew gettext; if it is keg-only, add \$(brew --prefix gettext)/bin to PATH)"
}

rewrite_modulemap() {
  local modulemap_path="$1"

  {
    echo "// This makes Ghostty available to the XCode build for the macOS app."
    echo "// We append \"Kit\" to it not to be cute, but because targets have to have"
    echo "// unique names and we use Ghostty for other things."
    echo "module GhosttyKit {"
    echo "    header \"ghostty.h\""
    echo "    export *"
    echo "}"
  } > "$modulemap_path"
}

archive_exports_ghostty_api() {
  local archive="$1"
  nm -gU "$archive" 2>/dev/null | grep ' _ghostty_init$' >/dev/null
}

find_ghostty_archives() {
  local cache_root="$ZIG_CACHE_DIR/local/o"
  local candidate

  [[ -d "$cache_root" ]] || return 1

  while IFS= read -r candidate; do
    printf '%s\n' "$candidate"
  done < <(find "$cache_root" -type f -name "*.a" -exec ls -1t {} + 2>/dev/null)
}

repair_ghostty_archive_if_needed() {
  local archive="$1"

  if archive_exports_ghostty_api "$archive"; then
    return
  fi

  local archives_file
  archives_file="$(mktemp "${TMPDIR:-/tmp}/workspaces-ghostty-archives.XXXXXX")"
  if ! find_ghostty_archives > "$archives_file" || [[ ! -s "$archives_file" ]]; then
    rm -f "$archives_file"
    die "GhosttyKit archive does not export ghostty_init and no Zig cache archives were found"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-ghostty-archive.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  local index=0
  local source_archive
  while IFS= read -r source_archive; do
    local archive_dir="$tmp_dir/objects/$index"
    mkdir -p "$archive_dir"
    (
      cd "$archive_dir"
      ar -x "$source_archive"
    )
    index=$((index + 1))
  done < "$archives_file"
  rm -f "$archives_file"

  chmod -R u+rwX "$tmp_dir"
  find "$tmp_dir/objects" -type f -name "*.o" -print0 \
    | xargs -0 libtool -static -o "$tmp_dir/libghostty-fat.a"
  mv "$tmp_dir/libghostty-fat.a" "$archive"
  rm -rf "$tmp_dir"
  trap - RETURN

  if ! archive_exports_ghostty_api "$archive"; then
    die "repaired GhosttyKit archive still does not export ghostty_init"
  fi
}

postprocess_xcframework() {
  local framework_dir="$1"

  while IFS= read -r modulemap; do
    rewrite_modulemap "$modulemap"
  done < <(find "$framework_dir" -type f -name module.modulemap)

  while IFS= read -r archive; do
    repair_ghostty_archive_if_needed "$archive"
    xcrun strip -S -x "$archive"
  done < <(find "$framework_dir" -type f -name "libghostty-fat.a")
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
    # Ghostty's `tip` tag moves; force tag updates so it does not block pinned commits.
    git -C "$GHOSTTY_DIR" fetch --force --tags origin
    git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_COMMIT"
  fi
}

build_ghostty_xcframework() {
  (
    cd "$GHOSTTY_DIR"
    mkdir -p "$ZIG_CACHE_DIR/local" "$ZIG_CACHE_DIR/global"
    "${ZIG_RUNNER[@]}" build \
      --cache-dir "$ZIG_CACHE_DIR/local" \
      --global-cache-dir "$ZIG_CACHE_DIR/global" \
      -Demit-xcframework=true \
      -Demit-macos-app=false \
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
  require_cmd git
  require_cmd xcrun
  require_msgfmt
  resolve_zig_runner

  resolve_ghostty_dir
  ensure_ghostty_checkout
  ensure_pinned_commit
  build_ghostty_xcframework

  local xcframework_src
  if ! xcframework_src="$(find_xcframework_src)"; then
    die "expected xcframework not found in known output locations"
  fi

  install_xcframework "$xcframework_src"
  postprocess_xcframework "$OUT_DIR/GhosttyKit.xcframework"
  echo "Built GhosttyKit.xcframework -> $OUT_DIR/GhosttyKit.xcframework"
}

main "$@"
