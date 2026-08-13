#!/bin/bash
# Teardown contract shared by the perf lanes. A harness that leaves its subject
# running measures a loaded machine on the next lane rather than a launch, which
# is how the first #1251 measurement pass was invalidated (#1277).
#
# Two rules hold everywhere: signals go only to a pid this run launched, never to
# whatever a pattern matches; and a lane reports success only after the process
# table is observably clear.

# `pgrep -f` matches a regex against whole command lines, and binary paths are
# full of `.` metacharacters that would otherwise match anything.
perf_escape_pattern() {
    printf '%s' "$1" | sed 's/[][\\.*^$(){}?+|]/\\&/g'
}

# Pids actually *running* the named binary.
#
# Anchored, because these lanes take the binary as `--app <path>`: an unanchored
# search finds the very string in the harness's own argv and every script in the
# chain reports itself as a survivor. A process running the app has the binary at
# the *start* of its command line; a harness mentioning it never does.
#
# Matching on the command line rather than `ps -o comm=` is deliberate — on macOS
# `comm` reports argv[0], so a process is free to present any name it likes there.
perf_instance_pids() {
    pgrep -f -- "^$(perf_escape_pattern "$1")" 2>/dev/null || true
}

# Read-only on purpose: an instance this run did not start belongs to someone
# else — a `launch-dev.sh` app, a concurrent capture — so the lane refuses to
# measure beside it rather than killing something it does not own.
perf_assert_no_instance() {
    local binary="$1" label="$2" pids
    pids="$(perf_instance_pids "$binary")"
    [[ -z "$pids" ]] && return 0
    echo "  [$label] a WorkspaceManager matching this lane's binary is already running: $(echo "$pids" | tr '\n' ' ')" >&2
    echo "  [$label] refusing to measure beside it — stop it and re-run." >&2
    return 1
}

# TERM, then KILL on a deadline, and only ever the pid this invocation launched.
# Bounded on purpose: a plain `kill` followed by `wait` blocks forever against an
# app that does not act on SIGTERM, and whatever interrupts that wait leaves the
# instance behind.
perf_stop_launched_app() {
    local pid="$1" attempt
    kill "$pid" 2>/dev/null || true
    for attempt in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.25
    done
    echo "  escalating to SIGKILL for launched pid $pid" >&2
    kill -9 "$pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.25
    done
    return 1
}

# The post-condition. Loud on purpose: a survivor that only shows up as a slower
# number in the next lane is the failure this whole file exists to prevent.
perf_assert_clean_exit() {
    local binary="$1" label="$2" pids
    pids="$(perf_instance_pids "$binary")"
    [[ -z "$pids" ]] && return 0
    echo "  [$label] a WorkspaceManager survived teardown: $(echo "$pids" | tr '\n' ' ')" >&2
    echo "  [$label] later lanes would measure a loaded machine — failing rather than reporting a number." >&2
    return 1
}
