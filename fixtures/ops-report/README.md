# Ops Report Fixtures

These fixture packs drive [`scripts/ops-report.py`](/Users/fairchild/.codex/worktrees/3272/workspaces/scripts/ops-report.py) in replay mode:

```bash
uv run --script scripts/ops-report.py \
  --fixtures-dir fixtures/ops-report/perf-breach \
  --dry-run \
  --open-idea-on-breach
```

Each scenario directory is complete and self-contained. Required files:

- `repo.json`
- `discussions.json`
- `issues.json`
- `prs.json`
- `runs.json`
- `perf-latest-summary.json`
- `perf-history.csv`

File shapes should mirror the live GitHub/perf inputs that `ops-report.py` already consumes:

- `repo.json`: repo owner/name, with optional `repository_id` and `category_ids`
- `discussions.json`: GitHub GraphQL discussion objects including `comments.nodes`
- `issues.json`: `gh issue list --json ...` style entries
- `prs.json`: `gh pr list --json ...` style entries
- `runs.json`: `gh run list --json ...` style entries
- perf files: same shape as [`docs/performance/latest-summary.json`](/Users/fairchild/.codex/worktrees/3272/workspaces/docs/performance/latest-summary.json) and [`docs/performance/metrics-history.csv`](/Users/fairchild/.codex/worktrees/3272/workspaces/docs/performance/metrics-history.csv)

Scenarios:

- `clean`: no breach, no candidate idea
- `perf-breach`: performance breach candidate
- `ci-breach`: CI reliability breach candidate
- `throughput-breach`: stalled planned work breach candidate
- `deduped`: breach exists, but an open matching ops idea suppresses creation
- `cooldown`: breach exists, but a recently closed matching ops idea suppresses creation
