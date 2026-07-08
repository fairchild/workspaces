# Subscription-Billed Agent Turns (web-next)

## Status

Decided 2026-07-08: **park implementation; re-check when Anthropic ships its
reworked Agent SDK billing.** Issue #972 stays open as the parking marker.
Research basis gathered 2026-07-08 (primary sources quoted in the issue
thread; method: web fetch of Anthropic's live terms, docs, and Help Center).

## Question

web-next's real compute provider runs Claude Code in a Vercel sandbox on
API-key billing (`ANTHROPIC_API_KEY` / AI Gateway). The owner already pays
for a Claude subscription. Can agent turns draw on that subscription
instead, and should we build it?

## What the sources establish

1. **The permission boundary is whose credentials, used for whom — not
   interactive vs. headless.** Anthropic's Claude Code legal-and-compliance
   page covers "ordinary, individual usage of Claude Code and the Agent SDK"
   under the owner's own OAuth login, and separately prohibits third parties
   from routing requests "through Free, Pro, or Max plan credentials on
   behalf of their users." A single owner running the official `claude`
   binary non-interactively on infrastructure they control is the sanctioned
   side of that line; a multi-tenant harness relaying other people's
   subscription credentials is the prohibited side. web-next is
   single-owner by construction, so the fatal case does not apply.

2. **The mechanism is first-party and built for this.** `claude setup-token`
   mints a ~1-year, inference-scoped OAuth token intended for CI/scripts,
   consumed via `CLAUDE_CODE_OAUTH_TOKEN`. Enforcement history (the
   January 2026 wave against OpenClaw/OpenCode/Goose) targeted tools that
   *extracted* subscription tokens into their own API clients — the
   credential must be consumed by the `claude` binary itself, which is
   exactly how our provider runs it (the harness drives the real CLI inside
   the sandbox).

3. **The billing ground is actively shifting.** Anthropic announced
   (May 2026) that Agent SDK / `claude -p` / GitHub Actions / third-party
   harness usage — Conductor was a named example — would move to a separate
   metered credit pool, then paused the change on June 15–16 ("nothing
   changes for now") while it reworks the plan. Today such usage draws from
   ordinary subscription limits; that is explicitly temporary.

## Decision

- **Do not wire subscription auth into the Vercel provider now.** Building
  against a billing arrangement Anthropic has paused mid-rework buys a small
  cost win that can be repriced or re-fenced without notice — and harness
  usage like ours is the named target of the rework.
- **When revisited, the compliant shape is fixed:** owner-minted
  `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` in the sandbox command
  env (never the transcript, same handling as the GitHub credential),
  consumed only by the `claude` CLI, single owner, no second principal.
  A config seam (`WEB_NEXT_CLAUDE_AUTH=subscription|api`) keeps API-key
  billing the default.
- **The local/native compute provider remains the least-ambiguous host** for
  subscription-billed turns (owner's own Mac, the CLI's normal home) and
  aligns with the embedded-webview direction for the native app — if the
  rework lands hostile to cloud sandboxes, that is the fallback shape.

## Re-check trigger

Before any implementation: re-read Anthropic's Help Center article on Agent
SDK plan usage (the pause notice) and `code.claude.com/docs/en/legal-and-compliance`
for the revised terms. If the metered credit pool ships, do the cost math
against gateway API billing before building anything — the subscription win
may evaporate at API-rate metering.
