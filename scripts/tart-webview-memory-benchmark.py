#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

"""Measure idle vs web-loaded memory impact inside an isolated Tart VM."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any, TextIO
from urllib.parse import urlparse


PROCESS_SNAPSHOT_CMD = r"""ps -axo pid=,rss=,comm= | awk '
BEGIN { sum=0 }
$3 ~ /WorkspaceManag|WebKit\.WebContent|WebKit\.Networking|WebKit\.GPU/ {
    printf("%s\t%s\t%s\n", $1, $2, $3)
    sum += $2
}
END {
    printf("__TOTAL_RSS_KB__=%d\n", sum)
}
'"""


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def fail(message: str) -> RuntimeError:
    return RuntimeError(message)


def run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture_output: bool = True,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        text=True,
        check=check,
        capture_output=capture_output,
        timeout=timeout,
    )


def require_cmd(name: str) -> None:
    result = run(["bash", "-lc", f"command -v {shlex.quote(name)}"], check=False)
    if result.returncode != 0:
        raise fail(f"missing required command: {name}")


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


def guest_exec(run_vm: str, command: str, timeout: int = 120) -> tuple[int, str, str]:
    completed = run(
        ["tart", "exec", run_vm, "bash", "-lc", command],
        check=False,
        timeout=timeout,
    )
    return completed.returncode, completed.stdout, completed.stderr


def parse_process_snapshot(raw: str) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    total_rss_kb = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        if line.startswith("__TOTAL_RSS_KB__="):
            try:
                total_rss_kb = int(line.split("=", 1)[1].strip())
            except ValueError:
                total_rss_kb = 0
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        try:
            pid = int(parts[0].strip())
            rss_kb = int(parts[1].strip())
        except ValueError:
            continue
        rows.append(
            {
                "pid": pid,
                "rss_kb": rss_kb,
                "command": parts[2].strip(),
            }
        )

    return {
        "total_rss_kb": total_rss_kb,
        "rows": rows,
    }


def collect_process_snapshot(run_vm: str) -> dict[str, Any]:
    rc, out, err = guest_exec(run_vm, PROCESS_SNAPSHOT_CMD, timeout=30)
    if rc != 0:
        raise fail(f"process snapshot failed:\n{out}\n{err}")
    return parse_process_snapshot(out)


def collect_app_rss_kb(run_vm: str, app_pid: int) -> int:
    rc, out, err = guest_exec(run_vm, f"ps -o rss= -p {app_pid} | tr -d ' '", timeout=20)
    if rc != 0:
        raise fail(f"failed to read app RSS:\n{out}\n{err}")
    text = out.strip()
    if not text or not text.isdigit():
        raise fail(f"unexpected app RSS output for pid={app_pid}: {text!r}")
    return int(text)


def summarize(values: list[int]) -> dict[str, float]:
    if not values:
        return {"mean": 0.0, "min": 0.0, "max": 0.0}
    return {
        "mean": sum(values) / len(values),
        "min": float(min(values)),
        "max": float(max(values)),
    }


