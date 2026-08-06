#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavior tests for scripts/factory-worker-identity.sh.

Runs the real script under `bash -c 'source ...'` with a controlled
environment (subprocess, no network) and asserts on exit code, stdout/stderr,
and whether GH_TOKEN ends up exported in the caller's shell — the actual
contract the script promises. Covers the bugs a codex review caught (#1180):
sourcing it must not leak `set -u`/`set -o pipefail` into the caller even on
the no-op path, and it must fail loudly rather than report success when
FACTORY_WORKER_IDENTITY=app is set but minting fails. Also covers a bug
caught by collateral damage during live use, not by review: under this
repo's standard multi-worktree topology, `git config --local` targets the
SHARED `$GIT_COMMON_DIR/config`, so an app-mode run in one worktree silently
overwrote git identity and blanked the credential helper chain for every
other worktree of the repo (see WorktreeIsolationTests below).
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "factory-worker-identity.sh"

STUB_TOKEN_SCRIPT = """\
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
print("stub-token-for-worktree-isolation-test")
"""


def run_sourced(overrides: dict[str, str], *, extra_after: str = "") -> subprocess.CompletedProcess[str]:
    """Source the script in a clean subshell and report on the caller's state."""
    command = f"""
set +u +o pipefail
before_nounset=$(set -o | awk '$1=="nounset"{{print $2}}')
before_pipefail=$(set -o | awk '$1=="pipefail"{{print $2}}')
source "{SCRIPT}"
status=$?
after_nounset=$(set -o | awk '$1=="nounset"{{print $2}}')
after_pipefail=$(set -o | awk '$1=="pipefail"{{print $2}}')
echo "STATUS=$status"
echo "GH_TOKEN_SET=${{GH_TOKEN:+yes}}"
echo "NOUNSET_BEFORE=$before_nounset"
echo "NOUNSET_AFTER=$after_nounset"
echo "PIPEFAIL_BEFORE=$before_pipefail"
echo "PIPEFAIL_AFTER=$after_pipefail"
{extra_after}
"""
    clean_env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"FACTORY_WORKER_IDENTITY", "FACTORY_WORKER_APP_ID", "FACTORY_WORKER_APP_KEY", "FACTORY_WORKER_BOT_EMAIL", "GH_TOKEN"}
    }
    return subprocess.run(
        ["bash", "-c", command],
        cwd=REPO_ROOT,
        env={**clean_env, **overrides},
        capture_output=True,
        text=True,
        timeout=30,
    )


def parse_markers(stdout: str) -> dict[str, str]:
    markers = {}
    for line in stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            markers[key] = value
    return markers


class NoOpTests(unittest.TestCase):
    def test_unset_flag_is_a_true_no_op(self):
        result = run_sourced({})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "0")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])

    def test_non_app_value_is_also_a_no_op(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "owner"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "0")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])


class AppModeWithoutCredentialsTests(unittest.TestCase):
    def test_fails_loudly_and_does_not_export_gh_token(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "app"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "1")
        self.assertEqual(markers["GH_TOKEN_SET"], "")
        self.assertIn("minting a workspaces-factory token failed", result.stderr)

    def test_does_not_leak_shell_options_either(self):
        result = run_sourced({"FACTORY_WORKER_IDENTITY": "app"})
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["NOUNSET_AFTER"], markers["NOUNSET_BEFORE"])
        self.assertEqual(markers["PIPEFAIL_AFTER"], markers["PIPEFAIL_BEFORE"])


class WorktreeIsolationTests(unittest.TestCase):
    """A scratch repo with two linked worktrees, its own stub token script
    (no real App, no network calls — same policy as the rest of this file),
    and the real factory-worker-identity.sh. Enabling app mode in worktree A
    must not be observable from worktree B: not in git identity, not in
    credential helper resolution.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.repo = root / "repo"
        self.wt_a = root / "wt-a"
        self.wt_b = root / "wt-b"

        self._run(["git", "init", "-q", str(self.repo)])
        self._run(["git", "config", "user.email", "test@example.com"], cwd=self.repo)
        self._run(["git", "config", "user.name", "scratch-repo-owner"], cwd=self.repo)

        scripts_dir = self.repo / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "factory-worker-token.py").write_text(STUB_TOKEN_SCRIPT)
        (scripts_dir / "factory-worker-identity.sh").write_text(SCRIPT.read_text())
        self._run(["git", "add", "-A"], cwd=self.repo)
        self._run(["git", "commit", "-q", "-m", "seed"], cwd=self.repo)

        self._run(["git", "branch", "wt-a"], cwd=self.repo)
        self._run(["git", "branch", "wt-b"], cwd=self.repo)
        self._run(["git", "worktree", "add", "-q", str(self.wt_a), "wt-a"], cwd=self.repo)
        self._run(["git", "worktree", "add", "-q", str(self.wt_b), "wt-b"], cwd=self.repo)

    @staticmethod
    def _run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, f"{cmd} failed: {result.stderr}"
        return result

    def _git_config(self, worktree: Path, key: str, *, scope: str = "--worktree") -> str | None:
        result = subprocess.run(
            ["git", "-C", str(worktree), "config", scope, "--get", key],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def test_app_mode_in_one_worktree_does_not_leak_into_another(self):
        clean_env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"FACTORY_WORKER_IDENTITY", "FACTORY_WORKER_APP_ID", "FACTORY_WORKER_APP_KEY", "FACTORY_WORKER_BOT_EMAIL", "GH_TOKEN"}
        }
        result = subprocess.run(
            ["bash", "-c", f'source "{self.wt_a}/scripts/factory-worker-identity.sh"; echo "STATUS=$?"; echo "GH_TOKEN_SET=${{GH_TOKEN:+yes}}"'],
            cwd=self.wt_a,
            env={**clean_env, "FACTORY_WORKER_IDENTITY": "app", "FACTORY_WORKER_APP_ID": "0", "FACTORY_WORKER_APP_KEY": "/dev/null"},
            capture_output=True,
            text=True,
            timeout=30,
        )
        markers = parse_markers(result.stdout)
        self.assertEqual(markers["STATUS"], "0", result.stderr)
        self.assertEqual(markers["GH_TOKEN_SET"], "yes")

        # Worktree A: identity and credential helper resolve to the bot,
        # scoped to A's own config.worktree file.
        self.assertEqual(self._git_config(self.wt_a, "user.name"), "workspaces-factory[bot]")
        self.assertEqual(
            self._git_config(self.wt_a, "credential.https://github.com.helper"),
            '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f',
        )

        # Worktree B never sourced the script: no worktree-scoped override,
        # and the merged (shared-config-fallback) identity is still the
        # scratch repo's original owner, not the bot.
        self.assertIsNone(self._git_config(self.wt_b, "user.name"))
        self.assertIsNone(self._git_config(self.wt_b, "credential.https://github.com.helper"))
        merged_name = subprocess.run(
            ["git", "-C", str(self.wt_b), "config", "--get", "user.name"],
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout.strip()
        self.assertEqual(merged_name, "scratch-repo-owner")


if __name__ == "__main__":
    unittest.main()
