#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Prove the sidebar stays live while its rows are skipping their bodies.

Row-level `Equatable` scoping (#1366) lets an unchanged row keep the closures it was built
with. The unit suite proves every input those closures read is either fingerprinted by the
row's display state or reads live storage; this proves the same thing about the running app,
which is the pass #1347 asked for when it deferred the slice over exactly this hazard.

It runs against an already-launched debug instance with the automation API on, and keeps
replayed hook events flowing the entire time, so every assertion is made while the sidebar is
coalescing and rebuilding rows.

What it checks, and why each is shaped the way it is:

  * **Selection is exact under churn.** Each of several workspaces is selected in turn and read
    back from `/v1/ui-state`; the last one is re-selected after the others so the check cannot
    be satisfied by a selection that simply never moved.
  * **Derived agent state keeps moving.** Not a targeted event — the churn driver is walking
    every session through the measured mix, so a single injected state is overwritten inside the
    same coalescing window. Staleness would look like the opposite of churn, so the assertion is
    that the sidebar's reading keeps changing rather than settling.
  * **Rows keep rebuilding.** A boundary that skipped everything would pass the two checks above
    while showing nothing; the row counter has to keep climbing.

What it cannot check, raised by the codex pass on #1504 and recorded here rather than left to be
rediscovered. `/v1/ui-state` builds a fresh projection straight from the SwiftData models, the
selection, the status dictionaries and `TileTreeStore` (`AutomationUIStateEnumerator.swift`). It
reads no pixels and no mounted row values, so a row *displaying* a stale value while the
projection reports the fresh one passes every check above. That is the shape of the accepted
hover-title residual, and it was the shape of the frozen workspace age and the stale pin graph
before those were fixed.

So this pass proves the sidebar's model-side state stays live under churn: that the boundary has
not frozen selection, derived agent state, or the rows themselves. What a *mounted* row draws is
proven by the suite instead, where `SidebarRowRebuildTests` mounts real rows, counts their body
evaluations, and invokes the closures they kept. Closing the gap here would mean reading rendered
row text back out of the running app, which no automation verb offers today.

Usage:
    ./scripts/launch-dev.sh --fixture --coexist --no-activate --clean-data \\
        --data-dir .dev-data/staleness \\
        --env WORKSPACES_HOOKS_SOCKET_OVERRIDE=$PWD/.dev-data/staleness/hooks.sock \\
        --env WORKSPACES_AUTOMATION_API=1 --env WORKSPACES_AUTOMATION_OPERATOR=1 \\
        --env OS_ACTIVITY_DT_MODE=YES --env WORKSPACES_UI_FIXTURE_LOAD_WORKSPACES=12 \\
        --env WORKSPACES_UI_FIXTURE_AGENT_STATES=...

    uv run --script scripts/verify-sidebar-row-staleness.py \\
        --data-dir .dev-data/staleness --app-log .dev-data/logs/launch-dev-<stamp>.log
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_replay():
    """Import the replay script as a module so the churn driver and this share one protocol."""
    spec = importlib.util.spec_from_file_location(
        "replay_agent_events", REPO_ROOT / "scripts" / "replay-agent-events.py"
    )
    module = importlib.util.module_from_spec(spec)
    # Registered before execution: the module's dataclasses resolve their annotations through
    # `sys.modules`, and a module loaded without being registered has none to resolve against.
    sys.modules["replay_agent_events"] = module
    spec.loader.exec_module(module)
    return module


class Checks:
    def __init__(self) -> None:
        self.total = 0
        self.failed: list[str] = []

    def __call__(self, name: str, ok: bool, detail: str = "") -> None:
        self.total += 1
        if not ok:
            self.failed.append(name)
        print(f"{'PASS' if ok else 'FAIL'}  {name}{('  — ' + detail) if detail else ''}", flush=True)


def credential(app_log: Path) -> tuple[str, str]:
    """The socket and handle the running instance printed, not the ones a resolver would guess."""
    matches = re.findall(r"operator credential minted at (\S+)", app_log.read_text(errors="replace"))
    if not matches:
        raise SystemExit(f"no automation credential in {app_log}")
    payload = json.loads(Path(matches[-1]).read_text())
    return payload["socketPath"], payload["handle"]


def api(socket_path: str, handle: str, method: str, path: str, body: str = "") -> dict:
    command = [
        "curl", "-s", "--unix-socket", socket_path,
        "-H", f"x-workspaces-automation-handle: {handle}", "-X", method,
    ]
    if body:
        command += ["-H", "Content-Type: application/json", "-d", body]
    command.append(f"http://localhost{path}")
    output = subprocess.run(command, capture_output=True, text=True, check=False).stdout
    return json.loads(output) if output else {}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", required=True, help="the launch's isolated data root")
    parser.add_argument("--app-log", required=True, help="the launch log (carries the credential path)")
    parser.add_argument("--rate", type=float, default=4.0, help="churn events/second (default 4)")
    parser.add_argument("--selections", type=int, default=6, help="workspaces to select in turn")
    parser.add_argument("--samples", type=int, default=14, help="derived-state samples, one per second")
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir).resolve()
    app_log = Path(args.app_log).resolve()
    hooks_socket = str(data_dir / "hooks.sock")
    store = data_dir / "local-state.sqlite"

    replay = load_replay()
    socket_path, handle = credential(app_log)
    check = Checks()

    def ui_state() -> dict:
        return api(socket_path, handle, "GET", "/v1/ui-state")["result"]["state"]

    def selected(state: dict) -> list[str]:
        return [
            workspace["name"]
            for repo in state.get("sidebar", [])
            for workspace in repo.get("workspaces", [])
            if workspace.get("isSelected")
        ]

    def attention(state: dict) -> int:
        found = re.match(r"(\d+)", state.get("attentionPillText") or "")
        return int(found.group(1)) if found else 0

    def row_builds() -> int | None:
        counts = re.findall(
            r"sidebar_row_body_evaluations count=(\d+)", app_log.read_text(errors="replace")
        )
        return int(counts[-1]) if counts else None

    sessions = replay.sessions_from_store(store)
    print(f"{len(sessions)} host sessions; churn at {args.rate} ev/s for the whole pass\n")

    stop = threading.Event()

    def churn() -> None:
        while not stop.is_set():
            subprocess.run(
                [
                    "uv", "run", "--script", str(REPO_ROOT / "scripts" / "replay-agent-events.py"),
                    "--socket", hooks_socket, "--store", str(store),
                    "--auto-sessions", "--rate", str(args.rate), "--duration", "25",
                ],
                capture_output=True, check=False, cwd=REPO_ROOT,
            )

    driver = threading.Thread(target=churn, daemon=True)
    driver.start()
    time.sleep(4)

    try:
        print("--- selection is exact under churn ---")
        workspaces = api(socket_path, handle, "GET", "/v1/workspaces")["result"]["workspaces"]
        targets = workspaces[: args.selections]
        for target in targets:
            api(
                socket_path, handle, "POST", "/v1/workspace/select",
                json.dumps({"workspaceID": target["workspaceID"]}),
            )
            time.sleep(1.2)
            chosen = selected(ui_state())
            check(
                f"selecting {target['name']} leaves exactly it selected",
                chosen == [target["name"]],
                f"sidebar reports {chosen}",
            )

        first = targets[0]
        api(
            socket_path, handle, "POST", "/v1/workspace/select",
            json.dumps({"workspaceID": first["workspaceID"]}),
        )
        time.sleep(1.2)
        check(
            f"selection returns to {first['name']} after moving away and back",
            selected(ui_state()) == [first["name"]],
        )

        print("\n--- derived agent state keeps moving under churn ---")
        readings = []
        for _ in range(args.samples):
            readings.append(attention(ui_state()))
            time.sleep(1.0)
        distinct = sorted(set(readings))
        print(f"attention pill over {args.samples}s: {readings}")
        check(
            "the sidebar's derived agent reading changes rather than freezing",
            len(distinct) > 1,
            f"distinct values {distinct}",
        )

        state = ui_state()
        names = [w["name"] for r in state.get("sidebar", []) for w in r.get("workspaces", [])]
        seeded = sum(1 for name in names if name.startswith("load-"))
        check(
            "every seeded workspace is still on the sidebar after the churn",
            seeded == 12,
            f"{seeded} load rows of {len(names)} total",
        )
        check(
            "exactly one workspace remains selected through the churn",
            len(selected(state)) == 1,
            f"selected {selected(state)}",
        )

        print("\n--- rows are skipping, not frozen ---")
        before = row_builds()
        time.sleep(20)
        after = row_builds()
        check(
            "sidebar rows keep rebuilding under sustained churn",
            before is not None and after is not None and after > before,
            f"row body evaluations {before} -> {after} over 20s",
        )
    finally:
        stop.set()

    print(f"\n{check.total - len(check.failed)}/{check.total} checks passed")
    if check.failed:
        print("failed: " + "; ".join(check.failed))
    return 1 if check.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
