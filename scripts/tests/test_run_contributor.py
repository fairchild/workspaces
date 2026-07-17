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


if __name__ == "__main__":
    unittest.main()
