# web-next perf baseline

Canonical scenario definitions and budgets live in `contract.json`; this file
records the measured baseline the budgets were set against. Refresh it (rerun
`pnpm perf` on a quiet machine, update the table, note date + commit) before
tightening any budget.

- **Date:** 2026-07-03
- **Commit:** `bd30142` (harness PR branch; app surface = Phase 0 spike)
- **Environment:** Linux dev container, headless Chromium (Playwright),
  production build via `next start` on localhost, 3 runs per scenario
- **Command:** `pnpm perf` (with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` set,
  remote-sandbox convention)

| Scenario | Metric | Stat | Baseline | Budget | Status |
|---|---|---|---|---|---|
| ttft_mock | ttft_ms | median | 713 | 1500 | pass |
| streaming_cadence | longest_task_ms | max | 0 | 50 | pass |
| transcript_render_200 | — | — | — | — | pending (#745/#748) |
| route_home | lcp_ms | median | 100 | 1200 | pass |
| route_home | tbt_ms | median | 0 | 200 | pass |
| route_home | first_load_js_kb | exact | 103.7 | 200 | pass |
| route_spike | lcp_ms | median | 120 | 1200 | pass |
| route_spike | tbt_ms | median | 2 | 200 | pass |
| route_spike | first_load_js_kb | exact | 158.1 | 200 | pass |
| resume_latency_100 | — | — | — | — | pending (#749) |

Raw samples from the baseline run:

| Scenario | Metric | Samples |
|---|---|---|
| ttft_mock | ttft_ms | 745, 713, 708 |
| streaming_cadence | longest_task_ms | 0, 0, 0 |
| route_home | lcp_ms | 100, 100, 100 |
| route_home | tbt_ms | 0, 1, 0 |
| route_spike | lcp_ms | 120, 112, 128 |
| route_spike | tbt_ms | 0, 2, 10 |

Reading notes:

- `ttft_mock` includes ~600ms of scripted provisioning-status delay in the
  mock turn, so real client+server overhead is roughly 110ms of the median.
- `longest_task_ms` uses the longtask API, which only reports tasks >= 50ms —
  0 means "no long task observed", and any nonzero value exceeds budget.
- `first_load_js_kb` is gzipped KiB from the build manifests; `next build`
  reported 106 kB (/) and 161 kB (/spike) for the same build (kB vs KiB).
- CI (ubuntu-latest) is slower than this container; budgets carry enough
  headroom that route metrics should hold there. If CI runs prove noisy,
  re-baseline from CI numbers rather than widening budgets ad hoc.
