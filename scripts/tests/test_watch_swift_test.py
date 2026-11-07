#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests that `scripts/watch-swift-test.sh` reports a hang as a hang and
everything else as the command's own result.

The watchdog exists because a deadlocked test sits at 0% CPU and looks like a
slow run for hours (#1842). Its value rests on two promises: a run that stops
making progress ends with exit 124 and no leftover processes, and a run that
finishes, passing or failing, keeps its own exit status. Each case below is a
way the first version broke one of those promises: a command that finished
while the watchdog was deciding, a progress file that vanished, two watchdogs
sharing an output directory, a watchdog terminated mid-run, a flag missing its
value.

The tests drive the real script with small shell commands instead of
`swift test`, so they need no build, no network, and no UI access. They take
about half a minute because stalls are measured in real seconds.
"""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "watch-swift-test.sh"


def watch(*args: str, timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_for_file(path: Path, timeout: float = 10) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return path.read_text().strip()
        time.sleep(0.1)
    raise AssertionError(f"{path} never appeared")


class WatchSwiftTestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="watch-swift-test-"))
        self.out = self.tmp / "out"

    def test_success_keeps_exit_zero(self) -> None:
        result = watch("--out", str(self.out), "--", "sh", "-c", "echo hi; exit 0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hi", result.stdout)

    def test_failure_keeps_its_exit_status(self) -> None:
        result = watch("--out", str(self.out), "--", "sh", "-c", "exit 7")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_quiet_command_that_finishes_inside_the_stall_window_is_not_a_hang(self) -> None:
        result = watch("--stall", "3", "--out", str(self.out), "--", "sh", "-c", "sleep 2; exit 0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stall_exits_124_and_kills_the_command(self) -> None:
        pidfile = self.tmp / "pid"
        result = watch(
            "--stall", "2", "--out", str(self.out), "--",
            "sh", "-c", f"echo $$ > {pidfile}; exec sleep 60",
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertTrue((self.out / "hang.tree").exists())
        self.assertFalse(alive(int(pidfile.read_text())))

    def test_removed_progress_file_still_counts_as_a_stall(self) -> None:
        progress = self.tmp / "progress"
        result = watch(
            "--stall", "2", "--progress", str(progress), "--out", str(self.out), "--",
            "sh", "-c", f"rm -f {progress}; sleep 60",
        )
        self.assertEqual(result.returncode, 124, result.stderr)

    def test_second_watchdog_refuses_a_busy_output_directory(self) -> None:
        first = subprocess.Popen(
            ["bash", str(SCRIPT), "--out", str(self.out), "--", "sleep", "5"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 5
            while not (self.out / ".watch-swift-test.lock").exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            second = watch("--out", str(self.out), "--", "sh", "-c", "exit 0")
            self.assertEqual(second.returncode, 2)
            self.assertIn("in use", second.stderr)
        finally:
            first.wait(timeout=30)
        self.assertEqual(first.returncode, 0)

    def test_terminating_the_watchdog_kills_the_command(self) -> None:
        pidfile = self.tmp / "pid"
        watchdog = subprocess.Popen(
            ["bash", str(SCRIPT), "--out", str(self.out), "--",
             "sh", "-c", f"echo $$ > {pidfile}; exec sleep 60"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        child = int(wait_for_file(pidfile))
        watchdog.send_signal(signal.SIGTERM)
        watchdog.wait(timeout=10)
        deadline = time.monotonic() + 5
        while alive(child) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(child))
        self.assertFalse((self.out / ".watch-swift-test.lock").exists())

    def test_flag_without_value_prints_usage(self) -> None:
        for flag in ("--stall", "--progress", "--out"):
            with self.subTest(flag=flag):
                result = watch(flag)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)

    def test_missing_command_prints_usage(self) -> None:
        result = watch("--stall", "5", "--")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
