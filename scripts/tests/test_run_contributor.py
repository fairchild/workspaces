#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Policy tests for the cofounder contributor runner.

Intent: protect the automation that lets trusted GitHub Apps commit and open
PRs. These tests cover app-bot git identity selection, sensitive path gates,
and PR evidence reconciliation without running an actual agent.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts" / "run-contributor.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


run_contributor = load_module("run_contributor", SCRIPT_PATH)
pr_readiness = load_module("pr_readiness", REPO_ROOT / "scripts" / "pr-readiness.py")


class RunContributorEvidenceTests(unittest.TestCase):
    maxDiff = None

    def test_sensitive_agent_patch_paths_are_deterministic(self) -> None:
        sensitive = run_contributor.sensitive_agent_patch_paths(
            [
                "Sources/WorkspaceManager/Views/MainWindow/ContentView.swift",
                ".github/workflows/agent-april.yml",
                ".agents/skills/cofounder-contributor/SKILL.md",
                "scripts/build-release.sh",
                "scripts/verify-app-keychain-signing.sh",
                "web/src/lib/auth-server.ts",
                "web/src/app/api/auth/[...all]/route.ts",
                "web/src/lib/github-token.ts",
                "web/src/lib/agent-runtime/vercel-sandbox.ts",
                "infra/cloudflare-webhook-relay/secret.txt",
                ".mcp.json",
                "web/.mcp.json",
                "prototypes/.npmrc",
            ]
        )

        self.assertEqual(
            sensitive,
            [
                ".github/workflows/agent-april.yml",
                ".agents/skills/cofounder-contributor/SKILL.md",
                "scripts/build-release.sh",
                "scripts/verify-app-keychain-signing.sh",
                "web/src/lib/auth-server.ts",
                "web/src/app/api/auth/[...all]/route.ts",
                "web/src/lib/github-token.ts",
                "web/src/lib/agent-runtime/vercel-sandbox.ts",
                "infra/cloudflare-webhook-relay/secret.txt",
                # Execution configuration wherever it sits: `.mcp.json` names
                # stdio commands a trust-seeded headless session launches, and
                # `.npmrc` redirects the npx fetch of the model CLI itself.
                ".mcp.json",
                "web/.mcp.json",
                "prototypes/.npmrc",
            ],
        )

    def test_app_bot_git_identity_uses_canonical_bot_noreply_addresses(self) -> None:
        self.assertEqual(
            run_contributor.app_bot_git_identity(
                {"GH_APP_SLUG": "april-clearwater"},
                "April Clearwater",
                "april-clearwater[bot]",
            ),
            (
                "april-clearwater[bot]",
                "268297116+april-clearwater[bot]@users.noreply.github.com",
            ),
        )
        self.assertEqual(
            run_contributor.app_bot_git_identity(
                {"GH_APP_SLUG": "workspace-agents"},
                "Plat Ironwood",
                "workspace-agents[bot]",
            ),
            (
                "workspace-agents[bot]",
                "266434718+workspace-agents[bot]@users.noreply.github.com",
            ),
        )

    def test_app_bot_git_identity_rejects_unknown_app_slug(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "does not have an approved commit identity"):
            run_contributor.app_bot_git_identity(
                {"GH_APP_SLUG": "workspaces-claude-pr-reviewer"},
                "Claude Reviewer",
                "workspaces-claude-pr-reviewer[bot]",
            )

    def test_non_app_git_identity_keeps_persona_fallback(self) -> None:
        self.assertEqual(
            run_contributor.app_bot_git_identity({}, "April Clearwater", ""),
            ("April Clearwater", "april-clearwater@users.noreply.github.com"),
        )

    def test_agent_patch_policy_requires_privileged_label_or_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            artifact = run_contributor.ScratchPatchArtifact(
                temp_root=root,
                baseline_dir=root / "baseline",
                scratch_dir=root / "scratch",
                changed_files=[".github/workflows/agent-april.yml"],
                patch_text="diff --git a/.github/workflows/agent-april.yml b/.github/workflows/agent-april.yml\n",
            )

            with io.StringIO() as stderr, contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit):
                    run_contributor.enforce_agent_patch_policy(
                        artifact,
                        {},
                        selection_item={"labels": ["agent", "task"]},
                        cli_override=False,
                    )

            run_contributor.enforce_agent_patch_policy(
                artifact,
                {},
                selection_item={"labels": [run_contributor.PRIVILEGED_PATCH_LABEL]},
                cli_override=False,
            )
            run_contributor.enforce_agent_patch_policy(
                artifact,
                {},
                selection_item={"labels": []},
                cli_override=True,
            )

    def test_directed_action_is_bound_to_selected_number(self) -> None:
        directed = run_contributor.parse_directed_message(
            "@fairchild mentioned you in issue #42"
        )
        self.assertIsNotNone(directed)
        self.assertEqual(directed["number"], 42)

        choice = run_contributor.SelectionChoice(
            selection_kind="execute_ready_issue",
            number=42,
        )
        matching = json.dumps({"action": "execute_issue", "issue_number": 42})
        mismatched = json.dumps({"action": "execute_issue", "issue_number": 43})

        run_contributor.validate_selected_action(matching, choice)
        with self.assertRaisesRegex(ValueError, "requires issue_number=42"):
            run_contributor.validate_selected_action(mismatched, choice)

    def test_factory_issue_scope_digest_rejects_post_admission_edits(self) -> None:
        issue = {"number": 42, "title": "Fix it", "body": "Original scope"}
        digest = run_contributor.issue_scope_digest(issue)

        run_contributor.verify_expected_issue_scope(
            issue,
            {"FACTORY_EXPECTED_ISSUE_SCOPE_DIGEST": digest},
        )
        with self.assertRaisesRegex(ValueError, "changed after Factory admission"):
            run_contributor.verify_expected_issue_scope(
                {**issue, "body": "Changed scope"},
                {"FACTORY_EXPECTED_ISSUE_SCOPE_DIGEST": digest},
            )

    def test_factory_claim_keeps_selected_issue_approved_for_current_agent(self) -> None:
        github_state = sys.modules["github_state"]
        issue = {
            "number": 42,
            "title": "Fix it",
            "body": "",
            "labels": {"nodes": [{"name": "agent"}, {"name": "task"}, {"name": "claimed"}]},
            "comments": {
                "nodes": [
                    {
                        "body": (
                            "<!-- contributor:issue=42;status=claimed;"
                            "agent=april-clearwater;branch=codex/april-clearwater-issue-42-fix-it -->"
                        ),
                        # A fixed date goes stale once STALE_CLAIM_HOURS passes
                        # in real time; the fixture must stay a fresh claim.
                        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "author": {"login": "april-clearwater[bot]"},
                        "authorAssociation": "NONE",
                    }
                ]
            },
        }

        with (
            mock.patch.object(
                github_state,
                "fetch_work_state",
                return_value={"issues": [issue], "pull_requests": []},
            ),
            mock.patch.object(github_state, "fetch_issue_state_map", return_value={}),
        ):
            state = run_contributor.find_issue_execution_state(
                42,
                {"GITHUB_REPOSITORY": "fairchild/workspaces", "GH_APP_SLUG": "april-clearwater"},
                persona="April Clearwater, Application Lead",
                bot_login="april-clearwater[bot]",
            )

        self.assertIsNotNone(state)
        self.assertTrue(state["approved"])
        self.assertEqual(state["approval_reason"], "trusted current-agent claim present")

    def test_author_labels_are_machinery_owned(self) -> None:
        self.assertEqual(
            run_contributor.author_label_for_persona("April Clearwater, Application Lead"),
            "author:april",
        )
        self.assertEqual(
            run_contributor.author_label_for_persona("Plat Ironwood, Platform Lead"),
            "author:plat",
        )

    def test_approved_review_uses_only_admitted_linked_issue(self) -> None:
        execution = sys.modules["execution"]
        commands: list[list[str]] = []

        def fake_run_checked(command, **_kwargs):
            commands.append(command)
            if command[:4] == ["gh", "pr", "view", "77"]:
                return mock.Mock(
                    stdout=json.dumps(
                        {
                            "body": "Closes #42",
                            "labels": [{"name": "author:codex"}],
                        }
                    )
                )
            return mock.Mock(stdout="")

        with (
            mock.patch.object(execution, "ensure_label_exists"),
            mock.patch.object(
                execution,
                "run_checked",
                side_effect=fake_run_checked,
            ),
        ):
            run_contributor._update_mergeable_label(
                77,
                "approve",
                {
                    "GH_TOKEN": "token",
                    "FACTORY_EXPECTED_LINKED_ISSUE": "42",
                },
            )

        self.assertIn(["gh", "pr", "edit", "77", "--add-label", "mergeable"], commands)
        self.assertIn(["gh", "issue", "edit", "42", "--add-label", "mergeable"], commands)

        commands.clear()
        with (
            mock.patch.object(execution, "ensure_label_exists"),
            mock.patch.object(execution, "run_checked", side_effect=fake_run_checked),
        ):
            run_contributor._update_mergeable_label(77, "approve", {"GH_TOKEN": "token"})

        self.assertIn(["gh", "pr", "edit", "77", "--add-label", "mergeable"], commands)
        self.assertFalse(any(command[:3] == ["gh", "issue", "edit"] for command in commands))

    def test_scratch_workspace_preserves_symlinks_and_yields_empty_diff(self) -> None:
        env = dict(run_contributor.os.environ)
        workspace = run_contributor.create_scratch_workspace(env)
        try:
            symlinks = [p for p in workspace.scratch_dir.rglob("*") if p.is_symlink()]
            artifact = run_contributor.build_scratch_patch_artifact(workspace, env)
        finally:
            run_contributor.shutil.rmtree(workspace.temp_root, ignore_errors=True)

        # The repo contains symlinks (e.g. CLAUDE.md); the scratch must mirror
        # them or every linked path becomes a phantom diff the patch refuses.
        self.assertTrue(symlinks)
        self.assertEqual(artifact.changed_files, [])
        # Trust seeding and path-scoped permission rules both key on the real
        # path, so the workspace root must come pre-resolved.
        self.assertEqual(workspace.temp_root, workspace.temp_root.resolve())

    def test_scratch_diff_detects_symlink_target_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            baseline = root / "baseline"
            scratch = root / "scratch"
            for tree, target in ((baseline, "AGENTS.md"), (scratch, "README.md")):
                tree.mkdir()
                (tree / "AGENTS.md").write_text("agents\n")
                (tree / "README.md").write_text("agents\n")
                (tree / "CLAUDE.md").symlink_to(target)
            workspace = run_contributor.ScratchPatchArtifact(
                temp_root=root,
                baseline_dir=baseline,
                scratch_dir=scratch,
                changed_files=[],
                patch_text="",
            )

            artifact = run_contributor.build_scratch_patch_artifact(
                workspace, dict(run_contributor.os.environ)
            )

        # Both link targets hold identical bytes, so a comparison that follows
        # symlinks would call this unchanged; the target path itself moved.
        self.assertEqual(artifact.changed_files, ["CLAUDE.md"])

    def test_review_workspace_stays_untrusted_and_oauth_compatible(self) -> None:
        with (
            tempfile.TemporaryDirectory() as home,
            mock.patch.object(
                run_contributor,
                "run_checked",
                return_value=mock.Mock(stdout="review"),
            ) as run_checked,
        ):
            output = run_contributor.run_claude(
                "system",
                "task",
                {"HOME": home, "PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "token"},
                mode="cli",
                tools=run_contributor.READ_ONLY_MODEL_TOOLS,
                cwd=Path("/tmp/model-workspace"),
            )
            trust_file_written = (Path(home) / ".claude.json").exists()

        command = run_checked.call_args.args[0]
        self.assertEqual(output, "review")
        # --bare restricts auth to ANTHROPIC_API_KEY; the runtime authenticates
        # with CLAUDE_CODE_OAUTH_TOKEN, so it must never be passed.
        self.assertNotIn("--bare", command)
        self.assertEqual(run_checked.call_args.kwargs["cwd"], Path("/tmp/model-workspace"))
        self.assertFalse(trust_file_written)

    def test_task_travels_via_stdin_not_argv(self) -> None:
        # Diff-carrying tasks on large PRs exceeded ARG_MAX as an argv element
        # (OSError "Argument list too long: npx" on #1203's review runs); the
        # prompt must ride stdin, which --print reads when no positional
        # prompt is given.
        with mock.patch.object(
            run_contributor,
            "run_checked",
            return_value=mock.Mock(stdout="ok"),
        ) as run_checked:
            run_contributor.run_claude(
                "system",
                "big task payload",
                {"PATH": "/usr/bin"},
                mode="cli",
            )
        command = run_checked.call_args.args[0]
        self.assertNotIn("big task payload", command)
        self.assertEqual(run_checked.call_args.kwargs["input"], "big task payload")

    def test_cli_mode_pre_approves_every_exposed_tool(self) -> None:
        with mock.patch.object(
            run_contributor,
            "run_checked",
            return_value=mock.Mock(stdout="ok"),
        ) as run_checked:
            run_contributor.run_claude(
                "system",
                "task",
                {"HOME": "/tmp", "PATH": "/usr/bin"},
                mode="cli",
                tools=run_contributor.EXECUTION_TOOLS,
            )

        command = run_checked.call_args.args[0]
        # --tools only controls which tools are available; --allowedTools is
        # the permission allowlist. Headless --print runs cannot answer
        # permission prompts, so every exposed tool must be pre-approved or
        # Edit/Write calls are silently denied and execution runs produce
        # zero file changes.
        self.assertIn("--tools", command)
        self.assertEqual(command[command.index("--tools") + 1], run_contributor.EXECUTION_TOOLS)
        self.assertIn("--allowedTools", command)
        self.assertEqual(
            command[command.index("--allowedTools") + 1],
            run_contributor.EXECUTION_TOOLS,
        )
        # With no --mcp-config given, --strict-mcp-config pins the MCP server
        # set to empty: a project `.mcp.json` in a trusted scratch would
        # otherwise define stdio commands the session launches -- code
        # execution the tool allowlist never sees.
        self.assertIn("--strict-mcp-config", command)

    def test_write_grant_is_scoped_to_the_scratch(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            scratch = Path(tmpdir).resolve()
            with mock.patch.object(
                run_contributor,
                "run_checked",
                return_value=mock.Mock(stdout="ok"),
            ) as run_checked:
                run_contributor.run_claude(
                    "system",
                    "task",
                    {"HOME": "/tmp", "PATH": "/usr/bin"},
                    mode="cli",
                    tools=run_contributor.EXECUTION_TOOLS,
                    write_scope=scratch,
                )

        command = run_checked.call_args.args[0]
        pattern = f"//{str(scratch).lstrip('/')}/**"
        # Exposure stays bare tool names; the permission rules bind every
        # write tool to the scratch while read tools stay unscoped.
        self.assertEqual(command[command.index("--tools") + 1], run_contributor.EXECUTION_TOOLS)
        self.assertEqual(
            command[command.index("--allowedTools") + 1],
            f"Read,Grep,Glob,Edit({pattern}),Write({pattern}),MultiEdit({pattern})",
        )

    def test_scoped_tool_rules_resolve_symlinked_scratch_paths(self) -> None:
        # macOS mkdtemp hands out symlinked paths (/var -> /private/var); the
        # permission matcher compares real paths, so an unresolved pattern
        # would deny every in-scratch edit.
        with tempfile.TemporaryDirectory() as tmpdir:
            real_dir = Path(tmpdir).resolve() / "real"
            real_dir.mkdir()
            alias = Path(tmpdir).resolve() / "alias"
            alias.symlink_to(real_dir)

            rules = run_contributor.scoped_tool_rules("Read,Edit", alias)

        self.assertEqual(
            rules,
            f"Read,Edit(//{str(real_dir).lstrip('/')}/**)",
        )
        self.assertEqual(
            run_contributor.scoped_tool_rules(run_contributor.EXECUTION_TOOLS, None),
            run_contributor.EXECUTION_TOOLS,
        )

    def test_run_claude_requests_stream_json_telemetry(self) -> None:
        for mode in ("cli", "print"):
            with self.subTest(mode=mode):
                with mock.patch.object(
                    run_contributor,
                    "run_checked",
                    return_value=mock.Mock(stdout="ok"),
                ) as run_checked:
                    run_contributor.run_claude(
                        "system",
                        "task",
                        {"HOME": "/tmp", "PATH": "/usr/bin"},
                        mode=mode,
                        tools=run_contributor.EXECUTION_TOOLS,
                    )
                command = run_checked.call_args.args[0]
                self.assertEqual(
                    command[command.index("--output-format") + 1], "stream-json"
                )
                # --print requires --verbose for stream-json output.
                self.assertIn("--verbose", command)

    def test_run_claude_extracts_result_text_and_logs_denials(self) -> None:
        stream = "\n".join(
            [
                json.dumps({"type": "system", "subtype": "init"}),
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "name": "Edit",
                                    "input": {"file_path": "/outside/forbidden.txt"},
                                }
                            ]
                        },
                    }
                ),
                json.dumps(
                    {
                        "type": "result",
                        "subtype": "success",
                        "result": "---\naction: propose\n---\nfinal text",
                        "permission_denials": [
                            {
                                "tool_name": "Edit",
                                "tool_input": {"file_path": "/outside/forbidden.txt"},
                            }
                        ],
                    }
                ),
            ]
        )

        with io.StringIO() as stderr, contextlib.redirect_stderr(stderr):
            with mock.patch.object(
                run_contributor,
                "run_checked",
                return_value=mock.Mock(stdout=stream),
            ):
                output = run_contributor.run_claude(
                    "system",
                    "task",
                    {"HOME": "/tmp", "PATH": "/usr/bin"},
                    mode="cli",
                    tools=run_contributor.EXECUTION_TOOLS,
                )
            telemetry = stderr.getvalue()

        # Downstream parses the model's final text: the return contract is the
        # `result` event payload, not the raw stream transcript.
        self.assertEqual(output, "---\naction: propose\n---\nfinal text")
        self.assertIn("Tool attempts: 1", telemetry)
        self.assertIn("tool_use: Edit", telemetry)
        self.assertIn("Permission denials: 1", telemetry)
        self.assertIn("denied: Edit", telemetry)
        self.assertIn("/outside/forbidden.txt", telemetry)

    def test_run_claude_falls_back_to_raw_output_without_result_event(self) -> None:
        with mock.patch.object(
            run_contributor,
            "run_checked",
            return_value=mock.Mock(stdout="plain prose output"),
        ):
            output = run_contributor.run_claude(
                "system",
                "task",
                {"HOME": "/tmp", "PATH": "/usr/bin"},
                mode="cli",
                tools=run_contributor.READ_ONLY_MODEL_TOOLS,
            )

        self.assertEqual(output, "plain prose output")

    def test_project_trust_seeding_preserves_existing_config(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".claude.json"
            config.write_text(json.dumps({
                "projects": {"/existing": {"hasTrustDialogAccepted": True, "other": 1}},
                "theme": "dark",
            }))

            run_contributor.ensure_claude_project_trust(Path("/scratch/ws"), {"HOME": home})
            run_contributor.ensure_claude_project_trust(Path("/scratch/ws"), {"HOME": home})

            data = json.loads(config.read_text())

        self.assertEqual(data["theme"], "dark")
        self.assertEqual(data["projects"]["/existing"], {"hasTrustDialogAccepted": True, "other": 1})
        self.assertTrue(data["projects"]["/scratch/ws"]["hasTrustDialogAccepted"])

    def test_reconcile_pending_ci_evidence_includes_uploaded_screenshot_links(self) -> None:
        body = "\n".join(
            [
                "## Evidence Status",
                "- [pending-ci] Post-setup screenshot -- CI evidence job will capture screenshot",
                "",
                "## Validation",
                "- blocked on evidence",
            ]
        )

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[
                ("01-launch", "https://evidence.example/workspaces/pr-42/01-launch.png"),
                ("02-final", "https://evidence.example/workspaces/pr-42/02-final.png"),
            ],
        )

        self.assertIn(
            "- [complete] Post-setup screenshot -- captured on self-hosted macOS CI: "
            "[01-launch](https://evidence.example/workspaces/pr-42/01-launch.png), "
            "[02-final](https://evidence.example/workspaces/pr-42/02-final.png)",
            reconciled,
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_screenshot_upload(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=False,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but R2 upload failed; "
            "see workflow artifacts\n",
        )

    def test_reconcile_pending_ci_evidence_blocks_missing_uploaded_urls(self) -> None:
        body = "## Evidence Status\n- [pending-ci] Final screenshot -- CI evidence job will capture screenshot\n"

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            screenshot_upload_succeeded=True,
            screenshot_urls=[],
        )

        self.assertEqual(
            reconciled,
            "## Evidence Status\n"
            "- [blocked] Final screenshot -- self-hosted macOS CI captured screenshots but no R2 URLs were recorded; "
            "see workflow artifacts\n",
        )

    def test_factory_visual_evidence_is_explicitly_blocked_until_capture_lane(self) -> None:
        rendered, errors = run_contributor.build_execution_summary_body(
            {
                "body": "## Summary\nVisual change\n\n## Validation\n- downstream evidence",
            },
            requested_evidence=["screenshot of the main window"],
            visual_evidence_available=False,
        )

        self.assertEqual(errors, [])
        self.assertIn("- [blocked] screenshot of the main window", rendered)
        self.assertIn("Xcode Cloud capture lane #1088 is not available", rendered)
        self.assertIn("blocked on evidence", rendered)

    def test_factory_visual_evidence_recognizes_standard_visual_phrasings(self) -> None:
        for request in (
            "Visual proof of the finished sidebar",
            "window capture after the change",
            "before/after images of the terminal",
        ):
            with self.subTest(request=request):
                self.assertTrue(run_contributor._needs_screenshot_evidence([request]))

    def test_factory_other_only_evidence_requires_blocking_label(self) -> None:
        execution = sys.modules["execution"]
        requested = ["Other proof recorded by the implementer"]
        needs_macos_evidence = run_contributor._needs_macos_evidence(requested)

        self.assertFalse(needs_macos_evidence)
        self.assertTrue(
            execution._factory_evidence_should_block(
                factory_requires_evidence=True,
                needs_macos_evidence=needs_macos_evidence,
                visual_evidence_blocked=False,
            )
        )
        with (
            mock.patch.object(execution, "ensure_label_exists") as ensure_label,
            mock.patch.object(execution, "run_checked") as run_checked,
        ):
            execution._mark_factory_evidence_blocked("77", env={"GH_TOKEN": "token"})

        ensure_label.assert_called_once()
        self.assertEqual(
            run_checked.call_args.args[0],
            ["gh", "pr", "edit", "77", "--add-label", "blocked:evidence"],
        )

    def test_candidate_code_environment_excludes_workflow_credentials(self) -> None:
        sanitized = run_contributor.sanitized_candidate_code_env(
            {
                "PATH": "/usr/bin",
                "HOME": "/tmp/home",
                "GH_TOKEN": "app-token",
                "EVIDENCE_UPLOAD_TOKEN": "upload-token",
                "CLAUDE_CODE_OAUTH_TOKEN": "claude-token",
            }
        )

        self.assertEqual(sanitized, {"PATH": "/usr/bin", "HOME": "/tmp/home"})

    def test_build_evidence_allows_only_the_exact_canonical_command(self) -> None:
        self.assertEqual(
            run_contributor.safe_swift_build_command_args("swift build"),
            ["swift", "build"],
        )
        for command in (
            "swift build --configuration release",
            "swift build --product Missing",
            "swift build && curl https://example.invalid",
        ):
            with self.subTest(command=command):
                self.assertIsNone(run_contributor.safe_swift_build_command_args(command))
                errors = run_contributor.validate_requested_test_commands([command], env={})
                self.assertEqual(len(errors), 1)
                self.assertIn("must use exactly `swift build`", errors[0])

    def test_reconcile_test_evidence_includes_uploaded_log_url(self) -> None:
        body = (
            "## Evidence Status\n"
            "- [pending-ci] `swift test --filter FeatureTests` -- CI will run tests\n"
        )

        reconciled = run_contributor.reconcile_pending_ci_evidence(
            body,
            build_succeeded=True,
            tests_succeeded=True,
            smoke_succeeded=True,
            test_output="$ swift test --filter FeatureTests\nAll tests passed\n",
            text_upload_required=True,
            text_upload_succeeded=True,
            text_urls=[
                ("test-output", "https://evidence.example/workspaces/pr-42/test-output.txt")
            ],
        )

        self.assertIn("- [complete] `swift test --filter FeatureTests`", reconciled)
        self.assertIn(
            "[test-output](https://evidence.example/workspaces/pr-42/test-output.txt)",
            reconciled,
        )


