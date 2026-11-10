# drill-shell.zsh — the interactive zsh startup file for continuity-drill tiles. The drill
# copies it to its isolated HOME as .zshrc, so every tile shell puts the stub `claude` first
# on PATH, types and runs the next command queued for its directory as a person would, and
# records what its command line holds, which is where a restore's prefill lands. HOME is
# re-pinned to this file's directory because a tmux server the app starts from a surface
# runs under /usr/bin/login, which resets HOME to the account's real home.
drill_inherited_home="$HOME"
export HOME="${${(%):-%x}:A:h}"
drill_root="$HOME/.drill"
drill_observe="$drill_root/observe"
drill_pending=""
drill_last_buffer=""

path=("$drill_root/bin" $path)
export PATH

drill_record_start() {
  mkdir -p "$drill_observe"
  {
    print -r -- "pid=$$"
    print -r -- "ppid=$PPID"
    print -r -- "cwd=${PWD:A}"
    print -r -- "phase=$(cat "$drill_root/phase" 2>/dev/null)"
    print -r -- "inherited_home=$drill_inherited_home"
    print -r -- "host_session_id=${WORKSPACES_HOST_SESSION_ID:-}"
    print -r -- "tmux=${TMUX:-}"
    print -r -- "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$drill_observe/shell-$$.start"
}

drill_take_queued_command() {
  local queue="$drill_root/autorun/${${PWD:A}//[^A-Za-z0-9]/-}"
  local entry
  for entry in "$queue"/*.cmd(N); do
    if mv "$entry" "$entry.taken-$$" 2>/dev/null; then
      drill_pending="$(cat "$entry.taken-$$")"
      return 0
    fi
  done
}

drill_line_init() {
  [[ -n "$drill_pending" ]] || return 0
  BUFFER="$drill_pending"
  drill_pending=""
  zle accept-line
}

drill_line_pre_redraw() {
  [[ -n "$BUFFER" && "$BUFFER" != "$drill_last_buffer" ]] || return 0
  drill_last_buffer="$BUFFER"
  print -r -- "$BUFFER" >"$drill_observe/shell-$$.buffer"
}

autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init drill_line_init
add-zle-hook-widget line-pre-redraw drill_line_pre_redraw
drill_record_start
drill_take_queued_command
