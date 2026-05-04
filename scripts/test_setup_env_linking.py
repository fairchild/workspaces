#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/setup env-file linking behavior."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SETUP_SCRIPT = REPO_ROOT / "scripts" / "setup"


class SetupEnvLinkingTests(unittest.TestCase):
    def run_command(
        self,
        args: list[str],
        *,
        cwd: Path,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            args,
            cwd=cwd,
            env={**os.environ, **(env or {})},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_env_only_links_from_sibling_worktree_with_env_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main = tmp_path / "repo"
            source = tmp_path / "source-worktree"
            target = tmp_path / "target-worktree"

            main.mkdir()
            self.assertEqual(self.run_command(["git", "init"], cwd=main).returncode, 0)
            self.assertEqual(
                self.run_command(["git", "config", "user.email", "test@example.com"], cwd=main).returncode,
                0,
            )
            self.assertEqual(
                self.run_command(["git", "config", "user.name", "Test User"], cwd=main).returncode,
                0,
            )

            (main / "scripts").mkdir()
            shutil.copy2(SETUP_SCRIPT, main / "scripts" / "setup")
            (main / "README.md").write_text("test repo\n", encoding="utf-8")
            self.assertEqual(
                self.run_command(["git", "add", "README.md", "scripts/setup"], cwd=main).returncode,
                0,
            )
            self.assertEqual(self.run_command(["git", "commit", "-m", "initial"], cwd=main).returncode, 0)

            self.assertEqual(
                self.run_command(["git", "worktree", "add", "-b", "env-source", str(source)], cwd=main).returncode,
                0,
            )
            (source / ".env").write_text("EVIDENCE_UPLOAD_TOKEN=test-token\n", encoding="utf-8")

            self.assertEqual(
                self.run_command(["git", "worktree", "add", "-b", "env-target", str(target)], cwd=main).returncode,
                0,
            )
            result = self.run_command(
                ["./scripts/setup", "--env-only"],
                cwd=target,
                env={"HOME": str(tmp_path / "home")},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            linked_env = target / ".env"
            self.assertTrue(linked_env.is_symlink())
            self.assertEqual(linked_env.resolve(), (source / ".env").resolve())
            self.assertIn("Symlinking .env", result.stdout)


if __name__ == "__main__":
    unittest.main()
