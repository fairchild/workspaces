# Security Critical Path Notes

This is an implementation note for repo operators and reviewers. It documents
mechanical controls that are now enforced in code, tests, or workflows; it is
not a broad public security stance.

## Hosted Compute

- Production agent runtime config fails closed when required compute/auth inputs
  are absent: `ALLOWED_AGENT_LOGINS`, `BETTER_AUTH_SECRET`,
  `TTYD_TOKEN_SECRET`, and provider credentials.
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

## Release And Update Chain

- Release signing runs on hosted `macos-15` behind the protected `release`
  environment. Every credential is scoped to that environment rather than to the
  repository, so a job must declare `environment: release` and clear its human
  approval to read any of them — the gate covers what a job can read, not only
  when it runs. The certificate is imported into a temporary keychain the job
  creates and destroys, so no signing material persists on the runner.
- `xcode-cloud-logs.yml` reads an Admin-scoped App Store Connect key, so it holds
  its own copies on the `xcode-cloud-logs` environment. That one gates on a
  deployment branch policy (`main` and `ci/xcode-cloud-logs`) instead of
  approval: log fetching should not need a human, but the key should not be
  reachable from an arbitrary branch. `scripts/audit-security-posture.py` checks
  both environments and warns on any name present in both an environment and
  repository scope, since the environment copy wins silently — including when it
  is empty.
- The signing job has read-only repository permissions; publication is isolated
  in a separate `contents: write` job.
- Host tooling comes from SHA-pinned actions at pinned versions — `mise` via
  `jdx/mise-action`, `uv` via `astral-sh/setup-uv` — never from an unpinned
  `curl | sh` or a package manager resolving latest at run time.
  `scripts/tests/test_security_hardening.py` enforces this.
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
uv run --script scripts/tests/test_security_hardening.py
uv run --script scripts/audit-security-posture.py --local-only --strict
```

When `gh` is authenticated, run the remote posture audit before releases:

```bash
uv run --script scripts/audit-security-posture.py --repo fairchild/workspaces --strict
```

## Explicit Follow-Ups

- Consider a true WebSocket proxy for terminal access so the browser never sees
  the final ttyd URL after ticket redemption.
- Keep dependency overrides current and remove them when upstream patched
  versions resolve cleanly.

## Durable Lessons (2026-03 security review)

Rationale behind the controls above, kept here because the incident context
that produced them is otherwise only in git history:

- Triage sanitization is theater if the agent re-fetches raw content — a
  sanitized summary protects the human's view while the contributor runtime
  passes full payloads into the model prompt. Defense-in-depth means limiting
  what the agent sees, not just what the human sees.
- Scheduled runs are a stealth attack surface: with mentions disabled, a
  crafted issue body still waits for the next agent wake-up. Kill switches
  must cover every entry path, and one verified switch
  (`AGENT_AUTOMATIONS_ENABLED`) beats several partial ones.
- Persistent self-hosted runners amplify prompt-injection impact relative to
  ephemeral hosted runners; keeping the untrusted-code lane free of secrets
  (the evidence workflow's two-lane design) is the load-bearing pattern.
