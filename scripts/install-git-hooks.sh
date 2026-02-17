#!/usr/bin/env bash
# ==========================================================================
# install-git-hooks.sh - Install repository-managed Git hooks
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.githooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "ERROR: hooks directory not found: $HOOKS_DIR" >&2
    exit 1
fi

chmod +x "$HOOKS_DIR"/pre-commit

if git -C "$REPO_ROOT" config --worktree core.hooksPath "$HOOKS_DIR" 2>/dev/null; then
    # Avoid leaking a worktree-specific absolute path into shared repo config.
    current_local_hooks_path="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"
    if [[ "$current_local_hooks_path" == "$HOOKS_DIR" ]]; then
        git -C "$REPO_ROOT" config --local --unset core.hooksPath || true
    fi
    config_scope="worktree"
else
    git -C "$REPO_ROOT" config --local core.hooksPath "$HOOKS_DIR"
    config_scope="local"
fi

echo "Installed Git hooks:"
echo "  scope=$config_scope"
echo "  core.hooksPath=$HOOKS_DIR"
