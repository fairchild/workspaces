#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Launcher tests for the Codespaces Claude worker.

Intent: protect the runner-side script that provisions a Codespace and starts
the in-Codespace Claude worker. These are stdlib-only unit tests so GitHub
workflow jobs can run them without installing the full app dependency stack.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "codespaces-claude-launch.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


launcher = load_module("codespaces_claude_launch", SCRIPT_PATH)


class CodespacesClaudeLaunchTests(unittest.TestCase):
    def make_options(self, **overrides):
        base = launcher.LaunchOptions(
            repo="fairchild/workspaces",
            ref="main",
            prompt="Investigate the issue.",
            prompt_file=None,
            machine=None,
            keep_running=False,
            max_turns=20,
            idle_timeout_minutes=30,
            retention_minutes=60,
            run_id="12345",
            display_name_prefix="claude-worker",
            request_root=".context/codespaces-claude-worker",
            output_json=None,
            api_url="https://api.github.com",
            ready_timeout_seconds=60,
            poll_interval_seconds=5,
        )
        return launcher.LaunchOptions(**{**base.__dict__, **overrides})

    def test_validate_args_requires_prompt_source(self) -> None:
        options = self.make_options(prompt="   ")
        with self.assertRaises(launcher.CodespacesClaudeLaunchError):
            launcher.validate_args(options)

    def test_build_request_markdown_combines_prompt_and_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            prompt_path = Path(temp_dir) / "request.md"
            prompt_path.write_text("Follow the repo conventions.\n", encoding="utf-8")
            request = launcher.build_request_markdown("Fix the workflow.", prompt_path)
        self.assertEqual(request, "Fix the workflow.\n\nFollow the repo conventions.\n")

    def test_build_create_payload_omits_empty_machine(self) -> None:
        payload = launcher.build_create_payload(self.make_options(machine=None))
        self.assertEqual(payload["ref"], "main")
        self.assertNotIn("machine", payload)
        self.assertEqual(payload["devcontainer_path"], ".devcontainer/devcontainer.json")

    def test_remote_paths_use_repo_name_and_run_id(self) -> None:
        paths = launcher.remote_paths(
            "fairchild/workspaces",
            ".context/codespaces-claude-worker",
            "run-99",
        )
        self.assertEqual(paths.repo_root, "/workspaces/workspaces")
        self.assertEqual(
            paths.request_file,
            "/workspaces/workspaces/.context/codespaces-claude-worker/run-99/request.md",
        )
        self.assertTrue(paths.worker_script.endswith("/scripts/codespaces-claude-worker.sh"))

    def test_build_remote_launch_command_quotes_paths(self) -> None:
        paths = launcher.RemotePaths(
            repo_root="/workspaces/workspaces",
            request_dir="/workspaces/workspaces/.context/codespaces-claude-worker/run-1",
            request_file="/workspaces/workspaces/.context/codespaces-claude-worker/run-1/request.md",
            worker_script="/workspaces/workspaces/scripts/codespaces-claude-worker.sh",
        )
        command = launcher.build_remote_launch_command(paths, "run-1", 25)
        self.assertIn("cd /workspaces/workspaces", command)
        self.assertIn("--run-id run-1", command)
        self.assertIn("--max-turns 25", command)

    def test_resolve_github_token_prefers_worker_token(self) -> None:
        token = launcher.resolve_github_token(
            {
                "GH_TOKEN": "gh-token",
                "CODESPACES_WORKER_GITHUB_TOKEN": "worker-token",
            }
        )
        self.assertEqual(token, "worker-token")

    def test_wait_for_codespace_exits_early_on_terminal_state(self) -> None:
        options = self.make_options(ready_timeout_seconds=30, poll_interval_seconds=1)
        original_get_codespace = launcher.get_codespace
        original_sleep = launcher.time.sleep
        try:
            launcher.get_codespace = lambda *_args, **_kwargs: {"state": "Failed"}
            launcher.time.sleep = lambda _seconds: None
            with self.assertRaises(launcher.CodespacesClaudeLaunchError) as exc:
                launcher.wait_for_codespace(options, "token", "codespace-name")
            self.assertIn("terminal state=Failed", str(exc.exception))
        finally:
            launcher.get_codespace = original_get_codespace
            launcher.time.sleep = original_sleep

    def test_run_launch_deletes_codespace_after_failed_post_create_step(self) -> None:
        options = self.make_options(keep_running=False)
        calls: list[tuple[str, str]] = []
        originals = {
            "create_codespace": launcher.create_codespace,
            "wait_for_codespace": launcher.wait_for_codespace,
            "ensure_remote_request_dir": launcher.ensure_remote_request_dir,
            "upload_request": launcher.upload_request,
            "wait_for_remote_command": launcher.wait_for_remote_command,
            "launch_remote_worker": launcher.launch_remote_worker,
            "delete_codespace": launcher.delete_codespace,
        }
        try:
            launcher.create_codespace = lambda *_args, **_kwargs: {"name": "codespace-name"}
            launcher.wait_for_codespace = lambda *_args, **_kwargs: {
                "name": "codespace-name",
                "state": "Available",
                "web_url": "https://example.test/codespace",
            }
            launcher.ensure_remote_request_dir = lambda *_args, **_kwargs: calls.append(
                ("ensure", "codespace-name")
            )
            launcher.upload_request = lambda *_args, **_kwargs: (_ for _ in ()).throw(
                launcher.CodespacesClaudeLaunchError("upload failed")
            )
            launcher.wait_for_remote_command = lambda *_args, **_kwargs: calls.append(
                ("wait", "codespace-name")
            )
            launcher.launch_remote_worker = lambda *_args, **_kwargs: calls.append(
                ("launch", "codespace-name")
            )
            launcher.delete_codespace = lambda name, _token: calls.append(("delete", name))

            with self.assertRaises(launcher.CodespacesClaudeLaunchError):
                launcher.run_launch(options, "token", "prompt\n")
        finally:
            for name, value in originals.items():
                setattr(launcher, name, value)

        self.assertIn(("delete", "codespace-name"), calls)

    def test_run_launch_keeps_codespace_on_failure_when_requested(self) -> None:
        options = self.make_options(keep_running=True)
        calls: list[tuple[str, str]] = []
        originals = {
            "create_codespace": launcher.create_codespace,
            "wait_for_codespace": launcher.wait_for_codespace,
            "ensure_remote_request_dir": launcher.ensure_remote_request_dir,
            "upload_request": launcher.upload_request,
            "wait_for_remote_command": launcher.wait_for_remote_command,
            "launch_remote_worker": launcher.launch_remote_worker,
            "delete_codespace": launcher.delete_codespace,
        }
        try:
            launcher.create_codespace = lambda *_args, **_kwargs: {"name": "codespace-name"}
            launcher.wait_for_codespace = lambda *_args, **_kwargs: {
                "name": "codespace-name",
                "state": "Available",
                "web_url": "https://example.test/codespace",
            }
            launcher.ensure_remote_request_dir = lambda *_args, **_kwargs: None
            launcher.upload_request = lambda *_args, **_kwargs: None
            launcher.wait_for_remote_command = lambda *_args, **_kwargs: None
            launcher.launch_remote_worker = lambda *_args, **_kwargs: (_ for _ in ()).throw(
                launcher.CodespacesClaudeLaunchError("launch failed")
            )
            launcher.delete_codespace = lambda name, _token: calls.append(("delete", name))

            with self.assertRaises(launcher.CodespacesClaudeLaunchError):
                launcher.run_launch(options, "token", "prompt\n")
        finally:
            for name, value in originals.items():
                setattr(launcher, name, value)

        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
