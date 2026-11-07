#!/usr/bin/env bash
# watch-swift-test.sh - run a `swift test` command under a stall watchdog.
#
# A hung test sits at 0% CPU and looks like a slow run for hours. This runs the
# command with its output in <out>/test.log and watches a progress file (the log
# by default). When the file stops changing for --stall seconds, it samples the
# command's swiftpm-testing-helper into <out>/hang.sample.txt, kills the command's
# process tree, and exits 124. Otherwise it exits with the command's status.
#
# Usage: scripts/watch-swift-test.sh [--stall SECONDS] [--progress FILE] [--out DIR] -- <command...>

set -uo pipefail

main() {
  parse_args "$@"
  mkdir -p "$OUT_DIR"
  LOCK_DIR="$OUT_DIR/.watch-swift-test.lock"
  if ! mkdir "$LOCK_DIR" 2> /dev/null; then
    echo "watch-swift-test: $OUT_DIR is in use by another watchdog ($LOCK_DIR exists)" >&2
    exit 2
  fi
  RUNNER=""
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local log="$OUT_DIR/test.log"
  STATUS_FILE="$OUT_DIR/test.status"
  rm -f "$STATUS_FILE" "$OUT_DIR/hang.sample.txt" "$OUT_DIR/hang.tree"
  : > "$log"
  : "${PROGRESS:=$log}"
  touch "$PROGRESS"
  echo "watch-swift-test: log=$log progress=$PROGRESS stall=${STALL}s"

  (
    "${COMMAND[@]}"
    echo "$?" > "$STATUS_FILE"
  ) > "$log" 2>&1 &
  RUNNER=$!

  local last_change
  last_change=$(mtime_or "$PROGRESS" "$(date +%s)")
  while ! finished; do
    sleep 1
    last_change=$(mtime_or "$PROGRESS" "$last_change")
    if (($(date +%s) - last_change >= STALL)) && ! finished; then
      capture_hang "$RUNNER"
      if finished; then
        break
      fi
      kill_tree "$RUNNER"
      RUNNER=""
      echo "watch-swift-test: no progress for ${STALL}s; sample in $OUT_DIR/hang.sample.txt" >&2
      exit 124
    fi
  done

  wait "$RUNNER" 2> /dev/null
  RUNNER=""
  tail -n 5 "$log"
  exit "$(cat "$STATUS_FILE" 2> /dev/null || echo 1)"
}

parse_args() {
  STALL=120
  PROGRESS=""
  OUT_DIR="${TMPDIR:-/tmp}/watch-swift-test.$$"
  while (($#)); do
    case "$1" in
      --stall | --progress | --out)
        (($# >= 2)) || usage
        case "$1" in
          --stall) STALL="$2" ;;
          --progress) PROGRESS="$2" ;;
          --out) OUT_DIR="$2" ;;
        esac
        shift 2
        ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [[ "$STALL" =~ ^[1-9][0-9]*$ ]] || usage
  (($#)) || usage
  COMMAND=("$@")
}

usage() {
  echo "Usage: $0 [--stall SECONDS] [--progress FILE] [--out DIR] -- <command...>" >&2
  exit 2
}

finished() {
  [[ -s "$STATUS_FILE" ]] || ! kill -0 "$RUNNER" 2> /dev/null
}

mtime_or() {
  stat -f %m "$1" 2> /dev/null || echo "$2"
}

cleanup() {
  if [[ -n "$RUNNER" ]]; then
    kill_tree "$RUNNER"
  fi
  rmdir "$LOCK_DIR" 2> /dev/null
}

capture_hang() {
  local root="$1" helper
  process_tree "$root" > "$OUT_DIR/hang.tree"
  helper=$(descendant_named "$root" swiftpm-testing-helper)
  : "${helper:=$(descendant_named "$root" xctest)}"
  if [[ -n "$helper" ]]; then
    sample "$helper" 10 -mayDie -file "$OUT_DIR/hang.sample.txt" > /dev/null 2>&1
  fi
}

descendant_named() {
  local root="$1" name="$2" pid
  for pid in $(pgrep -P "$root"); do
    if ps -o comm= -p "$pid" | grep -q "$name"; then
      echo "$pid"
      return
    fi
    descendant_named "$pid" "$name"
  done
}

process_tree() {
  local root="$1" pid
  ps -o pid=,ppid=,stat=,etime=,comm= -p "$root"
  for pid in $(pgrep -P "$root"); do
    process_tree "$pid"
  done
}

kill_tree() {
  local root="$1" pid
  kill -STOP "$root" 2> /dev/null
  for pid in $(pgrep -P "$root"); do
    kill_tree "$pid"
  done
  kill -9 "$root" 2> /dev/null
}

main "$@"