class EvidenceValidationTests(unittest.TestCase):
    maxDiff = None

    def _make_body(
        self,
        evidence_lines: list[str],
        *,
        section: bool = True,
        validation: str = "",
    ) -> str:
        parts: list[str] = []
        if section:
            parts.append("## Evidence Status")
            parts.extend(evidence_lines)
        if validation:
            parts.append("")
            parts.append("## Validation")
            parts.append(validation)
        return "\n".join(parts)

    def test_malformed_lines_truncated(self) -> None:
        long_line = "- broken entry " + "x" * 200
        body = self._make_body([long_line, "- another broken line"])
        requested = ["`swift test --filter Foo`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        malformed_errors = [e for e in errors if "malformed" in e]
        self.assertEqual(len(malformed_errors), 1)
        error = malformed_errors[0]
        # Should contain 'line 1:' with truncation
        self.assertIn('line 1:', error)
        self.assertIn('...', error)
        # Should NOT contain the full 200-char string
        self.assertNotIn("x" * 200, error)

    def test_missing_items_show_indexes(self) -> None:
        requested = [
            "`swift test --filter FooTests`",
            "`swift build`",
            "screenshot of final result",
        ]
        # Only provide evidence for item 2
        body = self._make_body(
            ["- [complete] `swift build` -- built ok"],
        )
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        missing_errors = [e for e in errors if "missing:" in e]
        self.assertEqual(len(missing_errors), 1)
        error = missing_errors[0]
        # 1-based indexes for items 1 and 3
        self.assertIn("[1]", error)
        self.assertIn("[3]", error)
        # Should not contain index 2 (that one was provided)
        self.assertNotIn("[2]", error)

    def test_missing_section(self) -> None:
        body = "Some PR body without evidence section"
        requested = ["`swift test`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        section_errors = [e for e in errors if "Evidence Status" in e and "section" in e]
        self.assertTrue(len(section_errors) >= 1)

    def test_duplicates_truncated(self) -> None:
        long_item = "very long evidence item " + "y" * 200
        body = self._make_body([
            f"- [complete] {long_item} -- proof 1",
            f"- [complete] {long_item} -- proof 2",
        ])
        requested = [long_item]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        dup_errors = [e for e in errors if "duplicate" in e]
        self.assertEqual(len(dup_errors), 1)
        error = dup_errors[0]
        self.assertIn("...", error)
        self.assertNotIn("y" * 200, error)

    def test_all_complete_no_errors(self) -> None:
        requested = ["`swift test`", "`swift build`"]
        body = self._make_body([
            "- [complete] `swift test` -- all passed",
            "- [complete] `swift build` -- built ok",
        ])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        self.assertEqual(errors, [])

    def test_structured_metadata_invalid(self) -> None:
        body = (
            '<!-- evidence-status:v1\n'
            'not valid json\n'
            '-->\n\n'
            '## Evidence Status\n'
        )
        requested = ["`swift test`"]
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        metadata_errors = [e for e in errors if "metadata" in e]
        self.assertTrue(len(metadata_errors) >= 1)

    def test_classify_evidence_error_categories(self) -> None:
        cases = [
            ("missing required '## Evidence Status' section", "evidence_section_missing"),
            ("malformed Evidence Status entries; expected '...' (line 1: ...)", "evidence_format"),
            ("malformed hidden evidence metadata: (line 1: ...)", "evidence_metadata"),
            ("duplicate Evidence Status entries for: foo", "evidence_duplicate"),
            ("PR body must account for every requested evidence item exactly; missing: [1] foo", "evidence_missing"),
        ]
        for error_msg, expected_category in cases:
            with self.subTest(error=error_msg):
                self.assertEqual(
                    run_contributor.classify_evidence_error(error_msg),
                    expected_category,
                )

        # Also test classify_evidence_errors returns list of dicts
        errors = [c[0] for c in cases]
        classified = run_contributor.classify_evidence_errors(errors)
        self.assertEqual(len(classified), len(cases))
        for i, (_, expected_cat) in enumerate(cases):
            self.assertEqual(classified[i]["category"], expected_cat)
            self.assertEqual(classified[i]["message"], errors[i])

    def test_fuzzy_matching_edge_cases(self) -> None:
        # Exact 70% word overlap should match
        requested = ["swift test filter FooTests BarTests BazTests QuuxTests FiveTests SixTests TenWord"]
        # 7 of 10 words match = 70%
        entry_text = "swift test filter FooTests BarTests BazTests QuuxTests different words here"
        body = self._make_body([
            f"- [complete] {entry_text} -- proof",
        ])
        accounting = run_contributor.evaluate_evidence_accounting(body, requested)
        # With 70% overlap the item should be matched (not missing)
        self.assertEqual(accounting["missing_items"], [])

        # Below 70% should NOT match
        requested_low = ["alpha bravo charlie delta echo foxtrot golf hotel india juliet"]
        entry_low = "alpha bravo charlie completely different words everywhere now ok done"
        body_low = self._make_body([
            f"- [complete] {entry_low} -- proof",
        ])
        accounting_low = run_contributor.evaluate_evidence_accounting(body_low, requested_low)
        self.assertEqual(len(accounting_low["missing_items"]), 1)

    def test_reproduce_april_failure_pattern(self) -> None:
        """Reproduce the exact pattern from April's CI logs: long evidence items
        with missing entries produce readable error messages."""
        requested = [
            "`swift test --filter 'WorkspaceManagerTests.SomeVeryLongTestSuiteName'`",
            "screenshot of the workspace manager main window after launching with the new sidebar layout changes applied",
            "`swift build`",
        ]
        # Only provide evidence for item 3
        body = self._make_body([
            "- [complete] `swift build` -- built successfully",
        ])
        _, errors = run_contributor.validate_evidence_accounting(body, requested)
        missing_errors = [e for e in errors if "missing:" in e]
        self.assertEqual(len(missing_errors), 1)
        error = missing_errors[0]
        # Should show 1-based indexes
        self.assertIn("[1]", error)
        self.assertIn("[2]", error)
        # Should truncate long items
        self.assertIn("...", error)
        # Should NOT contain the full long screenshot description
        self.assertNotIn("after launching with the new sidebar layout changes applied", error)
        # Verify total error message is readable (under ~500 chars)
        self.assertLess(len(error), 500)


    def test_render_then_validate_pending_ci_roundtrip(self) -> None:
        """Round-trip: render_execution_summary_body with pending-ci entries,
        then validate_evidence_accounting should not raise format errors."""
        requested = ["`swift test --filter Foo`", "screenshot of main window"]
        summary_body = "## Summary\nSome PR description\n\n## Validation\n- looks good\n"
        rendered, render_errors = run_contributor.render_execution_summary_body(
            summary_body,
            requested_evidence=requested,
            evidence_complete=["1 -- all tests pass"],
            evidence_blocked=None,
            evidence_pending_ci=["2 -- CI will capture screenshot"],
        )
        self.assertEqual(render_errors, [])
        # Rendered body should contain "blocked on evidence" language
        self.assertIn("blocked on evidence", rendered.casefold())
        # Now validate the rendered body — should have no errors
        _, validate_errors = run_contributor.validate_evidence_accounting(rendered, requested)
        self.assertEqual(validate_errors, [], f"Round-trip validation failed: {validate_errors}")


class DirectedPRParsingTests(unittest.TestCase):
    def test_review_pr_hash(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("Review PR #198"), 198)

    def test_review_pr_no_hash(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("Review PR 198"), 198)

    def test_cr_number(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("CR 123"), 123)

    def test_cr_hash(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("cr #123"), 123)

    def test_cr_hash_space(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("cr # 123"), 123)

    def test_cr_no_space(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("CR#456"), 456)

    def test_code_review(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("code review 99"), 99)

    def test_re_review(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("Re-review PR #185"), 185)

    def test_rereview(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("rereview #42"), 42)

    def test_embedded_in_sentence(self) -> None:
        self.assertEqual(
            run_contributor.parse_directed_pr_number(
                "Please review PR #198 — evidence section updated"
            ),
            198,
        )

    def test_no_match(self) -> None:
        self.assertIsNone(run_contributor.parse_directed_pr_number("Fix the login bug"))

    def test_pr_fallback(self) -> None:
        self.assertEqual(run_contributor.parse_directed_pr_number("Check PR 55 for issues"), 55)


class PrefetchedPRDiffTests(unittest.TestCase):
    def test_fetch_pr_diff_uses_run_optional_string_contract(self) -> None:
        def fake_run_optional(
            cmd: list[str],
            *,
            timeout: int,
            cwd: Path | None = None,
            env: dict[str, str] | None = None,
            default: str,
        ) -> str:
            self.assertEqual(cmd, ["gh", "pr", "diff", "123"])
            self.assertEqual(timeout, run_contributor.GITHUB_API_TIMEOUT)
            self.assertEqual(cwd, run_contributor.REPO_ROOT)
            self.assertEqual(env, {"GH_TOKEN": "token"})
            self.assertEqual(default, "")
            return "line 1\nline 2\nline 3\n"

        with mock.patch("github_state.run_optional", side_effect=fake_run_optional):
            diff = run_contributor.fetch_pr_diff(123, {"GH_TOKEN": "token"}, max_lines=2)

        self.assertEqual(
            diff,
            "line 1\nline 2\n... (truncated — 1 more lines)\n",
        )

    def test_format_pr_list_includes_directed_pr_diff_outside_open_state(self) -> None:
        payload = json.loads(
            run_contributor.format_pr_list_for_context(
                [],
                [],
                pr_diffs={185: "diff text"},
            )
        )

        self.assertEqual(
            payload,
            [
                {
                    "number": 185,
                    "title": "Directed PR outside open work state",
                    "state": "not_in_open_work_state",
                    "diffTrust": "explicitly_directed",
                    "diff": "diff text",
                }
            ],
        )

    def test_inline_pr_diff_policy_allows_trusted_same_repo_prs(self) -> None:
        allowed, reason = run_contributor.inline_pr_diff_policy(
            {
                "number": 12,
                "isCrossRepository": False,
                "authorAssociation": "MEMBER",
                "author": {"login": "fairchild"},
            },
            trusted_logins={"april-clearwater[bot]"},
        )

        self.assertTrue(allowed)
        self.assertIsNone(reason)

    def test_inline_pr_diff_policy_omits_untrusted_cross_repo_prs(self) -> None:
        allowed, reason = run_contributor.inline_pr_diff_policy(
            {
                "number": 12,
                "isCrossRepository": True,
                "authorAssociation": "CONTRIBUTOR",
                "author": {"login": "external-user"},
            },
            trusted_logins={"april-clearwater[bot]"},
        )

        self.assertFalse(allowed)
        self.assertEqual(reason, "cross_repository")

    def test_inline_pr_diff_policy_allows_directed_untrusted_pr(self) -> None:
        allowed, reason = run_contributor.inline_pr_diff_policy(
            {
                "number": 12,
                "isCrossRepository": True,
                "authorAssociation": "CONTRIBUTOR",
                "author": {"login": "external-user"},
            },
            trusted_logins={"april-clearwater[bot]"},
            directed_pr=12,
        )

        self.assertTrue(allowed)
        self.assertIsNone(reason)

    def test_format_pr_list_marks_omitted_untrusted_diff(self) -> None:
        payload = json.loads(
            run_contributor.format_pr_list_for_context(
                [
                    {
                        "number": 44,
                        "title": "PR from fork",
                        "author": {"login": "external-user"},
                        "authorAssociation": "CONTRIBUTOR",
                        "isDraft": False,
                        "isCrossRepository": True,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "headRefName": "external/fork-branch",
                        "url": "https://example.com/pr/44",
                        "body": "",
                    }
                ],
                [],
                pr_diff_omissions={44: "cross_repository"},
            )
        )

        self.assertEqual(payload[0]["diffOmittedReason"], "cross_repository")
        self.assertNotIn("diff", payload[0])


class RepoMemoryInjectionTests(unittest.TestCase):
    def test_compose_folds_memory_into_persona(self) -> None:
        with mock.patch.object(
            run_contributor, "load_repo_memory", return_value="- Never target bare self-hosted."
        ):
            composed = run_contributor.compose_system_prompt("# April Clearwater\n\nYou are April.")
        self.assertIn("You are April.", composed)
        self.assertIn("Repository memory (trusted, curated)", composed)
        self.assertIn("Never target bare self-hosted.", composed)
        # Memory follows the persona, not the other way around.
        self.assertLess(composed.index("You are April."), composed.index("Repository memory"))

    def test_compose_is_noop_without_memory(self) -> None:
        with mock.patch.object(run_contributor, "load_repo_memory", return_value=""):
            persona = "# April Clearwater\n\nYou are April."
            self.assertEqual(run_contributor.compose_system_prompt(persona), persona)

    def test_load_repo_memory_missing_file_is_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "does-not-exist" / "MEMORY.md"
            with mock.patch.object(run_contributor, "REPO_MEMORY_PATH", missing):
                self.assertEqual(run_contributor.load_repo_memory(), "")


class ClaudeCodePinTests(unittest.TestCase):
    def test_cli_package_is_version_pinned(self) -> None:
        # The contributor fetches the CLI with GH_TOKEN in the environment, so it
        # must never resolve `@latest`. Guard against a regression to an unpinned spec.
        package = run_contributor.CLAUDE_CODE_PACKAGE
        self.assertTrue(package.startswith("@anthropic-ai/claude-code@"))
        version = package.rsplit("@", 1)[1]
        self.assertRegex(version, r"^\d+\.\d+\.\d+")


class MergeabilitySeedTests(unittest.TestCase):
    """Factory-composed PR bodies must clear the pr-readiness Mergeability
    gate at open time (#1119): seeded from changed files and the agent's own
    Summary/Validation/Risks, honest placeholders where nothing is known."""

    maxDiff = None

    SUMMARY_BODY = (
        "## Summary\n"
        "- Reject dot-only segments in repo names before URL interpolation\n"
        "- All call sites consume the boolean return unchanged\n\n"
        "## Validation\n"
        "- vitest exercises the new validator rows\n\n"
        "## Risks\n"
        "- Client-side pattern hint intentionally unchanged\n"
    )
    CHANGED_FILES = [
        "web-next/src/lib/db/start-session.ts",
        "web-next/src/lib/db/start-session.test.ts",
    ]

    def readiness_result(self, body: str, files: list[str]):
        pr = {
            "title": "feat: example",
            "body": body,
            "draft": False,
            "labels": [],
        }
        return pr_readiness.evaluate(pr, files)

    def test_seeded_pr_body_passes_readiness_mergeability_checks(self) -> None:
        seeded = run_contributor.seed_mergeability_section(
            self.SUMMARY_BODY, changed_files=self.CHANGED_FILES
        )
        body = run_contributor.compose_pr_body(
            1032, "April Clearwater, Application Lead", seeded
        )
        result = self.readiness_result(body, self.CHANGED_FILES)

        self.assertEqual(
            [failure for failure in result.failures if "Mergeability" in failure],
            [],
        )

    def test_seed_prefills_surface_and_agent_sections(self) -> None:
        seeded = run_contributor.seed_mergeability_section(
            self.SUMMARY_BODY, changed_files=self.CHANGED_FILES
        )
        section = pr_readiness.extract_section(seeded, "Mergeability")

        surface = pr_readiness.field_value(section, "Surface")
        self.assertIn("web", surface)
        self.assertIn("start-session.ts", surface)
        self.assertIn(
            "Reject dot-only segments",
            pr_readiness.field_value(section, "User-facing behavior changed"),
        )
        self.assertIn(
            "vitest exercises",
            pr_readiness.field_value(section, "Non-happy paths considered"),
        )
        self.assertIn(
            "pattern hint intentionally unchanged",
            pr_readiness.field_value(section, "Residual risk or follow-up"),
        )

    def test_seed_uses_non_blank_placeholders_when_agent_says_nothing(self) -> None:
        seeded = run_contributor.seed_mergeability_section("", changed_files=[])
        section = pr_readiness.extract_section(seeded, "Mergeability")

        for field in (
            "Surface",
            "User-facing behavior changed",
            "Non-happy paths considered",
            "Residual risk or follow-up",
        ):
            with self.subTest(field=field):
                value = pr_readiness.field_value(section, field)
                default = pr_readiness.DEFAULT_SURFACE if field == "Surface" else None
                self.assertFalse(pr_readiness.is_blank_value(value, default=default))

    def test_seed_keeps_agent_authored_mergeability_section(self) -> None:
        authored = (
            "## Summary\n- change\n\n"
            "## Mergeability\n"
            "- Surface: desktop — SidebarView hover affordance\n"
            "- User-facing behavior changed: hover-visible actions\n"
            "- Non-happy paths considered: empty repo list\n"
            "- Residual risk or follow-up: none\n"
        )

        self.assertEqual(
            run_contributor.seed_mergeability_section(
                authored, changed_files=["Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift"]
            ),
            authored,
        )

    def test_seed_classifies_surfaces_by_path_prefix(self) -> None:
        surface = run_contributor._mergeability_surface(
            [
                "Sources/WorkspaceManager/App/AppActivationPolicy.swift",
                "web/src/lib/agent-runtime/vercel-sandbox.ts",
                "infra/cloudflare-evidence-store/worker.ts",
                "docs/development/evidence.md",
            ]
        )

        for label in ("desktop", "agent-runtime", "infra", "docs"):
            self.assertIn(label, surface)
        self.assertIn("(+1 more)", surface)

    def test_seed_does_not_disturb_evidence_status_rendering(self) -> None:
        rendered, errors = run_contributor.build_execution_summary_body(
            {
                "body": self.SUMMARY_BODY,
            },
            requested_evidence=["swift test --filter WorkspaceServiceTests"],
        )
        self.assertEqual(errors, [])

        seeded = run_contributor.seed_mergeability_section(
            rendered, changed_files=self.CHANGED_FILES
        )
        _, evidence_errors = run_contributor.validate_evidence_accounting(
            seeded, ["swift test --filter WorkspaceServiceTests"]
        )

        self.assertEqual(evidence_errors, [])
        self.assertLess(
            seeded.index("## Evidence Status"), seeded.index("## Mergeability")
        )


def _stream_transcript(
    *,
    total_cost_usd: float,
    model_usage: dict[str, dict[str, int]],
    subtype: str = "success",
    assistant_model: str | None = None,
) -> str:
    lines = []
    if assistant_model is not None:
        lines.append(
            json.dumps(
                {"type": "assistant", "message": {"model": assistant_model, "content": []}}
            )
        )
    aggregate = {
        "input_tokens": sum(u.get("inputTokens", 0) for u in model_usage.values()),
        "output_tokens": sum(u.get("outputTokens", 0) for u in model_usage.values()),
        "cache_creation_input_tokens": sum(
            u.get("cacheCreationInputTokens", 0) for u in model_usage.values()
        ),
        "cache_read_input_tokens": sum(
            u.get("cacheReadInputTokens", 0) for u in model_usage.values()
        ),
    }
    lines.append(
        json.dumps(
            {
                "type": "result",
                "subtype": subtype,
                "total_cost_usd": total_cost_usd,
                "usage": aggregate,
                "modelUsage": model_usage,
                "duration_ms": 4321,
                "num_turns": 3,
            }
        )
    )
    return "\n".join(lines) + "\n"


class CostTelemetryTests(unittest.TestCase):
    HAIKU_1M = {
        "claude-haiku-4-5": {
            "inputTokens": 1_000_000,
            "outputTokens": 1_000_000,
            "cacheReadInputTokens": 0,
            "cacheCreationInputTokens": 0,
        }
    }

    def test_derived_cost_wins_when_reported_is_inflated(self) -> None:
        # Haiku at 1M in + 1M out prices to $1 + $5 = $6; a ~10x-high report
        # (the known upstream bug) must fall back to the derived value.
        raw = _stream_transcript(total_cost_usd=60.0, model_usage=self.HAIKU_1M)
        row = run_contributor.build_cost_row(raw, "action", {})
        self.assertEqual(row["cost_source"], "derived")
        self.assertAlmostEqual(row["cost_usd"], 6.0)
        self.assertAlmostEqual(row["cost_usd_derived"], 6.0)
        self.assertAlmostEqual(row["cost_usd_reported"], 60.0)
        self.assertEqual(row["model"], "claude-haiku-4-5")
        self.assertEqual(row["input_tokens"], 1_000_000)

    def test_reported_cost_kept_when_values_agree(self) -> None:
        raw = _stream_transcript(total_cost_usd=6.2, model_usage=self.HAIKU_1M)
        row = run_contributor.build_cost_row(raw, "action", {})
        self.assertEqual(row["cost_source"], "reported")
        self.assertAlmostEqual(row["cost_usd"], 6.2)
        self.assertAlmostEqual(row["cost_usd_derived"], 6.0)

    def test_unknown_model_marks_reported_unpriced(self) -> None:
        raw = _stream_transcript(
            total_cost_usd=3.0,
            model_usage={"claude-zeta-9": {"inputTokens": 1_000_000, "outputTokens": 0}},
        )
        row = run_contributor.build_cost_row(raw, "action", {})
        self.assertEqual(row["cost_source"], "reported_unpriced")
        self.assertAlmostEqual(row["cost_usd"], 3.0)

    def test_zero_derivation_with_positive_report_keeps_reported(self) -> None:
        # An empty modelUsage entry derives $0; that means missing usage data,
        # not the inflation bug — the positive reported cost must survive.
        raw = _stream_transcript(
            total_cost_usd=2.5,
            model_usage={"claude-haiku-4-5": {}},
        )
        row = run_contributor.build_cost_row(raw, "action", {})
        self.assertEqual(row["cost_source"], "reported_unpriced")
        self.assertAlmostEqual(row["cost_usd"], 2.5)
        self.assertAlmostEqual(row["cost_usd_derived"], 0.0)

    def test_telemetry_dir_writes_transcript_and_row(self) -> None:
        raw = _stream_transcript(total_cost_usd=6.0, model_usage=self.HAIKU_1M)
        with tempfile.TemporaryDirectory() as tmp:
            env = {
                "FACTORY_TELEMETRY_DIR": tmp,
                "FACTORY_TELEMETRY_LANE": "implement",
                "GITHUB_RUN_ID": "42",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_WORKFLOW": "Factory Implement",
                "ISSUE_NUMBER": "1138",
            }
            run_contributor.record_run_telemetry(raw, phase="action", env=env)

            transcript = Path(tmp) / "transcripts" / "0001-action.jsonl"
            self.assertTrue(transcript.is_file())

            rows_file = Path(tmp) / "cost-rows.jsonl"
            lines = rows_file.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1)
            row = json.loads(lines[0])
            self.assertEqual(row["id"], "42-1-action")
            self.assertEqual(row["phase"], "action")
            self.assertEqual(row["lane"], "implement")
            self.assertEqual(row["issue"], 1138)
            self.assertIsNone(row["pr"])

    def test_telemetry_unset_writes_nothing(self) -> None:
        raw = _stream_transcript(total_cost_usd=6.0, model_usage=self.HAIKU_1M)
        with tempfile.TemporaryDirectory() as tmp:
            result = run_contributor.record_run_telemetry(
                raw, phase="action", env={"FACTORY_TELEMETRY_LANE": "implement"}
            )
            self.assertIsNone(result)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_redaction_scrubs_env_value_and_credential_patterns(self) -> None:
        secret = "SECRETVALUE12345"
        ghp = "ghp_" + "a" * 36
        bearer = "Bearer " + "b" * 25
        raw = (
            _stream_transcript(total_cost_usd=6.0, model_usage=self.HAIKU_1M)
            + json.dumps({"leak": f"{secret} {ghp} {bearer}"})
            + "\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "GH_TOKEN": secret}
            run_contributor.record_run_telemetry(raw, phase="action", env=env)
            transcript = (Path(tmp) / "transcripts" / "0001-action.jsonl").read_text(
                encoding="utf-8"
            )
        self.assertNotIn(secret, transcript)
        self.assertNotIn(ghp, transcript)
        self.assertNotIn(bearer, transcript)
        self.assertIn("[REDACTED]", transcript)

    def test_telemetry_write_failure_is_swallowed(self) -> None:
        raw = _stream_transcript(total_cost_usd=6.0, model_usage=self.HAIKU_1M)
        with tempfile.TemporaryDirectory() as tmp:
            blocker = Path(tmp) / "blocker"
            blocker.write_text("not a directory", encoding="utf-8")
            env = {"FACTORY_TELEMETRY_DIR": str(blocker / "telemetry")}
            # Must not raise even though the telemetry dir cannot be created.
            self.assertIsNone(run_contributor.record_run_telemetry(raw, phase="action", env=env))

    def test_redaction_scrubs_encoded_secret_variants(self) -> None:
        import base64 as b64mod
        from urllib.parse import quote as urlquote

        secret = "sekret%value+12345"
        encodings = [
            b64mod.b64encode(secret.encode()).decode(),
            b64mod.b64encode(secret.encode()).decode().rstrip("="),
            b64mod.urlsafe_b64encode(secret.encode()).decode(),
            secret.encode().hex(),
            urlquote(secret, safe=""),
        ]
        raw = (
            _stream_transcript(total_cost_usd=6.0, model_usage=self.HAIKU_1M)
            + json.dumps({"leaks": encodings})
            + "\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "CLAUDE_CODE_OAUTH_TOKEN": secret}
            run_contributor.record_run_telemetry(raw, phase="action", env=env)
            transcript = (Path(tmp) / "transcripts" / "0001-action.jsonl").read_text(
                encoding="utf-8"
            )
        for encoded in encodings:
            self.assertNotIn(encoded, transcript)

    def test_run_checked_reports_failure_output(self) -> None:
        captured: list[str] = []
        with self.assertRaises(SystemExit):
            run_contributor.run_checked(
                [sys.executable, "-c", "print('partial stream'); raise SystemExit(3)"],
                timeout=30,
                on_failure_output=captured.append,
            )
        self.assertEqual(len(captured), 1)
        self.assertIn("partial stream", captured[0])


class UnparseableOutputArtifactTests(unittest.TestCase):
    """#1179: preserve a review that died at output validation as an artifact
    instead of only a GitHub Actions log line that can expire before anyone
    inspects it."""

    def test_validate_output_failure_writes_raw_text_to_telemetry_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "PATH": "/usr/bin:/bin"}
            with mock.patch.object(
                run_contributor.subprocess,
                "run",
                return_value=mock.Mock(
                    returncode=1, stdout="", stderr="error: failed to parse output: bad input"
                ),
            ):
                exit_code, validated_json, error_text = run_contributor.validate_output(
                    "not json or frontmatter", env
                )

            self.assertEqual(exit_code, 1)
            self.assertIsNone(validated_json)
            self.assertIn("failed to parse output", error_text)

            written = list((Path(tmp) / "parse-failures").glob("*.txt"))
            self.assertEqual(len(written), 1)
            self.assertEqual(written[0].read_text(encoding="utf-8"), "not json or frontmatter")

    def test_validate_output_success_writes_no_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "PATH": "/usr/bin:/bin"}
            with mock.patch.object(
                run_contributor.subprocess,
                "run",
                return_value=mock.Mock(returncode=0, stdout='{"action": "review_pr"}', stderr=""),
            ):
                run_contributor.validate_output("---\naction: review_pr\n---\n", env)

            self.assertFalse((Path(tmp) / "parse-failures").exists())

    def test_duplicate_proposal_skip_writes_no_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "PATH": "/usr/bin:/bin"}
            with mock.patch.object(
                run_contributor.subprocess,
                "run",
                return_value=mock.Mock(
                    returncode=2, stdout="", stderr="duplicate: proposed 'x' matches existing 'x'"
                ),
            ):
                run_contributor.validate_output("---\naction: propose\n---\n", env)

            self.assertFalse((Path(tmp) / "parse-failures").exists())

    def test_validation_timeout_also_writes_the_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "PATH": "/usr/bin:/bin"}
            with mock.patch.object(
                run_contributor.subprocess,
                "run",
                side_effect=run_contributor.subprocess.TimeoutExpired(cmd="validate", timeout=30),
            ):
                exit_code, validated_json, error_text = run_contributor.validate_output(
                    "some output", env
                )

            self.assertEqual(exit_code, 1)
            self.assertIsNone(validated_json)
            self.assertEqual(error_text, "validation timed out")
            written = list((Path(tmp) / "parse-failures").glob("*.txt"))
            self.assertEqual(len(written), 1)
            self.assertEqual(written[0].read_text(encoding="utf-8"), "some output")

    def test_two_failures_in_one_run_get_distinct_sequential_filenames(self) -> None:
        # A retried review can fail output validation twice (attempt 1, then
        # attempt 2 after recovering from a runtime crash but still failing
        # to parse) -- both must be preserved, not overwrite each other.
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "PATH": "/usr/bin:/bin"}
            with mock.patch.object(
                run_contributor.subprocess,
                "run",
                return_value=mock.Mock(returncode=1, stdout="", stderr="failed to parse output: bad"),
            ):
                run_contributor.validate_output("first attempt output", env)
                run_contributor.validate_output("second attempt output", env)

            written = sorted((Path(tmp) / "parse-failures").glob("*.txt"))
            self.assertEqual([f.name for f in written], ["0001-unparsed-output.txt", "0002-unparsed-output.txt"])
            self.assertEqual(written[0].read_text(encoding="utf-8"), "first attempt output")
            self.assertEqual(written[1].read_text(encoding="utf-8"), "second attempt output")

    def test_artifact_write_failure_is_swallowed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            blocker = Path(tmp) / "blocker"
            blocker.write_text("not a directory", encoding="utf-8")
            env = {"FACTORY_TELEMETRY_DIR": str(blocker / "telemetry")}
            # Must not raise even though the telemetry dir cannot be created.
            run_contributor._preserve_unparseable_output("raw output", env)

    def test_redacts_secrets_before_writing(self) -> None:
        secret = "SECRETVALUE12345"
        with tempfile.TemporaryDirectory() as tmp:
            env = {"FACTORY_TELEMETRY_DIR": tmp, "GH_TOKEN": secret}
            run_contributor._preserve_unparseable_output(f"leaked token: {secret}", env)

            written = (Path(tmp) / "parse-failures" / "0001-unparsed-output.txt").read_text(
                encoding="utf-8"
            )
            self.assertNotIn(secret, written)
            self.assertIn("[REDACTED]", written)


