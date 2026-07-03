# web-next perf baseline

Canonical scenario definitions and budgets live in `contract.json`; this file
records the measured baseline the budgets were set against. Refresh it (rerun
`pnpm perf` on a quiet machine, update the table, note date + commit) before
tightening any budget.

- **Date:** 2026-07-03
- **Commit:** `55e3b98` + the Folio design-system change (#745 branch; app
  surface = Phase 0 spike + `/sessions/demo` Folio session view)
- **Environment:** Linux dev container, headless Chromium (Playwright),
  production build via `next start` on localhost, 3 runs per scenario
- **Command:** `pnpm perf` (with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` set,
  remote-sandbox convention)

| Scenario | Metric | Stat | Baseline | Budget | Status |
|---|---|---|---|---|---|
| ttft_mock | ttft_ms | median | 704 | 1500 | pass |
| streaming_cadence | longest_task_ms | max | 0 | 50 | pass |
| transcript_render_200 | initial_render_ms | median | 213.6 | 500 | pass |
| projection_200 | projection_ms | median | 12.7 | 40 | pass |
| route_home | lcp_ms | median | 60 | 1200 | pass |
| route_home | tbt_ms | median | 0 | 200 | pass |
| route_home | first_load_js_kb | exact | 103.7 | 200 | pass |
| route_spike | lcp_ms | median | 112 | 1200 | pass |
| route_spike | tbt_ms | median | 0 | 200 | pass |
| route_spike | first_load_js_kb | exact | 158.1 | 200 | pass |
| route_sessions_demo | lcp_ms | median | 112 | 1200 | pass |
| route_sessions_demo | tbt_ms | median | 0 | 200 | pass |
| route_sessions_demo | first_load_js_kb | exact | 103.6 | 200 | pass |
| resume_latency_100 | — | — | — | — | pending (#749) |

Raw samples from the baseline run:

| Scenario | Metric | Samples |
|---|---|---|
| ttft_mock | ttft_ms | 715, 704, 693 |
| streaming_cadence | longest_task_ms | 0, 0, 0 |
| transcript_render_200 | initial_render_ms | 223.4, 213.6, 207.2 |
| projection_200 | projection_ms | 12.7, 14.2, 10.0 |
| route_home | lcp_ms | 56, 60, 64 |
| route_home | tbt_ms | 0, 0, 0 |
| route_spike | lcp_ms | 140, 112, 76 |
| route_spike | tbt_ms | 1, 0, 0 |
| route_sessions_demo | lcp_ms | 112, 112, 152 |
| route_sessions_demo | tbt_ms | 0, 0, 0 |

Reading notes:

- **2026-07-03 (#745):** `transcript_render_200` converted from pending to
  measured — it loads `/sessions/demo?seed=200` (200 server-rendered fixture
  messages) and times navigation start → all 200 messages present in a
  painted frame. First measurement 213.6ms median against the provisional
  500ms budget, which is now confirmed. `route_sessions_demo` added with the
  same budgets as `route_spike`; the Folio view server-renders from fixtures,
  so its client JS (103.6 kB gz) is the shared baseline plus theme/disclosure
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
- `first_load_js_kb` is gzipped KiB from the build manifests; `next build`
  reported 106 kB (/), 161 kB (/spike), and 105 kB (/sessions/demo) for the
  same build (kB vs KiB).
- CI (ubuntu-latest) is slower than this container; budgets carry enough
  headroom that route metrics should hold there. If CI runs prove noisy,
  re-baseline from CI numbers rather than widening budgets ad hoc.
