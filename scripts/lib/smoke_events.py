#!/usr/bin/env python3
"""Shared JSONL milestone-stream reader for the API smoke lanes.

api-create-smoke.sh and api-desktop-ui-smoke.sh drove the identical
read_event_field/event_index heredocs before this consolidation (#1236); this
is the one copy they now both call through scripts/lib/api-smoke-common.sh.
api-select-smoke.sh keeps its own local copies deliberately (coordination
with in-flight PR #1265, which is mid-flight on that exact code) rather than
switching them over here.

A torn final line (the app killed mid-write) is skipped, not fatal — cleanup
and milestone waits must survive an interrupted run's partial JSONL.
"""

import json
import sys
from pathlib import Path


def _events(path: Path):
    if not path.exists():
        return
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def read_field(path: Path, field: str, event_type: str) -> str:
    """Last value of `field` on an event whose type == event_type, or ''."""
    value = ""
    for event in _events(path):
        if event.get("type") == event_type and event.get(field):
            value = event[field]
    return value


def event_index(path: Path, target: str) -> int:
    """0-based index of the first event of type `target`, or -1."""
    for index, event in enumerate(_events(path)):
        if event.get("type") == target:
            return index
    return -1


def main() -> int:
    command = sys.argv[1]
    events_path = Path(sys.argv[2])
    if command == "read-field":
        print(read_field(events_path, sys.argv[3], sys.argv[4]))
    elif command == "event-index":
        print(event_index(events_path, sys.argv[3]))
    else:
        print(f"unknown command: {command}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