class ReviewActionRetryTests(unittest.TestCase):
    """#1179: reviews had a meaningful first-attempt failure rate with a
    near-100% rerun success rate; a bounded in-process retry should absorb
    that without a second GitHub Actions run (which is what #1202's daily
    cap and runaway guard actually count)."""

    def test_review_recovers_on_second_attempt_after_a_runtime_crash(self) -> None:
        with mock.patch.object(
            run_contributor, "run_claude", side_effect=[SystemExit(249), "---\naction: review_pr\n---\n"]
        ) as run_claude:
            with mock.patch.object(
                run_contributor, "validate_output", return_value=(0, '{"action": "review_pr"}', "")
            ) as validate_output:
                raw_output, exit_code, validated_json, error_text = run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

        self.assertEqual(run_claude.call_count, 2)
        self.assertEqual(validate_output.call_count, 1)
        self.assertEqual(exit_code, 0)
        self.assertEqual(validated_json, '{"action": "review_pr"}')
        self.assertEqual(raw_output, "---\naction: review_pr\n---\n")

    def test_review_recovers_on_second_attempt_after_a_parse_failure(self) -> None:
        with mock.patch.object(
            run_contributor, "run_claude", side_effect=["garbled first pass", "---\naction: review_pr\n---\n"]
        ) as run_claude:
            with mock.patch.object(
                run_contributor,
                "validate_output",
                side_effect=[(1, None, "failed to parse output"), (0, '{"action": "review_pr"}', "")],
            ) as validate_output:
                raw_output, exit_code, validated_json, error_text = run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

        self.assertEqual(run_claude.call_count, 2)
        self.assertEqual(validate_output.call_count, 2)
        self.assertEqual(exit_code, 0)
        self.assertEqual(validated_json, '{"action": "review_pr"}')

    def test_review_exhausts_retries_and_returns_the_last_failure(self) -> None:
        with mock.patch.object(run_contributor, "run_claude", side_effect=["a", "b"]):
            with mock.patch.object(
                run_contributor,
                "validate_output",
                side_effect=[(1, None, "first failure"), (1, None, "second failure")],
            ) as validate_output:
                raw_output, exit_code, validated_json, error_text = run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

        self.assertEqual(validate_output.call_count, 2)
        self.assertEqual(exit_code, 1)
        self.assertIsNone(validated_json)
        self.assertEqual(error_text, "second failure")
        self.assertEqual(raw_output, "b")

    def test_runtime_crash_on_the_final_attempt_propagates(self) -> None:
        with mock.patch.object(run_contributor, "run_claude", side_effect=SystemExit(249)):
            with self.assertRaises(SystemExit):
                run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

    def test_single_attempt_budget_never_retries(self) -> None:
        # Non-review selection kinds (advance_pr, execute_issue) are called
        # with max_attempts=1 by main() -- a single failure must not retry,
        # since those runs mutate a scratch workspace that a blind rerun
        # would layer edits onto rather than start clean.
        with mock.patch.object(run_contributor, "run_claude", return_value="raw") as run_claude:
            with mock.patch.object(
                run_contributor, "validate_output", return_value=(1, None, "boom")
            ) as validate_output:
                raw_output, exit_code, validated_json, error_text = run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=1,
                )

        self.assertEqual(run_claude.call_count, 1)
        self.assertEqual(validate_output.call_count, 1)
        self.assertEqual(exit_code, 1)

    def test_duplicate_proposal_short_circuits_without_retry(self) -> None:
        with mock.patch.object(run_contributor, "run_claude", return_value="raw") as run_claude:
            with mock.patch.object(
                run_contributor, "validate_output", return_value=(2, None, "duplicate: matches 'x'")
            ):
                raw_output, exit_code, validated_json, error_text = run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

        self.assertEqual(run_claude.call_count, 1)
        self.assertEqual(exit_code, 2)
        self.assertTrue(error_text.startswith("duplicate:"))

    def test_only_review_selection_kinds_get_the_retry_budget(self) -> None:
        for kind in ("review_pr", "review_followup_pr"):
            self.assertIn(kind, run_contributor.REVIEW_RETRYABLE_SELECTION_KINDS)
        for kind in ("advance_pr", "execute_claimed_issue", "execute_ready_issue", "comment_discussion", "propose"):
            self.assertNotIn(kind, run_contributor.REVIEW_RETRYABLE_SELECTION_KINDS)

    def test_retried_attempts_get_distinct_telemetry_phases(self) -> None:
        # #1179 codex review: both attempts previously used phase="action",
        # so their cost-telemetry rows got the identical id
        # (f"{run_id}-{run_attempt}-{phase}") and factory-cost-append.py's
        # id-dedup silently dropped the retry's real cost row. Confirms each
        # attempt now gets a distinct phase.
        with mock.patch.object(
            run_contributor, "run_claude", side_effect=[SystemExit(249), "---\naction: review_pr\n---\n"]
        ) as run_claude:
            with mock.patch.object(
                run_contributor, "validate_output", return_value=(0, '{"action": "review_pr"}', "")
            ):
                run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                )

        phases = [call.kwargs["phase"] for call in run_claude.call_args_list]
        self.assertEqual(phases, ["action", "action-retry-2"])
        self.assertEqual(len(set(phases)), len(phases))

        # Prove the distinctness where it actually matters: the cost row
        # telemetry.py builds from each phase, not just that the phase
        # strings differ syntactically.
        env = {"GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1"}
        row_ids = {run_contributor.build_cost_row("", phase, env)["id"] for phase in phases}
        self.assertEqual(len(row_ids), 2, f"expected 2 distinct cost-row ids, got {row_ids}")

    def test_review_attempts_use_the_tighter_retry_timeout(self) -> None:
        # Both attempts, not just the first -- a retry only helps if the
        # SECOND call also gets a timeout that leaves the job headroom.
        with mock.patch.object(
            run_contributor,
            "run_claude",
            side_effect=[SystemExit(249), "---\naction: review_pr\n---\n"],
        ) as run_claude:
            with mock.patch.object(
                run_contributor, "validate_output", return_value=(0, "{}", "")
            ):
                run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Read", cwd=Path("."),
                    write_scope=None, max_attempts=2,
                    timeout=run_contributor.REVIEW_RETRY_ATTEMPT_TIMEOUT_SECONDS,
                )

        self.assertEqual(run_claude.call_count, 2)
        for call in run_claude.call_args_list:
            self.assertEqual(
                call.kwargs["timeout"], run_contributor.REVIEW_RETRY_ATTEMPT_TIMEOUT_SECONDS
            )

    def test_non_retryable_runs_keep_the_default_uncapped_timeout(self) -> None:
        with mock.patch.object(run_contributor, "run_claude", return_value="raw") as run_claude:
            with mock.patch.object(run_contributor, "validate_output", return_value=(0, "{}", "")):
                run_contributor.run_action_phase(
                    "system", "task", {}, {}, mode="cli", tools="Edit", cwd=Path("."),
                    write_scope=None, max_attempts=1,
                )

        self.assertIsNone(run_claude.call_args.kwargs["timeout"])


