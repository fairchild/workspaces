#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Regression tests for the workflow and Lume security hardening."""

from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SecurityHardeningTests(unittest.TestCase):
    def run_bash(self, script: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged_env = os.environ.copy()
        merged_env["REPO_ROOT"] = str(REPO_ROOT)
        if env:
            merged_env.update(env)
        return subprocess.run(
            ["bash", "-lc", script],
            cwd=REPO_ROOT,
            env=merged_env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_standalone_defaults_to_nat(self) -> None:
        result = self.run_bash(
            'source scripts/lib/lume-standalone-common.sh; printf "%s\\n%s\\n" "$LUME_STANDALONE_RUN_NETWORK" "$LUME_STANDALONE_PREPARE_NETWORK"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["nat", "nat"])

    def test_render_requires_guest_password(self) -> None:
        result = subprocess.run(
            ["./scripts/render-lume-unattended-config.sh", "config/lume/unattended/tahoe-workspaces-v26.yml"],
            cwd=REPO_ROOT,
            env={k: v for k, v in os.environ.items() if k not in {"LUME_GUEST_PASSWORD", "LUME_STANDALONE_SSH_PASSWORD"}},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set LUME_GUEST_PASSWORD", result.stderr)

    def test_render_replaces_template_and_restricts_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "rendered.yml"
            result = subprocess.run(
                [
                    "./scripts/render-lume-unattended-config.sh",
                    "config/lume/unattended/tahoe-workspaces-v26.yml",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                env={**os.environ, "LUME_GUEST_PASSWORD": "ExamplePasscode_1234"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output_path.exists())
            rendered = output_path.read_text()
            self.assertIn("ExamplePasscode_1234", rendered)
            self.assertNotIn("__LUME_GUEST_PASSWORD__", rendered)
            self.assertEqual(stat.S_IMODE(output_path.stat().st_mode), 0o600)

    def test_agent_mentions_workflow_is_public_triage_only(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/agent-mention.yml").read_text()
        on_block, _ = workflow.split("\npermissions:\n", 1)
        for trigger in ("issue_comment:", "pull_request_review_comment:", "pull_request_review:", "issues:"):
            self.assertIn(trigger, on_block)
        self.assertIn("runs-on: ubuntu-latest", workflow)
        for secret_name in (
            "CLAUDE_CODE_OAUTH_TOKEN",
            "APRIL_PRIVATE_KEY",
            "WORKSPACE_AGENTS_PRIVATE_KEY",
            "EVIDENCE_UPLOAD_TOKEN",
        ):
            self.assertNotIn(secret_name, workflow)

    def test_claude_workflow_is_manual_dispatch_only(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/claude.yml").read_text()
        on_block, _ = workflow.split("\njobs:\n", 1)
        self.assertIn("workflow_dispatch:", on_block)
        self.assertIn("prompt:", workflow)
        for trigger in (
            "issue_comment",
            "pull_request_review_comment",
            "pull_request_review",
            "issues",
        ):
            self.assertIsNone(re.search(rf"(?m)^  {re.escape(trigger)}:$", on_block))

    def test_agent_executor_is_label_gated(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/agent-executor.yml").read_text()
        on_block, _ = workflow.split("\npermissions:\n", 1)
        self.assertIn("issues:", on_block)
        self.assertIn("pull_request:", on_block)
        self.assertIn("types: [labeled]", on_block)
        self.assertIn("safe-to-run-agent", workflow)

    def test_all_actions_pinned_to_sha(self) -> None:
        """Every `uses:` reference to a third-party action must be pinned to a full SHA."""
        workflows_dir = REPO_ROOT / ".github/workflows"
        floating_refs: list[str] = []
        tag_pattern = re.compile(
            r"^\s*uses:\s+(?!\./)(\S+)@([a-z0-9]{40})\b",
        )
        uses_pattern = re.compile(r"^\s*uses:\s+(?!\./)(\S+)@(\S+)")
        for wf in sorted(workflows_dir.glob("*.yml")):
            for i, line in enumerate(wf.read_text().splitlines(), 1):
                m = uses_pattern.match(line)
                if not m:
                    continue
                ref = m.group(2)
                if not re.fullmatch(r"[0-9a-f]{40}", ref):
                    floating_refs.append(f"{wf.name}:{i}  {m.group(1)}@{ref}")
        self.assertEqual(
            floating_refs,
            [],
            "Actions with floating (non-SHA) refs found:\n" + "\n".join(floating_refs),
        )

    def test_ci_workflows_have_explicit_permissions(self) -> None:
        """CI workflows should declare explicit top-level permissions to limit default token scope."""
        for name in ("ci.yml", "ci-agents.yml", "web-ci.yml"):
            workflow = (REPO_ROOT / ".github/workflows" / name).read_text()
            self.assertIn(
                "\npermissions:\n",
                workflow,
                f"{name} must declare explicit top-level permissions",
            )

    def test_no_pull_request_target_trigger(self) -> None:
        """No workflow should use pull_request_target, which runs with write access on untrusted PRs."""
        workflows_dir = REPO_ROOT / ".github/workflows"
        for wf in sorted(workflows_dir.glob("*.yml")):
            content = wf.read_text()
            self.assertNotIn(
                "pull_request_target",
                content,
                f"{wf.name} must not use pull_request_target trigger",
            )


if __name__ == "__main__":
    unittest.main()
