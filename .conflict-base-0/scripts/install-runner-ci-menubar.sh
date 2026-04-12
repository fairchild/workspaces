#!/bin/bash
# Install the SwiftBar runner status plugin into the configured plugin folder.
#
# Usage:
#   ./scripts/install-runner-ci-menubar.sh
#   ./scripts/install-runner-ci-menubar.sh ~/swiftbar
#   SWIFTBAR_PLUGIN_DIR=~/swiftbar ./scripts/install-runner-ci-menubar.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="runner-ci-menubar.5s.sh"
PLUGIN_DIR_ARG="${1:-}"

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf '%s\n' "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf '%s\n' "$HOME/${path#~/}"
        return
    fi
    printf '%s\n' "$path"
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/install-runner-ci-menubar.sh [plugin-dir]

Installs the SwiftBar runner status plugin as a real file so it keeps working
even if the current checkout or worktree moves.

Resolution order for plugin-dir:
  1. First positional argument
  2. SWIFTBAR_PLUGIN_DIR
  3. ~/Library/Application Support/SwiftBar/Plugins
  4. ~/swiftbar
USAGE
}

resolve_plugin_dir() {
    if [[ -n "$PLUGIN_DIR_ARG" ]]; then
        expand_home_prefix "$PLUGIN_DIR_ARG"
        return
    fi

    if [[ -n "${SWIFTBAR_PLUGIN_DIR:-}" ]]; then
        expand_home_prefix "$SWIFTBAR_PLUGIN_DIR"
        return
    fi

    local official_dir="$HOME/Library/Application Support/SwiftBar/Plugins"
    if [[ -d "$official_dir" ]]; then
        printf '%s\n' "$official_dir"
        return
    fi

    local legacy_dir="$HOME/swiftbar"
    if [[ -d "$legacy_dir" ]]; then
        printf '%s\n' "$legacy_dir"
        return
    fi

    return 1
}

if [[ "$PLUGIN_DIR_ARG" == "--help" || "$PLUGIN_DIR_ARG" == "-h" ]]; then
    usage
    exit 0
fi

PLUGIN_DIR="$(resolve_plugin_dir)" || {
    echo "Could not determine the SwiftBar plugin folder." >&2
    echo "Pass it explicitly, for example: ./scripts/install-runner-ci-menubar.sh ~/swiftbar" >&2
    exit 1
}

PLUGIN_DIR="$(expand_home_prefix "$PLUGIN_DIR")"
SIDECAR_DIR="$PLUGIN_DIR/.runner-ci-menubar"
PLUGIN_DEST="$PLUGIN_DIR/$PLUGIN_NAME"
STATUS_DEST="$SIDECAR_DIR/runner-status.sh"

mkdir -p "$PLUGIN_DIR" "$SIDECAR_DIR"
rm -f "$PLUGIN_DEST"
install -m 755 "$SCRIPT_DIR/runner-ci-menubar.5s.sh" "$PLUGIN_DEST"
install -m 755 "$SCRIPT_DIR/runner-status.sh" "$STATUS_DEST"

cat <<EOF
Installed SwiftBar plugin:
  Plugin: $PLUGIN_DEST
  Helper: $STATUS_DEST

If SwiftBar is already pointing at $PLUGIN_DIR, refresh the plugin or reopen SwiftBar.
EOF
