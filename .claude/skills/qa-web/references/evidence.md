# Evidence

Every finding needs durable, reproducible evidence. The repo's merge gate requires uploaded evidence for PRs (see `AGENTS.md` § Evidence-Driven Development).

## Layout

All runtime artifacts land under:

```
output/qa-agent/<ISO-date>/<slug>/
```

`output/` is gitignored. Subdirectories per run are named `<slug>` where `<slug>` is kebab-case and human-meaningful (e.g. `dashboard-color-contrast`, `heal-chat-empty-submit`).

## Contents per finding

| File | Required? | Notes |
|---|---|---|
| `finding.md` | yes | Explanation in user-facing language. See template below. |
| `<page>.png` | yes | Full-page screenshot captured via Playwright at the observation viewport. |
| `<page>-axe.json` | when a11y-related | Full axe output, not just counts. |
| `trace.zip` | optional | Playwright trace if one was recorded. |
| `dom.html` | optional | Snapshot of the relevant DOM region. Useful for Heal regressions. |

## finding.md template

```markdown
# Finding: <one-line imperative — what is wrong or missing>

**Severity:** P0 | P1 | gap | nit
**Page:** <path>
**Viewport:** <w×h>
**Oracle:** <which FEW HICCUPPS / SFDIPOT heuristic>
**Captured:** <ISO date>
**Via:** <qa-probe, Playwright MCP, manual>

## Steps to reproduce
1. ...

## Expected vs Actual
- Expected: <what should happen>
- Actual: <what happened>

## Evidence
- <filename> — description
```

## Upload for PRs

When the caller opens (or updates) a PR based on qa-web findings, upload via:

```bash
./scripts/evidence.sh --pr <N> --name qa-<slug> --file output/qa-agent/<date>/<slug>/<page>.png
```

The script auto-sources `.env` for `EVIDENCE_UPLOAD_TOKEN`. Uploads go to `https://evidence.cloudcompute.com/`.

If `EVIDENCE_UPLOAD_TOKEN` is missing, flag this to the caller as `blocked on evidence` per the repo's merge-gate convention. Do not invent local paths in the PR body.

## Never

- Commit `output/qa-agent/` into git. It's gitignored for a reason — screenshots balloon the repo.
- Reference `output/qa-agent/...` paths in a PR body. Use the uploaded URL from `evidence.sh`.
- Reuse a previous run's evidence. Capture fresh evidence at the commit under review.
