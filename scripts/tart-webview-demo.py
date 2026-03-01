#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "paramiko>=3.4.0",
#   "vncdotool>=1.2.0",
# ]
# ///

"""Record the repo -> webview transition in an isolated Tart VM."""

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
from typing import Iterable, TextIO
from urllib.parse import urlparse

import paramiko


WINDOW_PROBE_SWIFT = r"""swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["Workspaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

var bestWindow: (x: Int, y: Int, width: Int, height: Int, area: Int)?
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = Int((bounds["X"] as? Double) ?? 0)
    let y = Int((bounds["Y"] as? Double) ?? 0)
    let width = Int((bounds["Width"] as? Double) ?? 0)
    let height = Int((bounds["Height"] as? Double) ?? 0)
    let area = max(0, width * height)
    guard width > 200, height > 200 else { continue }

    if let existing = bestWindow, existing.area >= area {
        continue
    }
    bestWindow = (x: x, y: y, width: width, height: height, area: area)
}

if let bestWindow {
    print("\(bestWindow.x),\(bestWindow.y),\(bestWindow.width),\(bestWindow.height)")
    exit(0)
}

exit(1)
SWIFT"""

VNC_CAPTURE_SNIPPET = """import os
from vncdotool import api

host = os.environ["WM_VNC_HOST"]
port = os.environ["WM_VNC_PORT"]
password = os.environ["WM_VNC_PASSWORD"]
path = os.environ["WM_CAPTURE_PATH"]

client = api.connect(f"{host}::{port}", password=password, timeout=12)
client.captureScreen(path)
client.disconnect()
api.shutdown()
"""


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def fail(message: str) -> RuntimeError:
    return RuntimeError(message)


def run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    text: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        text=text,
        check=check,
        capture_output=capture_output,
    )


def require_cmd(name: str) -> None:
    if shutil_which(name) is None:
        raise fail(f"missing required command: {name}")


def shutil_which(name: str) -> str | None:
    return subprocess.run(
        ["bash", "-lc", f"command -v {shlex.quote(name)}"],
        text=True,
        check=False,
        capture_output=True,
    ).stdout.strip() or None


def parse_args(repo_root: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a webview demo flow inside Tart and record an MP4 artifact."
    )
    parser.add_argument(
        "--base-vm",
        default=os.environ.get("WORKSPACES_TART_BASE_VM", ""),
        help="base VM to clone (default: WORKSPACES_TART_BASE_VM)",
    )
    parser.add_argument(
        "--vm-name",
        default="",
        help="explicit run VM name (default: wm-webview-demo-<timestamp>)",
    )
    parser.add_argument(
        "--bridge-interface",
        default="en0",
        help="bridge interface for tart run --net-bridged (default: en0)",
    )
    parser.add_argument(
        "--share-name",
        default="workspaces",
        help="virtiofs share name for mounted repo (default: workspaces)",
    )
    parser.add_argument(
        "--ssh-host",
        default="",
        help="guest SSH host; when omitted script auto-discovers host on bridged subnet",
    )
    parser.add_argument("--ssh-user", default="admin")
    parser.add_argument("--ssh-password", default="admin")
    parser.add_argument(
        "--build-in-guest",
        action="store_true",
        help="build in guest before launch (slower but useful for debug parity)",
    )
    parser.add_argument(
        "--frame-rate",
        type=int,
        default=2,
        help="output MP4 framerate (default: 2)",
    )
    parser.add_argument(
        "--keep-vm",
        action="store_true",
        help="keep cloned run VM after completion",
    )
    parser.add_argument(
        "--keep-running",
        action="store_true",
        help="keep VM running after completion",
    )
    parser.add_argument(
        "--output-root",
        default=str(repo_root / "output" / "tart-webview-demo" / "live"),
        help="host artifact root directory",
    )
    parser.add_argument(
        "--open-vnc",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="open a local VNC viewer for live observation (default: headless)",
    )
    return parser.parse_args()


def ensure_vm_exists(name: str) -> None:
    result = run(["tart", "get", name], check=False)
    if result.returncode != 0:
        raise fail(f"VM '{name}' not found. Pull/create it first.")


def stop_vm(name: str) -> None:
    run(["tart", "stop", name, "--timeout", "20"], check=False)


def delete_vm(name: str) -> None:
    run(["tart", "delete", name], check=False)


