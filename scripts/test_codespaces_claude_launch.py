#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stdlib tests for the Codespaces Claude launcher."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
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


if __name__ == "__main__":
    unittest.main()
