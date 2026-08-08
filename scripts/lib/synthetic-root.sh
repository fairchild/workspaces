#!/bin/bash
# Synthetic-run isolation boundary (WORKSPACES_SYNTHETIC_ROOT). Every smoke or
# capture launch of the app points this at a disposable directory inside its own
# run dir, so workspace worktrees and orphan scans never touch the owner's real
# workspaces root. The app honors it in WorkspaceService/WorkspaceOrphanReconciler.

# The real workspaces root this boundary exists to protect. The app resolves its
# root as WORKSPACES_SYNTHETIC_ROOT → the `workspacesRoot` UserDefaults override
# → ~/workspaces (WorkspaceService.swift); only the last of those is readable
# from the shell, so that is the one these checks compare against.
synthetic_root_real_root() {
    local home="${HOME:-}"
    while [[ "$home" == */ ]]; do
        home="${home%/}"
    done
    printf '%s\n' "$home/workspaces"
}

# Trailing-slash-insensitive comparison form; "/" stays "/".
synthetic_root_normalize_path() {
    local path="$1"
    while [[ "$path" == */ && "$path" != "/" ]]; do
        path="${path%/}"
    done
    printf '%s\n' "$path"
}

# Symlink-resolved form when the path exists, otherwise the path as given — so a
# synthetic root that reaches the real one through a symlink is still caught.
synthetic_root_physical_path() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    else
        printf '%s\n' "$path"
    fi
}

# True when <candidate> is the real root or an ancestor of it — the two shapes
# that put real worktrees inside the scan boundary. The reverse (a candidate
# nested inside the real root) is allowed on purpose: the scan root is then the
# candidate itself, so real worktrees beside it stay out of range, and a checkout
# under ~/workspaces — the layout this app creates for its own repo — produces
# exactly that shape.
synthetic_root_covers() {
    local candidate="$1" real="$2"
    [[ -n "$candidate" && -n "$real" ]] || return 1
    [[ "$candidate" == "$real" ]] && return 0

    local candidate_prefix="$candidate/"
    [[ "$candidate" == "/" ]] && candidate_prefix="/"
    [[ "$real" == "$candidate_prefix"* ]] && return 0
    return 1
}

# synthetic_root_reject_real_root — a root that is set is not yet a root that is
# synthetic. Pointing WORKSPACES_SYNTHETIC_ROOT at the real workspaces root (or
# at an ancestor of it like $HOME or /) satisfies every other check here while
# leaving the orphan scan reading real worktrees, which is the one thing this
# boundary exists to prevent — so refuse the launch loudly.
synthetic_root_reject_real_root() {
    local candidate="${WORKSPACES_SYNTHETIC_ROOT:-}"
    [[ -n "$candidate" ]] || return 0

    local real
    candidate="$(synthetic_root_normalize_path "$candidate")"
    real="$(synthetic_root_normalize_path "$(synthetic_root_real_root)")"

    if synthetic_root_covers "$candidate" "$real" \
        || synthetic_root_covers \
            "$(synthetic_root_physical_path "$candidate")" \
            "$(synthetic_root_physical_path "$real")"; then
        echo "error: WORKSPACES_SYNTHETIC_ROOT ($candidate) is the real workspaces root ($real), or contains it." >&2
        echo "       A synthetic run root must be a disposable directory that holds no real worktrees;" >&2
        echo "       otherwise the run still scans them and the isolation boundary is decorative." >&2
        return 1
    fi
    return 0
}

# synthetic_root_ensure <default-dir> — resolve WORKSPACES_SYNTHETIC_ROOT (a
# caller-exported value wins, otherwise <default-dir>), require it to be an
# absolute path that is neither the real workspaces root nor an ancestor of it,
# create it, and export it for the app launch.
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
    # Rejected before mkdir: a bad value must not create directories inside the
    # real root on its way to failing.
    synthetic_root_reject_real_root || return 1
    if ! mkdir -p "$WORKSPACES_SYNTHETIC_ROOT"; then
        echo "error: failed to create WORKSPACES_SYNTHETIC_ROOT directory: $WORKSPACES_SYNTHETIC_ROOT" >&2
        return 1
    fi
    export WORKSPACES_SYNTHETIC_ROOT
    return 0
}

# synthetic_root_require — launch gate: refuse to start a synthetic run without
# the isolation root exported non-empty and pointing somewhere actually
# synthetic. Re-checks the real-root rule here as well as in ensure, so a caller
# that sets the variable by hand still hits the gate.
synthetic_root_require() {
    if [[ -z "${WORKSPACES_SYNTHETIC_ROOT:-}" ]]; then
        echo "error: WORKSPACES_SYNTHETIC_ROOT must be set (non-empty) before launching a synthetic run." >&2
        echo "       Call synthetic_root_ensure <run-dir>/workspaces-root first (scripts/lib/synthetic-root.sh)." >&2
        return 1
    fi
    synthetic_root_reject_real_root || return 1
}
