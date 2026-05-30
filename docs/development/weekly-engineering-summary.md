# Weekly Engineering Summary Automation

Use `scripts/weekly-engineering-summary.py` to produce the weekly update with a fixed structure and cross-repo checks.

## Output Template

The script emits:

1. `Scope` (window + repos)
2. `PR Throughput` (counts + notable PRs)
3. `Rollouts / Releases` (releases created inside the window, or latest known release when none landed)
4. `Incidents` (confirmed incident references with state + created/closed timestamps + labels)
5. `Review Signal` (PR review coverage + event counts)
6. `Deltas Vs Previous Window` (PR count and confirmed incident count)

## Default Behavior

- Window start is inferred from the latest `Window reviewed: ... to ...` entry in:
  - `~/.codex/automations/weekly-engineering-summary/memory.md`
- If no reviewed window exists, the script falls back to the latest `- Run time (UTC): ...`.
- Repos included by default:
  - `fairchild/workspaces`
  - `fairchild/services`
  - `fairchild/code-cadence`
- Incident detection query:
  - `incident OR postmortem OR sev OR outage OR rollback OR regression`
- Broad incident-query matches are lifecycle-filtered to the current window.
- Only issues with operational incident signals are reported as confirmed incidents:
  - title contains `prod regression`, `postmortem`, or `outage`
  - label is `incident` or starts with `cd-failure`
- Other broad matches are summarized separately so backlog items such as regression-test coverage are not presented as incidents.

## Usage

```bash
uv run --script scripts/weekly-engineering-summary.py
```

```bash
uv run --script scripts/weekly-engineering-summary.py \
  --since 2026-05-22T23:00:50Z \
  --output /tmp/weekly-summary.md
```

```bash
uv run --script scripts/weekly-engineering-summary.py \
  --repo fairchild/workspaces \
  --repo fairchild/services
```
