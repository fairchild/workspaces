#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "paramiko>=3.4.0",
#   "vncdotool>=1.2.0",
# ]
# ///

"""Headless-first Tart VM harness for deterministic GUI automation."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import paramiko
from vncdotool import api


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def fail(message: str) -> RuntimeError:
    return RuntimeError(message)


def run_command(
    argv: list[str],
    *,
    check: bool = True,
    capture_output: bool = True,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        check=check,
        text=True,
        capture_output=capture_output,
        cwd=str(cwd) if cwd else None,
    )


def require_command(name: str) -> None:
    result = run_command(["bash", "-lc", f"command -v {shlex.quote(name)}"], check=False)
    if result.returncode != 0:
        raise fail(f"missing required command: {name}")


def load_session(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise fail(f"session file does not exist: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def save_session(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def parse_vnc_url(log_text: str) -> str:
    match = re.search(r"Opening\s+(vnc://\S+)", log_text)
    if not match:
        return ""
    return match.group(1).rstrip(".")


def wait_for_vnc_url(log_path: Path, process: subprocess.Popen[str], timeout_seconds: int) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if process.poll() is not None:
            text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
            raise fail(f"tart run exited before VNC endpoint was available\n{text}")

        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            url = parse_vnc_url(text)
            if url:
                return url

        time.sleep(0.4)

    raise fail(f"timed out waiting for VNC URL in {log_path}")


def ensure_vm_exists(name: str) -> None:
    result = run_command(["tart", "get", name], check=False)
    if result.returncode != 0:
        raise fail(f"VM not found: {name}")


def vm_exists(name: str) -> bool:
    result = run_command(["tart", "get", name], check=False)
    return result.returncode == 0


def close_screen_sharing() -> None:
    applescript = 'tell application "Screen Sharing" to quit'
    run_command(["osascript", "-e", applescript], check=False)


def tart_stop(vm_name: str, timeout_seconds: int) -> None:
    run_command(["tart", "stop", vm_name, "--timeout", str(timeout_seconds)], check=False)


def tart_delete(vm_name: str) -> None:
    run_command(["tart", "delete", vm_name], check=False)


def parse_subnet_prefix(interface: str) -> str:
    result = run_command(["ipconfig", "getifaddr", interface], check=True)
    ip = result.stdout.strip()
    parts = ip.split(".")
    if len(parts) != 4:
        raise fail(f"could not parse IP for interface {interface}: {ip!r}")
    return ".".join(parts[:3])


def find_open_ssh_hosts(prefix: str) -> list[str]:
    candidates = [f"{prefix}.{index}" for index in range(2, 255)]

    def is_open(ip: str) -> bool:
        try:
            with socket.create_connection((ip, 22), timeout=0.35):
                return True
        except OSError:
            return False

    open_hosts: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=96) as executor:
        future_to_ip = {executor.submit(is_open, ip): ip for ip in candidates}
        for future in concurrent.futures.as_completed(future_to_ip):
            ip = future_to_ip[future]
            try:
                if future.result():
                    open_hosts.append(ip)
            except Exception:
                continue

    return sorted(open_hosts)


def host_matches_target(ip: str, username: str, password: str, share_name: str) -> bool:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            ip,
            username=username,
            password=password,
            timeout=3,
            banner_timeout=3,
            auth_timeout=3,
            look_for_keys=False,
            allow_agent=False,
        )
        probe_cmd = (
            "set -euo pipefail; "
            f"test -d {shlex.quote(f'/Volumes/My Shared Files/{share_name}')}; "
            "echo __TART_HARNESS_OK__; "
            "whoami"
        )
        stdin, stdout, stderr = client.exec_command(probe_cmd, timeout=4)
        lines = [line.strip() for line in stdout.read().decode("utf-8", errors="replace").splitlines()]
        return len(lines) >= 2 and lines[0] == "__TART_HARNESS_OK__" and lines[1] == username
    except Exception:
        return False
    finally:
        try:
            client.close()
        except Exception:
            pass


def discover_ssh_host(prefix: str, username: str, password: str, share_name: str) -> str:
    open_hosts = find_open_ssh_hosts(prefix)
    log(f"Open SSH hosts on {prefix}.0/24: {len(open_hosts)}")

    for ip in open_hosts:
        if host_matches_target(ip, username, password, share_name):
            return ip

    raise fail(
        "could not find target VM over SSH; pass --ssh-host manually or verify Remote Login + credentials"
    )


def capture_frame(vnc_host: str, vnc_port: int, vnc_password: str, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    last_error = ""
    for _ in range(5):
        client = None
        try:
            client = api.connect(f"{vnc_host}::{vnc_port}", password=vnc_password, timeout=12)
            client.captureScreen(str(output_path))
            client.disconnect()
            api.shutdown()
            return
        except Exception as exc:
            last_error = str(exc)
            try:
                if client is not None:
                    client.disconnect()
            except Exception:
                pass
            try:
                api.shutdown()
            except Exception:
                pass
            time.sleep(0.4)

    raise fail(f"failed VNC capture after retries: {last_error}")


def command_start(args: argparse.Namespace) -> int:
    require_command("tart")

    ensure_vm_exists(args.base_vm)

    ts = time.strftime("%Y%m%d-%H%M%S")
    run_vm = args.run_vm or f"{args.vm_prefix}-{ts}"

    if vm_exists(run_vm):
        raise fail(f"run VM already exists: {run_vm}")

    output_dir = Path(args.output_dir or f"./output/tart-harness/{ts}").resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    log_path = output_dir / "tart-run.log"
    session_path = output_dir / "session.json"

    log(f"Cloning {args.base_vm} -> {run_vm}")
    run_command(["tart", "clone", args.base_vm, run_vm], check=True)

    log_handle = log_path.open("w", encoding="utf-8")
    process: subprocess.Popen[str] | None = None

    try:
        log(f"Starting VM {run_vm} (headless by default)")
        process = subprocess.Popen(
            [
                "tart",
                "run",
                "--vnc-experimental",
                f"--net-bridged={args.bridge_interface}",
                "--dir",
                f"{args.share_name}:{Path(args.share_path).resolve()}",
                run_vm,
            ],
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            text=True,
        )

        vnc_url = wait_for_vnc_url(log_path, process, timeout_seconds=args.vnc_wait_seconds)
        parsed = urlparse(vnc_url)
        vnc_host = parsed.hostname or "127.0.0.1"
        vnc_port = parsed.port
        vnc_password = parsed.password or ""

        if vnc_port is None or not vnc_password:
            raise fail(f"failed to parse VNC endpoint from URL: {vnc_url}")

        if args.open_vnc:
            run_command(["open", vnc_url], check=False)
            log("Opened VNC viewer")

        session = {
            "status": "running",
            "created_at": ts,
            "base_vm": args.base_vm,
            "run_vm": run_vm,
            "bridge_interface": args.bridge_interface,
            "share_name": args.share_name,
            "share_path": str(Path(args.share_path).resolve()),
            "vnc_url": vnc_url,
            "vnc_host": vnc_host,
            "vnc_port": vnc_port,
            "vnc_password": vnc_password,
            "open_vnc": args.open_vnc,
            "run_pid": process.pid,
            "log_path": str(log_path),
            "session_file": str(session_path),
        }
        save_session(session_path, session)
        print(json.dumps(session, indent=2))
        return 0
    except Exception:
        tart_stop(run_vm, timeout_seconds=8)
        if not args.keep_failed_vm:
            tart_delete(run_vm)
        raise
    finally:
        try:
            log_handle.close()
        except Exception:
            pass


def command_discover_ssh(args: argparse.Namespace) -> int:
    session_path = Path(args.session_file).resolve()
    session = load_session(session_path)

    prefix = parse_subnet_prefix(args.bridge_interface or session.get("bridge_interface", "en0"))
    share_name = args.share_name or session.get("share_name", "workspaces")

    log("Discovering target VM SSH host")
    ssh_host = discover_ssh_host(
        prefix=prefix,
        username=args.ssh_user,
        password=args.ssh_password,
        share_name=share_name,
    )

    session["ssh_host"] = ssh_host
    session["ssh_user"] = args.ssh_user
    save_session(session_path, session)
    print(ssh_host)
    return 0


def command_capture(args: argparse.Namespace) -> int:
    session = load_session(Path(args.session_file).resolve())
    capture_frame(
        vnc_host=session["vnc_host"],
        vnc_port=int(session["vnc_port"]),
        vnc_password=session["vnc_password"],
        output_path=Path(args.output).resolve(),
    )
    print(str(Path(args.output).resolve()))
    return 0


def command_teardown(args: argparse.Namespace) -> int:
    require_command("tart")

    session_path = Path(args.session_file).resolve()
    session = load_session(session_path)

    run_vm = session.get("run_vm")
    if not run_vm:
        raise fail(f"session missing run_vm: {session_path}")

    if args.close_vnc and session.get("open_vnc", False):
        log("Closing Screen Sharing before VM shutdown")
        close_screen_sharing()

    log(f"Stopping VM {run_vm}")
    tart_stop(run_vm, timeout_seconds=args.stop_timeout)

    if args.delete_vm:
        log(f"Deleting VM {run_vm}")
        tart_delete(run_vm)

    run_pid = session.get("run_pid")
    if isinstance(run_pid, int):
        try:
            os.kill(run_pid, 15)
        except OSError:
            pass

    session["status"] = "stopped"
    session["stopped_at"] = time.strftime("%Y%m%d-%H%M%S")
    session["delete_vm"] = args.delete_vm
    session["close_vnc"] = args.close_vnc
    save_session(session_path, session)
    print(json.dumps(session, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Headless-first Tart harness for GUI automation and capture"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="clone + run VM with VNC endpoint")
    start.add_argument("--base-vm", required=True)
    start.add_argument("--run-vm", default="")
    start.add_argument("--vm-prefix", default="tart-gui-run")
    start.add_argument("--bridge-interface", default="en0")
    start.add_argument("--share-name", default="workspaces")
    start.add_argument("--share-path", default=".")
    start.add_argument("--output-dir", default="")
    start.add_argument("--vnc-wait-seconds", type=int, default=60)
    start.add_argument("--keep-failed-vm", action="store_true")
    start.add_argument(
        "--open-vnc",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="open live Screen Sharing session (default: headless)",
    )
    start.set_defaults(func=command_start)

    discover = subparsers.add_parser(
        "discover-ssh",
        help="find target VM SSH host and store it in session.json",
    )
    discover.add_argument("--session-file", required=True)
    discover.add_argument("--bridge-interface", default="")
    discover.add_argument("--share-name", default="")
    discover.add_argument("--ssh-user", default="admin")
    discover.add_argument("--ssh-password", default="admin")
    discover.set_defaults(func=command_discover_ssh)

    capture = subparsers.add_parser("capture", help="capture one VNC frame")
    capture.add_argument("--session-file", required=True)
    capture.add_argument("--output", required=True)
    capture.set_defaults(func=command_capture)

    teardown = subparsers.add_parser(
        "teardown",
        help="close VNC (optional), stop VM, then delete VM (optional)",
    )
    teardown.add_argument("--session-file", required=True)
    teardown.add_argument("--stop-timeout", type=int, default=20)
    teardown.add_argument(
        "--delete-vm",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    teardown.add_argument(
        "--close-vnc",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="close Screen Sharing first when open-vnc was used",
    )
    teardown.set_defaults(func=command_teardown)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        return int(args.func(args))
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
