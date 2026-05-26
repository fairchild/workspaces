#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Regression tests for the workflow and Lume security hardening."""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import tomllib
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
        self.assertIn("privileged_patch_approved:", workflow)
        self.assertIn("--allow-privileged-patches", workflow)

    def test_codespaces_claude_worker_is_break_glass_ref_gated(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/codespaces-claude-worker.yml").read_text()
        self.assertIn("environment:\n      name: codespaces-claude-break-glass", workflow)
        self.assertIn("allow_ref_override:", workflow)
        self.assertIn("Break-glass ref override enabled", workflow)
        self.assertIn('[[ "$WORKER_REF" == "main" ]]', workflow)
        self.assertIn('[[ "$WORKER_REF" == refs/* ]]', workflow)
        self.assertIn('git ls-remote --exit-code --heads origin "$WORKER_REF"', workflow)

    def test_public_content_agent_triggers_do_not_receive_privileged_secrets(self) -> None:
        privileged_secrets = (
            "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_API_KEY",
            "APRIL_PRIVATE_KEY",
            "WORKSPACE_AGENTS_PRIVATE_KEY",
            "EVIDENCE_UPLOAD_TOKEN",
            "CODESPACES_WORKER_GITHUB_TOKEN",
        )
        public_content_triggers = (
            "issue_comment:",
            "pull_request_review_comment:",
            "pull_request_review:",
            "types: [opened, assigned]",
        )
        workflows_dir = REPO_ROOT / ".github/workflows"
        for wf in sorted(workflows_dir.glob("agent-*.yml")):
            workflow = wf.read_text()
            on_block = workflow.split("\npermissions:\n", 1)[0]
            if not any(trigger in on_block for trigger in public_content_triggers):
                continue
            for secret_name in privileged_secrets:
                self.assertNotIn(
                    secret_name,
                    workflow,
                    f"{wf.name} must not expose {secret_name} from public content triggers",
                )

    def test_all_actions_pinned_to_sha(self) -> None:
        """Every `uses:` reference to a third-party action must be pinned to a full SHA."""
        workflows_dir = REPO_ROOT / ".github/workflows"
        floating_refs: list[str] = []
        uses_pattern = re.compile(r"^\s*(?:-\s*)?uses:\s+(?!\./)(\S+)@(\S+)")
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

    def test_pull_request_ci_uses_github_hosted_runner(self) -> None:
        """Untrusted PR code must not run on persistent self-hosted macOS runners."""
        workflow = (REPO_ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("pull_request:", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertNotIn("runs-on: [self-hosted, lume-macos]", workflow)

    def test_ci_fallback_uses_github_hosted_runner(self) -> None:
        """Failed PR fallback must not execute untrusted commits on self-hosted runners."""
        workflow = (REPO_ROOT / ".github/workflows/ci-fallback.yml").read_text()
        self.assertIn("workflow_run:", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertNotIn("runs-on: [self-hosted, lume-macos]", workflow)
        self.assertNotIn("runs-on: [self-hosted, signing-host]", workflow)

    def test_release_workflow_does_not_export_secrets_job_wide(self) -> None:
        """Generated and notarization secrets must not be written into GITHUB_ENV."""
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("::add-mask::$KEYCHAIN_PASSWORD", workflow)
        self.assertIn("environment: release", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("publish-github-release:", workflow)
        self.assertIn("validate-published-release-assets:", workflow)
        self.assertIn("gh release download", workflow)
        self.assertIn("xcrun stapler validate", workflow)
        self.assertIn("spctl --assess", workflow)
        self.assertIn("APPLE_API_KEY_BASE64", workflow)
        self.assertIn("APPLE_API_KEY_ID", workflow)
        self.assertIn("APPLE_API_ISSUER_ID", workflow)
        self.assertIn("security delete-keychain \"$KEYCHAIN_PATH\"", workflow)
        self.assertIn("${CERT_PATH:-}", workflow)
        self.assertIn("${PROFILE_PATH:-}", workflow)
        self.assertIn("${APPLE_API_KEY_PATH:-}", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("permissions:\n      contents: write", workflow)
        for forbidden in (
            'echo "KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD" >> "$GITHUB_ENV"',
            'echo "KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"',
            'echo "CODESIGN_KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"',
            'echo "PROVISIONING_PROFILE_PATH=$PROFILE_PATH" >> "$GITHUB_ENV"',
            'echo "APP_PASSWORD=$APPLE_APP_PASSWORD" >> "$GITHUB_ENV"',
            'echo "APPLE_ID=$APPLE_ID" >> "$GITHUB_ENV"',
            'echo "TEAM_ID=$APPLE_TEAM_ID" >> "$GITHUB_ENV"',
            'echo "APPLE_API_KEY_PATH=$API_KEY_PATH" >> "$GITHUB_ENV"',
            'echo "APPLE_API_KEY_ID=$APPLE_API_KEY_ID" >> "$GITHUB_ENV"',
            'echo "APPLE_API_ISSUER_ID=$APPLE_API_ISSUER_ID" >> "$GITHUB_ENV"',
        ):
            self.assertNotIn(forbidden, workflow)

    def test_release_workflow_fails_closed_when_mise_is_missing(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("mise is required on the signing host", workflow)
        self.assertIn("exit 1", workflow)
        self.assertNotIn("brew install mise", workflow)

    def test_mise_configs_keep_trust_surface_small(self) -> None:
        allowed = {
            REPO_ROOT / ".mise.toml",
            REPO_ROOT / "web/.mise.toml",
        }
        configs = {
            path
            for path in REPO_ROOT.rglob(".mise.toml")
            if "node_modules" not in path.parts and ".git" not in path.parts
        }
        self.assertEqual(configs, allowed)

        forbidden = re.compile(
            r"(?m)(^\s*\[(env|hooks)\]\s*$|trusted_config_paths|^\s*(yes|ci)\s*=\s*true\s*(#.*)?$|_[.](source|file)\s*=)"
        )
        for config in configs:
            body = config.read_text()
            self.assertIsNone(forbidden.search(body), config)

        root_mise = tomllib.loads((REPO_ROOT / ".mise.toml").read_text())
        self.assertTrue(root_mise["settings"]["lockfile"])

    def test_mise_lock_pins_zig_for_ci_platforms(self) -> None:
        lock_path = REPO_ROOT / "mise.lock"
        self.assertTrue(lock_path.exists())
        lock = tomllib.loads(lock_path.read_text())
        zig_entries = lock["tools"]["zig"]
        self.assertEqual(len(zig_entries), 1)
        zig = zig_entries[0]
        self.assertEqual(zig["version"], "0.15.2")
        self.assertEqual(zig["backend"], "core:zig")
        for platform in ("linux-x64", "macos-arm64"):
            entry = zig[f"platforms.{platform}"]
            self.assertRegex(entry["checksum"], r"^sha256:[a-f0-9]{64}$")
            self.assertTrue(entry["url"].startswith("https://"))

    def test_mise_invocations_are_locked_and_pinned(self) -> None:
        verify_mise = (REPO_ROOT / "scripts/verify-mise-security.sh").read_text()
        self.assertIn("MISE_EXPECTED_VERSION=\"v2026.5.15\"", verify_mise)
        self.assertIn("verify_locked_zig_exec", verify_mise)
        self.assertIn("github.com/repos/jdx/mise/releases/latest", verify_mise)
        self.assertIn("SHASUMS256.txt", verify_mise)

        build_ghosttykit = (REPO_ROOT / "scripts/build-ghosttykit.sh").read_text()
        self.assertIn('mise exec --locked "zig@$ZIG_VERSION" -- zig', build_ghosttykit)
        self.assertIn("MISE_CONFIG_FILE=$PROJECT_DIR/.mise.toml", build_ghosttykit)
        self.assertIn("MISE_CONFIG_ROOT=$PROJECT_DIR", build_ghosttykit)
        self.assertIn("MISE_IGNORED_CONFIG_PATHS=$HOME/.config/mise", build_ghosttykit)

        setup = (REPO_ROOT / "scripts/setup").read_text()
        self.assertIn('"$REPO_ROOT/.mise.toml"|"$REPO_ROOT/web/.mise.toml"', setup)
        self.assertIn('if [[ "$FAST" == "1" ]]', setup)
        self.assertIn("mise install --locked zig@0.15.2", setup)
        self.assertIn("MISE_IGNORED_CONFIG_PATHS=", setup)
        self.assertIn('-path "*/.pnpm-store" -prune', setup)
        self.assertNotIn("trust every checked-in project config", setup)

        conductor = json.loads((REPO_ROOT / "conductor.json").read_text())
        self.assertIn("./scripts/setup --fast", conductor["scripts"]["setup"])

        web_npmrc = (REPO_ROOT / "web/.npmrc").read_text()
        self.assertIn("enable-global-virtual-store=true", web_npmrc)

        sandbox = (REPO_ROOT / "web/src/lib/agent-runtime/vercel-sandbox.ts").read_text()
        self.assertIn("MISE_VERSION='v2026.5.15'", sandbox)
        self.assertIn(
            "MISE_SHA256='a86aa65c8ca48a548c3f9904853489383bb8cdebfd8f2cf8ddd18b675e03bbf4'",
            sandbox,
        )
        self.assertIn("sha256sum -c -", sandbox)
        self.assertNotIn("mise-latest-linux-x64", sandbox)

    def test_mise_security_workflow_runs_for_mise_changes(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/mise-security.yml").read_text()
        self.assertIn("name: Mise Security", workflow)
        self.assertIn("scripts/verify-mise-security.sh", workflow)
        for expected_path in (
            ".mise.toml",
            "web/.mise.toml",
            "mise.lock",
            "scripts/setup",
            "scripts/build-ghosttykit.sh",
            "scripts/verify-mise-security.sh",
            "web/src/lib/agent-runtime/vercel-sandbox.ts",
        ):
            self.assertIn(expected_path, workflow)

    def test_release_workflow_publishes_and_validates_manifest_and_appcast_signature(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text()
        for expected in (
            "release-manifest.json",
            "scripts/verify-sparkle-appcast.swift",
            "scripts/release-manifest.sh generate",
            "scripts/release-manifest.sh validate",
            "COMMITTED_SPARKLE_PUBLIC_KEY",
            "SUPublicEDKey",
            "--sparkle-public-key \"$COMMITTED_SPARKLE_PUBLIC_KEY\"",
        ):
            self.assertIn(expected, workflow)

    def test_release_change_validator_covers_release_manifest_and_appcast_verifier(self) -> None:
        validator = (REPO_ROOT / "scripts/validate-release-changes.py").read_text()
        self.assertIn('"scripts/release-manifest.sh"', validator)
        self.assertIn('"scripts/verify-sparkle-appcast.swift"', validator)
        self.assertIn("validate_swift_parse", validator)

    def test_web_terminal_status_does_not_return_direct_ttyd_urls(self) -> None:
        status_route = (REPO_ROOT / "web/src/app/api/terminal/status/route.ts").read_text()
        ticket_route = (REPO_ROOT / "web/src/app/api/terminal/ticket/route.ts").read_text()
        terminal_canvas = (REPO_ROOT / "web/src/app/dashboard/components/terminal-canvas.tsx").read_text()

        self.assertNotIn("terminalUrl: state.terminalUrl", status_route)
        self.assertIn('terminalAccess: state.terminalUrl ? "ticket" : undefined', status_route)
        self.assertIn("issueTerminalTicket", ticket_route)
        self.assertIn("consumeTerminalTicket", ticket_route)
        self.assertIn('fetch("/api/terminal/ticket"', terminal_canvas)

    def test_pr_reviewer_limits_github_credentials_to_repository_resource(self) -> None:
        reviewer = (REPO_ROOT / "web/src/lib/agent-runtime/pr-review.ts").read_text()
        self.assertNotIn(".github-token", reviewer)
        self.assertNotIn('networking: { type: "unrestricted" }', reviewer)
        self.assertIn("authorization_token: githubToken", reviewer)
        self.assertIn("short-lived GitHub App installation token", reviewer)
        self.assertIn(
            "do not look for environment variables or files containing GitHub credentials",
            reviewer,
        )
        self.assertIn(
            "server-side broker is the only component that may post the review or labels",
            reviewer,
        )

    def test_pr_reviewer_ingress_canary_is_hmac_and_secret_gated(self) -> None:
        route = (REPO_ROOT / "web/src/app/api/webhooks/github/route.ts").read_text()
        monitor = (
            REPO_ROOT / "web/src/app/api/webhooks/github/pr-reviewer-monitor/route.ts"
        ).read_text()
        broker = (
            REPO_ROOT / "web/src/app/api/webhooks/github/pr-reviewer-broker/route.ts"
        ).read_text()
        runs = (REPO_ROOT / "web/src/lib/agent-runtime/pr-review-runs.ts").read_text()
        route_test = (REPO_ROOT / "web/src/app/api/webhooks/github/route.test.ts").read_text()
        worker = (REPO_ROOT / "infra/cloudflare-webhook-relay/src/index.ts").read_text()
        workflow = (REPO_ROOT / ".github/workflows/managed-reviewer-ingress.yml").read_text()
        broker_workflow = (
            REPO_ROOT / ".github/workflows/managed-reviewer-broker.yml"
        ).read_text()
        cd_workflow = (REPO_ROOT / ".github/workflows/cd.yml").read_text()
        canary_script = (REPO_ROOT / "scripts/managed-reviewer-ingress-canary.py").read_text()
        broker_script = (REPO_ROOT / "scripts/pr-reviewer-broker.py").read_text()

        for source in (
            route,
            monitor,
            broker,
            worker,
            workflow,
            broker_workflow,
            cd_workflow,
            canary_script,
            broker_script,
        ):
            self.assertIn("WORKSPACES_WEBHOOK_CANARY_SECRET", source)

        self.assertIn("validateCanaryRequest", route)
        self.assertIn("verifySignature(body, signature)", route)
        self.assertLess(
            route.index("verifySignature(body, signature)"),
            route.index("validateCanaryRequest(request.headers)"),
        )
        self.assertIn("pushEvent).not.toHaveBeenCalled", route_test)
        self.assertIn("triggerPrReview).not.toHaveBeenCalled", route_test)

        self.assertIn("/canary/pr-review-ingress", worker)
        self.assertIn("signGitHubSignature", worker)
        self.assertIn("allowedForwardUrl", worker)
        self.assertIn("managed_pr_review_runs", runs)
        self.assertIn("listRecentPrReviewRuns", monitor)
        self.assertIn("processPendingPrReviewRuns", broker)
        self.assertIn("pr-reviewer-broker", canary_script)
        self.assertIn("pr-reviewer-monitor", canary_script)
        self.assertIn("scripts/managed-reviewer-ingress-canary.py", workflow)
        self.assertIn("scripts/managed-reviewer-ingress-canary.py", cd_workflow)
        self.assertNotIn("python3 - <<", workflow)
        self.assertNotIn("python3 - <<", cd_workflow)
        self.assertIn("Managed reviewer ingress canary", cd_workflow)
        self.assertIn("canary-secret-preflight", cd_workflow)
        self.assertIn("managed-reviewer-canary-preflight", cd_workflow)
        self.assertIn("Managed reviewer ingress canary before promotion", cd_workflow)
        self.assertIn("pre-prod-managed-reviewer-ingress-findings", cd_workflow)
        self.assertIn(
            "WORKSPACES_WEBHOOK_CANARY_SECRET is required before production promotion",
            cd_workflow,
        )
        self.assertIn("managed-reviewer-ingress-canary.log", cd_workflow)
        self.assertIn("bun run test:e2e", workflow)
        self.assertIn("wrangler deploy --dry-run", workflow)
        self.assertIn("urllib.request", canary_script)
        self.assertIn("SAFE_RESPONSE_KEYS", canary_script)
        self.assertIn("scripts/pr-reviewer-broker.py", broker_workflow)
        self.assertIn("schedule:", broker_workflow)
        self.assertNotIn("scripts/managed-reviewer-ingress-canary.py", broker_workflow)
        self.assertNotIn("pr-reviewer-monitor", broker_workflow)
        self.assertIn("pr-reviewer-broker", broker_script)
        self.assertIn("Authorization", broker_script)
        self.assertNotIn("pr-reviewer-monitor", broker_script)
        self.assertNotIn("canary/pr-review-ingress", broker_script)

        result = subprocess.run(
            ["python3", "scripts/managed-reviewer-ingress-canary.py", "--skip-monitor"],
            cwd=REPO_ROOT,
            env={key: value for key, value in os.environ.items() if key != "WORKSPACES_WEBHOOK_CANARY_SECRET"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WORKSPACES_WEBHOOK_CANARY_SECRET is required", result.stderr)

    def test_sparkle_appcast_verifier_accepts_valid_ed25519_signature(self) -> None:
        if shutil.which("swift") is None:
            self.skipTest("swift is required for Sparkle appcast verifier")

        # RFC 8032 Ed25519 test vector 1: signature for an empty message.
        public_key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
        signature = (
            "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7"
            "rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            dmg = tmp / "WorkSpaces-9.9.9.dmg"
            appcast = tmp / "appcast.xml"
            dmg.write_bytes(b"")
            appcast.write_text(
                f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>999</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <enclosure url="https://example.com/WorkSpaces-9.9.9.dmg" sparkle:edSignature="{signature}" length="0" />
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "./scripts/verify-sparkle-appcast.swift",
                    "--appcast",
                    str(appcast),
                    "--dmg",
                    str(dmg),
                    "--public-key",
                    public_key,
                    "--expected-url",
                    "https://example.com/WorkSpaces-9.9.9.dmg",
                    "--expected-version",
                    "999",
                    "--expected-short-version",
                    "9.9.9",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_manifest_script_validates_hash_bound_assets(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            app = tmp / "WorkSpaces.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            info = {
                "CFBundleIdentifier": "com.cloudcompute.workspaces",
                "SUPublicEDKey": "2iJCG30PnNC42c7NxxsMNFup+mnlKOU2/MZMEwm6lg4=",
            }
            with (contents / "Info.plist").open("wb") as f:
                plistlib.dump(info, f)

            dmg = tmp / "WorkSpaces-9.9.9.dmg"
            latest = tmp / "WorkSpaces-latest.dmg"
            appcast = tmp / "appcast.xml"
            manifest = tmp / "release-manifest.json"
            dmg.write_bytes(b"dmg")
            latest.write_bytes(b"dmg")
            appcast.write_text("<rss />", encoding="utf-8")

            generate = subprocess.run(
                [
                    "./scripts/release-manifest.sh",
                    "generate",
                    "--output",
                    str(manifest),
                    "--commit",
                    "abc123",
                    "--tag",
                    "v9.9.9",
                    "--version",
                    "9.9.9",
                    "--build",
                    "999",
                    "--app",
                    str(app),
                    "--dmg",
                    str(dmg),
                    "--latest-dmg",
                    str(latest),
                    "--appcast",
                    str(appcast),
                    "--team-id",
                    "LKVN4J3C6C",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(generate.returncode, 0, generate.stderr)

            validate = subprocess.run(
                [
                    "./scripts/release-manifest.sh",
                    "validate",
                    "--manifest",
                    str(manifest),
                    "--commit",
                    "abc123",
                    "--tag",
                    "v9.9.9",
                    "--version",
                    "9.9.9",
                    "--build",
                    "999",
                    "--dmg",
                    str(dmg),
                    "--latest-dmg",
                    str(latest),
                    "--appcast",
                    str(appcast),
                    "--bundle-id",
                    "com.cloudcompute.workspaces",
                    "--team-id",
                    "LKVN4J3C6C",
                    "--sparkle-public-key",
                    "2iJCG30PnNC42c7NxxsMNFup+mnlKOU2/MZMEwm6lg4=",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(validate.returncode, 0, validate.stderr)

    def test_release_setup_uses_app_store_connect_api_key_notarization(self) -> None:
        """Release setup should configure App Store Connect API-key notarization."""
        setup_script = (REPO_ROOT / "scripts/setup-release-secrets.sh").read_text()
        signing_template = (REPO_ROOT / "scripts/signing-config.sh.template").read_text()
        releasing_doc = (REPO_ROOT / "RELEASING.md").read_text()

        for content in (setup_script, signing_template, releasing_doc):
            self.assertIn("APPLE_API_KEY_ID", content)
            self.assertIn("APPLE_API_ISSUER_ID", content)
            self.assertNotIn("APPLE_APP_PASSWORD", content)
            self.assertNotIn("--app-password", content)

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
