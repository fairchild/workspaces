# web-next perf baseline

Canonical scenario definitions and budgets live in `contract.json`; this file
records the measured baseline the budgets were set against. Refresh it (rerun
`pnpm perf` on a quiet machine, update the table, note date + commit) before
tightening any budget.

- **Date:** 2026-07-03
- **Commit:** `5187c00` + the live streamed-turn change (#748 branch; app
  surface = sessions home at `/`, real `/sessions/[id]` with live mock turns,
  `/sessions/demo` Folio session view — all behind the auth gate; the Phase 0
  spike is deleted)
- **Environment:** Linux dev container, headless Chromium (Playwright),
  production build via `next start` on localhost, 3 runs per scenario
- **Command:** `pnpm perf` (with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` set,
  remote-sandbox convention)

| Scenario | Metric | Stat | Baseline | Budget | Status |
|---|---|---|---|---|---|
| ttft_mock | ttft_ms | median | 733 | 1500 | pass |
| streaming_cadence | longest_task_ms | max | 0 | 50 | pass |
| transcript_render_200 | initial_render_ms | median | 180.5 | 500 | pass |
| projection_200 | projection_ms | median | 13.6 | 40 | pass |
| route_home | lcp_ms | median | 80 | 1200 | pass |
| route_home | tbt_ms | median | 0 | 200 | pass |
| route_home | first_load_js_kb | exact | 115.7 | 200 | pass |
| route_session_empty | lcp_ms | median | 140 | 1200 | pass |
| route_session_empty | tbt_ms | median | 0 | 200 | pass |
| route_session_empty | first_load_js_kb | exact | 173.3 | 200 | pass |
| route_sessions_demo | lcp_ms | median | 148 | 1200 | pass |
| route_sessions_demo | tbt_ms | median | 0 | 200 | pass |
| route_sessions_demo | first_load_js_kb | exact | 114.1 | 200 | pass |
| resume_latency_100 | resume_ms | median | 197.3 | 800 | pass |

Raw samples from the baseline run:

| Scenario | Metric | Samples |
|---|---|---|
| ttft_mock | ttft_ms | 764, 729, 733 |
| streaming_cadence | longest_task_ms | 0, 0, 0 |
| transcript_render_200 | initial_render_ms | 180.5, 226.4, 162.3 |
| projection_200 | projection_ms | 13.6, 15.1, 10.7 |
| route_home | lcp_ms | 100, 72, 80 |
| route_home | tbt_ms | 0, 0, 0 |
| route_session_empty | lcp_ms | 140, 164, 136 |
| route_session_empty | tbt_ms | 0, 5, 0 |
| route_sessions_demo | lcp_ms | 156, 148, 140 |
| route_sessions_demo | tbt_ms | 0, 0, 0 |
| resume_latency_100 | resume_ms | 218.9, 190.1, 197.3 |

Reading notes:

- **2026-07-03 (#749):** `resume_latency_100` converted from pending to
  measured. It loads a session whose ~100-event assistant turn was left in
  flight (seeded stale, no `done`, one fresh session per run), so the client's
  `resume` reconnects to the tail route, which closes the abandoned turn and
  backfills the whole log; the metric times navigation start → the turn's last
  event (a marker) painted. First measurement 197.3ms median. Budget set to
  800ms: ~4x the dev-container median, enough headroom for a cold/noisy CI
  reconnect while still tripping a real regression (a 100-event backfill that
  blocks the client for most of a second would be one). This is the durable
  read+replay path, so it is budgeted meaningfully rather than loosely.
  `ttft_mock`/`streaming_cadence` re-verified unchanged (750ms / 0ms) — the
  detached-ingest + tail refactor did not regress the connected send path,
  which now tails the same log instead of teeing the provider directly.
- **2026-07-03 (#748):** `ttft_mock` and `streaming_cadence` repointed from
  the Phase 0 `/spike` at the real session surface: a message sent from the
  Folio compose on a fresh `/sessions/[id]` through the auth-gated chat route,
  the user-event append, and the mock provider, with every chunk persisted to
  `session_events` as it streams. Medians moved 692 → 733ms (ttft; still
  ~600ms of scripted provisioning delay, so real client+server+persistence
  overhead is ~130ms) and stayed 0ms (longest task, with
  `experimental_throttle: 50` batching token application into the Folio
  transcript). `route_spike` removed with the spike itself; its role is fully
  covered by `route_session_empty`, whose first-load JS moved 171.5 → 173.3 kB
  gz (useChat + transport replacing the local echo shell — the full chat
  runtime costs ~2 kB over it). Budgets unchanged.
- **2026-07-03 (#747):** `/` is now the sessions home (auth-gated, one seeded
  session row) instead of the static placeholder, and every route scenario
  runs signed in through the middleware + server auth gate — so route metrics
  now include the same per-request auth work production does. `route_home`
  first-load JS moved 103.7 → 115.7 kB gz (session list, new-session flow,
  server-action plumbing); LCP 60 → 76ms. `route_session_empty` added
  (measured): a real empty session at `/sessions/[id]` — 136ms LCP, 171.5 kB
  gz (the Folio surface plus the client compose/echo shell). Budgets
  unchanged; both sit far inside them. `route_spike` / `route_sessions_demo`
  shifted a few kB from the shared chunks; same budgets.
- **2026-07-03 (#745):** `transcript_render_200` converted from pending to
  measured — it loads `/sessions/demo?seed=200` (200 server-rendered fixture
  messages) and times navigation start → all 200 messages present in a
  painted frame. First measurement 213.6ms median against the provisional
  500ms budget, which is now confirmed. `route_sessions_demo` added with the
  same budgets as `route_spike`; the Folio view server-renders from fixtures,
  so its client JS is the shared baseline plus theme/disclosure
  interactivity — no chat runtime on this route yet (#748 will add it).
- **2026-07-03 (#746):** `projection_200` added (measured) — the pure
  events→UIMessage[] projection over a 200-event log (20 interleaved
  user+assistant turns), run in-process under tsx via `perf/projection-bench.mjs`
  (not the browser). First measurement 12.7ms median. Budget set to 40ms: ~3x
  headroom over the dev-container median, chosen so ordinary noise and slower CI
  pass while a real regression (e.g. an accidental O(n²) over events, or
  per-event allocation blowup across the 20 `readUIMessageStream` reductions)
  trips it. This is #749's tail/resume read cost, so it is budgeted tight rather
  than generous. Re-baseline from CI if it proves noisy there.
- `ttft_mock` includes ~600ms of scripted provisioning-status delay in the
  mock turn, so real client+server (and, since #748, per-chunk persistence)
  overhead is roughly 130ms of the median.
- `longest_task_ms` uses the longtask API, which only reports tasks >= 50ms —
  0 means "no long task observed", and any nonzero value exceeds budget.
- `first_load_js_kb` is gzipped KiB from the build manifests (route groups
  stripped when matching manifest keys; dynamic routes map via the
  scenario's `manifest_route`).
- CI (ubuntu-latest) is slower than this container; budgets carry enough
  headroom that route metrics should hold there. If CI runs prove noisy,
  re-baseline from CI numbers rather than widening budgets ad hoc.
