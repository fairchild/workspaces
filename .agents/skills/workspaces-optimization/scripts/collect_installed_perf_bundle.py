#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Collect a bundled set of installed-app performance diagnostics for Workspaces.

This wrapper is intended for target machines that have both:

- an installed WorkspaceManager app
- a checkout of the workspaces repo so the helper scripts are available

It guides the operator through a repeatable sequence and writes one output
directory plus a zip archive that can be shared back for analysis.
"""

from __future__ import annotations

import argparse
import json
import shutil
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_APP = Path("/Applications/WorkspaceManager.app/Contents/MacOS/WorkspaceManager")


def repo_root_from_self() -> Path:
    return Path(__file__).resolve().parents[4]


def parse_args() -> argparse.Namespace:
    repo_root = repo_root_from_self()
    default_output = Path.home() / "Desktop" / f"workspaces-installed-perf-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    parser = argparse.ArgumentParser(
        description="Collect a bundled installed-app performance investigation for Workspaces."
    )
    parser.add_argument(
        "--slow-repo",
        type=Path,
        required=True,
        help="Path to the repo that feels slow in Workspaces.",
    )
    parser.add_argument(
        "--wm-repo",
        type=Path,
        default=repo_root,
        help="Path to the workspaces repo checkout that contains the helper scripts.",
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=DEFAULT_APP,
        help="Installed WorkspaceManager binary path.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=default_output,
        help="Directory for collected artifacts. Default: ~/Desktop/workspaces-installed-perf-<timestamp>",
    )
    parser.add_argument(
        "--countdown",
        type=int,
        default=5,
        help="Countdown before active-lag sampling starts. Default: 5.",
    )
    parser.add_argument(
        "--sample-seconds",
        type=int,
        default=8,
        help="Duration for active-lag samples. Default: 8.",
    )
    parser.add_argument(
        "--host-probe-runs",
        type=int,
        default=3,
        help="Number of shell timing runs per directory in the host probe. Default: 3.",
    )
    parser.add_argument(
        "--skip-input-run",
        action="store_true",
        help="Skip the short input-diagnostics phase.",
    )
    parser.add_argument(
        "--skip-active-lag",
        action="store_true",
        help="Skip the active-lag sample capture phase.",
    )
    parser.add_argument(
        "--no-zip",
        action="store_true",
        help="Do not create a zip archive at the end.",
    )
    parser.add_argument(
        "--plan-only",
        action="store_true",
        help="Print the collection plan and exit without launching anything.",
    )
    return parser.parse_args()


def check_paths(args: argparse.Namespace) -> dict[str, Path]:
    wm_repo = args.wm_repo.expanduser().resolve()
    slow_repo = args.slow_repo.expanduser().resolve()
    app = args.app.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()

    if not wm_repo.is_dir():
        raise SystemExit(f"Workspaces repo checkout not found: {wm_repo}")
    if not slow_repo.is_dir():
        raise SystemExit(f"Slow repo not found: {slow_repo}")
    if not app.exists() or not app.is_file():
        raise SystemExit(f"Installed app binary not found: {app}")

    launcher = wm_repo / "scripts" / "launch-installed-diagnostics.sh"
    summarize_perf = wm_repo / ".agents" / "skills" / "workspaces-optimization" / "scripts" / "summarize_perf_log.py"
    host_probe = wm_repo / ".agents" / "skills" / "workspaces-optimization" / "scripts" / "host_perf_probe.py"
    active_lag = wm_repo / ".agents" / "skills" / "workspaces-optimization" / "scripts" / "capture_active_lag_samples.py"

    for required in [launcher, summarize_perf, host_probe, active_lag]:
        if not required.exists():
            raise SystemExit(f"Required helper script not found: {required}")

    output_dir.mkdir(parents=True, exist_ok=True)
    return {
        "wm_repo": wm_repo,
        "slow_repo": slow_repo,
        "app": app,
        "output_dir": output_dir,
        "launcher": launcher,
        "summarize_perf": summarize_perf,
        "host_probe": host_probe,
        "active_lag": active_lag,
    }


def print_header(title: str) -> None:
    border = "=" * len(title)
    print(f"\n{title}\n{border}")


def prompt(message: str) -> str:
    try:
        return input(message)
    except EOFError:
        return ""


def wait_for_enter(message: str) -> None:
    prompt(message)


def kill_workspaces() -> None:
    subprocess.run(["pkill", "-x", "WorkspaceManager"], capture_output=True, text=True, check=False)
    time.sleep(1)


def newest_workspace_manager_pid() -> int | None:
    result = subprocess.run(["pgrep", "-x", "WorkspaceManager"], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    pids = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if not pids:
        return None
    return int(pids[-1])


def terminate_launcher(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait_for_launcher_exit(process: subprocess.Popen[Any]) -> None:
    while True:
        wait_for_enter("Quit Workspaces, then press Enter to continue.")
        if process.poll() is None:
            print("WorkspaceManager is still running. Quit it first, then press Enter again.")
            continue
        break


def summarize_log(wm_repo: Path, summarize_perf: Path, log_file: Path, base_name: str) -> None:
    text_path = log_file.parent / f"{base_name}-summary.txt"
    json_path = log_file.parent / f"{base_name}-summary.json"

    with text_path.open("w", encoding="utf-8") as handle:
        result = subprocess.run(
            [str(summarize_perf), str(log_file)],
            cwd=str(wm_repo),
            stdout=handle,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    if result.returncode != 0:
        raise SystemExit(f"Failed to summarize perf log: {log_file}")

    with json_path.open("w", encoding="utf-8") as handle:
        result = subprocess.run(
            [str(summarize_perf), "--json", str(log_file)],
            cwd=str(wm_repo),
            stdout=handle,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    if result.returncode != 0:
        raise SystemExit(f"Failed to write perf JSON summary: {log_file}")


def launch_phase(
    *,
    paths: dict[str, Path],
    output_dir: Path,
    phase_name: str,
    shell_mode: str,
    with_input_diagnostics: bool,
    instructions: list[str],
    notes: list[dict[str, str]],
) -> None:
    kill_workspaces()
    log_file = output_dir / f"{phase_name}.log"

    command = [
        str(paths["launcher"]),
        "--app",
        str(paths["app"]),
        "--log-file",
        str(log_file),
        f"--{shell_mode}-shell",
    ]
    if with_input_diagnostics:
        command.append("--with-input-diagnostics")

    print_header(f"Phase: {phase_name}")
    print(f"Launching Workspaces with {shell_mode} shell mode.")
    for line in instructions:
        print(f"- {line}")

    process = subprocess.Popen(
        command,
        cwd=str(paths["wm_repo"]),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(2)
    if process.poll() is not None:
        raise SystemExit(f"Workspaces exited immediately during {phase_name}. Check {log_file}.")

    wait_for_launcher_exit(process)
    process.wait(timeout=5)
    summarize_log(paths["wm_repo"], paths["summarize_perf"], log_file, phase_name)
    note = prompt(f"Short note for {phase_name} (optional): ").strip()
    if note:
        notes.append({"phase": phase_name, "note": note})
    print(f"Wrote {log_file}")
    print(f"Wrote {output_dir / f'{phase_name}-summary.txt'}")


def run_host_probe(paths: dict[str, Path], output_dir: Path, host_probe_runs: int) -> None:
    print_header("Phase: host-probe")
    print("- Running shell timing and process snapshot collection.")
    host_probe_dir = output_dir / "host-probe"
    command = [
        str(paths["host_probe"]),
        "--cwd",
        str(paths["slow_repo"]),
        "--cwd",
        str(Path.home()),
        "--runs",
        str(host_probe_runs),
        "--output-dir",
        str(host_probe_dir),
    ]
    result = subprocess.run(command, cwd=str(paths["wm_repo"]), text=True, check=False)
    if result.returncode != 0:
        raise SystemExit("Host probe failed.")
    print(f"Wrote {host_probe_dir}")


def run_active_lag_capture(
    *,
    paths: dict[str, Path],
    output_dir: Path,
    countdown: int,
    sample_seconds: int,
    notes: list[dict[str, str]],
) -> None:
    kill_workspaces()
    log_file = output_dir / "lag-run.log"
    active_lag_dir = output_dir / "active-lag"

    print_header("Phase: active-lag")
    print("- Workspaces will launch with normal login-shell behavior.")
    print("- Open the slow repo and get it into the visibly laggy state.")
    print("- Do not quit the app before the sampler runs.")

    launcher = subprocess.Popen(
        [
            str(paths["launcher"]),
            "--app",
            str(paths["app"]),
            "--log-file",
            str(log_file),
            "--login-shell",
        ],
        cwd=str(paths["wm_repo"]),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(2)
    if launcher.poll() is not None:
        raise SystemExit(f"Workspaces exited immediately during active-lag capture. Check {log_file}.")

    wait_for_enter("When Workspaces is open and actively lagging, press Enter to start the sample countdown.")
    pid = newest_workspace_manager_pid()
    if pid is None:
        terminate_launcher(launcher)
        raise SystemExit("Could not find a running WorkspaceManager PID for active-lag capture.")

    result = subprocess.run(
        [
            str(paths["active_lag"]),
            "--pid",
            str(pid),
            "--countdown",
            str(countdown),
            "--sample-seconds",
            str(sample_seconds),
            "--output-dir",
            str(active_lag_dir),
        ],
        cwd=str(paths["wm_repo"]),
        text=True,
        check=False,
    )
    if result.returncode != 0:
        terminate_launcher(launcher)
        raise SystemExit("Active-lag sample capture failed.")

    wait_for_launcher_exit(launcher)
    launcher.wait(timeout=5)
    summarize_log(paths["wm_repo"], paths["summarize_perf"], log_file, "lag-run")
    note = prompt("Short note for active-lag run (optional): ").strip()
    if note:
        notes.append({"phase": "active-lag", "note": note})
    print(f"Wrote {active_lag_dir}")


def write_manifest(
    *,
    output_dir: Path,
    paths: dict[str, Path],
    args: argparse.Namespace,
    notes: list[dict[str, str]],
) -> None:
    manifest = {
        "collected_at": datetime.now().astimezone().isoformat(),
        "wm_repo": str(paths["wm_repo"]),
        "slow_repo": str(paths["slow_repo"]),
        "app": str(paths["app"]),
        "output_dir": str(output_dir),
        "host_probe_runs": args.host_probe_runs,
        "countdown": args.countdown,
        "sample_seconds": args.sample_seconds,
        "skip_input_run": args.skip_input_run,
        "skip_active_lag": args.skip_active_lag,
        "notes": notes,
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "Workspaces installed performance bundle",
        f"Collected at: {manifest['collected_at']}",
        f"Workspaces repo: {paths['wm_repo']}",
        f"Slow repo: {paths['slow_repo']}",
        f"Installed app: {paths['app']}",
        "",
        "Files to send back:",
        f"- {output_dir / 'clean-shell.log'}",
        f"- {output_dir / 'clean-shell-summary.txt'}",
        f"- {output_dir / 'login-shell.log'}",
        f"- {output_dir / 'login-shell-summary.txt'}",
    ]
    if not args.skip_input_run:
        lines.extend(
            [
                f"- {output_dir / 'input.log'}",
                f"- {output_dir / 'input-summary.txt'}",
            ]
        )
    lines.append(f"- {output_dir / 'host-probe'}")
    if not args.skip_active_lag:
        lines.extend(
            [
                f"- {output_dir / 'lag-run.log'}",
                f"- {output_dir / 'lag-run-summary.txt'}",
                f"- {output_dir / 'active-lag'}",
            ]
        )

    lines.extend(
        [
            "",
            "Operator notes:",
        ]
    )
    if notes:
        for note in notes:
            lines.append(f"- {note['phase']}: {note['note']}")
    else:
        lines.append("- none")

    (output_dir / "README.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def make_zip(output_dir: Path) -> Path:
    archive = shutil.make_archive(str(output_dir), "zip", root_dir=str(output_dir.parent), base_dir=output_dir.name)
    return Path(archive)


def print_plan(paths: dict[str, Path], args: argparse.Namespace) -> None:
    print("Collection plan")
    print(f"- Workspaces repo: {paths['wm_repo']}")
    print(f"- Slow repo: {paths['slow_repo']}")
    print(f"- Installed app: {paths['app']}")
    print(f"- Output dir: {paths['output_dir']}")
    print("- Phases:")
    print("  1. clean-shell launch + perf summary")
    print("  2. login-shell launch + perf summary")
    if not args.skip_input_run:
        print("  3. login-shell input diagnostics + perf summary")
    print("  4. host shell/process probe")
    if not args.skip_active_lag:
        print("  5. active-lag samples + perf summary")
    print("  6. write manifest and zip bundle")


def main() -> int:
    global args
    args = parse_args()
    paths = check_paths(args)
    output_dir = paths["output_dir"]

    if args.plan_only:
        print_plan(paths, args)
        return 0

    notes: list[dict[str, str]] = []
    print_header("Workspaces Performance Bundle")
    print(f"Output directory: {output_dir}")
    print("Each launch phase writes its own log and summary, then the script zips the bundle at the end.")

    launch_phase(
        paths=paths,
        output_dir=output_dir,
        phase_name="clean-shell",
        shell_mode="clean",
        with_input_diagnostics=False,
        instructions=[
            "Open the same slow repo in Workspaces.",
            "Type in the terminal for 10-20 seconds.",
            "Quit Workspaces when you are done.",
        ],
        notes=notes,
    )

    launch_phase(
        paths=paths,
        output_dir=output_dir,
        phase_name="login-shell",
        shell_mode="login",
        with_input_diagnostics=False,
        instructions=[
            "Open the same slow repo again.",
            "Repeat the same typing and terminal actions as the clean-shell run.",
            "Quit Workspaces when you are done.",
        ],
        notes=notes,
    )

    if not args.skip_input_run:
        launch_phase(
            paths=paths,
            output_dir=output_dir,
            phase_name="input",
            shell_mode="login",
            with_input_diagnostics=True,
            instructions=[
                "This is a short capture run only.",
                "Type for about 10-15 seconds in the terminal.",
                "Quit Workspaces when you are done.",
            ],
            notes=notes,
        )

    run_host_probe(paths, output_dir, args.host_probe_runs)

    if not args.skip_active_lag:
        run_active_lag_capture(
            paths=paths,
            output_dir=output_dir,
            countdown=args.countdown,
            sample_seconds=args.sample_seconds,
            notes=notes,
        )

    clean_observation = prompt("Did the clean-shell run still feel slow? [yes/no/notes] ").strip()
    if clean_observation:
        notes.append({"phase": "observation", "note": f"clean-shell subjective: {clean_observation}"})
    terminal_observation = prompt("Did Terminal.app also feel slow in the same repo? [yes/no/unknown/notes] ").strip()
    if terminal_observation:
        notes.append({"phase": "observation", "note": f"Terminal.app subjective: {terminal_observation}"})

    write_manifest(output_dir=output_dir, paths=paths, args=args, notes=notes)
    if args.no_zip:
        print(f"Collection complete: {output_dir}")
        return 0

    zip_path = make_zip(output_dir)
    print(f"Collection complete: {output_dir}")
    print(f"Zip archive: {zip_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
