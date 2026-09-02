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
- `xcode-cloud-logs.yml` reads the App Store Connect key — a Team key at App
  Manager role, the least role the Xcode Cloud API accepts (#1352) — and holds
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

### D1 migration drift

The remote audit also compares each Cloudflare environment's applied migrations
against the ones in the repo, per service in `D1_SERVICE_DIRS`. It fails when the
repo is ahead — a migration merged but never applied, which is how production went
a month without `feedback_audit`
([#1309](https://github.com/fairchild/workspaces/issues/1309)) — and only ever
reports. Applying a migration stays a deliberate act; the gap was that nobody knew
one was pending.

It belongs on the release preflight rather than in per-PR CI. It needs Cloudflare
credentials, so it cannot run in an untrusted lane, and two things make per-PR the
wrong shape regardless: a PR that *adds* a migration is legitimately ahead of every
environment and would fail the gate for doing the right thing, and drift only
becomes a defect once the change has merged and shipped without the environment
following.

`wrangler` must be installed and authenticated. Where more than one Cloudflare
account is reachable, set `CLOUDFLARE_ACCOUNT_ID` (already a repository secret) or
wrangler cannot choose one non-interactively:

```bash
CLOUDFLARE_ACCOUNT_ID=… uv run --script scripts/audit-security-posture.py --repo fairchild/workspaces
```

Anything that stops the check reading live state — no `wrangler`, no credentials,
a timeout, output it cannot parse — reports `warn`, never `pass`. Being unable to
look is the condition this check exists to make visible, so it is never reported
as health. `--local-only` skips it along with the rest of the remote audit;
`--skip-d1` skips only this check, for a machine that has GitHub access but no
Cloudflare credentials.

The 60-second query timeout is per environment rather than per run, since
environments are queried in sequence.

The wrangler settings that change where migrations live are honored:
`migrations_table` when a binding renames the table, and `migrations_pattern` for
nested layouts, whose migrations wrangler records under their path relative to
`migrations_dir`. A binding that omits `migrations_dir` is still watched, using
wrangler's default of `migrations`, because omitting the field is not opting out.
`infra/feedback-store` sets `migrations_dir` and takes the defaults for the rest.

Two places where this check is narrower than wrangler, both reported rather than
guessed at. Pattern matching uses Python's `Path.glob`, which agrees with wrangler's
minimatch on literal characters, `*`, `?` and `**` in segments that do not begin
with a dot, and on skipping dotfiles and anything reached through a symlink. A
pattern outside that subset — character or POSIX classes, brace alternation,
extglobs, a leading `!` or `#`, a segment naming a dot component, or a trailing
`**`, whose meaning depends on the Python version — warns and says which part it
cannot compare, rather than matching a different set of files than wrangler
applies. A table name carrying a
NUL, and an empty one, are refused rather than sent.

One SQL failure is deliberately not in that bucket. A database that has never had
a migration applied has no migrations table, so the query errors — but that is the
answer, not an obstacle, and it is maximal drift: every migration in the repo is
pending. It reports `fail`. Read as a warn it would make a freshly recreated
database report *softer* than one missing a single migration, since `--strict` fails
only on `fail`. Wrangler reports that error on stdout while writing unrelated
chatter to stderr, so both streams are read. Wrangler's JSON is decoded before the
table name is compared, and compared for equality rather than matched inside the
message, so a neighbouring table like `d1_migrations_v2` is an obstacle rather than
an answer and a quoted name survives the round trip.

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
