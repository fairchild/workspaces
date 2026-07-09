# Attack patterns by surface type

Directed review questions that have caught real defects in this repo, grouped by
the kind of code the diff touches. Quote the relevant block into the review
prompt, then add diff-specific questions. Append new patterns when a review
finds a defect class not listed here — this file is meant to accumulate.

Provenance: seeded from the W6 arc (2026-07-08/09, milestone 19), where these
questions found 15 substantive defects across 6 issues — see
`.claude/skills/codex-execution/README.md` for the narrative.

## UI / components

- Can an invisible hit area (padding halo, `::after`, oversized button) overlap
  an adjacent interactive control and steal its clicks? Check stacking context
  and paint order, not just geometry. *(Found: dismissed-handle halo stealing
  send-button taps, #809.)*
- Do e2e assertions pin usable behavior (elementFromPoint hit-tests) or only
  declared CSS? A test asserting `::after` dimensions passes while the control
  is unclickable. *(Found: same PR.)*
- Client components: does `useSearchParams` (or any dynamic hook) opt the page
  out of static server paint? Watch the perf-contract routes. *(Found: 2x home
  LCP regression, #986 — caught by the perf floor, not review; ask anyway.)*
- Keyboard handlers on `window`: do they yield to focused text inputs AND
  focused interactive elements (Enter on a button double-firing)? Do URL-sync
  effects clobber mid-keystroke input when a stale RSC payload lands?
  *(Found: three of the five #986 findings.)*

## Event-log / durable-turn code (session_events discipline)

- Single-writer: does ANY new code path append turn chunks outside the ingest
  loop? (Answer endpoints, queue enqueues, sweeps.) *(Found: mutation-checked
  in #982/#984; SQLite surfaces violations as SQLITE_BUSY.)*
- Terminal-state hygiene: if the turn ends (stop, crash, timeout) with a
  pending interactive element (approval card, queued marker), does projection
  render it actionable in a dead turn — and is live-replay (stream ends
  WITHOUT `done`) distinguished from termination? *(Found: dangling approval
  card, #982 — and the first fix broke live replay; the suite caught it.)*
- Race the dispatchers: completion continuation vs sweep vs direct POST — is
  the claim session-atomic (one transaction: verify idle + claim + append) or
  merely row-atomic (loser claims the NEXT row → two concurrent turns)?
  *(Found: #984 blocker.)*
- Claim windows: can a process die between claiming work and making it
  observable? A claimed-but-unstarted row is invisible to every recovery
  path. *(Found: #984 blocker — fix is claim+append in one transaction.)*
- FIFO under ties: timestamp ordering with random tiebreakers is not FIFO.
  Use insertion-ordered keys.

## Process-spawning / provider code

- Env curation: is the child env an allowlist, and does a sentinel-secret test
  prove server secrets don't leak? Which credentials does the allowlist
  itself smuggle — does an API key reaching the child silently change BILLING
  or auth mode? *(Found: ANTHROPIC_API_KEY flipping host turns from
  subscription to API billing, #981.)*
- Restriction escape: do CLI flags only ADD permissions while user-level
  config (settings.json via HOME/CLAUDE_CONFIG_DIR) can re-grant tools, hooks,
  MCP? Is there a configless/safe-mode flag, and is it test-pinned on every
  spawn? *(Found: settings escape past --allowedTools, #981.)*
- Lifecycle bounds: wall-clock timeout, bounded stdout-close→exit wait,
  process-GROUP kill (descendants), capped stderr/line buffers. Can any await
  hang forever? *(Found: three unbounded paths, #981.)*
- Stale resume: when a resume handle fails, does the stored handle CLEAR
  (metadata field present-and-null, not absent) or does the session wedge
  retrying it forever? *(Found: #981.)*
- Flag verification: were new CLI flags verified against the REAL binary's
  --help (excerpts in the report), or only against the fake test binary?
  Unit tests pass either way; real turns die on unknown flags.

## Auth / serving surfaces

- Prod inertness first: trace every changed file's default-off path before
  anything else. New modes must be startup-refused in combination with
  existing modes, not silently precedence-ordered.
- Host-header strictness: parse via URL construction; `localhost:3100:evil`
  and `[::1]:bad` must fail; build redirects from the VALIDATED origin, never
  request.url. *(Found: #983.)*
- Coupled modes: is an orthogonal concern (repo directory source, feature
  availability) keyed off the AUTH mode instead of its own real condition
  (creds present)? *(Found: fixture repos shown despite real App creds, #983.)*
- Token/file hygiene: TOCTOU between validate and read (open O_NOFOLLOW, fstat
  the handle, read the handle); symlinked secrets files refused; permissive
  modes repaired on reuse; constant-time compares. *(Found: #983, #985.)*
- Hermeticity vs ambient env: does the test harness explicitly CLEAR real
  credentials, or does it break the moment a dev machine's env gets richer?
  Cross-PR interaction class — ask what merged recently. *(Found: #983 ×
  the setup-script env-linking fix.)*

## Content-injection / config code

- Is the hash/receipt computed over the EXACT bytes injected (post-trim), or
  over what was read? *(Found: #985.)*
- Per-item caps without an aggregate budget still explode argv/prompts.
  *(Found: #985.)*
- Fixed temp paths: stale content across resumed/parked lifecycles — is the
  file turn-scoped (always overwritten) or write-once? *(Found: #985.)*
