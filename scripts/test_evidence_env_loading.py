#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/evidence.sh env-file discovery."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_SCRIPT = REPO_ROOT / "scripts" / "evidence.sh"


class EvidenceEnvLoadingTests(unittest.TestCase):
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
        merged_env = {**os.environ, **(env or {})}
        merged_env.pop("EVIDENCE_UPLOAD_TOKEN", None)
        return subprocess.run(
            args,
            cwd=cwd,
            env=merged_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def create_repo_with_evidence_script(self, repo_path: Path) -> None:
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

        scripts_dir = repo_path / "scripts"
        scripts_dir.mkdir()
        shutil.copy2(EVIDENCE_SCRIPT, scripts_dir / "evidence.sh")
        (repo_path / "README.md").write_text("test repo\n", encoding="utf-8")

        self.assert_success(
            self.run_command(["git", "add", "README.md", "scripts/evidence.sh"], cwd=repo_path)
        )
        self.assert_success(self.run_command(["git", "commit", "-m", "initial"], cwd=repo_path))

    def add_worktree(self, repo_path: Path, branch: str, worktree_path: Path) -> None:
        self.assert_success(
            self.run_command(
                ["git", "worktree", "add", "-b", branch, str(worktree_path)],
                cwd=repo_path,
            )
        )

    def write_fake_uv(self, bin_dir: Path, expected_token: str) -> None:
        bin_dir.mkdir()
        fake_uv = bin_dir / "uv"
        fake_uv.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env bash",
                    "set -euo pipefail",
                    f'if [[ "${{EVIDENCE_UPLOAD_TOKEN:-}}" != "{expected_token}" ]]; then',
                    '  echo "missing expected token" >&2',
                    "  exit 42",
                    "fi",
                    'echo "https://evidence.example/workspaces/pr-1/test.png"',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        fake_uv.chmod(fake_uv.stat().st_mode | stat.S_IXUSR)

    def test_evidence_sources_token_from_sibling_worktree_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main = tmp_path / "repo"
            source = tmp_path / "source-worktree"
            target = tmp_path / "target-worktree"
            fake_bin = tmp_path / "bin"
            isolated_home = tmp_path / "home"

            self.create_repo_with_evidence_script(main)
            self.add_worktree(main, "env-source", source)
            (source / ".env").write_text("EVIDENCE_UPLOAD_TOKEN=test-token\n", encoding="utf-8")
            self.add_worktree(main, "env-target", target)
            self.write_fake_uv(fake_bin, "test-token")

            evidence_file = target / "test.png"
            evidence_file.write_bytes(b"not a real png; fake uv does not inspect it\n")

            result = self.run_command(
                [
                    "./scripts/evidence.sh",
                    "--pr",
                    "1",
                    "--name",
                    "test",
                    "--file",
                    str(evidence_file),
                ],
                cwd=target,
                env={
                    "HOME": str(isolated_home),
                    "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                },
            )

            self.assert_success(result)
            self.assertEqual(
                result.stdout.strip(),
                "https://evidence.example/workspaces/pr-1/test.png",
            )
            self.assertFalse((target / ".env").exists())


if __name__ == "__main__":
    unittest.main()
