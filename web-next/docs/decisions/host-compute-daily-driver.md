# ADR: Host compute — web-next as a daily driver

- Status: **Proposed** (2026-07-08; acceptance = owner merge)
- Scope: `web-next/`, plus one explicitly-scoped native-lane issue (#987)
- Resolves: [#972](https://github.com/fairchild/workspaces/issues/972) (build/don't-build on subscription-billed local compute)
- Related: `docs/decisions/web-next-harness-runtime.md` (runtime), `web-next/docs/roadmap.md` (W-arc record), the [#972 research memo](https://github.com/fairchild/workspaces/issues/972#issuecomment-4916538698) (sourced facts this decision rests on), milestone [W6](https://github.com/fairchild/workspaces/milestone/19)

## Context

Two owner directions converged on 2026-07-08:

1. **Billing (#972).** Agent turns should draw on the Claude subscription where
   possible, not API keys. The research memo established that Anthropic's line
   is *whose credentials, used by whom* — not interactive vs. headless. A single
   owner running the first-party `claude` binary non-interactively, under their
   own subscription login, on hardware they control is the sanctioned
   "ordinary, individual usage" case (`claude setup-token` is a documented,
   first-party mechanism for exactly this). What's prohibited is a third party
   routing *other users'* Pro/Max credentials. Subscription auth inside a
   Vercel sandbox is the interpretive gray zone; subscription auth on the
   owner's own machine is not.

2. **Product.** web-next should round out into a **daily-driver alternative to
   Claude Code** standalone, and to **Claude Desktop** when embedded in the
   workspaces native app, served locally, with turns executing on the host.

These are one decision, not two: the piece that answers the billing question —
a compute provider that runs turns on owned hardware — is also the keystone of
the embedded product story. The provider seam
(`src/lib/agent-runtime/provider.ts`) was built for exactly this swap: one
method, `runTurn(TurnRequest) → AsyncIterable<StreamChunk>`, with an opaque
resume handle.

## Decision

**Build, host-first.** A `host` ComputeProvider (#981) that executes turns via
the local `claude` binary against a working copy on the serving machine,
subscription-authed with the owner's existing login. Around it, in dependency
order:

| # | Issue | What it is |
|---|---|---|
| [#981](https://github.com/fairchild/workspaces/issues/981) | host compute provider | The keystone. `claude -p --output-format stream-json` → StreamChunks, resume via harness session id, opt-in via `WEB_NEXT_COMPUTE_PROVIDER=host`. |
| [#982](https://github.com/fairchild/workspaces/issues/982) | approval protocol | The one genuinely new protocol surface. StreamChunk is output-only today; a host provider touching real filesystems needs `approval_request` chunks + an answer endpoint, persisted in `session_events`. Designed once, for both providers. Until it lands, host runs restricted. |
| [#983](https://github.com/fairchild/workspaces/issues/983) | local serving mode | `next start` on the owner's machine as a first-class target: loopback-bound, locally-minted auth, SQLite file DB. The thing the native app will spawn. |
| [#984](https://github.com/fairchild/workspaces/issues/984) | mid-turn steering | Compose stays live during a turn; queued messages are durable and dispatch next. The biggest feel gap vs. Claude Code. |
| [#985](https://github.com/fairchild/workspaces/issues/985) | harness config parity | User-level CLAUDE.md/skills/commands visible to the runtime; a config receipt in the session UI. Free on host, injected on sandbox. |
| [#986](https://github.com/fairchild/workspaces/issues/986) | session list as a workspace | Search/filter/keyboard across accumulated sessions. |
| [#820](https://github.com/fairchild/workspaces/issues/820) | PR from a session | Existing follow-up; the get-work-out half of the loop. |
| [#809](https://github.com/fairchild/workspaces/issues/809) | mobile polish | Un-parked: notifications (#971) + kick-off-and-walk-away made the phone the second screen. |
| [#987](https://github.com/fairchild/workspaces/issues/987) | native embedding | Desktop-lane: WKWebView hosts local-mode web-next, sessions bound to app workspaces. The one sanctioned containment-boundary crossing. |

**What we are not building:** subscription auth inside the Vercel sandbox. The
policy ground is unstable (Anthropic announced, then paused, a metered Agent
SDK credit in June 2026 and has said a revised plan is coming) and the host
provider delivers the same outcome — subscription-billed turns — in the
configuration that is clearly sanctioned. The vercel provider stays as-is,
API-key-billed, for turns that want disposable cloud compute. Re-check the
[Agent SDK plan-usage Help Center article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
before any future revisit.

## Containment (how this work is organized)

Owner direction, recorded here as policy: **web-next work stays in
`web-next/`.**

- Code, tests, docs, and *decisions* live under `web-next/` — new ADRs go in
  `web-next/docs/decisions/` (this file is the first; earlier web-next ADRs in
  repo-root `docs/decisions/` stay where they are, linked from here).
- CI is already scoped (`web-next-ci.yml`); keep new gates inside it.
- The **one sanctioned boundary crossing** is #987, and it crosses via a
  contract, not reach-in: the native app spawns the `start:local` entrypoint,
  passes a loopback port + minted token, and talks localhost HTTP/deep-links.
  Native code never imports from or writes into `web-next/`; web-next never
  imports from `Sources/`. Native work lands in separate PRs on the desktop
  lane.

## Consequences

- **Two providers, one protocol.** The approval protocol (#982) and steering
  (#984) are designed against the StreamChunk/session-events layer, not against
  a provider — sandbox and host stay swappable, and the mock provider keeps
  the whole surface testable without credentials.
- **Security posture inverts on host.** The sandbox's "auto-approve everything"
  default is safe because the blast radius is a disposable clone; on host the
  blast radius is the owner's machine. #982 is therefore a prerequisite for
  unrestricted host turns, and #983 must be loopback-bound by construction.
- **Billing outcome without the gray zone.** Local turns bill the
  subscription because they are ordinary first-party CLI use — no credential
  relaying, no sandbox OAuth plumbing, nothing to re-litigate when Anthropic
  lands its revised Agent SDK billing.
- **The desktop app gains a session surface for free** once #981 + #983 land;
  reachability (the hard problem in #972's cloud framing) collapses to
  localhost, and the app's existing workspace lifecycle answers "who keeps the
  working copy alive."

## Sequencing

W5 (continuity) finishes first — its Lane A issues (#968, #969, #970) touch the
provider files and should not run concurrently with #981. Within W6:
#981 → #982 → #983 form the spine, serial (shared runtime files); #984/#985/#986/#809
are parallel-safe against the spine after #982's chunk-type design settles;
#820 needs its own design pass; #987 waits for #981 + #983 and rides the
desktop lane. Authority contract carries over from W5: Fable coordinates,
plans, reviews, and merges when gates are green; implementation dispatched per
`codex-execution` where it fits.