class RouteActionCallDisciplineTests(unittest.TestCase):
    """#1179 codex review: the retry-helper-level tests above prove
    run_action_phase() never calls route_action() itself, but don't prove
    main() only calls it once end to end. This exercises main()'s directed
    (--message) path, which is the actual path factory-review-execute.yml
    invokes, and patches run_action_phase()/route_action() at the seam
    main() actually calls -- it does NOT itself simulate an internal retry
    (run_action_phase is mocked to return a value, not exercised); that's
    covered separately by ReviewActionRetryTests above. What this proves is
    narrower and complementary: no matter what run_action_phase returns or
    how many attempts it took to get there, main() calls it and
    route_action() each exactly once."""

    def _patched_env(self, tmp_path: str) -> dict[str, str]:
        return {
            "CLAUDE_CODE_OAUTH_TOKEN": "token",
            "GH_TOKEN": "token",
            "HOME": tmp_path,
            "PATH": "/usr/bin:/bin",
        }

    def test_main_calls_route_action_exactly_once_after_a_retried_success(self) -> None:
        pr = {
            "number": 42,
            "author": {"login": "workspace-agents"},
            "body": "",
            "authorAssociation": "OWNER",
            "reviews": {"nodes": []},
            "comments": {"nodes": []},
        }
        with tempfile.TemporaryDirectory() as tmp, tempfile.NamedTemporaryFile(
            "w", suffix=".md", delete=False
        ) as prompt_file:
            prompt_file.write("# April Clearwater\nsystem prompt\n")
            prompt_file.flush()
            with mock.patch.object(sys, "argv", [
                "run-contributor.py", "--prompt-file", prompt_file.name, "--mode", "cli",
                "--message", "@fairchild mentioned you in PR #42\n---\ndirected body\n---\n",
            ]):
                with mock.patch.dict(os.environ, self._patched_env(tmp), clear=True):
                    with mock.patch.object(run_contributor, "detect_bot_login", return_value=""):
                        with mock.patch.object(
                            run_contributor, "repo_owner_name", return_value=("fairchild", "workspaces")
                        ):
                            with mock.patch.object(run_contributor, "recent_commit_summary", return_value={}):
                                with mock.patch.object(run_contributor, "gather_backlog_state", return_value=""):
                                    with mock.patch.object(
                                        run_contributor, "fetch_detailed_pull_request", return_value=pr
                                    ):
                                        with mock.patch.object(
                                            run_contributor, "fetch_pr_diff", return_value=""
                                        ):
                                            with mock.patch.object(
                                                run_contributor,
                                                "run_action_phase",
                                                return_value=(
                                                    "raw", 0, '{"action": "review_pr", "pr_number": 42}', ""
                                                ),
                                            ) as run_action_phase:
                                                with mock.patch.object(
                                                    run_contributor, "route_action", return_value=0
                                                ) as route_action:
                                                    exit_code = run_contributor.main()

        self.assertEqual(exit_code, 0)
        self.assertEqual(run_action_phase.call_count, 1)
        self.assertEqual(route_action.call_count, 1)


