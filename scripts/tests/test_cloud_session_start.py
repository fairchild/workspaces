#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for scripts/cloud-session-start.sh, the cloud SessionStart hook.

The hook runs on every local session too, so it has to do nothing there. In a
cloud session it is the only place a failed setup step surfaces: setup scripts
exit 0 by design, so what the hook reports is what the agent knows. These tests
hold both, and that a broken step never stops a session from starting.

Safe to run without network, secrets, UI access, or GitHub: pnpm, node, mise and
prek are stubs on a private PATH, in a throwaway project and state directory.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HOOK = REPO_ROOT / "scripts" / "cloud-session-start.sh"


class CloudSessionStartTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.project = tmp / "project"
        self.state = tmp / "state"
        self.home = tmp / "home"
        self.bin = tmp / "bin"
        self.calls = tmp / "calls.log"
        for directory in (self.project / "web-next", self.project / "web", self.state, self.home, self.bin):
            directory.mkdir(parents=True)
        for directory in ("web-next", "web"):
            (self.project / directory / "pnpm-lock.yaml").write_text("")
        self.browser = tmp / "pw-browsers" / "chromium-1228"
        self.browser.mkdir(parents=True)
        self.stub_pnpm(f'echo "pnpm $*" >> "{self.calls}"', browser=self.browser)

    def stub_pnpm(self, install: str, browser: Path) -> None:
        self.stub(
            "pnpm",
            f'if [ "$1" = exec ]; then echo "  Install location:    {browser}"; exit 0; fi\n{install}',
        )

    def stub(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text(f"#!/bin/bash\n{body}\n")
        path.chmod(0o755)

    def run_hook(self, remote: bool = True) -> tuple[subprocess.CompletedProcess[str], str]:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "CLAUDE_PROJECT_DIR": str(self.project),
            "WORKSPACES_CLOUD_STATE": str(self.state),
        }
        if remote:
            env["CLAUDE_CODE_REMOTE"] = "true"
        result = subprocess.run(
            ["bash", str(HOOK)], env=env, capture_output=True, text=True, timeout=30, check=False
        )
        if not remote:
            return result, ""
        payload = json.loads(result.stdout)
        self.assertEqual(payload["hookSpecificOutput"]["hookEventName"], "SessionStart")
        return result, payload["hookSpecificOutput"]["additionalContext"]

    # intent: guard
    def test_local_sessions_are_untouched(self) -> None:
        result, _ = self.run_hook(remote=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.calls.exists(), "a local session must not install anything")

    # intent: guard
    def test_both_web_apps_install_from_the_lockfile(self) -> None:
        (self.state / "status").write_text("ok install_mise 3s\n")
        result, context = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text().count("pnpm install --frozen-lockfile"), 2)
        self.assertIn("web-next dependencies: installed", context)
        self.assertIn("web dependencies: installed", context)

    # intent: fix
    def test_a_node_modules_left_by_pnpm_fetch_still_gets_installed(self) -> None:
        # pnpm fetch writes .modules.yaml but links no tools, so a freshness check
        # on that file reported "current" over a tree with no vitest or tsc in it.
        for directory in ("web-next", "web"):
            marker = self.project / directory / "node_modules" / ".modules.yaml"
            marker.parent.mkdir()
            marker.write_text("")
            lockfile = self.project / directory / "pnpm-lock.yaml"
            os.utime(lockfile, (1_000_000, 1_000_000))
        self.run_hook()
        self.assertEqual(self.calls.read_text().count("pnpm install --frozen-lockfile"), 2)

    # intent: guard
    def test_a_failed_setup_step_is_named_with_its_log(self) -> None:
        (self.state / "status").write_text("ok install_mise 3s\nfailed install_swift_format 240s\n")
        (self.state / "install_swift_format.log").write_text("curl: (22) 403 Forbidden\n")
        _, context = self.run_hook()
        self.assertIn("install_swift_format failed after 240s", context)
        self.assertIn("curl: (22) 403 Forbidden", context)
        self.assertNotIn("install_mise", context)

    # intent: guard
    def test_a_missing_setup_record_reads_as_unknown_not_as_clean(self) -> None:
        _, context = self.run_hook()
        self.assertIn("is unknown", context)

    # intent: guard
    def test_a_failed_install_reports_and_still_starts_the_session(self) -> None:
        self.stub("pnpm", 'echo "ERR_PNPM_OUTDATED_LOCKFILE stale"; exit 1')
        result, context = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertIn("web-next dependencies: pnpm install failed", context)
        self.assertIn("ERR_PNPM_OUTDATED_LOCKFILE", context)

    # intent: fix
    def test_a_huge_log_line_still_reaches_the_session(self) -> None:
        # Passing the report as argv failed past Linux's 128 KiB per-argument
        # limit, and the session got no report at all.
        self.stub("pnpm", "head -c 300000 /dev/zero | tr '\\0' x; echo; exit 1")
        result, context = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertIn("web-next dependencies: pnpm install failed", context)
        self.assertLess(len(context), 10_000)

    # intent: fix
    def test_the_web_apps_install_at_the_same_time(self) -> None:
        # In sequence, two installs at their time limit outlast the hook's own 300 s
        # timeout, and it dies before printing anything. Each stub waits to see the
        # other one running, so an install in sequence fails here.
        self.stub(
            "pnpm",
            f'touch "{self.state}/started-$(basename "$PWD")"\n'
            f'other=web; [ "$(basename "$PWD")" = web ] && other=web-next\n'
            f'for _ in $(seq 1 50); do [ -e "{self.state}/started-$other" ] && exit 0; sleep 0.1; done\n'
            f"exit 1",
        )
        _, context = self.run_hook()
        self.assertIn("web-next dependencies: installed", context)
        self.assertIn("web dependencies: installed", context)

    # intent: guard
    def test_a_stale_browser_cache_is_reported(self) -> None:
        self.stub_pnpm("exit 0", browser=self.browser.parent / "chromium-9999")
        _, context = self.run_hook()
        self.assertIn("pinned browser is not installed", context)

    # intent: guard
    def test_a_failed_browser_lookup_reads_as_not_installed(self) -> None:
        self.stub("pnpm", "exit 1")
        _, context = self.run_hook()
        self.assertIn("pinned browser is not installed", context)

    # intent: guard
    def test_an_installed_browser_is_reported(self) -> None:
        _, context = self.run_hook()
        self.assertIn("pinned browser is installed", context)

    # intent: guard
    def test_dotclaude_status_is_relayed_or_reported_absent(self) -> None:
        _, context = self.run_hook()
        self.assertIn("dotclaude config: not installed", context)
        claude_dir = self.home / ".claude"
        claude_dir.mkdir()
        (claude_dir / "cloud-bootstrap.status").write_text("2026-11-02T05:00:00Z failed: download: 403\n")
        _, context = self.run_hook()
        self.assertIn("failed: download: 403", context)

    # intent: guard
    def test_the_session_is_told_what_this_vm_cannot_do(self) -> None:
        _, context = self.run_hook()
        self.assertIn("swift build", context)
        self.assertIn("gh api", context)


if __name__ == "__main__":
    unittest.main()
