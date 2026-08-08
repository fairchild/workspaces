#!/bin/bash
# Synthetic-run isolation boundary (WORKSPACES_SYNTHETIC_ROOT). Every smoke or
# capture launch of the app points this at a disposable directory inside its own
# run dir, so workspace worktrees and orphan scans never touch the owner's real
# workspaces root. The app honors it in WorkspaceService/WorkspaceOrphanReconciler.

# synthetic_root_ensure <default-dir> — resolve WORKSPACES_SYNTHETIC_ROOT (a
# caller-exported value wins, otherwise <default-dir>), require it to be an
# absolute path, create it, and export it for the app launch.
synthetic_root_ensure() {
    local default_dir="${1:-}"
    if [[ -z "${WORKSPACES_SYNTHETIC_ROOT:-}" ]]; then
        WORKSPACES_SYNTHETIC_ROOT="$default_dir"
    fi
    if [[ -z "${WORKSPACES_SYNTHETIC_ROOT:-}" ]]; then
        echo "error: WORKSPACES_SYNTHETIC_ROOT is empty and no default run-dir root was provided." >&2
        return 1
    fi
    if [[ "$WORKSPACES_SYNTHETIC_ROOT" != /* ]]; then
        echo "error: WORKSPACES_SYNTHETIC_ROOT must be an absolute path (got: $WORKSPACES_SYNTHETIC_ROOT)." >&2
        return 1
    fi
    if ! mkdir -p "$WORKSPACES_SYNTHETIC_ROOT"; then
        echo "error: failed to create WORKSPACES_SYNTHETIC_ROOT directory: $WORKSPACES_SYNTHETIC_ROOT" >&2
        return 1
    fi
    export WORKSPACES_SYNTHETIC_ROOT
    return 0
}

# synthetic_root_require — launch gate: refuse to start a synthetic run without
# the isolation root exported non-empty.
synthetic_root_require() {
    if [[ -z "${WORKSPACES_SYNTHETIC_ROOT:-}" ]]; then
        echo "error: WORKSPACES_SYNTHETIC_ROOT must be set (non-empty) before launching a synthetic run." >&2
        echo "       Call synthetic_root_ensure <run-dir>/workspaces-root first (scripts/lib/synthetic-root.sh)." >&2
        return 1
    fi
}
