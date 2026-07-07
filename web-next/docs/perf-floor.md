# Perf floor: budgets, ratchet policy, deployed-target measurement

`perf/run.mjs` runs the scenarios in `perf/contract.json` against a
production build and fails the run when a measured metric exceeds its
budget. It is a regression guard, not a performance target — budgets exist
to catch a slowdown, not to define where the app should land.

## Scenario set

Nine scenarios, defined in `perf/contract.json`:

| Scenario | What it measures |
|---|---|
| `ttft_mock` | Time from submitting a message to the first assistant token painted |
| `streaming_cadence` | Longest main-thread task while a full turn streams in |
| `transcript_render_200` | Cold load of a 200-message session to full paint |
| `projection_200` | In-process cost of projecting a 200-event log into `UIMessage[]` (the tail/resume read path) |
| `route_home` / `route_session_empty` / `route_sessions_demo` | LCP, total blocking time, and gzipped first-load JS for the three primary routes |
| `terminal_drawer_interactive` | Drawer toggle → shell painted interactive (lazy ghostty-web init + ticket exchange), over the mock PTY seam |
| `resume_latency_100` | Reconnect-and-backfill latency for an interrupted 100-event turn |

`perf/projection-bench.mjs` runs `projection_200` in-process (no browser);
everything else drives headless Chromium against `next start` in
`AUTH_BYPASS=1` mode over a throwaway seeded database (`scripts/harness.mjs`).

## Ratchet policy

Each budget is derived from a measured floor, not chosen a priori. The
refresh procedure: run `pnpm run perf` repeatedly (at least 10 — see below)
on the same machine that will do the final verification, then per metric:

- **Build-artifact-size metrics** (`first_load_js_kb`) are deterministic
  across runs on a given commit — the gzipped size doesn't move with host
  load — so `budget = ceil(median * 1.10)`, rounded to the nearest 5kb.
- **Wall-clock browser timing metrics** (`ttft_ms`, `initial_render_ms`,
  `projection_ms`, `lcp_ms`, `tbt_ms`, `resume_ms`) are exposed to host CPU
  scheduling noise, so `budget = ceil(max-observed-across-runs * 1.3)`,
  rounded to a sensible figure (10-50ms). Using the max (not the median)
  with margin, over enough runs to see real tail noise, is what kept this
  stable in practice — see the note below.

Budgets only ever **tighten**: if the formula's result lands above the
current budget, the current budget is kept unchanged rather than loosened.
A metric whose measured value already exceeds its *current* budget is a live
regression, not a ratchet decision — that stops the refresh for a fix, not a
number change.

**Why 10 runs and a max-based margin, not the simpler median*1.25 for
everything:** the #856 refresh first tried the plainest version of this
formula (median of 3 runs, ×1.25 for every timing metric) and it failed its
own re-verification repeatedly. The sandbox it ran in was heavily
oversubscribed — host load average ~35 on a 10-core machine, from concurrent
unrelated CPU-bound work — and several scenarios showed 2-4x swings run to
run on the identical commit (`initial_render_ms` 79-321ms,
`route_sessions_demo`'s `lcp_ms` 44-144ms). A tight margin computed from a
noisy 3-sample median just encodes the noise as a flaky gate. Widening to 10
samples and keying the margin off the observed max (not the median) produced
budgets that held across repeated clean runs; see `perf/BASELINE.md`'s
2026-07-07 entry for the raw samples. A dedicated CI runner should be
quieter than that sandbox, so these budgets are expected to hold there with
room to spare — if CI proves noisy in practice, re-baseline from CI numbers
with the same formula rather than widening budgets ad hoc.

## CI enforcement

`.github/workflows/web-next-ci.yml`'s `quality-lane` job runs `pnpm run perf`
on every `web-next/**` PR and push to `main`, after lint/typecheck/unit/build/
E2E/evidence. A budget breach fails the job; `perf/results.json` and
`perf/results.md` are uploaded as workflow artifacts either way.

## Deployed-target mode

`node perf/run.mjs --url <origin>` (or `--env prod`, defaulting to
`WEB_NEXT_PROD_URL` / the known deployment — same resolution as
`scripts/validate.mjs`, see `scripts/validate-core.mjs`) measures against a
live deployment instead of spawning a local server.

Every one of the eight contract scenarios needs either the auth-bypass
cookie or a locally seeded database row (`contract.json`'s own `auth`
methodology note) — neither exists against a real deployment — so all eight
are reported `skipped: requires the auth-bypass cookie + locally seeded
fixtures`, the same way `scripts/validate.mjs` reports a stage as skipped
rather than silently passing it. The one honest, credential-free measurement
is the `/sign-in` entry route's `lcp_ms`/`tbt_ms` — reachable by anyone,
gated by nothing.

Deployed-target results are **report-only**: nothing here fails the run,
regardless of value, and they're written to a separate file
(`perf/results-deployed.json`/`.md`) so they never get confused with the
budget-gating local results. This is a measurement surface, not a gate — no
production baseline or budget is defined for it yet. If a Vercel deployment
is SSO-walled, the entry measurement reports that skip too (`set
VERCEL_AUTOMATION_BYPASS_SECRET`, mirroring `validate.mjs`'s handling of the
same wall, #814).

The target-resolution and skip-reporting logic (`perf/deployed-core.mjs`) is
pure and unit-tested (`perf/deployed-core.test.mjs`) — no browser or network
I/O — following the same split as `scripts/validate-core.mjs` /
`scripts/validate-core.test.mjs`.
