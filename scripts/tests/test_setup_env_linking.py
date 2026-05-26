#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Setup tests for local environment-file linking.

Intent: protect the bootstrap path that links private local env files between
worktrees without copying secrets into the repository or overwriting deliberate
checkout-local configuration.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SETUP_SCRIPT = REPO_ROOT / "scripts" / "setup"


class SetupEnvLinkingTests(unittest.TestCase):
    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(
            result.returncode,
            0,
            f"command failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

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

    def create_repo_with_setup_script(self, repo_path: Path) -> None:
        """Create the smallest real git repo that can add sibling worktrees.

        The production setup script decides whether it is in a linked worktree
        by comparing git metadata paths, so a mocked directory layout would not
        exercise the branch this test cares about.
        """

        repo_path.mkdir()
        self.assert_success(self.run_command(["git", "init"], cwd=repo_path))
        self.assert_success(
            self.run_command(
                ["git", "config", "user.email", "test@example.com"],
                cwd=repo_path,
            )
        )
        self.assert_success(
            self.run_command(
                ["git", "config", "user.name", "Test User"],
                cwd=repo_path,
            )
        )

        (repo_path / "scripts").mkdir()
        shutil.copy2(SETUP_SCRIPT, repo_path / "scripts" / "setup")
        (repo_path / "README.md").write_text("test repo\n", encoding="utf-8")

        self.assert_success(
            self.run_command(["git", "add", "README.md", "scripts/setup"], cwd=repo_path)
        )
        self.assert_success(self.run_command(["git", "commit", "-m", "initial"], cwd=repo_path))

    def add_worktree(self, repo_path: Path, branch: str, worktree_path: Path) -> None:
        self.assert_success(
            self.run_command(
                ["git", "worktree", "add", "-b", branch, str(worktree_path)],
                cwd=repo_path,
            )
        )

    def test_env_only_links_from_sibling_worktree_with_env_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main = tmp_path / "repo"
            source = tmp_path / "source-worktree"
            target = tmp_path / "target-worktree"

            self.create_repo_with_setup_script(main)

            # The source worktree stands in for a developer's existing checkout
            # that already has local, gitignored secrets such as evidence upload
            # tokens. The target starts clean and should receive only a symlink.
            self.add_worktree(main, "env-source", source)
            source_env = source / ".env"
            source_env.write_text("EVIDENCE_UPLOAD_TOKEN=test-token\n", encoding="utf-8")

            self.add_worktree(main, "env-target", target)

            # Keep HOME inside the temp directory so the preferred
            # ~/code/<repo> lookup cannot accidentally find this developer
            # machine's real checkout. That forces the sibling-worktree fallback
            # path under test.
            isolated_home = tmp_path / "home"
            result = self.run_command(
                ["./scripts/setup", "--env-only"],
                cwd=target,
                env={"HOME": str(isolated_home)},
            )

            self.assert_success(result)
            linked_env = target / ".env"
            self.assertTrue(linked_env.is_symlink())
            self.assertEqual(linked_env.resolve(), source_env.resolve())
            self.assertIn("Symlinking .env", result.stdout)

    def test_env_only_prefers_conductor_root_path_env_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main = tmp_path / "repo"
            target = tmp_path / "target-worktree"
            conductor_root = tmp_path / "conductor-root"

            self.create_repo_with_setup_script(main)
            self.add_worktree(main, "env-target", target)
            conductor_root.mkdir()
            conductor_env = conductor_root / ".env"
            conductor_env.write_text("EVIDENCE_UPLOAD_TOKEN=test-token\n", encoding="utf-8")

            isolated_home = tmp_path / "home"
            result = self.run_command(
                ["./scripts/setup", "--env-only"],
                cwd=target,
                env={"HOME": str(isolated_home), "CONDUCTOR_ROOT_PATH": str(conductor_root)},
            )

            self.assert_success(result)
            linked_env = target / ".env"
            self.assertTrue(linked_env.is_symlink())
            self.assertEqual(linked_env.resolve(), conductor_env.resolve())
            self.assertIn("Symlinking .env", result.stdout)

    def test_env_only_replaces_broken_env_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main = tmp_path / "repo"
            source = tmp_path / "source-worktree"
            target = tmp_path / "target-worktree"

            self.create_repo_with_setup_script(main)
            self.add_worktree(main, "env-source", source)
            source_env = source / ".env"
            source_env.write_text("EVIDENCE_UPLOAD_TOKEN=test-token\n", encoding="utf-8")
            self.add_worktree(main, "env-target", target)
            (target / ".env").symlink_to(tmp_path / "missing-env")

            isolated_home = tmp_path / "home"
            result = self.run_command(
                ["./scripts/setup", "--env-only"],
                cwd=target,
                env={"HOME": str(isolated_home)},
            )

            self.assert_success(result)
            linked_env = target / ".env"
            self.assertTrue(linked_env.is_symlink())
            self.assertEqual(linked_env.resolve(), source_env.resolve())
            self.assertIn("Replacing broken .env symlink", result.stdout)
            self.assertIn("Symlinking .env", result.stdout)


if __name__ == "__main__":
    unittest.main()
