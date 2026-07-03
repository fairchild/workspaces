# web-next perf baseline

Canonical scenario definitions and budgets live in `contract.json`; this file
records the measured baseline the budgets were set against. Refresh it (rerun
`pnpm perf` on a quiet machine, update the table, note date + commit) before
tightening any budget.

- **Date:** 2026-07-03
- **Commit:** `2752507` + the auth + sessions home change (#747 branch; app
  surface = sessions home at `/`, real `/sessions/[id]`, Phase 0 spike,
  `/sessions/demo` Folio session view — all behind the auth gate)
- **Environment:** Linux dev container, headless Chromium (Playwright),
  production build via `next start` on localhost, 3 runs per scenario
- **Command:** `pnpm perf` (with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` set,
  remote-sandbox convention)

| Scenario | Metric | Stat | Baseline | Budget | Status |
|---|---|---|---|---|---|
| ttft_mock | ttft_ms | median | 692 | 1500 | pass |
| streaming_cadence | longest_task_ms | max | 0 | 50 | pass |
| transcript_render_200 | initial_render_ms | median | 217.6 | 500 | pass |
| projection_200 | projection_ms | median | 12.5 | 40 | pass |
| route_home | lcp_ms | median | 76 | 1200 | pass |
| route_home | tbt_ms | median | 0 | 200 | pass |
| route_home | first_load_js_kb | exact | 115.7 | 200 | pass |
| route_session_empty | lcp_ms | median | 136 | 1200 | pass |
| route_session_empty | tbt_ms | median | 0 | 200 | pass |
| route_session_empty | first_load_js_kb | exact | 171.5 | 200 | pass |
| route_spike | lcp_ms | median | 124 | 1200 | pass |
| route_spike | tbt_ms | median | 0 | 200 | pass |
| route_spike | first_load_js_kb | exact | 168.7 | 200 | pass |
| route_sessions_demo | lcp_ms | median | 108 | 1200 | pass |
| route_sessions_demo | tbt_ms | median | 0 | 200 | pass |
| route_sessions_demo | first_load_js_kb | exact | 114.1 | 200 | pass |
| resume_latency_100 | — | — | — | — | pending (#749) |

Raw samples from the baseline run:

| Scenario | Metric | Samples |
|---|---|---|
| ttft_mock | ttft_ms | 713, 690, 692 |
| streaming_cadence | longest_task_ms | 0, 0, 0 |
| transcript_render_200 | initial_render_ms | 118.7, 236.6, 217.6 |
| projection_200 | projection_ms | 12.5, 14.6, 10.4 |
| route_home | lcp_ms | 76, 72, 76 |
| route_home | tbt_ms | 0, 0, 0 |
| route_session_empty | lcp_ms | 140, 136, 120 |
| route_session_empty | tbt_ms | 0, 0, 0 |
| route_spike | lcp_ms | 140, 124, 120 |
| route_spike | tbt_ms | 4, 0, 0 |
| route_sessions_demo | lcp_ms | 152, 108, 100 |
| route_sessions_demo | tbt_ms | 0, 0, 0 |

Reading notes:

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
  mock turn, so real client+server overhead is roughly 110ms of the median.
- `longest_task_ms` uses the longtask API, which only reports tasks >= 50ms —
  0 means "no long task observed", and any nonzero value exceeds budget.
- `first_load_js_kb` is gzipped KiB from the build manifests (route groups
  stripped when matching manifest keys; dynamic routes map via the
  scenario's `manifest_route`).
- CI (ubuntu-latest) is slower than this container; budgets carry enough
  headroom that route metrics should hold there. If CI runs prove noisy,
  re-baseline from CI numbers rather than widening budgets ad hoc.