class DirectedRevisionRoutingTests(unittest.TestCase):
    """#1125: a trusted workflow can direct April at her own PR to answer a
    blocking review. The pre-existing mention form must keep meaning `review
    this PR`, or the review lane starts pushing commits."""

    def test_requested_changes_form_routes_to_advance_pr(self) -> None:
        directed = run_contributor.parse_directed_message(
            "@fairchild requested changes on your PR #77\n---\nreview body\n---\n"
        )

        self.assertIsNotNone(directed)
        self.assertEqual(directed["number"], 77)
        self.assertEqual(directed["author"], "fairchild")
        self.assertEqual(directed["body"], "review body")
        self.assertEqual(
            run_contributor.DIRECTED_SELECTION_KINDS[str(directed["target_type"])],
            "advance_pr",
        )

    def test_mention_forms_keep_their_selection_kinds(self) -> None:
        for message, expected in (
            ("@fairchild mentioned you in PR #77", "review_pr"),
            ("@fairchild mentioned you in issue #42", "execute_ready_issue"),
        ):
            with self.subTest(message=message):
                directed = run_contributor.parse_directed_message(message)
                self.assertIsNotNone(directed)
                self.assertEqual(
                    run_contributor.DIRECTED_SELECTION_KINDS[str(directed["target_type"])],
                    expected,
                )

    def test_unrecognized_directed_message_is_still_rejected(self) -> None:
        self.assertIsNone(
            run_contributor.parse_directed_message("@fairchild please fix PR #77")
        )

    def test_pr_branch_checkout_falls_back_to_the_remote_branch(self) -> None:
        # The revise lane fetches origin/<pr_branch> and hands the runner a
        # default-branch checkout, so the local branch usually does not exist.
        attempted: list[list[str]] = []

        def fail_local_checkout(command, *, default, **_kwargs):
            attempted.append(command)
            return default

        with (
            mock.patch.object(run_contributor, "current_branch", return_value="main"),
            mock.patch.object(run_contributor, "run_optional", side_effect=fail_local_checkout),
            mock.patch.object(run_contributor, "run_checked") as run_checked,
        ):
            run_contributor.prepare_workspace_for_selection(
                "advance_pr", {"pr_branch": "codex/april-clearwater-issue-42-fix-it"}, {}
            )

        self.assertEqual(
            attempted[0], ["git", "checkout", "codex/april-clearwater-issue-42-fix-it"]
        )
        self.assertEqual(
            run_checked.call_args.args[0],
            [
                "git",
                "checkout",
                "-b",
                "codex/april-clearwater-issue-42-fix-it",
                "origin/codex/april-clearwater-issue-42-fix-it",
            ],
        )

    def _run_directed_main(
        self, message: str, pull_request: dict[str, object], action: dict[str, object]
    ):
        """Drive main()'s directed path with every network and model seam stubbed."""
        env = {
            "CLAUDE_CODE_OAUTH_TOKEN": "token",
            "GH_TOKEN": "token",
            "HOME": tempfile.gettempdir(),
            "PATH": "/usr/bin:/bin",
        }
        with tempfile.TemporaryDirectory() as scratch, tempfile.NamedTemporaryFile(
            "w", suffix=".md", delete=False
        ) as prompt_file:
            prompt_file.write("# April Clearwater\nsystem prompt\n")
            prompt_file.flush()
            workspace = run_contributor.ScratchPatchArtifact(
                temp_root=Path(scratch),
                baseline_dir=Path(scratch) / "baseline",
                scratch_dir=Path(scratch) / "scratch",
                changed_files=[],
                patch_text="",
            )
            with (
                mock.patch.object(sys, "argv", [
                    "run-contributor.py", "--prompt-file", prompt_file.name,
                    "--mode", "cli", "--message", message,
                ]),
                mock.patch.dict(os.environ, env, clear=True),
                mock.patch.object(run_contributor, "detect_bot_login", return_value="april-clearwater[bot]"),
                mock.patch.object(run_contributor, "repo_owner_name", return_value=("fairchild", "workspaces")),
                mock.patch.object(run_contributor, "recent_commit_summary", return_value={}),
                mock.patch.object(run_contributor, "gather_backlog_state", return_value=""),
                mock.patch.object(run_contributor, "fetch_detailed_pull_request", return_value=pull_request),
                mock.patch.object(run_contributor, "fetch_detailed_issue", return_value=None),
                mock.patch.object(run_contributor, "fetch_pr_diff", return_value=""),
                mock.patch.object(run_contributor, "prepare_workspace_for_selection") as prepare,
                mock.patch.object(run_contributor, "create_scratch_workspace", return_value=workspace) as create_scratch,
                mock.patch.object(run_contributor, "ensure_claude_project_trust"),
                mock.patch.object(run_contributor, "build_scratch_patch_artifact", return_value=workspace),
                mock.patch.object(run_contributor, "shutil"),
                mock.patch.object(
                    run_contributor,
                    "run_action_phase",
                    return_value=("raw", 0, json.dumps(action), ""),
                ) as run_action_phase,
                mock.patch.object(run_contributor, "route_action", return_value=0) as route_action,
            ):
                exit_code = run_contributor.main()
        return exit_code, prepare, create_scratch, run_action_phase, route_action

    def test_directed_revision_checks_out_the_pr_branch_before_the_turn(self) -> None:
        pull_request = {
            "number": 77,
            "author": {"login": "april-clearwater[bot]"},
            "authorAssociation": "NONE",
            "body": "Closes #42",
            "headRefName": "codex/april-clearwater-issue-42-fix-it",
            "reviews": {"nodes": [{"author": {"login": "workspace-agents[bot]"}, "body": "blocking", "state": "CHANGES_REQUESTED", "submittedAt": "2026-08-27T00:00:00Z"}]},
            "comments": {"nodes": [{"author": {"login": "fairchild"}, "body": "also worth noting", "createdAt": "2026-08-27T00:05:00Z"}]},
        }

        exit_code, prepare, create_scratch, run_action_phase, route_action = self._run_directed_main(
            "@fairchild requested changes on your PR #77",
            pull_request,
            {"action": "advance_pr", "pr_number": 77},
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(route_action.call_count, 1)
        selection_kind, selection_item, _ = prepare.call_args.args
        self.assertEqual(selection_kind, "advance_pr")
        self.assertEqual(selection_item["pr_branch"], "codex/april-clearwater-issue-42-fix-it")
        self.assertEqual(selection_item["issue_number"], 42)
        # The revision turn edits files, so it runs in the isolated scratch
        # with the write tools exposed.
        self.assertEqual(create_scratch.call_count, 1)
        self.assertEqual(
            run_action_phase.call_args.kwargs["tools"], run_contributor.EXECUTION_TOOLS
        )

    def test_directed_revision_payloads_carry_the_review_and_comment_feedback(self) -> None:
        pull_request = {
            "number": 77,
            "author": {"login": "april-clearwater[bot]"},
            "authorAssociation": "NONE",
            "body": "PR body text",
            "headRefName": "codex/april-clearwater-issue-42-fix-it",
            "reviews": {"nodes": [
                {"author": {"login": "workspace-agents[bot]"}, "body": "blocking finding", "state": "CHANGES_REQUESTED", "submittedAt": "2026-08-27T00:00:00Z"},
                {"author": {"login": "fairchild"}, "body": "worth noting", "state": "COMMENTED", "submittedAt": "2026-08-27T00:01:00Z"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "fairchild"}, "body": "one more thing", "createdAt": "2026-08-27T00:05:00Z"}
            ]},
        }

        with mock.patch.object(run_contributor, "fetch_detailed_pull_request", return_value=pull_request):
            _, payloads = run_contributor.build_action_phase_inputs(
                run_contributor.SelectionChoice(selection_kind="advance_pr", number=77),
                {"number": 77, "pr_branch": "codex/april-clearwater-issue-42-fix-it"},
                {
                    "owner": "fairchild",
                    "name": "workspaces",
                    "recent_commit_summary": {},
                    "backlog_state": "",
                },
                {"GITHUB_REPOSITORY": "fairchild/workspaces"},
                message="@fairchild requested changes on your PR #77",
            )

        bodies = {payload.source_type: payload.body for payload in payloads}
        # April answers the blocking review AND the non-blocking feedback, so
        # both have to reach her as untrusted payloads alongside the PR body.
        self.assertEqual(bodies["pull_request"], "PR body text")
        review_bodies = [p.body for p in payloads if p.source_type == "pull_request_review"]
        self.assertEqual(review_bodies, ["blocking finding", "worth noting"])
        self.assertIn("one more thing", bodies["pull_request_comment"])

    def test_directed_mention_run_stays_a_read_only_review(self) -> None:
        pull_request = {
            "number": 77,
            "author": {"login": "fairchild"},
            "authorAssociation": "OWNER",
            "body": "",
            "headRefName": "feature-branch",
            "reviews": {"nodes": []},
            "comments": {"nodes": []},
        }

        exit_code, prepare, create_scratch, run_action_phase, route_action = self._run_directed_main(
            "@fairchild mentioned you in PR #77",
            pull_request,
            {"action": "review_pr", "pr_number": 77},
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(prepare.call_args.args[0], "review_pr")
        # No branch checkout, no scratch, no write tools on a review run.
        self.assertEqual(create_scratch.call_count, 0)
        self.assertEqual(
            run_action_phase.call_args.kwargs["tools"], run_contributor.READ_ONLY_MODEL_TOOLS
        )


class RevisionTurnTests(unittest.TestCase):
    """#1125: FACTORY_REVISION_REVIEW_ID turns an advance into a revision turn
    — it may end without a commit, and it always ends with a marked comment or
    a non-zero exit. With the variable unset every path here is today's."""

    maxDiff = None

    PERSONA = "April Clearwater, Application Lead"
    BRANCH = "codex/april-clearwater-issue-42-fix-it"
    REVIEW_ID = "9001"
    LIVE_HEAD = "0123456789abcdef0123456789abcdef01234567"
    MODEL_BODY = (
        "## Summary\n- Rewrote the sheet's status mapping\n\n"
        "## Validation\n- `swift test --filter SheetTests`\n\n"
        "## Risks\n- None beyond the sheet\n"
    )

    def _data(self, body: str | None = None) -> dict[str, object]:
        return {
            "action": "advance_pr",
            "persona": self.PERSONA,
            "issue_number": 42,
            "pr_number": 77,
            "pr_title": "Fix environment status colors",
            "commit_message": "Address review feedback",
            "body": self.MODEL_BODY if body is None else body,
        }

    def _state(self) -> dict[str, object]:
        return {
            "issue": {"number": 42, "title": "Fix it", "body": ""},
            "approved": True,
            "approval_reason": "ready label present",
            "blockers": [],
            "requested_evidence": [],
            "latest_claim": None,
            "stale_claim": False,
            "own_pr": {"number": 77, "headRefName": self.BRANCH, "agent": "april-clearwater"},
            "other_pr": None,
        }

    def _rendered_pr_body(self, data: dict[str, object]) -> str:
        execution = sys.modules["execution"]
        summary, _ = execution.build_execution_summary_body(data, requested_evidence=[])
        seeded = execution.seed_mergeability_section(summary, changed_files=[])
        return execution.compose_pr_body(42, self.PERSONA, seeded)

    def _route(
        self,
        *,
        dirty: bool,
        live_body: str,
        data: dict[str, object] | None = None,
        revision: bool = True,
        head_current: bool = True,
        comment_posts: bool = True,
    ):
        execution = sys.modules["execution"]
        data = data or self._data()
        env = {"GH_TOKEN": "token", "GITHUB_REPOSITORY": "fairchild/workspaces"}
        if revision:
            env["FACTORY_REVISION_REVIEW_ID"] = self.REVIEW_ID
            env["FACTORY_EXPECTED_PR_HEAD_SHA"] = self.LIVE_HEAD
        commands: list[list[str]] = []
        comments: list[str] = []

        def fake_run_checked(command, **_kwargs):
            commands.append(command)
            if command[:2] == ["git", "rev-parse"]:
                return mock.Mock(stdout=f"{self.LIVE_HEAD}\n")
            return mock.Mock(stdout="")

        def fake_run_optional(command, *, default, **_kwargs):
            if command[:3] == ["gh", "pr", "comment"]:
                comments.append(command[command.index("--body") + 1])
                return "https://github.com/fairchild/workspaces/pull/77#issuecomment-1" if comment_posts else default
            if command[:2] == ["gh", "api"]:
                return json.dumps(
                    {
                        "id": int(self.REVIEW_ID),
                        "user": {"login": "workspace-agents[bot]"},
                        "html_url": "https://github.com/fairchild/workspaces/pull/77#pullrequestreview-9001",
                    }
                )
            return default

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            output_path = handle.name
        try:
            with (
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": output_path}),
                mock.patch.object(execution, "detect_bot_login", return_value="april-clearwater[bot]"),
                mock.patch.object(execution, "find_issue_execution_state", return_value=self._state()),
                mock.patch.object(execution, "current_branch", return_value=self.BRANCH),
                mock.patch.object(execution, "working_tree_dirty", return_value=dirty),
                mock.patch.object(execution, "_changed_surface_files", return_value=[]),
                mock.patch.object(execution, "_pr_body_and_head", return_value=(live_body, self.LIVE_HEAD)),
                mock.patch.object(execution, "_factory_expected_pr_head_is_current", return_value=head_current),
                mock.patch.object(execution, "ensure_label_exists"),
                mock.patch.object(execution, "run_checked", side_effect=fake_run_checked),
                mock.patch.object(execution, "run_optional", side_effect=fake_run_optional),
            ):
                exit_code = execution.route_execution_action(data, env, require_existing_pr=True)
            outputs = dict(
                line.split("=", 1)
                for line in Path(output_path).read_text(encoding="utf-8").splitlines()
                if "=" in line
            )
        finally:
            os.unlink(output_path)
        return exit_code, commands, comments, outputs

    def test_body_only_revision_edits_the_pr_without_committing(self) -> None:
        exit_code, commands, comments, outputs = self._route(dirty=False, live_body="stale body")

        self.assertEqual(exit_code, 0)
        self.assertEqual(outputs["revision_outcome"], "body-only")
        self.assertEqual(outputs["revision_comment_posted"], "true")
        self.assertEqual(outputs["pr_head_sha"], self.LIVE_HEAD)
        edits = [c for c in commands if c[:3] == ["gh", "pr", "edit"]]
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0][edits[0].index("--title") + 1], "Fix environment status colors")
        self.assertIn("Rewrote the sheet's status mapping", edits[0][edits[0].index("--body") + 1])
        self.assertFalse(any(c[:2] == ["git", "commit"] for c in commands))
        self.assertFalse(any(c[:2] == ["git", "push"] for c in commands))
        self.assertEqual(len(comments), 1)

    def test_identical_body_escalates_to_the_owner(self) -> None:
        data = self._data(
            "## Summary\n- The review asks to change the linked issue's scope, "
            "which I cannot decide.\n"
        )
        exit_code, commands, comments, outputs = self._route(
            dirty=False, live_body=self._rendered_pr_body(data), data=data
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(outputs["revision_outcome"], "needs-owner")
        self.assertEqual(outputs["revision_comment_posted"], "true")
        self.assertFalse(any(c[:3] == ["gh", "pr", "edit"] for c in commands))
        self.assertFalse(any(c[:2] == ["git", "commit"] for c in commands))
        escalation = comments[0]
        self.assertIn("**This needs @fairchild**", escalation)
        self.assertIn("change the linked issue's scope", escalation)
        # No marker: the deterministic escalation that carries one is the
        # lane's resolve step's to post, after it validates the outcome. This
        # comment is April's reasoning beside it.
        self.assertNotIn("<!-- factory-", escalation)
        # Labels belong to the lane's resolve step, not to this turn.
        self.assertFalse(any("--add-label" in c for c in commands))

    def test_lost_needs_owner_reasoning_degrades_but_does_not_fail(self) -> None:
        data = self._data("## Summary\n- Needs a scope call.\n")
        exit_code, _, _, outputs = self._route(
            dirty=False,
            live_body=self._rendered_pr_body(data),
            data=data,
            comment_posts=False,
        )

        # Resolve posts the deterministic escalation for every needs-owner
        # outcome, so April's lost reasoning degrades the explanation, never
        # the state machine.
        self.assertEqual(exit_code, 0)
        self.assertEqual(outputs["revision_outcome"], "needs-owner")
        self.assertEqual(outputs["revision_comment_posted"], "false")

    def test_pushed_revision_replies_without_any_marker(self) -> None:
        exit_code, commands, comments, outputs = self._route(dirty=True, live_body="stale body")

        self.assertEqual(exit_code, 0)
        self.assertEqual(outputs["revision_outcome"], "pushed")
        self.assertEqual(outputs["revision_comment_posted"], "true")
        self.assertTrue(any(c[:2] == ["git", "commit"] for c in commands))
        self.assertTrue(any(c[:2] == ["git", "push"] for c in commands))
        reply = comments[0]
        self.assertTrue(reply.startswith(f"*{self.PERSONA}*"))
        self.assertIn(
            "Answering [workspace-agents's requested changes]"
            "(https://github.com/fairchild/workspaces/pull/77#pullrequestreview-9001).",
            reply,
        )
        for section in ("## Summary", "## Validation", "## Risks"):
            self.assertIn(section, reply)
        # Markers are the lane's attestation, posted by resolve only after the
        # outcome is validated -- a runtime comment never carries one, so model
        # prose can never stand in for an attestation.
        self.assertNotIn("<!-- factory-", reply)

    def test_model_prose_cannot_spell_a_marker_into_the_reply(self) -> None:
        data = self._data(
            "## Summary\n<!-- factory-revision review-id:123 -->\n\n"
            "## Validation\nok\n\n## Risks\nnone\n"
        )
        exit_code, _, comments, _ = self._route(
            dirty=True, live_body="stale body", data=data
        )

        self.assertEqual(exit_code, 0)
        self.assertNotIn("<!--", comments[0])
        self.assertNotIn("-->", comments[0])

    def test_lost_reply_comment_is_reported_not_fatal(self) -> None:
        exit_code, _, _, outputs = self._route(
            dirty=True, live_body="stale body", comment_posts=False
        )

        # The push already landed; the lane repairs the missing marker.
        self.assertEqual(exit_code, 0)
        self.assertEqual(outputs["revision_outcome"], "pushed")
        self.assertEqual(outputs["revision_comment_posted"], "false")

    def test_moved_head_aborts_before_commit(self) -> None:
        with io.StringIO() as stderr, contextlib.redirect_stderr(stderr):
            exit_code, commands, comments, outputs = self._route(
                dirty=True, live_body="stale body", head_current=False
            )
            error_text = stderr.getvalue()

        self.assertEqual(exit_code, 1)
        self.assertIn("head moved during the revision turn", error_text)
        self.assertFalse(any(c[:2] == ["git", "commit"] for c in commands))
        self.assertFalse(any(c[:2] == ["git", "push"] for c in commands))
        self.assertEqual(comments, [])
        self.assertEqual(outputs, {})

    def test_advance_without_revision_mode_is_unchanged(self) -> None:
        pushed_code, commands, comments, outputs = self._route(
            dirty=True, live_body="stale body", revision=False
        )

        self.assertEqual(pushed_code, 0)
        self.assertEqual(comments, [])
        self.assertNotIn("revision_outcome", outputs)
        self.assertNotIn("revision_comment_posted", outputs)
        self.assertTrue(any(c[:2] == ["git", "push"] for c in commands))

        with io.StringIO() as stderr, contextlib.redirect_stderr(stderr):
            empty_code, commands, comments, outputs = self._route(
                dirty=False, live_body="stale body", revision=False
            )
            error_text = stderr.getvalue()

        # Outside revision mode an empty scratch is still a failed run.
        self.assertEqual(empty_code, 1)
        self.assertIn("no file changes were made", error_text)
        self.assertEqual(comments, [])
        self.assertEqual(outputs, {})


if __name__ == "__main__":
    unittest.main()
