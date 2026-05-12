# Security Critical Path Notes

This is an implementation note for repo operators and reviewers. It documents
mechanical controls that are now enforced in code, tests, or workflows; it is
not a broad public security stance.

## Hosted Compute

- Production agent runtime config fails closed when required compute/auth inputs
  are absent: `ALLOWED_AGENT_LOGINS`, `BETTER_AUTH_SECRET`,
  `TTYD_TOKEN_SECRET`, provider credentials, and PR reviewer app credentials
  when the reviewer is explicitly enabled.
- Terminal compute remains allowlisted by GitHub login.
- User-facing terminal shells do not receive the deployment
  `ANTHROPIC_API_KEY` unless `TERMINAL_ANTHROPIC_API_KEY=1` is set.
- `/api/terminal/status` does not return direct ttyd WebSocket URLs. The UI
  requests a short-lived one-time ticket and redeems it through
  `/api/terminal/ticket` before opening the WebSocket.

## Agent Automation

- Public mention triage workflows do not receive privileged model, GitHub App,
  evidence, or release secrets.
- Agent executor jobs remain maintainer-label gated with `safe-to-run-agent`.
- Agent-generated patches touching repo-control, release/signing, auth/token,
  sandbox, or infra secret paths require `privileged-agent-patch` or an explicit
  break-glass workflow input.
- The Codespaces Claude worker is protected by the
  `codespaces-claude-break-glass` environment and defaults to `main` or
  owner-repository branches.
- The managed PR reviewer no longer mounts a GitHub write token into the agent
  workspace. It produces a structured review intent, and the server-side broker
  validates and posts the GitHub review with the App token.

## Release And Update Chain

- Release signing stays on `[self-hosted, signing-host]` behind the protected
  `release` environment.
- The signing job has read-only repository permissions; publication is isolated
  in a separate `contents: write` job.
- The signing workflow fails closed if required host tools such as `mise` are
  missing instead of installing them live.
- Cleanup removes decoded certificate, provisioning profile, App Store Connect
  API key, and temporary keychain artifacts in `always()`.
- Sparkle appcasts are verified cryptographically against `SUPublicEDKey` and
  the published DMG.
- `release-manifest.json` binds commit SHA, tag, version/build, bundle id, team
  id, Sparkle public key, and artifact hashes/sizes.
- mise tool resolution is locked for the pinned Zig toolchain, setup only trusts
  the reviewed root/web configs, and hosted agent sandboxes verify the pinned
  mise binary checksum before use. See [mise Security](./mise-security.md).

## Operator Checks

Run these before merging security/release changes:

```bash
uv run --script scripts/test_security_hardening.py
uv run --script scripts/audit-security-posture.py --local-only --strict
```

When `gh` is authenticated, run the remote posture audit before releases:

```bash
uv run --script scripts/audit-security-posture.py --repo fairchild/workspaces --strict
```

## Explicit Follow-Ups

- Move PR-review broker execution to a durable queue if Vercel post-response
  execution proves too short for unusually long managed-agent reviews.
- Consider a true WebSocket proxy for terminal access so the browser never sees
  the final ttyd URL after ticket redemption.
- Keep dependency overrides current and remove them when upstream patched
  versions resolve cleanly.
