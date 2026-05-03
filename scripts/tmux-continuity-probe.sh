#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/tmux-continuity-probe.sh start <path> [label]
  scripts/tmux-continuity-probe.sh check <path> [label]
  scripts/tmux-continuity-probe.sh cleanup <path> [label]

Starts or checks a deterministic Workspaces tmux session on the dedicated
"workspaces" socket. Use start before an app restart, sleep/wake, logout, or
reboot boundary; use check after the boundary to record whether the session,
cwd, and marker state survived.
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 64
fi

action="$1"
target_path="$2"
label="${3:-manual}"
socket_name="workspaces"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is not available on PATH" >&2
  exit 69
fi

if [[ ! -d "$target_path" ]]; then
  echo "target path is not a directory: $target_path" >&2
  exit 66
fi

real_path="$(cd "$target_path" && pwd -P)"
base="$(basename "$real_path" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/^$/session/')"
base="${base:0:20}"
hash_prefix="$(printf '%s' "$real_path" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
session_name="probe-${base}-${hash_prefix}"
marker="/tmp/workspaces-continuity-${session_name}.txt"

case "$action" in
  start)
    tmux -L "$socket_name" new-session -A -d -s "$session_name" -c "$real_path" \
      "printf 'started %s\npath %s\nlabel %s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$real_path\" \"$label\" > '$marker'; while true; do sleep 60; done"
    echo "started session=$session_name socket=$socket_name path=$real_path marker=$marker"
    ;;
  check)
    if ! tmux -L "$socket_name" has-session -t "$session_name" 2>/dev/null; then
      echo "missing session=$session_name socket=$socket_name"
      exit 1
    fi

    pane_cwd="$(tmux -L "$socket_name" display-message -p -t "$session_name" '#{pane_current_path}')"
    if [[ ! -f "$marker" ]]; then
      echo "session=$session_name survived but marker missing marker=$marker"
      exit 1
    fi

    echo "survived session=$session_name socket=$socket_name cwd=$pane_cwd marker=$marker"
    cat "$marker"
    ;;
  cleanup)
    tmux -L "$socket_name" kill-session -t "$session_name" 2>/dev/null || true
    rm -f "$marker"
    echo "cleaned session=$session_name marker=$marker"
    ;;
  *)
    usage
    exit 64
    ;;
esac