def clone_vm(base_vm: str, run_vm: str) -> None:
    run(["tart", "clone", base_vm, run_vm], check=True)


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def parse_vnc_url(log_text: str) -> str:
    match = re.search(r"Opening\s+(vnc://\S+)", log_text)
    if not match:
        return ""
    return match.group(1).rstrip(".")


def get_host_subnet_prefix(interface: str) -> str:
    result = run(["ipconfig", "getifaddr", interface], check=True)
    host_ip = result.stdout.strip()
    parts = host_ip.split(".")
    if len(parts) != 4:
        raise fail(f"could not parse host IP for interface '{interface}': {host_ip!r}")
    return ".".join(parts[:3])


def arp_ips(prefix: str) -> set[str]:
    result = run(["arp", "-an"], check=True)
    ips: set[str] = set()
    for line in result.stdout.splitlines():
        if " at (incomplete) " in line:
            continue
        match = re.search(r"\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-f:]+)", line)
        if not match:
            continue
        ip = match.group(1)
        mac = match.group(2)
        if mac.lower() == "ff:ff:ff:ff:ff:ff":
            continue
        if ip.startswith(f"{prefix}."):
            ips.add(ip)
    return ips


def probe_ssh_target(ip: str, user: str, password: str, share_name: str) -> bool:
    sock: socket.socket | None = None
    try:
        sock = socket.create_connection((ip, 22), timeout=0.6)
        sock.settimeout(3.0)
    except OSError:
        return False

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            ip,
            username=user,
            password=password,
            timeout=3,
            banner_timeout=3,
            auth_timeout=3,
            look_for_keys=False,
            allow_agent=False,
            sock=sock,
        )
        probe_cmd = (
            "set -euo pipefail; "
            f"test -d {shlex.quote(f'/Volumes/My Shared Files/{share_name}')}; "
            "echo __WM_PROBE_OK__; "
            "whoami"
        )
        stdin, stdout, stderr = client.exec_command(probe_cmd, timeout=4)
        lines = [line.strip() for line in stdout.read().decode("utf-8", errors="replace").splitlines()]
        return len(lines) >= 2 and lines[0] == "__WM_PROBE_OK__" and lines[1] == user
    except Exception:
        return False
    finally:
        try:
            client.close()
        except Exception:
            pass
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def find_open_ssh_hosts(candidates: Iterable[str]) -> list[str]:
    candidate_list = list(dict.fromkeys(candidates))
    if not candidate_list:
        return []

    def is_open(ip: str) -> bool:
        try:
            with socket.create_connection((ip, 22), timeout=0.35):
                return True
        except OSError:
            return False

    open_hosts: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as executor:
        future_to_ip = {executor.submit(is_open, ip): ip for ip in candidate_list}
        for future in concurrent.futures.as_completed(future_to_ip):
            ip = future_to_ip[future]
            try:
                if future.result():
                    open_hosts.append(ip)
            except Exception:
                continue

    return sorted(open_hosts)


def first_probe_hit(candidates: Iterable[str], user: str, password: str, share_name: str) -> str:
    candidate_list = list(dict.fromkeys(candidates))
    if not candidate_list:
        return ""

    open_hosts = find_open_ssh_hosts(candidate_list)
    for ip in open_hosts:
        if probe_ssh_target(ip, user, password, share_name):
            return ip
    return ""


def discover_ssh_host(
    *,
    prefix: str,
    baseline_arp: set[str],
    user: str,
    password: str,
    share_name: str,
    timeout_seconds: int = 90,
) -> str:
    checked: set[str] = set()
    deadline = time.time() + timeout_seconds
    full_scan_done = False
    iteration = 0

    while time.time() < deadline:
        iteration += 1
        current_arp = arp_ips(prefix)
        new_candidates = sorted(ip for ip in current_arp if ip not in baseline_arp and ip not in checked)
        existing_candidates = sorted(ip for ip in current_arp if ip not in checked)
        candidates = new_candidates + existing_candidates

        if candidates:
            log(
                "SSH discovery probe "
                f"(attempt={iteration}, candidates={len(candidates)}, new={len(new_candidates)})"
            )
            hit = first_probe_hit(candidates, user, password, share_name)
            checked.update(candidates)
            if hit:
                return hit

        if not full_scan_done and (iteration >= 3 or time.time() + 20 >= deadline):
            full_scan_done = True
            brute_force = [f"{prefix}.{i}" for i in range(2, 255) if f"{prefix}.{i}" not in checked]
            log(f"SSH discovery fallback brute-force scan ({len(brute_force)} addresses)")
            hit = first_probe_hit(brute_force, user, password, share_name)
            checked.update(brute_force)
            if hit:
                return hit

        time.sleep(1.0)

    raise fail("unable to discover guest SSH host; pass --ssh-host explicitly")


