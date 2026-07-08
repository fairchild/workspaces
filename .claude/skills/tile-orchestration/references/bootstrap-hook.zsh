# WorkSpaces tile agent bootstrap — goes in ~/.zshrc.local (the dotfiles'
# per-machine override). Interactive WorkSpaces-tile shells run
# .agents/inbox/tile-start when it appears; the file is moved away before
# sourcing so it can never run twice; the TMOUT watcher lets a coordinator
# drop work into an idle tile within ~5s (also the re-tasking path).
#
# Guards, each load-bearing (see the W5 dogfood retro):
# - [[ -o interactive ]]: codex's own `zsh -lc` subshells source rc files
#   and would consume a re-task file mid-run without it.
# - cwd fallback: tiles currently receive no automation env (#973); the
#   handle check is kept for when that fixes. Scope the path to the app's
#   workspace dir so ordinary shells never run inbox files.
if [[ -o interactive ]] && [[ -n "$WORKSPACES_AUTOMATION_HANDLE" || "$PWD" == "$HOME/workspaces/workspaces/"* ]]; then
  _ws_tile_start() {
    if [[ -f .agents/inbox/tile-start ]]; then
      local f="/tmp/ws-tile-start-$$"
      command mv .agents/inbox/tile-start "$f" && source "$f"
    fi
  }
  _ws_tile_start
  TMOUT=5
  TRAPALRM() { _ws_tile_start }
fi
