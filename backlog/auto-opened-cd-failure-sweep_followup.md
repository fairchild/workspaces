---
status: pending
category: followup
topic: cd-automation
priority: 2
relates_to: backlog/GROOMING.md
description: Sweep accumulating auto-opened CD-failure issues and add a stale-close policy so the auto-opener stops piling up dead tickets against long-stale SHAs.
---

# Sweep accumulating auto-opened CD-failure issues

Surfaced in `backlog/GROOMING.md` (2026-05-24).

## Problem

The CD auto-opener creates GitHub issues per failed run, tagged `auto-opened`+`cd-failure`+`cd-failure:<kind>`, and dispatches an agent (April) to investigate. When the agent doesn't close the loop — or when the underlying SHA is superseded by later commits — the issue lingers indefinitely. Currently 3 open:

- [#357](https://github.com/fairchild/workspaces/issues/357) — `cd-failure:lighthouse`, opened 2026-04-19 against commit `04f5fc82`, no movement since. April was dispatched once (attempt 1/2) and never returned. SHA is 5+ weeks stale.
- [#356](https://github.com/fairchild/workspaces/issues/356) — `cd-failure:playwright`, opened 2026-04-19, last touched 2026-05-14, carries `needs-human`. SHA also 5+ weeks stale.
- [#509](https://github.com/fairchild/workspaces/issues/509) — `cd-failure:prod`+`urgent`, opened 2026-05-25 (today) against commit `69e1e79`. Live; needs triage now.

The pattern: each commit-pinned failure spawns its own issue with no dedup, no stale-close, no rerun-against-current-SHA flow. The queue grows monotonically.

## Sweep (immediate)

1. **#509** — triage. If reproducible on current `main`, leave open with `needs-human`; otherwise rerun CD and close on green.
2. **#357** — close as `wontfix` with a comment noting SHA staleness; rerun lighthouse against current `main` separately, and if it still fails, let the auto-opener file a fresh issue.
3. **#356** — same close-as-stale path; the `needs-human` label suggests a real signal was found but not actioned, so capture any hypothesis from the issue comments in a new ticket before closing if there's anything load-bearing.

## Policy (durable fix)

Decide and implement one of:

- **Stale-close action** — a scheduled GH Action that closes `auto-opened`+`cd-failure` issues with no comment activity for 14 days, leaving a comment that says "closed as stale; rerun CD will reopen if still broken". Lowest mechanism, prevents accumulation.
- **Auto-rerun before re-filing** — modify the auto-opener to first search for an existing open issue with the same `cd-failure:<kind>` label; if one exists, comment on it with the new SHA + run URL instead of opening a fresh issue. Higher fidelity, more code.
- **Both** — stale-close handles abandonment; dedup handles same-kind re-occurrence.

Recommendation: start with stale-close (single workflow file, low risk), add dedup only if accumulation continues after stale-close lands.

## Acceptance

- The three current issues are resolved (closed or actioned).
- A stale-close workflow exists for `label:auto-opened label:cd-failure` issues with N-day inactivity threshold (proposed: 14 days, configurable).
- Workflow has run once successfully against the queue.
- AGENTS.md or CI docs mention the policy so future auto-opener tweaks don't fight it.

## Dependencies

None blocking. Worth doing before the GitHub-issues backend cutover (Phase 5 of grooming) so the queue is clean at handover.

## Notes

- The auto-opener itself likely lives in a `.github/workflows/*.yml` and a Python or TS script under `scripts/` or `web/`. Find it first; it'll inform the dedup option's feasibility.
- The April-dispatch comment pattern suggests the agent was supposed to close the loop. If April is the right place to add "close as stale if rerun is green" logic, that's a third option.
