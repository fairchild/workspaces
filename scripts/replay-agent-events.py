#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Replay synthetic Claude Code hook and status-line traffic into the running app.

Drives the agent bus at a chosen rate and event mix over the app's Unix domain
socket so main-thread cost per agent event is measurable under a known load
(#1347). Speaks the listener's minimal HTTP/1.1 directly: no curl, no subprocess
per event.

Protocol notes (derived from the app, not guessed):
  * Routes: POST /event (hook events), POST /statusline (status line), both
    keyed by header `x-workspaces-host-session-id: <UUID>`
    (AgentUpdateIntake.swift:70, AgentHookListener.swift:352).
  * The listener answers 200 *before* it checks registration; events for host
    sessions the running app does not currently hold are dropped silently
    (AgentHookListener.swift:204-224, :265-289). HTTP success is not ingestion.
  * Socket path is bundle-ID keyed and ignores WORKSPACES_DATA_DIR:
    `~/Library/Application Support/<bundleID>/hooks.sock`
    (AgentHookListener.defaultSocketURL, AgentHookListener.swift:85-93). The
    installed app is `com.cloudcompute.workspaces`; scripts/launch-dev.sh
    launches the bare debug binary (no Info.plist), so Bundle.main
    .bundleIdentifier is nil and the same default path is used — one flock'd
    owner per path (AgentHookListener.swift:366-379), which is why under
    `--coexist` the second instance logs "listener dormant" and never binds.
    The live path per session is recorded in terminal_sessions.hooks_socket_path.
  * The sqlite sidecar is data-dir keyed, not bundle-ID keyed:
    `$WORKSPACES_LOCAL_STATE_DIR` or `$WORKSPACES_DATA_DIR`, else
    `~/Library/Application Support/WorkspaceManager/local-state.sqlite`
    (LocalStateStore.swift:129-162).
"""

from __future__ import annotations

import argparse
import http.client
import itertools
import json
import os
import socket
import socketserver
import sqlite3
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Callable, Iterator

APP_SUPPORT = Path.home() / "Library" / "Application Support"
DEFAULT_BUNDLE_ID = "com.cloudcompute.workspaces"
DEFAULT_SOCKET = APP_SUPPORT / DEFAULT_BUNDLE_ID / "hooks.sock"
DEFAULT_STORE_DIR = APP_SUPPORT / "WorkspaceManager"
STORE_FILENAME = "local-state.sqlite"

EVENT_ROUTE = "/event"
STATUSLINE_ROUTE = "/statusline"
SESSION_HEADER = "X-WorkSpaces-Host-Session-ID"

TOOL_NAMES = ("Bash", "Read", "Edit", "Grep")

# Measured distribution from issue #1347 (13,234 rows on 2026-08-24Z):
# tool_start 3011, tool_end 2916, status_fields 2135, tool_batch_end 2116,
# awaiting_input 700, everything else < 100 each.
MIX_MEASURED = {
    "tool_start": 23,
    "tool_end": 22,
    "status_fields": 16,
    "tool_batch_end": 16,
    "awaiting_input": 12,
    "user_prompt": 6,
    "stopped": 5,
}


@dataclass
class Session:
    """One host session the app has registered, plus the agent-side identity the
    forwarders would carry for it."""

    host_session_id: str
    cwd: str
    agent_session_id: str = field(default_factory=lambda: str(uuid.uuid4()))


@dataclass
class EventKind:
    name: str
    route: str
    build: Callable[[Session, int], dict[str, Any]]


# --- Payload builders ------------------------------------------------------
# Shapes derived from ClaudeHookDecoder.decode (ClaudeHookEvent.swift:216-301):
# `hook_event_name` selects the case; `session_id` and `cwd` are required on
# every hook event or decode throws missingCommonField.


def _common(session: Session) -> dict[str, Any]:
    return {
        "session_id": session.agent_session_id,
        "cwd": session.cwd,
        "transcript_path": f"{Path.home()}/.claude/projects/replay/{session.agent_session_id}.jsonl",
    }


def _tool_input(tool_name: str, seq: int) -> dict[str, Any]:
    # ClaudeHookTranslator.extractDetail reads file_path / path / command / url
    # (AgentEventTranslators.swift:66-77).
    if tool_name == "Bash":
        return {"command": f"git status --short # replay {seq}", "description": "status"}
    if tool_name == "Grep":
        return {"pattern": f"replay{seq}", "path": "Sources"}
    return {"file_path": f"Sources/WorkspaceManagerCore/Services/Replay{seq}.swift"}


def build_tool_start(session: Session, seq: int) -> dict[str, Any]:
    tool_name = TOOL_NAMES[seq % len(TOOL_NAMES)]
    return {
        "hook_event_name": "PreToolUse",
        **_common(session),
        "tool_name": tool_name,
        "tool_input": _tool_input(tool_name, seq),
    }


def build_tool_end(session: Session, seq: int) -> dict[str, Any]:
    tool_name = TOOL_NAMES[seq % len(TOOL_NAMES)]
    return {
        "hook_event_name": "PostToolUse",
        **_common(session),
        "tool_name": tool_name,
        "duration_ms": 40 + (seq * 17) % 900,
        "tool_response": {"ok": True},
    }


def build_tool_batch_end(session: Session, seq: int) -> dict[str, Any]:
    return {
        "hook_event_name": "PostToolBatch",
        **_common(session),
        "tool_count": 1 + seq % 4,
    }


def build_user_prompt(session: Session, seq: int) -> dict[str, Any]:
    return {
        "hook_event_name": "UserPromptSubmit",
        **_common(session),
        "prompt": f"replay prompt {seq}",
    }


def build_stopped(session: Session, seq: int) -> dict[str, Any]:
    return {"hook_event_name": "Stop", **_common(session), "stop_hook_active": False}


def build_awaiting_input(session: Session, seq: int) -> dict[str, Any]:
    # notification_type steers the awaiting reason
    # (AgentEventTranslators.swift:40-50).
    kind = ("idle_prompt", "permission_prompt")[seq % 2]
    return {
        "hook_event_name": "Notification",
        **_common(session),
        "notification_type": kind,
        "title": "Claude Code",
        "message": (
            "Claude is waiting for your input"
            if kind == "idle_prompt"
            else "Claude needs permission to use Bash"
        ),
    }


def build_status_fields(session: Session, seq: int) -> dict[str, Any]:
    # StatusLinePayload.init(rawJSON:) (StatusLinePayload.swift:135-213).
    return {
        "session_id": session.agent_session_id,
        "cwd": session.cwd,
        "model": {"id": "claude-opus-4-6", "display_name": "Opus 4.6"},
        "workspace": {"current_dir": session.cwd, "project_dir": session.cwd},
        "cost": {
            "total_cost_usd": round(0.25 + seq * 0.011, 4),
            "total_lines_added": 12 + seq,
            "total_lines_removed": 3 + seq // 2,
        },
        "context_window": {
            "used_percentage": round(11.0 + (seq * 3) % 70, 1),
            "context_window_size": 1_000_000,
        },
        "rate_limits": {
            "five_hour": {
                "used_percentage": round(4.0 + (seq * 2) % 60, 1),
                "resets_at": "2026-08-24T09:00:00Z",
            }
        },
        "output_style": {"name": "default"},
        "version": "2.1.241",
    }


EVENT_KINDS: dict[str, EventKind] = {
    "tool_start": EventKind("tool_start", EVENT_ROUTE, build_tool_start),
    "tool_end": EventKind("tool_end", EVENT_ROUTE, build_tool_end),
    "tool_batch_end": EventKind("tool_batch_end", EVENT_ROUTE, build_tool_batch_end),
    "status_fields": EventKind("status_fields", STATUSLINE_ROUTE, build_status_fields),
    "awaiting_input": EventKind("awaiting_input", EVENT_ROUTE, build_awaiting_input),
    "user_prompt": EventKind("user_prompt", EVENT_ROUTE, build_user_prompt),
    "stopped": EventKind("stopped", EVENT_ROUTE, build_stopped),
}


def mix_weights(preset: str) -> dict[str, int]:
    if preset == "measured":
        return dict(MIX_MEASURED)
    if preset == "uniform":
        return {name: 1 for name in EVENT_KINDS}
    raise ValueError(f"unknown mix preset: {preset}")


def mix_schedule(weights: dict[str, int]) -> Iterator[str]:
    """Deterministic repeating schedule matching the weights.

    A fixed schedule beats sampling here: a 60 s run at 2/s is 120 events, and
    random draws at that count miss the target mix by several percent.
    """
    if sum(weights.values()) <= 0:
        raise ValueError("mix has no weight")
    # Interleave so bursts of one kind do not clump at the head of the run.
    ordered: list[str] = []
    buckets = {name: [name] * weights[name] for name in weights}
    while any(buckets.values()):
        for name in sorted(buckets, key=lambda n: (-len(buckets[n]), n)):
            if buckets[name]:
                ordered.append(buckets[name].pop())
    return itertools.cycle(ordered)


# --- Transport -------------------------------------------------------------


class UnixHTTPConnection(http.client.HTTPConnection):
    """http.client over AF_UNIX; the app speaks HTTP/1.1 on a unix socket."""

    def __init__(self, socket_path: str, timeout: float = 2.0) -> None:
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:  # noqa: D102
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


@dataclass
class SendResult:
    ok: bool
    status: int | None = None
    error: str | None = None


def post(socket_path: str, route: str, host_session_id: str, payload: dict[str, Any],
         timeout: float = 2.0) -> SendResult:
    body = json.dumps(payload).encode("utf-8")
    conn = UnixHTTPConnection(socket_path, timeout=timeout)
    try:
        # http.client sets Content-Length from the bytes body.
        conn.request(
            "POST",
            route,
            body=body,
            headers={"Content-Type": "application/json", SESSION_HEADER: host_session_id},
        )
        response = conn.getresponse()
        response.read()
        return SendResult(ok=response.status == 200, status=response.status)
    except OSError as exc:
        return SendResult(ok=False, error=f"{type(exc).__name__}: {exc}")
    finally:
        conn.close()


# --- Store discovery -------------------------------------------------------


def default_store_path() -> Path:
    raw = os.environ.get("WORKSPACES_LOCAL_STATE_DIR") or os.environ.get("WORKSPACES_DATA_DIR")
    directory = Path(os.path.expanduser(raw)) if raw else DEFAULT_STORE_DIR
    return directory / STORE_FILENAME


def open_store(path: Path) -> sqlite3.Connection:
    if not path.exists():
        raise SystemExit(f"store not found: {path}")
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def sessions_from_store(store: Path) -> list[Session]:
    """Active rows of the most recent run.

    Run-scoped on purpose: is_active = 1 alone carries stale rows from earlier
    runs (issue #1347 D4 — 152 rows on this machine, 5 in the current run). The
    query mirrors LocalStateStore.fetchPreviousRunSessions (LocalStateStore.swift:667).
    """
    conn = open_store(store)
    try:
        rows = conn.execute(
            """
            SELECT host_session_id, directory_path
            FROM terminal_sessions
            WHERE run_id = (
                SELECT run_id FROM terminal_sessions
                WHERE run_started_at IS NOT NULL
                ORDER BY run_started_at DESC LIMIT 1
            )
              AND is_active = 1
              AND ended_at IS NULL
            ORDER BY last_seen_at DESC
            """
        ).fetchall()
    finally:
        conn.close()
    return [Session(host_session_id=row[0], cwd=row[1]) for row in rows]


def socket_from_store(store: Path) -> str | None:
    conn = open_store(store)
    try:
        row = conn.execute(
            """
            SELECT hooks_socket_path FROM terminal_sessions
            WHERE hooks_socket_path IS NOT NULL
            ORDER BY last_seen_at DESC LIMIT 1
            """
        ).fetchone()
    finally:
        conn.close()
    return row[0] if row else None


def ingested_since(store: Path, sessions: list[Session], since_iso: str) -> int:
    conn = open_store(store)
    try:
        placeholders = ",".join("?" for _ in sessions)
        row = conn.execute(
            f"""
            SELECT count(*) FROM agent_status_events
            WHERE event_at >= ? AND host_session_id IN ({placeholders})
            """,
            [since_iso, *(s.host_session_id for s in sessions)],
        ).fetchone()
    finally:
        conn.close()
    return int(row[0])


# --- Replay ----------------------------------------------------------------


def replay(args: argparse.Namespace, socket_path: str, sessions: list[Session]) -> int:
    weights = mix_weights(args.mix)
    schedule = mix_schedule(weights)
    interval = 1.0 / args.rate
    sent: dict[str, int] = {name: 0 for name in EVENT_KINDS}
    failures: dict[str, int] = {}
    failure_count = 0
    seq = 0

    started_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"socket:    {socket_path}")
    print(f"sessions:  {len(sessions)}")
    print(f"mix:       {args.mix} ({', '.join(f'{k}={v}' for k, v in sorted(weights.items()))})")
    print(f"rate:      {args.rate:g} events/s total, duration {args.duration:g}s")
    print("", flush=True)

    start = time.monotonic()
    deadline = start + args.duration
    next_at = start
    interrupted = False
    try:
        while time.monotonic() < deadline:
            session = sessions[seq % len(sessions)]
            kind = EVENT_KINDS[next(schedule)]
            result = post(socket_path, kind.route, session.host_session_id,
                          kind.build(session, seq), timeout=args.timeout)
            if result.ok:
                sent[kind.name] += 1
            else:
                failure_count += 1
                reason = result.error or f"HTTP {result.status}"
                failures[reason] = failures.get(reason, 0) + 1
            seq += 1
            next_at += interval
            delay = next_at - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except KeyboardInterrupt:
        interrupted = True

    elapsed = time.monotonic() - start
    total = sum(sent.values())
    print("--- replay summary ---")
    if interrupted:
        print("state:     interrupted (SIGINT)")
    print(f"elapsed:   {elapsed:.2f}s")
    print(f"sent:      {total} accepted, {failure_count} failed")
    print(f"rate:      {total / elapsed if elapsed else 0:.2f} events/s achieved "
          f"(requested {args.rate:g})")
    print("per type:")
    for name in sorted(sent, key=lambda n: -sent[n]):
        share = 100.0 * sent[name] / total if total else 0.0
        print(f"  {name:<16} {sent[name]:>6}  {share:5.1f}%  {EVENT_KINDS[name].route}")
    if failures:
        print("failures:")
        for reason, count in sorted(failures.items(), key=lambda kv: -kv[1]):
            print(f"  {count:>6}  {reason}")

    if args.verify_store:
        # Persistence is async and batched (LocalStateStore.recordAgentEvents),
        # so settle briefly before counting.
        time.sleep(2.0)
        try:
            ingested = ingested_since(args.store, sessions, started_iso)
            print(f"ingested:  {ingested} rows in agent_status_events since {started_iso}")
        except sqlite3.Error as exc:
            print(f"ingested:  unavailable ({exc})")

    print("note:      the listener answers 200 before checking registration; events for")
    print("           host sessions the app does not currently hold are dropped silently.")
    return 1 if failure_count else 0


# --- Self-test -------------------------------------------------------------


@dataclass
class CapturedRequest:
    method: str
    path: str
    headers: dict[str, str]
    raw_body: bytes


class _CaptureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        self.server.captured.append(  # type: ignore[attr-defined]
            CapturedRequest(
                method=self.command,
                path=self.path,
                headers={k.lower(): v for k, v in self.headers.items()},
                raw_body=body,
            )
        )
        self.send_response(200, "OK")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def address_string(self) -> str:
        return "unix"

    def log_message(self, fmt: str, *fmt_args: Any) -> None:
        return


class _CaptureServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str) -> None:
        super().__init__(path, _CaptureHandler)
        self.captured: list[CapturedRequest] = []
        self.server_name = "localhost"
        self.server_port = 0


def self_test() -> int:
    checks: list[tuple[str, bool, str]] = []

    def check(label: str, ok: bool, detail: str = "") -> None:
        checks.append((label, ok, detail))

    tmpdir = tempfile.mkdtemp(prefix="replay-selftest-", dir="/tmp")
    sock_path = os.path.join(tmpdir, "t.sock")
    server = _CaptureServer(sock_path)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    host_session_id = str(uuid.uuid4()).upper()
    session = Session(host_session_id=host_session_id, cwd="/Users/replay/code/workspaces")

    try:
        for index, (name, kind) in enumerate(sorted(EVENT_KINDS.items())):
            payload = kind.build(session, index)
            body = json.dumps(payload).encode("utf-8")
            before = len(server.captured)
            result = post(sock_path, kind.route, host_session_id, payload)
            deadline = time.monotonic() + 2.0
            while len(server.captured) == before and time.monotonic() < deadline:
                time.sleep(0.01)

            check(f"{name}: response 200", result.ok,
                  result.error or f"status={result.status}")
            if len(server.captured) == before:
                check(f"{name}: request received", False, "listener saw nothing")
                continue
            req = server.captured[-1]
            check(f"{name}: method POST", req.method == "POST", req.method)
            check(f"{name}: path {kind.route}", req.path == kind.route, req.path)

            header_value = req.headers.get(SESSION_HEADER.lower())
            check(f"{name}: host-session header", header_value == host_session_id,
                  str(header_value))
            parsed_uuid = True
            try:
                uuid.UUID(header_value or "")
            except (ValueError, TypeError):
                parsed_uuid = False
            check(f"{name}: host-session header is a UUID", parsed_uuid, str(header_value))

            declared = req.headers.get("content-length")
            check(
                f"{name}: content-length correct",
                declared is not None
                and declared.isdigit()
                and int(declared) == len(body) == len(req.raw_body),
                f"declared={declared} built={len(body)} received={len(req.raw_body)}",
            )
            check(f"{name}: content-type json",
                  req.headers.get("content-type") == "application/json",
                  str(req.headers.get("content-type")))

            decoded: Any = None
            try:
                decoded = json.loads(req.raw_body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                check(f"{name}: body decodes as JSON", False, str(exc))
            else:
                check(f"{name}: body decodes as JSON object", isinstance(decoded, dict), "")

            if isinstance(decoded, dict):
                if kind.route == EVENT_ROUTE:
                    # ClaudeHookDecoder throws without these
                    # (ClaudeHookEvent.swift:226, :314-315).
                    check(f"{name}: hook_event_name present",
                          isinstance(decoded.get("hook_event_name"), str)
                          and bool(decoded["hook_event_name"]),
                          str(decoded.get("hook_event_name")))
                    check(f"{name}: session_id + cwd present",
                          isinstance(decoded.get("session_id"), str)
                          and isinstance(decoded.get("cwd"), str),
                          f"session_id={decoded.get('session_id')} cwd={decoded.get('cwd')}")
                else:
                    # StatusLinePayload decodes tolerantly; assert the fields the
                    # sidebar actually projects (StatusLinePayload.swift:224-232).
                    check(f"{name}: statusline carries model/context/cost",
                          all(key in decoded for key in ("model", "context_window", "cost")),
                          ",".join(sorted(decoded)))

        # tool names must cycle through the realistic set.
        seen = {
            EVENT_KINDS["tool_start"].build(session, i)["tool_name"]
            for i in range(len(TOOL_NAMES))
        }
        check("tool_start cycles tool names", seen == set(TOOL_NAMES), ",".join(sorted(seen)))

        # every kind the mix can schedule must be a known kind.
        for preset in ("measured", "uniform"):
            weights = mix_weights(preset)
            check(f"mix {preset}: kinds known",
                  set(weights).issubset(set(EVENT_KINDS)),
                  ",".join(sorted(set(weights) - set(EVENT_KINDS))))
            schedule = mix_schedule(weights)
            window = [next(schedule) for _ in range(sum(weights.values()))]
            check(f"mix {preset}: one full cycle matches weights",
                  all(window.count(name) == weight for name, weight in weights.items()),
                  "")
    finally:
        server.shutdown()
        server.server_close()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        os.rmdir(tmpdir)

    failed = 0
    for label, ok, detail in checks:
        if ok:
            print(f"PASS  {label}")
        else:
            failed += 1
            print(f"FAIL  {label}  ({detail})")
    print(f"\n{len(checks) - failed}/{len(checks)} checks passed")
    return 1 if failed else 0


# --- CLI -------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay synthetic agent hook/status traffic at the WorkSpaces hook socket.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  uv run --script scripts/replay-agent-events.py --self-test\n"
            "  uv run --script scripts/replay-agent-events.py --auto-sessions "
            "--rate 2 --duration 60\n"
            "  uv run --script scripts/replay-agent-events.py --session-id <UUID> "
            "--rate 8 --duration 300\n"
        ),
    )
    parser.add_argument("--socket", type=str, default=None,
                        help="hook socket path (default: from --store, else "
                             f"{DEFAULT_SOCKET})")
    parser.add_argument("--store", type=Path, default=default_store_path(),
                        help="local-state.sqlite used for discovery (default: %(default)s)")
    parser.add_argument("--auto-sessions", action="store_true",
                        help="target every active host session of the most recent app run")
    parser.add_argument("--session-id", action="append", default=[], metavar="UUID",
                        help="target host session UUID (repeatable)")
    parser.add_argument("--rate", type=float, default=2.0,
                        help="total events/sec across all sessions (default: %(default)s)")
    parser.add_argument("--duration", type=float, default=60.0,
                        help="seconds to run (default: %(default)s)")
    parser.add_argument("--mix", choices=("measured", "uniform"), default="measured",
                        help="event mix preset (default: %(default)s)")
    parser.add_argument("--timeout", type=float, default=2.0,
                        help="per-request socket timeout in seconds (default: %(default)s)")
    parser.add_argument("--verify-store", action="store_true",
                        help="after the run, count ingested agent_status_events rows")
    parser.add_argument("--self-test", action="store_true",
                        help="assert request framing against an in-process UDS listener")
    return parser.parse_args(argv)


def resolve_socket(args: argparse.Namespace) -> str:
    if args.socket:
        return os.path.expanduser(args.socket)
    if args.store.exists():
        from_store = socket_from_store(args.store)
        if from_store:
            return from_store
    return str(DEFAULT_SOCKET)


def resolve_sessions(args: argparse.Namespace) -> list[Session]:
    sessions: list[Session] = []
    for raw in args.session_id:
        try:
            uuid.UUID(raw)
        except ValueError:
            raise SystemExit(f"--session-id is not a UUID: {raw}")
        sessions.append(Session(host_session_id=raw, cwd=str(Path.cwd())))
    if args.auto_sessions:
        sessions.extend(sessions_from_store(args.store))
    return sessions


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()

    if args.rate <= 0:
        raise SystemExit("--rate must be positive")
    if args.duration <= 0:
        raise SystemExit("--duration must be positive")

    sessions = resolve_sessions(args)
    if not sessions:
        raise SystemExit("no target sessions: pass --auto-sessions or --session-id UUID")

    socket_path = resolve_socket(args)
    if not Path(socket_path).exists():
        raise SystemExit(
            f"socket not found: {socket_path}\n"
            "The app must be running and own the socket (one flock'd owner per path)."
        )
    return replay(args, socket_path, sessions)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
