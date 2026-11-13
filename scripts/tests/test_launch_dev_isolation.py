#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for the state scripts/launch-dev.sh isolates under its data root.

A dev launch with an isolated data root must keep the Conversation records it
migrates and writes apart from the installed app's. A WorkSpaces terminal
exports the installed app's records directory, and the app reads an inherited
value as explicit, so the launcher names its own. These run the real script in
a throwaway checkout with stubs for `swift` and the app binary, which records
the environment it was launched with and exits. No network, secrets or UI.
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
KEY = "WORKSPACES_CONVERSATIONS_DIR"


def write_executable(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class LaunchDevIsolationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="LaunchDev-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

        self.checkout = self.root / "checkout"
        (self.checkout / "scripts" / "lib").mkdir(parents=True)
        shutil.copy(REPO_ROOT / "scripts" / "launch-dev.sh", self.checkout / "scripts" / "launch-dev.sh")
        for name in ("build-products.sh", "synthetic-root.sh"):
            shutil.copy(REPO_ROOT / "scripts" / "lib" / name, self.checkout / "scripts" / "lib" / name)
        (self.checkout / "Package.swift").write_text("// stand-in\n", encoding="utf-8")

        self.products = self.root / "products"
        self.products.mkdir()
        self.app_env = self.root / "app-env"
        write_executable(
            self.products / "WorkspaceManager",
            f"""\
            #!/bin/sh
            env > "{self.app_env}"
            """,
        )
        self.stub_bin = self.root / "bin"
        self.stub_bin.mkdir()
        write_executable(
            self.stub_bin / "swift",
            f"""\
            #!/bin/sh
            echo "{self.products}"
            """,
        )
        self.data_dir = self.root / "data"

    def launch(self, *extra: str, inherited: str | None = None) -> str | None:
        env = {
            **os.environ,
            "PATH": f"{self.stub_bin}:{os.environ['PATH']}",
            "GHOSTTY_RESOURCES_DIR": str(self.root / "ghostty"),
        }
        env.pop(KEY, None)
        if inherited is not None:
            env[KEY] = inherited
        result = subprocess.run(
            [
                str(self.checkout / "scripts" / "launch-dev.sh"),
                "--no-build", "--coexist", "--foreground",
                "--data-dir", str(self.data_dir),
                *extra,
            ],
            capture_output=True, text=True, env=env, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        values = [line.split("=", 1)[1] for line in self.app_env.read_text().splitlines() if line.startswith(f"{KEY}=")]
        return values[-1] if values else None

    # intent: fix
    def test_an_isolated_launch_from_a_workspaces_terminal_records_conversations_under_its_data_root(self) -> None:
        value = self.launch(inherited="/installed/conversations")
        self.assertEqual(value, f"{self.data_dir.resolve()}/conversations")

    # intent: guard
    def test_a_caller_naming_its_own_conversations_directory_keeps_it(self) -> None:
        value = self.launch("--env", f"{KEY}=/drill/pass/conversations", inherited="/installed/conversations")
        self.assertEqual(value, "/drill/pass/conversations")


if __name__ == "__main__":
    unittest.main()
