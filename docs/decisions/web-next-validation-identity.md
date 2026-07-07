# web-next validation identity (#814)

**Status:** proposed 2026-07-07 (web-next W1–W4 arc) · **Owner gate:** Michael approves before any credential is created.

How automated validation (`web-next/scripts/validate.mjs`, milestone #13) authenticates
against deployed web-next environments, least-privilege and revocable. The
uncredentialed stages (#813 reachability, #815 security posture) already run
against production with zero secrets; this decision covers the three
credentials the *authenticated* stages (#814/#816/#817/#818/#819) consume.
Each stage self-gates: a missing credential reports `skipped: missing <name>`,
never a silent pass.

## The three credentials

1. **A GitHub machine account on the allowlist** (suggested: `fairchild-web-validator`).
   Added to `ALLOWED_LOGINS` in the Vercel project env. It needs no org
   membership and no repo permissions — it exists only to pass the OAuth +
   allowlist door. Because sessions are unscoped (#829 parked), this identity
   sees the owner's sessions; that is the accepted single-user posture, and
   the account is the unit of revocation: remove the allowlist entry and its
   access is gone at the next edge check.

2. **A pre-minted session seed — `WEB_NEXT_VALIDATION_SESSION`** (GitHub Actions
   secret + local `.env`). One interactive sign-in as the machine account
   yields a Better Auth session token; the harness replays it as the session
   cookie. A pre-minted session is deliberately chosen over scripting the
   OAuth web flow: headless OAuth against GitHub is fragile and looks like
   credential-stuffing, while a seeded session is one secret with Better
   Auth's own lifetime and server-side revocation. Expiry is a first-class
   state: the harness detects a bounced session and reports the authed stages
   `skipped: validation session expired — re-seed`, so a stale secret degrades
   the report, never fakes it. Rotation = repeat the sign-in.

3. **Vercel Protection Bypass for Automation — `VERCEL_AUTOMATION_BYPASS_SECRET`**
   (project setting, one toggle). Lets the harness reach *preview*
   deployments behind Vercel's deployment protection; production is publicly
   reachable and doesn't need it. `validate-core.mjs` and the perf runner's
   deployed mode already send it as the `x-vercel-protection-bypass` header
   when present. Project-scoped, rotated from the Vercel dashboard.

## Spend posture (#818 real-turn stage)

The real-agentic-turn stage exercises the deployed app's own model gateway —
no separate model key. Proposed cadence: one scheduled run per day against
the freshest preview, prod on demand; each run is a single small coding turn
(cents, not dollars). The owner adjusts cadence by editing one workflow cron.

## What the owner does (once)

Create the machine account → add it to `ALLOWED_LOGINS` → sign in once and
hand the session token to the Actions secret + local `.env` → flip the Vercel
protection-bypass toggle and store its secret alongside. Everything else —
header/cookie plumbing, skip-reporting, expiry detection, rotation notes in
`web-next/CONTRIBUTING.md` — is code in the #813-family harness and lands
with the W3 PRs.

## Alternatives considered

- **Scripted OAuth device/web flow per run** — no standing session secret, but
  headless OAuth is brittle, rate-limited, and indistinguishable from abuse;
  rejected for a validation lane that must be boring.
- **A test bypass in production** — already deliberately double-locked inert
  (#815 proves it); widening it for validation would trade a real security
  property for convenience; rejected.
- **Owner's own account** — no second identity to manage, but revocation would
  mean rotating the owner's own session and validation traffic would be
  indistinguishable from real use in logs; rejected.
