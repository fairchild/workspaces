#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the evidence lane's capture path, scripts/lib/app-capture.sh (#1427).

The lane runs beside the owner's installed app, whose automation credential sits
at the real Application Support path. These run the real `app_capture_window`
against a throwaway checkout with stubs for the launcher, the app, the CLI and
`swift`, under a redirected HOME holding a stand-in for that credential.

The stub CLI plays whichever app is meant to answer the socket: the launched
debug binary, or something else, which is the regression the lane has to fail on
rather than capture.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "scripts" / "lib"
CREDENTIAL_BYTES = b'{"socketPath":"/live.sock","handle":"live"}'


def write_executable(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class AppCaptureWindowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="AppCapture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

        self.checkout = self.root / "checkout"
        (self.checkout / "scripts" / "lib").mkdir(parents=True)
        for name in ("app-capture.sh", "build-products.sh", "synthetic-root.sh", "fixture-scenarios.sh"):
            shutil.copy(LIB_DIR / name, self.checkout / "scripts" / "lib" / name)

        self.products = self.root / "products"
        self.products.mkdir()
        self.binary = self.products / "WorkspaceManager"
        self.binary.symlink_to(shutil.which("sleep"))
        self.pid_file = self.root / "app.pid"

        self.home = self.root / "home"
        self.credential = (
            self.home / "Library" / "Application Support" / "com.cloudcompute.workspaces" / "automation-operator.json"
        )
        self.credential.parent.mkdir(parents=True)
        self.credential.write_bytes(CREDENTIAL_BYTES)

        write_executable(
            self.checkout / "scripts" / "launch-dev.sh",
            f"""\
            #!/bin/sh
            nohup "{self.binary}" 60 >/dev/null 2>&1 &
            echo $! > "{self.pid_file}"
            sleep 0.2
            echo "[12:00:00] WorkspaceManager running (pid=$!)"
            """,
        )

        self.stub_bin = self.root / "bin"
        self.stub_bin.mkdir()
        write_executable(
            self.stub_bin / "swift",
            f"""\
            #!/bin/sh
            [ "$1" = build ] && echo "{self.products}"
            exit 0
            """,
        )

    def stub_cli(self, health_pid: str, credential: str = "minted") -> None:
        pid = f'$(cat "{self.pid_file}")' if health_pid == "launched" else health_pid
        write_executable(
            self.products / "workspaces",
            f"""\
            #!/bin/sh
            echo "${{WORKSPACES_AUTOMATION_SOCKET-unset}} ${{WORKSPACES_AUTOMATION_HANDLE-unset}}" >> "{self.root}/cli-env"
            case "$1 $2" in
                "automation health")
                    echo '{{"status":"ok","server":{{"pid":'"{pid}"',"operatorCredential":"{credential}"}}}}'
                    ;;
                "window snapshot")
                    echo png > "$4"
                    ;;
                *)
                    exit 64
                    ;;
            esac
            """,
        )

    def capture(
        self, timeout_seconds: int = 3, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        script = textwrap.dedent(
            f"""\
            set -euo pipefail
            REPO_ROOT="{self.checkout}"
            source "$REPO_ROOT/scripts/lib/fixture-scenarios.sh"
            source "$REPO_ROOT/scripts/lib/app-capture.sh"
            trap app_capture_stop EXIT
            if ! app_capture_window "{self.root}/out.png" clean {timeout_seconds}; then
                exit 1
            fi
            """
        )
        env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.stub_bin}:{os.environ['PATH']}",
        }
        for key in ("WORKSPACES_SYNTHETIC_ROOT", "WORKSPACES_AUTOMATION_SOCKET", "WORKSPACES_AUTOMATION_HANDLE"):
            env.pop(key, None)
        env.update(extra_env or {})
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=60)

    def test_captures_once_the_launched_app_reports_its_credential(self) -> None:
        self.stub_cli("launched")
        result = self.capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "out.png").is_file())

    def test_the_live_credential_survives_a_capture_byte_for_byte(self) -> None:
        self.stub_cli("launched")
        result = self.capture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.credential.read_bytes(), CREDENTIAL_BYTES)

    def test_the_live_credential_survives_a_failed_capture(self) -> None:
        self.stub_cli("launched", credential="mint_failed")
        result = self.capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.credential.read_bytes(), CREDENTIAL_BYTES)

    def test_another_app_answering_the_socket_fails_the_lane(self) -> None:
        """Pid 1 is never the debug binary: this is the lane reaching some other app's
        listener, where a snapshot would succeed and show the wrong window."""
        self.stub_cli("1")
        result = self.capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A snapshot here would capture another app", result.stderr)
        self.assertFalse((self.root / "out.png").exists())

    def test_an_earlier_instance_of_the_same_binary_fails_the_lane(self) -> None:
        """A process that outlived its replacement's launch still runs this binary and
        still holds this root's socket, so only the exact pid tells them apart."""
        earlier = subprocess.Popen([str(self.binary), "60"])
        self.addCleanup(earlier.wait)
        self.addCleanup(earlier.kill)
        self.stub_cli(str(earlier.pid))
        result = self.capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"pid {earlier.pid} answered", result.stderr)
        self.assertFalse((self.root / "out.png").exists())

    def test_a_launch_that_reports_no_pid_fails_rather_than_trust_the_listener(self) -> None:
        launcher = self.checkout / "scripts" / "launch-dev.sh"
        launcher.write_text(
            launcher.read_text(encoding="utf-8").replace("running (pid=$!)", "running"), encoding="utf-8"
        )
        self.stub_cli("launched")
        result = self.capture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not determine the launched app's pid", result.stderr)

    def test_a_capture_from_a_workspaces_terminal_ignores_that_terminals_socket(self) -> None:
        """Every WorkSpaces terminal exports the installed app's socket and handle, and
        the CLI's socket verbs prefer them over the synthetic root."""
        self.stub_cli("launched")
        result = self.capture(
            extra_env={
                "WORKSPACES_AUTOMATION_SOCKET": "/installed/automation.sock",
                "WORKSPACES_AUTOMATION_HANDLE": "installed-tile-handle",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set((self.root / "cli-env").read_text().splitlines()), {"unset unset"})

    def test_an_app_without_operator_scope_fails_at_once_with_the_reason(self) -> None:
        self.stub_cli("launched", credential="not_opted_in")
        result = self.capture(timeout_seconds=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("operatorCredential=not_opted_in", result.stderr)

    def test_a_listener_that_never_reports_a_credential_times_out(self) -> None:
        self.stub_cli("launched", credential="")
        result = self.capture(timeout_seconds=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not become ready within 1s", result.stderr)

    def test_stopping_the_lane_stops_the_launched_app(self) -> None:
        self.stub_cli("launched")
        self.capture()
        pid = int(self.pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            for _ in range(50):
                os.kill(pid, 0)
                subprocess.run(["sleep", "0.1"], check=True, timeout=5)
            raise AssertionError(f"pid {pid} outlived the lane")


if __name__ == "__main__":
    unittest.main()