def ssh_exec(client: paramiko.SSHClient, command: str, timeout: int = 120) -> tuple[int, str, str]:
    stdin, stdout, stderr = client.exec_command(f"bash -lc {shlex.quote(command)}", timeout=timeout)
    rc = stdout.channel.recv_exit_status()
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    return rc, out, err


def capture_vnc_frame(host: str, port: int, password: str, output_path: Path) -> None:
    env = os.environ.copy()
    env["WM_VNC_HOST"] = host
    env["WM_VNC_PORT"] = str(port)
    env["WM_VNC_PASSWORD"] = password
    env["WM_CAPTURE_PATH"] = str(output_path)

    last_error = ""
    for _ in range(5):
        proc = subprocess.run(
            [sys.executable, "-c", VNC_CAPTURE_SNIPPET],
            text=True,
            capture_output=True,
            env=env,
        )
        if proc.returncode == 0:
            return
        last_error = (proc.stderr or proc.stdout).strip()
        time.sleep(0.4)

    raise fail(f"failed VNC capture for {output_path}: {last_error}")


def parse_window_geometry(raw: str) -> tuple[int, int, int, int] | None:
    text = raw.strip()
    if not re.match(r"^-?\d+,-?\d+,\d+,\d+$", text):
        return None
    x_str, y_str, w_str, h_str = text.split(",")
    return int(x_str), int(y_str), int(w_str), int(h_str)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    args = parse_args(repo_root)

    if not args.base_vm:
        print(
            "ERROR: base VM required. Pass --base-vm or set WORKSPACES_TART_BASE_VM.",
            file=sys.stderr,
        )
        return 1

    require_cmd("tart")
    require_cmd("ffmpeg")
    ensure_vm_exists(args.base_vm)

    run_id = time.strftime("%Y%m%d-%H%M%S")
    run_vm = args.vm_name or f"wm-webview-demo-{run_id}"

    output_root = Path(args.output_root).resolve()
    host_output_dir = output_root / run_id
    frames_dir = host_output_dir / "frames"
    host_output_dir.mkdir(parents=True, exist_ok=True)
    frames_dir.mkdir(parents=True, exist_ok=True)

    host_metadata_path = host_output_dir / "metadata.json"
    host_launch_output_path = host_output_dir / "launch-output.txt"
    tart_log_path = host_output_dir / "tart-run.log"
    host_video_path = host_output_dir / "webview-demo.mp4"

    cloned = False
    tart_proc: subprocess.Popen[str] | None = None
    tart_log_file: TextIO | None = None
    ssh_client: paramiko.SSHClient | None = None
    ssh_host = args.ssh_host.strip()
    vnc_url = ""

    baseline_arp = set()
    subnet_prefix = get_host_subnet_prefix(args.bridge_interface)
    baseline_arp = arp_ips(subnet_prefix)

    try:
        ensure_vm_exists(args.base_vm)
        if run_vm == args.base_vm:
            raise fail("--vm-name must differ from --base-vm")
        if run_vm != args.base_vm and run(["tart", "get", run_vm], check=False).returncode == 0:
            raise fail(f"run VM '{run_vm}' already exists; choose a different --vm-name")

        log(f"Cloning VM '{args.base_vm}' -> '{run_vm}'")
        clone_vm(args.base_vm, run_vm)
        cloned = True

        log(f"Starting VM '{run_vm}' with VNC and bridged networking")
        tart_log_file = tart_log_path.open("w", encoding="utf-8")
        tart_proc = subprocess.Popen(
            [
                "tart",
                "run",
                "--vnc-experimental",
                f"--net-bridged={args.bridge_interface}",
                "--dir",
                f"{args.share_name}:{repo_root}",
                run_vm,
            ],
            stdout=tart_log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )

        vnc_deadline = time.time() + 60
        while time.time() < vnc_deadline:
            if tart_proc.poll() is not None:
                tart_log_file.flush()
                raise fail(f"tart run exited early:\n{read_text(tart_log_path)}")
            tart_log_file.flush()
            vnc_url = parse_vnc_url(read_text(tart_log_path))
            if vnc_url:
                break
            time.sleep(0.4)

        if not vnc_url:
            raise fail(f"timed out waiting for VNC endpoint:\n{read_text(tart_log_path)}")

        parsed = urlparse(vnc_url)
        vnc_host = parsed.hostname or "127.0.0.1"
        if parsed.port is None:
            raise fail(f"could not parse VNC port from URL: {vnc_url}")
        vnc_port = parsed.port
        vnc_password = parsed.password or ""
        if not vnc_password:
            raise fail(f"could not parse VNC password from URL: {vnc_url}")

        if args.open_vnc:
            run(["open", vnc_url], check=False, capture_output=True)
            log("Opened local VNC viewer")

        if not ssh_host:
            log("Discovering guest SSH host")
            ssh_host = discover_ssh_host(
                prefix=subnet_prefix,
                baseline_arp=baseline_arp,
                user=args.ssh_user,
                password=args.ssh_password,
                share_name=args.share_name,
            )

        log(f"Connecting SSH: {args.ssh_user}@{ssh_host}")
        ssh_client = paramiko.SSHClient()
        ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh_client.connect(
            ssh_host,
            username=args.ssh_user,
            password=args.ssh_password,
            timeout=12,
            banner_timeout=12,
            auth_timeout=12,
            look_for_keys=False,
            allow_agent=False,
        )

        preflight_cmd = "command -v cliclick >/dev/null && command -v swift >/dev/null && command -v bash >/dev/null"
        rc, out, err = ssh_exec(ssh_client, preflight_cmd, timeout=20)
        if rc != 0:
            raise fail(f"guest preflight failed:\n{out}\n{err}")

        ssh_exec(ssh_client, "pkill -x WorkspaceManager >/dev/null 2>&1 || true", timeout=20)
        time.sleep(1.0)

        guest_repo_root = f"/Volumes/My Shared Files/{args.share_name}"
        guest_output_dir = f"{guest_repo_root}/output/tart-webview-demo/live/vnc-record-{run_id}-guest"
        guest_data_dir = f"{guest_output_dir}/data"

        launch_args = [
            "./scripts/launch-dev.sh",
            "--fixture",
            "--clean-data",
            "--no-activate",
            "--data-dir",
            guest_data_dir,
        ]
        if not args.build_in_guest:
            launch_args.insert(1, "--no-build")

        launch_cmd = " && ".join(
            [
                f"mkdir -p {shlex.quote(guest_output_dir)} {shlex.quote(guest_data_dir)}",
                f"cd {shlex.quote(guest_repo_root)}",
                " ".join(shlex.quote(arg) for arg in launch_args),
            ]
        )

        log("Launching WorkspaceManager inside guest")
        rc, launch_out, launch_err = ssh_exec(ssh_client, launch_cmd, timeout=240)
        host_launch_output_path.write_text(
            launch_out + ("\n--- STDERR ---\n" + launch_err if launch_err else ""),
            encoding="utf-8",
        )
        if rc != 0:
            raise fail(f"launch-dev failed (rc={rc}); see {host_launch_output_path}")

        app_pid_match = re.search(r"WorkspaceManager running \(pid=(\d+)\)", launch_out)
        app_pid = int(app_pid_match.group(1)) if app_pid_match else None
        app_log_match = re.search(r"Log file: (.+)$", launch_out, flags=re.MULTILINE)
        app_log = app_log_match.group(1).strip() if app_log_match else ""

        window = None
        for _ in range(20):
            rc, window_out, _ = ssh_exec(ssh_client, WINDOW_PROBE_SWIFT, timeout=45)
            if rc == 0:
                parsed_window = parse_window_geometry(window_out)
                if parsed_window is not None:
                    window = parsed_window
                    break
            time.sleep(0.6)

        if window is None:
            window = (0, 22, 1024, 746)

        win_x, win_y, win_w, win_h = window
        focus_click = (win_x + 380, win_y + 80)
        repo_click = (win_x + 120, win_y + 120)
        web_offsets = [300, 322, 340, 270]
        web_click = (win_x + 120, win_y + web_offsets[0])

        frame_index = 0
        frame_rows: list[tuple[int, str, str]] = []

        def activate_workspace_manager() -> None:
            activate_cmd = (
                "osascript -e 'tell application \"Workspaces\" to activate' "
                "|| osascript -e 'tell application \"WorkspaceManager\" to activate'"
            )
            ssh_exec(ssh_client, f"{activate_cmd} >/dev/null 2>&1 || true", timeout=20)

        def capture(label: str) -> None:
            nonlocal frame_index
            frame_index += 1
            frame_path = frames_dir / f"frame-{frame_index:04d}.png"
            capture_vnc_frame(vnc_host, vnc_port, vnc_password, frame_path)
            timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            frame_rows.append((frame_index, label, timestamp))
            log(f"captured {frame_path.name} ({label})")

        activate_workspace_manager()
        time.sleep(1.0)
        capture("initial")

        rc, _, err = ssh_exec(ssh_client, f"cliclick c:{focus_click[0]},{focus_click[1]}", timeout=20)
        if rc != 0:
            raise fail(f"failed to focus app window: {err}")
        time.sleep(0.4)
        capture("focused")

        rc, _, err = ssh_exec(ssh_client, f"cliclick c:{repo_click[0]},{repo_click[1]}", timeout=20)
        if rc != 0:
            raise fail(f"failed to click repo row: {err}")
        time.sleep(0.8)
        capture("repo_selected")

        metric_seen = False
        for idx, offset in enumerate(web_offsets):
            candidate = (win_x + 120, win_y + offset)
            rc, _, err = ssh_exec(ssh_client, f"cliclick c:{candidate[0]},{candidate[1]}", timeout=20)
            if rc != 0:
                continue
            web_click = candidate
            time.sleep(0.8)
            if idx == 0:
                capture("web_selected_loading")

            if app_log:
                for _ in range(6):
                    metric_cmd = (
                        f"test -f {shlex.quote(app_log)} && "
                        f"grep -n 'metric=web_first_load' {shlex.quote(app_log)} || true"
                    )
                    _, metric_out, _ = ssh_exec(ssh_client, metric_cmd, timeout=20)
                    if metric_out.strip():
                        metric_seen = True
                        break
                    time.sleep(0.4)
            if metric_seen:
                break

        activate_workspace_manager()
        time.sleep(0.3)
        time.sleep(0.8)
        capture("web_selected_loaded")

        time.sleep(0.6)
        capture("web_selected_stable")

        frames_csv = host_output_dir / "frames.csv"
        lines = [f"{index:04d},{label},{timestamp}\n" for index, label, timestamp in frame_rows]
        frames_csv.write_text("".join(lines), encoding="utf-8")

        metadata = {
            "run_id": run_id,
            "base_vm": args.base_vm,
            "run_vm": run_vm,
            "vnc_url": vnc_url,
            "vnc_host": vnc_host,
            "vnc_port": vnc_port,
            "ssh_host": ssh_host,
            "ssh_user": args.ssh_user,
            "guest_repo_root": guest_repo_root,
            "app_pid": app_pid,
            "app_log": app_log,
            "window": {
                "x": win_x,
                "y": win_y,
                "width": win_w,
                "height": win_h,
            },
            "clicks": {
                "focus": list(focus_click),
                "repo": list(repo_click),
                "web": list(web_click),
            },
            "metric_web_first_load_seen": metric_seen,
            "frames": frame_index,
            "output_dir": str(host_output_dir),
        }
        host_metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

        ffmpeg_cmd = [
            "ffmpeg",
            "-y",
            "-framerate",
            str(args.frame_rate),
            "-i",
            str(frames_dir / "frame-%04d.png"),
            "-vf",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
            "-c:v",
            "libx264",
            "-movflags",
            "+faststart",
            str(host_video_path),
        ]
        run(ffmpeg_cmd, check=True, capture_output=True)

        print(f"OUTPUT_DIR={host_output_dir}")
        print(f"VIDEO={host_video_path}")
        return 0
    finally:
        if ssh_client is not None:
            try:
                ssh_client.close()
            except Exception:
                pass

        if tart_log_file is not None:
            try:
                tart_log_file.close()
            except Exception:
                pass

        if not args.keep_running:
            stop_vm(run_vm)

        if tart_proc is not None and tart_proc.poll() is None:
            try:
                tart_proc.terminate()
                tart_proc.wait(timeout=10)
            except Exception:
                try:
                    tart_proc.kill()
                except Exception:
                    pass

        if cloned and not args.keep_vm:
            delete_vm(run_vm)


if __name__ == "__main__":
    raise SystemExit(main())
