#!/bin/bash
# measure-main-thread.sh - main-thread CPU cost of a process over one interval.
#
# Samples `ps -M <pid>` twice and diffs the first thread row's STIME+UTIME, the
# recipe issue #1347 uses to attribute UI cost to the main thread. Prints the
# main-thread CPU seconds and percentage over the measured wall interval, plus
# the whole-process cputime delta for context.
#
# Usage: scripts/measure-main-thread.sh <pid> [interval_seconds]
#
# Single-threaded processes print no thread rows under `ps -M`; the process row
# is used for those, so the numbers stay meaningful for any pid.

set -eu

usage() {
    echo "Usage: $0 <pid> [interval_seconds]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 2
fi

PID="$1"
INTERVAL="${2:-10}"

case "$PID" in
    ''|*[!0-9]*)
        echo "ERROR: pid must be a positive integer: $PID" >&2
        exit 2
        ;;
esac

case "$INTERVAL" in
    ''|*[!0-9]*)
        echo "ERROR: interval must be a positive integer number of seconds: $INTERVAL" >&2
        exit 2
        ;;
esac

if [ "$INTERVAL" -lt 1 ]; then
    echo "ERROR: interval must be at least 1 second" >&2
    exit 2
fi

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: no such process: $PID" >&2
    exit 1
fi

HIRES="$(command -v python3 2>/dev/null || true)"

now_seconds() {
    if [ -n "$HIRES" ]; then
        "$HIRES" -c 'import time; print("%.3f" % time.time())'
    else
        date +%s
    fi
}

# Prints "STIME UTIME" for the main thread. `ps -M` emits a header, then the
# process row, then one row per thread; the first thread row is the main thread.
sample_main_thread() {
    ps -M "$1" | awk '
        NR == 2 { proc_stime = $7; proc_utime = $8 }
        NR == 3 && NF >= 6 { print $5, $6; found = 1; exit }
        END { if (!found) print proc_stime, proc_utime }
    '
}

# Prints the process cumulative cputime, e.g. "12:34.56".
sample_process_total() {
    ps -o time= -p "$1" | awk '{ print $1 }'
}

# Converts H:MM:SS.ss, M:SS.ss or SS.ss to seconds.
cputime_to_seconds() {
    awk -v value="$1" 'BEGIN {
        n = split(value, parts, ":")
        total = 0
        for (i = 1; i <= n; i++) { total = total * 60 + parts[i] }
        printf "%.2f", total
    }'
}

delta() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'
}

percent() {
    awk -v part="$1" -v whole="$2" 'BEGIN {
        if (whole <= 0) { printf "n/a" } else { printf "%.1f", 100 * part / whole }
    }'
}

FIRST_THREAD="$(sample_main_thread "$PID")"
FIRST_TOTAL="$(sample_process_total "$PID")"
START_WALL="$(now_seconds)"

sleep "$INTERVAL"

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: process $PID exited during the interval" >&2
    exit 1
fi

SECOND_THREAD="$(sample_main_thread "$PID")"
SECOND_TOTAL="$(sample_process_total "$PID")"
END_WALL="$(now_seconds)"

FIRST_STIME="$(cputime_to_seconds "$(echo "$FIRST_THREAD" | awk '{ print $1 }')")"
FIRST_UTIME="$(cputime_to_seconds "$(echo "$FIRST_THREAD" | awk '{ print $2 }')")"
SECOND_STIME="$(cputime_to_seconds "$(echo "$SECOND_THREAD" | awk '{ print $1 }')")"
SECOND_UTIME="$(cputime_to_seconds "$(echo "$SECOND_THREAD" | awk '{ print $2 }')")"

STIME_DELTA="$(delta "$FIRST_STIME" "$SECOND_STIME")"
UTIME_DELTA="$(delta "$FIRST_UTIME" "$SECOND_UTIME")"
THREAD_DELTA="$(awk -v s="$STIME_DELTA" -v u="$UTIME_DELTA" 'BEGIN { printf "%.2f", s + u }')"

TOTAL_DELTA="$(delta "$(cputime_to_seconds "$FIRST_TOTAL")" "$(cputime_to_seconds "$SECOND_TOTAL")")"
ELAPSED="$(delta "$START_WALL" "$END_WALL")"

COMMAND_NAME="$(ps -o comm= -p "$PID")"

echo "pid:                $PID"
echo "command:            $COMMAND_NAME"
echo "interval:           ${INTERVAL}s requested, ${ELAPSED}s elapsed"
echo "main thread stime:  +${STIME_DELTA}s"
echo "main thread utime:  +${UTIME_DELTA}s"
echo "main thread cpu:    +${THREAD_DELTA}s  ($(percent "$THREAD_DELTA" "$ELAPSED")% of one core)"
echo "process total cpu:  +${TOTAL_DELTA}s  ($(percent "$TOTAL_DELTA" "$ELAPSED")% of one core)"
echo "main thread share:  $(percent "$THREAD_DELTA" "$TOTAL_DELTA")% of process cpu"