def parse_args(repo_root: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark memory impact of loading embedded WebView in an isolated Tart VM."
    )
    parser.add_argument(
        "--base-vm",
        default=os.environ.get("WORKSPACES_TART_BASE_VM", ""),
        help="base VM to clone (default: WORKSPACES_TART_BASE_VM)",
    )
    parser.add_argument(
        "--vm-name",
        default="",
        help="explicit run VM name (default: wm-webview-bench-<timestamp>)",
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
        "--binary",
        choices=["release", "debug"],
        default="release",
        help="binary flavor to launch in guest (default: release)",
    )
    parser.add_argument(
        "--web-source-name",
        default="Swift Docs",
        help="fixture web source name for web-loaded phase (default: Swift Docs)",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=5,
        help="number of benchmark iterations (default: 5)",
    )
    parser.add_argument(
        "--launch-warmup-seconds",
        type=float,
        default=2.0,
        help="wait after app launch before sampling idle (default: 2.0)",
    )
    parser.add_argument(
        "--web-load-timeout-seconds",
        type=float,
        default=30.0,
        help="max wait for WebKit process in web-loaded phase (default: 30.0)",
    )
    parser.add_argument(
        "--post-load-settle-seconds",
        type=float,
        default=2.0,
        help="wait after web load detection before final sample (default: 2.0)",
    )
    parser.add_argument(
        "--output-root",
        default=str(repo_root / "output" / "tart-webview-benchmark" / "live"),
        help="host artifact root directory",
    )
    parser.add_argument(
        "--open-vnc",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="open local Screen Sharing during benchmark (default: headless)",
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
    return parser.parse_args()


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    args = parse_args(repo_root)

    if not args.base_vm:
        print(
            "ERROR: base VM required. Pass --base-vm or set WORKSPACES_TART_BASE_VM.",
            file=os.sys.stderr,
        )
        return 1
    if args.runs < 1:
        print("ERROR: --runs must be >= 1", file=os.sys.stderr)
        return 1

    require_cmd("tart")
    ensure_vm_exists(args.base_vm)

    run_id = time.strftime("%Y%m%d-%H%M%S")
    run_vm = args.vm_name or f"wm-webview-bench-{run_id}"

    output_root = Path(args.output_root).resolve()
    host_output_dir = output_root / run_id
    host_output_dir.mkdir(parents=True, exist_ok=True)

    host_metadata_path = host_output_dir / "benchmark.json"
    tart_log_path = host_output_dir / "tart-run.log"

    cloned = False
    tart_proc: subprocess.Popen[str] | None = None
    tart_log_file: TextIO | None = None
    vnc_url = ""
    results: list[dict[str, Any]] = []

    try:
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

        vnc_deadline = time.time() + 120
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

        if args.open_vnc:
            run(["open", vnc_url], check=False, capture_output=True)
            log("Opened local VNC viewer")

        parsed = urlparse(vnc_url)
        vnc_host = parsed.hostname or "127.0.0.1"
        vnc_port = parsed.port or 0

        guest_repo_root = f"/Volumes/My Shared Files/{args.share_name}"
        guest_output_dir = (
            f"{guest_repo_root}/output/tart-webview-benchmark/live/benchmark-{run_id}-guest"
        )
        guest_data_root = f"{guest_output_dir}/data"
        guest_logs_root = f"{guest_output_dir}/logs"
        guest_binary = (
            f"{guest_repo_root}/.build/arm64-apple-macosx/{args.binary}/WorkspaceManager"
        )

        preflight_cmd = (
            "set -euo pipefail; "
            "command -v bash >/dev/null; "
            "command -v ps >/dev/null; "
            f"test -x {shlex.quote(guest_binary)}; "
            f"mkdir -p {shlex.quote(guest_data_root)} {shlex.quote(guest_logs_root)}"
        )
        rc, out, err = guest_exec(run_vm, preflight_cmd, timeout=45)
        if rc != 0:
            raise fail(f"guest preflight failed:\n{out}\n{err}")

        def kill_app_and_webkit() -> None:
            cleanup_cmd = (
                "pkill -x WorkspaceManager >/dev/null 2>&1 || true; "
                "pkill -f WebKit.WebContent >/dev/null 2>&1 || true; "
                "pkill -f WebKit.Networking >/dev/null 2>&1 || true; "
                "pkill -f WebKit.GPU >/dev/null 2>&1 || true; "
                "sleep 1"
            )
            guest_exec(run_vm, cleanup_cmd, timeout=20)

        def launch_app(*, data_dir: str, log_path: str, web_bootstrap: bool) -> int:
            base_env = [
                f"WORKSPACES_DATA_DIR={shlex.quote(data_dir)}",
                "WORKSPACES_UI_FIXTURE=1",
                "WORKSPACES_DISABLE_AUTO_IMPORT=1",
                "WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1",
            ]
            if web_bootstrap:
                base_env.append("WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE=1")
                base_env.append(
                    f"WORKSPACES_UI_FIXTURE_WEB_SOURCE={shlex.quote(args.web_source_name)}"
                )

            launch_cmd = (
                "set -euo pipefail; "
                f"cd {shlex.quote(guest_repo_root)}; "
                f"rm -rf {shlex.quote(data_dir)}; "
                f"mkdir -p {shlex.quote(data_dir)} {shlex.quote(guest_logs_root)}; "
                f"nohup env {' '.join(base_env)} {shlex.quote(guest_binary)} "
                f">{shlex.quote(log_path)} 2>&1 & echo __WM_PID__:$!"
            )

            rc_local, launch_out, launch_err = guest_exec(run_vm, launch_cmd, timeout=120)
            if rc_local != 0:
                raise fail(f"failed to launch app in guest:\n{launch_out}\n{launch_err}")

            pid_match = re.search(r"__WM_PID__:(\d+)", launch_out)
            if not pid_match:
                raise fail(f"could not parse app pid from launch output: {launch_out!r}")
            app_pid_local = int(pid_match.group(1))

            rc_local, _, _ = guest_exec(run_vm, f"kill -0 {app_pid_local}", timeout=20)
            if rc_local != 0:
                raise fail(f"launched app pid={app_pid_local} is not running")
            return app_pid_local

        def latest_web_metric_line(log_path: str) -> str:
            metric_cmd = (
                f"test -f {shlex.quote(log_path)} && "
                f"grep -n 'metric=web_first_load' {shlex.quote(log_path)} | tail -n 1 || true"
            )
            _, metric_out, _ = guest_exec(run_vm, metric_cmd, timeout=20)
            return metric_out.strip()

        def wait_for_webkit_and_metric(log_path: str) -> tuple[bool, bool, str]:
            deadline = time.time() + args.web_load_timeout_seconds
            saw_webkit = False
            saw_metric = False
            metric_line = ""

            while time.time() < deadline:
                snapshot = collect_process_snapshot(run_vm)
                saw_webkit = any("WebKit.WebContent" in row["command"] for row in snapshot["rows"])
                metric_line = latest_web_metric_line(log_path)
                saw_metric = bool(metric_line)
                if saw_webkit:
                    return saw_webkit, saw_metric, metric_line
                time.sleep(0.4)

            metric_line = latest_web_metric_line(log_path)
            return saw_webkit, bool(metric_line), metric_line

        for run_index in range(1, args.runs + 1):
            log(f"Benchmark run {run_index}/{args.runs}")
            kill_app_and_webkit()

            idle_data_dir = f"{guest_data_root}/run-{run_index}-idle"
            idle_log_path = f"{guest_logs_root}/app-run-{run_index}-idle.log"
            idle_pid = launch_app(data_dir=idle_data_dir, log_path=idle_log_path, web_bootstrap=False)
            time.sleep(args.launch_warmup_seconds)
            idle_snapshot = collect_process_snapshot(run_vm)
            idle_app_rss_kb = collect_app_rss_kb(run_vm, idle_pid)
            guest_exec(run_vm, f"kill {idle_pid} >/dev/null 2>&1 || true", timeout=20)
            time.sleep(1.0)

            web_data_dir = f"{guest_data_root}/run-{run_index}-web"
            web_log_path = f"{guest_logs_root}/app-run-{run_index}-web.log"
            web_pid = launch_app(data_dir=web_data_dir, log_path=web_log_path, web_bootstrap=True)
            saw_webkit, saw_metric, metric_line = wait_for_webkit_and_metric(web_log_path)
            time.sleep(args.post_load_settle_seconds)
            web_snapshot = collect_process_snapshot(run_vm)
            web_app_rss_kb = collect_app_rss_kb(run_vm, web_pid)
            guest_exec(run_vm, f"kill {web_pid} >/dev/null 2>&1 || true", timeout=20)
            time.sleep(1.0)

            run_result = {
                "run_index": run_index,
                "idle_phase": {
                    "pid": idle_pid,
                    "log_path": idle_log_path,
                    "app_rss_kb": idle_app_rss_kb,
                    "webkit_processes_rss_kb": idle_snapshot["total_rss_kb"],
                    "webkit_process_rows": idle_snapshot["rows"],
                },
                "web_phase": {
                    "pid": web_pid,
                    "log_path": web_log_path,
                    "app_rss_kb": web_app_rss_kb,
                    "webkit_processes_rss_kb": web_snapshot["total_rss_kb"],
                    "webkit_process_rows": web_snapshot["rows"],
                    "saw_webkit_process": saw_webkit,
                    "saw_web_first_load_metric": saw_metric,
                    "web_first_load_metric_line": metric_line,
                },
                "delta": {
                    "app_kb": web_app_rss_kb - idle_app_rss_kb,
                    "webkit_processes_kb": web_snapshot["total_rss_kb"] - idle_snapshot["total_rss_kb"],
                },
            }
            results.append(run_result)

            log(
                "run="
                f"{run_index} app_delta_kb={run_result['delta']['app_kb']} "
                f"webkit_delta_kb={run_result['delta']['webkit_processes_kb']} "
                f"saw_webkit={saw_webkit} saw_metric={saw_metric}"
            )

        app_deltas = [entry["delta"]["app_kb"] for entry in results]
        webkit_deltas = [entry["delta"]["webkit_processes_kb"] for entry in results]
        idle_app = [entry["idle_phase"]["app_rss_kb"] for entry in results]
        web_app = [entry["web_phase"]["app_rss_kb"] for entry in results]
        idle_webkit = [entry["idle_phase"]["webkit_processes_rss_kb"] for entry in results]
        web_webkit = [entry["web_phase"]["webkit_processes_rss_kb"] for entry in results]
        webkit_seen_count = sum(1 for entry in results if entry["web_phase"]["saw_webkit_process"])
        metric_seen_count = sum(1 for entry in results if entry["web_phase"]["saw_web_first_load_metric"])

        summary = {
            "run_id": run_id,
            "base_vm": args.base_vm,
            "run_vm": run_vm,
            "binary": args.binary,
            "runs": args.runs,
            "web_source_name": args.web_source_name,
            "vnc_host": vnc_host,
            "vnc_port": vnc_port,
            "webkit_seen_count": webkit_seen_count,
            "metric_seen_count": metric_seen_count,
            "app_only": {
                "idle_rss_kb": summarize(idle_app),
                "web_loaded_rss_kb": summarize(web_app),
                "delta_kb": summarize(app_deltas),
            },
            "webkit_processes": {
                "idle_rss_kb": summarize(idle_webkit),
                "web_loaded_rss_kb": summarize(web_webkit),
                "delta_kb": summarize(webkit_deltas),
            },
        }

        payload = {
            "summary": summary,
            "runs": results,
            "artifacts": {
                "output_dir": str(host_output_dir),
                "tart_log": str(tart_log_path),
            },
        }
        host_metadata_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        print(f"OUTPUT_DIR={host_output_dir}")
        print(f"BENCHMARK_JSON={host_metadata_path}")
        return 0
    finally:
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
