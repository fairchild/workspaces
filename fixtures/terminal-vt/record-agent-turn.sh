#!/usr/bin/env bash
# Records agent-turn.vt beside this script: an agent-style turn
# (colored prompt, a progress line redrawn in place, a spinner rewritten with
# cursor-up, wide characters, 256-color and truecolor text) written through a
# real PTY by script(1), so the bytes carry the CRLF translation and redraw
# sequences a live terminal stream does. Regenerate agent-turn.golden.json
# after recording (docs/development/libghostty-vt.md).
set -euo pipefail

main() {
  local here fixture
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fixture="$here/agent-turn.vt"
  if [[ "${1:-}" == "--emit" ]]; then
    emit_turn
    return
  fi
  script -q "$fixture" bash "${BASH_SOURCE[0]}" --emit >/dev/null
  printf 'recorded %s (%s bytes)\n' "$fixture" "$(wc -c <"$fixture" | tr -d ' ')"
}

emit_turn() {
  local esc=$'\e'
  printf '%s[1;34m~/project%s[0m %s[32m❯%s[0m swift test\n' "$esc" "$esc" "$esc" "$esc"
  local step
  for step in 1 7 15 23 31 38 42; do
    printf '\r%s[K%s[2m[%d/42]%s[0m Compiling TerminalScreen' "$esc" "$esc" "$step" "$esc"
  done
  printf '\r%s[K%s[1mBuild complete!%s[0m (3.21s)\n' "$esc" "$esc" "$esc"
  printf '%s[33m⠋%s[0m running 6 tests\n' "$esc" "$esc"
  printf '%s[1A\r%s[K%s[32m✔%s[0m 6 tests passed\n' "$esc" "$esc" "$esc" "$esc"
  printf '%s[32m✔%s[0m wraps a %s[1mbold%s[0m, %s[3mitalic%s[0m, %s[4munderlined%s[0m run\n' \
    "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc"
  printf '%s[31m✘%s[0m %s[9mflaky%s[0m quarantined\n' "$esc" "$esc" "$esc" "$esc"
  printf '%s[1m╭────────────── summary ──────────────╮%s[0m\n' "$esc" "$esc"
  printf '%s[1m│%s[0m wide: 完成 ✅  %s[38;5;208m256-color%s[0m  %s[38;2;120;200;255mtruecolor%s[0m %s[1m│%s[0m\n' \
    "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc"
  printf '%s[1m╰─────────────────────────────────────╯%s[0m\n' "$esc" "$esc"
  printf '%s[7m inverse %s[0m %s[44m on blue %s[0m\n' "$esc" "$esc" "$esc" "$esc"
  printf '%s[1;34m~/project%s[0m %s[32m❯%s[0m ' "$esc" "$esc" "$esc" "$esc"
}

main "$@"
